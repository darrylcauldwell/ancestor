import Foundation
import os

/// Generic same-host BFS crawler for the prose-corpus subsystem (spec §6).
///
/// Single-host, single-task. The crawler walks from a user-supplied seed
/// URL, following `<a href>` links that resolve to the same registrable
/// host, respecting `robots.txt`, capping by depth and page budget, and
/// writing each fetched page through `ProseCorpusStorage` (which handles
/// content-hash idempotency).
///
/// Politeness primitives mirror the existing source plugins (`FreeBMDSource`
/// in particular): 500 ms between requests, 429 circuit breaker with a
/// 60s/300s/900s cool-down ladder, fixed User-Agent string. HTTP layer is
/// `SourceHTTPClient.shared` verbatim per spec §6.4 — no new HTTP stack.
///
/// What this v1 deliberately does NOT do (open questions / spec items
/// that need wider plumbing):
///
/// - `If-Modified-Since` conditional GETs (spec §6.1). `HTTPClient`
///   currently abstracts away response headers, so 304 cannot be
///   distinguished from a clean 200. Content-hash idempotency in
///   `ProseCorpusStorage` still satisfies AC-B4 ("zero filesystem writes
///   on unchanged sync") because re-fetching a page that hasn't changed
///   produces the same body and `writePage` returns `.unchanged`. The
///   bandwidth savings of true conditional GETs are a follow-up.
/// - `HEAD` content-type sniffing for ambiguous extensions. Same reason:
///   no header access. Fallback is a URL-extension allow/deny heuristic
///   that catches the common binary types (PDF/JPG/ZIP/…) and lets the
///   converter handle anything else.
/// - Full Public Suffix List. The same-host check normalises `www.`,
///   compares hostnames case-insensitively, AND accepts subdomain
///   parent/child relationships (`staff.example.com` ↔ `example.com`).
///   Sibling subdomains (`a.example.com` ↔ `b.example.com`) need true
///   PSL knowledge to disambiguate from `a.example.co.uk` ↔
///   `b.example.co.uk` and remain TODO.
actor ProseCorpusCrawler {

    // MARK: - Public configuration

    struct Configuration: Sendable {
        let seedURL: URL
        /// 1–12. Capped at init. Default is 10 — biased toward
        /// "grab everything reachable" because the target sites
        /// (parish records, local-history portals, GENUKI-style
        /// volunteer sites) are hand-written HTML with deep nav
        /// hierarchies that aren't depth-optimised.
        ///
        /// Spec §6.2 originally suggested 4 but P8 empirical
        /// testing on Wirksworth (the canonical example) showed
        /// depth-4 captures only ~8% of the site — 174 of 2,187
        /// pages. Volunteer-site hierarchies are commonly 5-7
        /// hops from the seed (index → menu → category → letter
        /// → surname → person → pedigree), and orphan pages
        /// reachable only via in-content cross-references push
        /// even further. The page-budget cap (10,000 default) is
        /// the real safety net against runaway crawls; depth is
        /// just a secondary guard against pathological link
        /// structures (e.g. infinite calendar pages).
        let maxDepth: Int
        /// Spec §6.2 default 10,000.
        let pageBudget: Int
        /// Optional inclusion filter applied to every candidate URL.
        /// `nil` follows everything that passes same-host + depth.
        let linkFilter: LinkFilter?
        /// Identical to existing source plugins. Hard-coded default; the
        /// crawler is unbranded so politeness identification points at
        /// the project's GitHub URL for contact.
        let userAgent: String
        /// Spec §6.1 — 500 ms between consecutive requests.
        let requestDelay: Duration
        /// Skip robots.txt entirely. Default `true`. Tests can flip to
        /// `false` to exercise the crawl loop without staging a robots
        /// fixture.
        let respectRobots: Bool
        /// Skip sitemap.xml discovery. Default `true`. Independent of
        /// `respectRobots` because some sites publish a sitemap but have
        /// no robots file.
        let useSitemap: Bool

        static let defaultUserAgent = "AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"

        init(
            seedURL: URL,
            maxDepth: Int = 10,
            pageBudget: Int = 10_000,
            linkFilter: LinkFilter? = nil,
            userAgent: String = Configuration.defaultUserAgent,
            requestDelay: Duration = .milliseconds(500),
            respectRobots: Bool = true,
            useSitemap: Bool = true
        ) {
            self.seedURL = seedURL
            self.maxDepth = max(1, min(12, maxDepth))
            self.pageBudget = max(1, pageBudget)
            self.linkFilter = linkFilter
            self.userAgent = userAgent
            self.requestDelay = requestDelay
            self.respectRobots = respectRobots
            self.useSitemap = useSitemap
        }
    }

    /// Per-corpus inclusion filter. Glob is shell-style with `*` matching
    /// any character run (no path-segment semantics — `*` matches `/`),
    /// `?` matching a single character. Regex is whatever the user passed.
    enum LinkFilter: Sendable {
        case glob(String)
        case regex(String)

        func matches(_ url: URL) -> Bool {
            let s = url.absoluteString
            switch self {
            case .glob(let pattern):
                let regexPattern = Self.globToRegex(pattern)
                guard let r = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]) else {
                    return true
                }
                let range = NSRange(s.startIndex..., in: s)
                return r.firstMatch(in: s, range: range) != nil
            case .regex(let pattern):
                guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    return true
                }
                let range = NSRange(s.startIndex..., in: s)
                return r.firstMatch(in: s, range: range) != nil
            }
        }

        /// Serialised form used by the manifest's `link_filter` field —
        /// `"glob:<pattern>"` or `"regex:<pattern>"`. Pairs with
        /// `LinkFilter.init(serialised:)` for round-trip.
        var serialised: String {
            switch self {
            case .glob(let pattern): return "glob:\(pattern)"
            case .regex(let pattern): return "regex:\(pattern)"
            }
        }

        /// Parse a manifest-style serialised filter. Returns nil for
        /// nil or empty input, or for an unrecognised kind prefix —
        /// the caller treats those as "follow everything".
        init?(serialised: String?) {
            guard let raw = serialised, !raw.isEmpty else { return nil }
            if raw.hasPrefix("glob:") {
                self = .glob(String(raw.dropFirst("glob:".count)))
            } else if raw.hasPrefix("regex:") {
                self = .regex(String(raw.dropFirst("regex:".count)))
            } else {
                return nil
            }
        }

        private static func globToRegex(_ glob: String) -> String {
            var out = "^"
            for ch in glob {
                switch ch {
                case "*": out.append(".*")
                case "?": out.append(".")
                case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                    out.append("\\")
                    out.append(ch)
                default: out.append(ch)
                }
            }
            out.append("$")
            return out
        }
    }

    // MARK: - Report

    /// Outcome of a single `crawl()` invocation. Populated incrementally
    /// as the BFS runs and returned at the end. Consumers (Settings UI
    /// progress, manifest writer) inspect this directly — there is no
    /// separate `manifest.json` writer here in v1; the crawler returns
    /// the data and the caller (the corpus registry, P3) is responsible
    /// for persisting manifest/external-links state.
    struct CrawlReport: Sendable {
        let seedURL: URL
        var pagesWritten: Int = 0
        var pagesUnchanged: Int = 0
        var pagesRewritten: Int = 0
        var skipped: [Skipped] = []
        var externalLinks: [URL] = []
        var stop: StopReason = .complete
        var startedAt: Date = Date()
        var finishedAt: Date = Date()

        var pagesProcessed: Int { pagesWritten + pagesUnchanged + pagesRewritten }
    }

    struct Skipped: Sendable {
        let url: URL
        let reason: SkipReason
    }

    enum SkipReason: Sendable, Equatable {
        case robotsDisallow
        case linkFilter
        case offHost
        case nonHTMLExtension
        case alreadyVisited
        case beyondDepth
        case fetchFailed(String)
        case parseFailed(String)
    }

    enum StopReason: Sendable, Equatable {
        /// Frontier drained naturally.
        case complete
        /// Hit `pageBudget` before the frontier drained. Partial corpus
        /// is usable; UI may surface this for "widen the cap?" prompts.
        case budgetExhausted
        /// 429 ladder fully consumed. The host has been telling us to
        /// stop for a long time; v1 abandons the run.
        case circuitBreakerExhausted
        /// Seed itself failed before we got a single page. Distinct from
        /// `fetchFailed` because there's no partial corpus to keep.
        case seedFailed(String)
    }

    // MARK: - Dependencies

    private let configuration: Configuration
    private let storage: ProseCorpusStorage
    private let http: any HTTPClient
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "ProseCorpusCrawler")

    /// Callers pass `SourceHTTPClient.shared` for production, or a
    /// `FixtureHTTPClient` for tests. No default value because actor
    /// inits run in a nonisolated context and `SourceHTTPClient.shared`
    /// is main-actor-isolated under this project's Swift 6.2 default
    /// isolation settings.
    init(
        configuration: Configuration,
        storage: ProseCorpusStorage,
        http: any HTTPClient
    ) {
        self.configuration = configuration
        self.storage = storage
        self.http = http
    }

    // MARK: - State (actor-isolated)

    /// FIFO frontier of pending URLs with their distance from the seed.
    /// Plain array used as a queue — pop from front, append at back.
    /// Volunteer genealogy corpora are 10⁴ scale, well below the point
    /// where O(n) shift cost matters.
    private var frontier: [(URL, depth: Int)] = []
    /// Canonicalised URLs we've already processed (or refused). Lookups
    /// dominate frontier admission so a Set keeps this O(1).
    private var visited: Set<String> = []
    /// External-host link URLs encountered during the crawl. Spec §6.2 —
    /// not followed, recorded for diagnostics.
    private var externalLinks: [URL] = []

    /// Slot-reservation pattern lifted from `FreeBMDSource`. Each request
    /// atomically advances `nextRequestSlot` then sleeps until that
    /// moment, guaranteeing serial 500ms-spaced pacing even under actor
    /// reentrancy. The crawler is single-task so reentrancy isn't a
    /// concern today; keeping the pattern keeps the politeness story
    /// uniform across sources.
    private var nextRequestSlot: ContinuousClock.Instant?

    /// 429 circuit breaker — same ladder as `FreeBMDSource` (60s, 300s,
    /// 900s, give up). When `consecutive429s` hits the threshold, the
    /// breaker opens and the crawl pauses until cool-down expires; one
    /// success closes it. After the ladder runs out, `giveUp` is set
    /// and the next request short-circuits to a hard stop.
    private var consecutive429s: Int = 0
    private var circuitOpenUntil: ContinuousClock.Instant?
    private let circuit429Threshold: Int = 3
    private let circuitCooldownLadder: [Duration] = [.seconds(60), .seconds(300), .seconds(900)]
    private var circuitTripCount: Int = 0
    private var giveUp: Bool = false

    // MARK: - Entry point

    /// Run a full crawl from the configured seed URL. Returns a populated
    /// `CrawlReport`; throws only on host-level errors that prevent any
    /// crawling at all (the seed URL is malformed for example). Per-page
    /// failures are recorded in `report.skipped` and the crawl continues.
    func crawl() async -> CrawlReport {
        var report = CrawlReport(seedURL: configuration.seedURL)
        report.startedAt = Date()
        defer { report.finishedAt = Date() }

        // Robots.txt first — Disallow rules gate every subsequent fetch.
        // Failure to fetch robots.txt is non-fatal; we treat absence as
        // "no restrictions" per the de-facto convention.
        let robots: RobotsTxt
        if configuration.respectRobots {
            robots = await fetchRobots(forHost: configuration.seedURL)
        } else {
            robots = RobotsTxt(disallow: [])
        }

        // Sitemap discovery — populate frontier ahead of link walking.
        if configuration.useSitemap {
            let sitemapURLs = await fetchSitemap(forHost: configuration.seedURL)
            for url in sitemapURLs {
                enqueue(url: url, depth: 0)
            }
        }

        // Seed always goes in, even if a sitemap was found.
        enqueue(url: configuration.seedURL, depth: 0)

        // Main BFS loop.
        while !frontier.isEmpty {
            if giveUp {
                report.stop = .circuitBreakerExhausted
                return report
            }
            if report.pagesProcessed >= configuration.pageBudget {
                report.stop = .budgetExhausted
                return report
            }

            let (url, depth) = frontier.removeFirst()
            let canonical = canonicalise(url)
            if visited.contains(canonical) {
                report.skipped.append(Skipped(url: url, reason: .alreadyVisited))
                continue
            }
            visited.insert(canonical)

            if depth > configuration.maxDepth {
                report.skipped.append(Skipped(url: url, reason: .beyondDepth))
                continue
            }
            if configuration.respectRobots, robots.isDisallowed(url) {
                report.skipped.append(Skipped(url: url, reason: .robotsDisallow))
                logger.info("robots.txt disallow skipped \(url.absoluteString, privacy: .public)")
                continue
            }
            if let filter = configuration.linkFilter, !filter.matches(url) {
                report.skipped.append(Skipped(url: url, reason: .linkFilter))
                continue
            }
            if !isLikelyHTML(url: url) {
                report.skipped.append(Skipped(url: url, reason: .nonHTMLExtension))
                continue
            }

            // Park behind the 429 breaker before issuing the request.
            await awaitCircuitClosed()
            if giveUp {
                report.stop = .circuitBreakerExhausted
                return report
            }

            let fetchResult = await fetch(url: url)
            switch fetchResult {
            case .data(let html):
                noteRequestSucceeded()
                let title = extractTitle(html: html)
                let body = HTMLToMarkdownConverter.convert(html)
                do {
                    let outcome = try storage.writePage(
                        sourceURL: url.absoluteString,
                        title: title,
                        body: body
                    )
                    switch outcome {
                    case .written: report.pagesWritten += 1
                    case .unchanged: report.pagesUnchanged += 1
                    case .rewritten: report.pagesRewritten += 1
                    }
                } catch {
                    report.skipped.append(Skipped(url: url, reason: .parseFailed("\(error)")))
                    continue
                }

                // Link discovery — extract outbound href values, classify
                // each as same-host (enqueue) or external (log).
                let links = LinkExtractor.extract(html: html, baseURL: url)
                for link in links {
                    if Self.sameRegistrableHost(link, configuration.seedURL) {
                        enqueue(url: link, depth: depth + 1)
                    } else {
                        // De-dupe externals so we don't blow up the report
                        // when a site has 5,000 links to a shared CDN.
                        if !externalLinks.contains(link) {
                            externalLinks.append(link)
                        }
                    }
                }

            case .throttled:
                noteRequest429()
                // Re-enqueue at the same depth so the URL is retried once
                // the breaker closes. Remove from visited so the re-tried
                // attempt actually runs through the loop again.
                visited.remove(canonical)
                frontier.append((url, depth: depth))

            case .failed(let reason):
                report.skipped.append(Skipped(url: url, reason: .fetchFailed(reason)))
            }
        }

        report.externalLinks = externalLinks
        return report
    }

    // MARK: - Frontier admission

    /// Enqueue a URL if not already known. The visited Set is the source
    /// of truth for "is this URL pending or processed?" — frontier
    /// duplicates are filtered at dequeue time instead.
    private func enqueue(url: URL, depth: Int) {
        let canonical = canonicalise(url)
        guard !visited.contains(canonical) else { return }
        // Pre-emptive depth check — saves enqueue noise for far-out links.
        guard depth <= configuration.maxDepth else { return }
        frontier.append((url, depth: depth))
    }

    /// Normalise a URL for visited-set membership. Strip the fragment
    /// (anchors point at the same document), lowercase host, default
    /// "/" path when empty. Query string is preserved — query-driven
    /// pages on a single path serve distinct content.
    nonisolated private func canonicalise(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.fragment = nil
        c.host = c.host?.lowercased()
        if c.path.isEmpty { c.path = "/" }
        return c.url?.absoluteString ?? url.absoluteString
    }

    // MARK: - Same-host check

    /// Compare two URLs for "registrable host equality" — should the
    /// crawler treat them as the same site for the purpose of link
    /// following and seed verification.
    ///
    /// Three accepted relationships:
    ///   1. Identical hosts (after lowercasing and `www.` strip).
    ///   2. `www.` ↔ bare equivalence — already covered by normalisation.
    ///   3. Parent/child subdomain relationship — `staff.example.com`
    ///      and `example.com` are the same site for crawl purposes.
    ///      Implemented by suffix check with a leading `.` to avoid
    ///      `attacker-example.com` matching `example.com` (the leading
    ///      `.` requires a real subdomain boundary).
    ///
    /// Not yet handled — sibling subdomains (`staff.example.com` ↔
    /// `news.example.com`). Distinguishing these from siblings under a
    /// public suffix (`a.example.co.uk` ↔ `b.example.co.uk`, which
    /// would also be siblings of the registrable domain) needs PSL
    /// knowledge. The conservative choice is to reject sibling
    /// subdomains; the parent/child case is the one the target
    /// genealogy sites actually need.
    ///
    /// Static so the site verifier (P3 add-corpus flow) can call it
    /// without instantiating a crawler. Same-host logic lives in one
    /// place — moving it would scatter the registrable-host contract.
    nonisolated static func sameRegistrableHost(_ a: URL, _ b: URL) -> Bool {
        guard let ha = normaliseHost(a), let hb = normaliseHost(b) else { return false }
        if ha == hb { return true }
        // Parent/child subdomain. The leading `.` in the suffix check
        // is load-bearing — without it `attacker-example.com` would
        // match `example.com`.
        if ha.hasSuffix("." + hb) { return true }
        if hb.hasSuffix("." + ha) { return true }
        return false
    }

    nonisolated static func normaliseHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: - URL-extension content-type guard

    /// Best-effort filter against obvious non-HTML extensions. Returns
    /// `true` (proceed with GET) when the extension is HTML-flavoured
    /// or unknown — the converter copes with surprises; the binary
    /// list is the conservative gate. Spec §6.2 calls for HEAD-based
    /// verification on ambiguous extensions; absent header support on
    /// `HTTPClient`, this is the v1 fallback.
    nonisolated private func isLikelyHTML(url: URL) -> Bool {
        let path = url.path.lowercased()
        let nonHTML: Set<String> = [
            "pdf", "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "webp", "svg",
            "zip", "tar", "gz", "rar", "7z",
            "mp3", "mp4", "mov", "avi", "wav", "ogg",
            "doc", "docx", "xls", "xlsx", "ppt", "pptx",
            "exe", "dmg", "pkg", "deb", "rpm",
            "css", "js", "json", "xml", "rss", "atom",
        ]
        for ext in nonHTML {
            if path.hasSuffix(".\(ext)") { return false }
        }
        return true
    }

    // MARK: - Fetch + politeness

    private enum FetchResult {
        case data(String)
        case throttled
        case failed(String)
    }

    private func fetch(url: URL) async -> FetchResult {
        let scheduledFor = reserveNextSlot()
        let now = ContinuousClock.now
        if scheduledFor > now {
            try? await Task.sleep(until: scheduledFor, clock: .continuous)
        }
        do {
            let data = try await http.get(
                url: url,
                headers: ["User-Agent": configuration.userAgent]
            )
            guard let s = String(data: data, encoding: .utf8) else {
                // Try latin-1 as a fallback — many old genealogy sites
                // serve windows-1252 without declaring encoding.
                if let s = String(data: data, encoding: .isoLatin1) {
                    return .data(s)
                }
                return .failed("non-decodable response body")
            }
            return .data(s)
        } catch let error as HTTPError {
            if error.isThrottled { return .throttled }
            return .failed(error.localizedDescription)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Atomically (within the actor's serial section, no await) compute
    /// the next allowed request time and advance `nextRequestSlot`.
    private func reserveNextSlot() -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        let scheduledFor: ContinuousClock.Instant
        if let nextSlot = nextRequestSlot, nextSlot > now {
            scheduledFor = nextSlot
        } else {
            scheduledFor = now
        }
        nextRequestSlot = scheduledFor.advanced(by: configuration.requestDelay)
        return scheduledFor
    }

    /// Block until the 429 circuit breaker closes. Mirrors the FreeBMD
    /// pattern: the first request to find the timer expired clears the
    /// state and resets the counter so subsequent successes don't get
    /// charged for a stale trip.
    private func awaitCircuitClosed() async {
        guard let until = circuitOpenUntil else { return }
        let now = ContinuousClock.now
        if until > now {
            try? await Task.sleep(until: until, clock: .continuous)
        }
        circuitOpenUntil = nil
        consecutive429s = 0
    }

    private func noteRequest429() {
        consecutive429s += 1
        guard consecutive429s >= circuit429Threshold && circuitOpenUntil == nil else { return }
        let trip = circuitTripCount
        circuitTripCount += 1
        if trip >= circuitCooldownLadder.count {
            giveUp = true
            return
        }
        let cooldown = circuitCooldownLadder[trip]
        circuitOpenUntil = ContinuousClock.now.advanced(by: cooldown)
        logger.warning("Circuit breaker tripped (count=\(trip + 1)/\(self.circuitCooldownLadder.count)); pausing for \(String(describing: cooldown))")
    }

    private func noteRequestSucceeded() {
        if consecutive429s > 0 {
            consecutive429s = 0
            circuitTripCount = 0
        }
    }

    // MARK: - Robots.txt fetch

    private func fetchRobots(forHost url: URL) async -> RobotsTxt {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return RobotsTxt(disallow: [])
        }
        components.path = "/robots.txt"
        components.query = nil
        components.fragment = nil
        guard let robotsURL = components.url else { return RobotsTxt(disallow: []) }
        // Robots is one request — share the same rate-limit slot so we
        // don't burst on the very first run.
        let result = await fetch(url: robotsURL)
        switch result {
        case .data(let text):
            return RobotsTxt.parse(text, userAgent: configuration.userAgent)
        case .throttled, .failed:
            // Non-fatal — convention is "no robots.txt = no restrictions".
            return RobotsTxt(disallow: [])
        }
    }

    // MARK: - Sitemap discovery

    private func fetchSitemap(forHost url: URL) async -> [URL] {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return []
        }
        components.path = "/sitemap.xml"
        components.query = nil
        components.fragment = nil
        guard let sitemapURL = components.url else { return [] }
        let result = await fetch(url: sitemapURL)
        switch result {
        case .data(let text):
            return Sitemap.extractURLs(from: text)
        case .throttled, .failed:
            return []
        }
    }

    // MARK: - Title extraction

    /// Pull the first `<title>` tag content from a raw HTML document.
    /// Falls back to the first `<h1>`. Returns nil if neither exists —
    /// `PageFrontmatter.title` is optional for exactly this reason.
    nonisolated private func extractTitle(html: String) -> String? {
        if let t = firstTagContent(html: html, tag: "title") {
            return t
        }
        if let h = firstTagContent(html: html, tag: "h1") {
            return h
        }
        return nil
    }

    nonisolated private func firstTagContent(html: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let raw = String(html[r])
        // Strip inner tags + collapse whitespace; titles often have
        // nested span/font markup that the converter would discard but
        // we want a flat string here.
        let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let collapsed = stripped
            .replacingOccurrences(of: "[\\s]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return collapsed.isEmpty ? nil : collapsed
    }
}

// MARK: - Robots.txt

/// Minimal robots.txt model — `Disallow` paths only, applied against the
/// crawler's User-Agent (and `*` as fallback). No `Allow`, no
/// `Crawl-delay` (we have our own 500 ms slot already), no `Sitemap`
/// directive (we fetch `/sitemap.xml` directly).
///
/// Path matching follows the de-facto convention: prefix-match against
/// the URL's path, with `*` treated as wildcard. Empty `Disallow:`
/// allows everything; `Disallow: /` blocks everything.
nonisolated struct RobotsTxt: Sendable, Equatable {
    let disallow: [String]

    static let allowAll = RobotsTxt(disallow: [])

    func isDisallowed(_ url: URL) -> Bool {
        let path = url.path.isEmpty ? "/" : url.path
        for rule in disallow {
            if rule.isEmpty { continue }
            if matches(path: path, rule: rule) { return true }
        }
        return false
    }

    private func matches(path: String, rule: String) -> Bool {
        // Trivial case: literal prefix.
        if !rule.contains("*") {
            return path.hasPrefix(rule)
        }
        // Wildcard match. Translate `*` to regex `.*` and anchor at the
        // start (de-facto robots.txt semantics).
        var pattern = "^"
        for ch in rule {
            switch ch {
            case "*": pattern.append(".*")
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "?", "\\":
                pattern.append("\\")
                pattern.append(ch)
            default: pattern.append(ch)
            }
        }
        guard let r = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(path.startIndex..., in: path)
        return r.firstMatch(in: path, range: range) != nil
    }

    /// Parse a robots.txt body, returning the disallow rules that apply
    /// to `userAgent`. Lookup order: rules under `User-agent: <exact
    /// product token>` first, falling back to `User-agent: *`. If both
    /// exist, only the more-specific block applies (de-facto robots.txt
    /// behaviour — most-specific group wins).
    static func parse(_ text: String, userAgent: String) -> RobotsTxt {
        // Reduce the UA to its product token: everything before the
        // first whitespace or `/`. "AncestorResearch/1.0 (…)" → "ancestorresearch".
        let product = productToken(of: userAgent)

        // Walk groups separated by blank line(s). Each group has one or
        // more User-agent lines and a set of Disallow lines.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

        var groups: [(agents: [String], disallow: [String])] = []
        var currentAgents: [String] = []
        var currentDisallow: [String] = []
        var inGroup = false

        func flush() {
            if !currentAgents.isEmpty {
                groups.append((currentAgents, currentDisallow))
            }
            currentAgents = []
            currentDisallow = []
            inGroup = false
        }

        for rawLine in lines {
            // Strip comments.
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if inGroup { flush() }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "user-agent":
                if !currentDisallow.isEmpty {
                    // New UA after a Disallow → start a new group.
                    flush()
                }
                currentAgents.append(value.lowercased())
                inGroup = true
            case "disallow":
                inGroup = true
                currentDisallow.append(value)
            default:
                continue
            }
        }
        flush()

        // Prefer the most-specific group: any group whose agent list
        // contains the product token wins; otherwise fall back to `*`.
        var specific: [String]? = nil
        var wildcard: [String]? = nil
        for group in groups {
            if group.agents.contains(product) { specific = group.disallow }
            if group.agents.contains("*") { wildcard = group.disallow }
        }
        let resolved = specific ?? wildcard ?? []
        return RobotsTxt(disallow: resolved)
    }

    private static func productToken(of userAgent: String) -> String {
        // "AncestorResearch/1.0 (...)" → "ancestorresearch"
        let lower = userAgent.lowercased()
        if let slash = lower.firstIndex(of: "/") {
            return String(lower[..<slash])
        }
        if let space = lower.firstIndex(where: { $0.isWhitespace }) {
            return String(lower[..<space])
        }
        return lower
    }
}

// MARK: - Sitemap parsing

/// Minimal sitemap.xml extractor — pulls `<loc>` values from a sitemap
/// or sitemap-index. Doesn't follow nested sitemaps in v1 because the
/// volunteer-site corpora we target rarely use sitemap indexes; future
/// versions can recurse. Tolerant of malformed XML — uses regex rather
/// than a full XML parser to avoid pulling in XMLParser delegate state.
nonisolated enum Sitemap {
    static func extractURLs(from xml: String) -> [URL] {
        let pattern = "<loc>([\\s\\S]*?)</loc>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(xml.startIndex..., in: xml)
        var out: [URL] = []
        for match in regex.matches(in: xml, range: range) {
            guard match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: xml) else { continue }
            let raw = String(xml[r])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                // Some sitemaps wrap <loc> values in CDATA.
                .replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: raw) {
                out.append(url)
            }
        }
        return out
    }
}

// MARK: - Link extraction

/// Pull outbound `<a href>` values from HTML, resolving each against the
/// page's base URL. Skips `mailto:`, `javascript:`, `tel:`, and anchor-
/// only fragments. Output is in document order, de-duplicated within
/// the page.
///
/// Implemented as a separate type from `HTMLToMarkdownConverter` so
/// link discovery can run on the raw HTML (links inside chrome blocks
/// matter for site-map building even when the converter strips them
/// from the body — Wirksworth's pedigree index pages are entirely
/// chrome-shaped, every useful link lives inside a navigation block).
nonisolated enum LinkExtractor {
    /// Captures `<a href=...>` in three flavours seen in genealogy
    /// volunteer HTML:
    ///   `<a href="...">`   — double-quoted (modern)
    ///   `<a href='...'>`   — single-quoted
    ///   `<a href=...>`     — bare / unquoted (1990s-era hand-coded)
    ///
    /// Wirksworth's index, for example, uses the unquoted form for
    /// most of its menu bar (`<A HREF=ARTICLES.htm>Articles</A>`)
    /// while sprinkling quoted hrefs elsewhere. The earlier
    /// quoted-only regex silently dropped every unquoted link and
    /// produced ~13% coverage vs the site's self-reported 2,187
    /// pages on a depth-10 crawl. Capture groups are alternatives:
    /// only one is non-empty per match; the extractor picks the
    /// first non-empty.
    static func extract(html: String, baseURL: URL) -> [URL] {
        let pattern = #"<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        var seen: Set<String> = []
        var out: [URL] = []
        for match in regex.matches(in: html, range: range) {
            // Three capture groups, exactly one matches.
            var raw: String?
            for groupIndex in 1...3 where match.range(at: groupIndex).location != NSNotFound {
                if let r = Range(match.range(at: groupIndex), in: html) {
                    raw = String(html[r]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            guard let rawHref = raw, !rawHref.isEmpty else { continue }
            let lower = rawHref.lowercased()
            if lower.hasPrefix("javascript:") || lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") {
                continue
            }
            if rawHref.hasPrefix("#") { continue }
            guard let resolved = URL(string: rawHref, relativeTo: baseURL)?.absoluteURL else { continue }
            // Strip the fragment for de-dup — anchors point at the same
            // document so we don't fetch it twice.
            var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) ?? URLComponents()
            components.fragment = nil
            guard let normalised = components.url else { continue }
            let key = normalised.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(normalised)
        }
        return out
    }
}
