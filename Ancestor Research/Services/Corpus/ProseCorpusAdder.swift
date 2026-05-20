import Foundation
import os

/// Orchestrator for the user-facing "add a prose corpus" flow (spec §6.2
/// site verification + §3.3 registry write + §3.1 initial manifest).
///
/// The flow is two-stage on purpose: `verify(seedURL:)` does the
/// network probe and returns a `SiteVerification` the UI presents to
/// the user; `commitAdd(...)` is only called after the user confirms.
/// That separation matters because the verification step can take
/// 2–3 seconds (two HTTP round-trips) and the result may surface
/// warnings ("seed is disallowed by robots.txt", "no outbound links")
/// that the user should see before any registry mutation happens.
///
/// `sync(sourceID:)` is the post-add operation — re-run the crawler
/// against an existing source_id using the configuration baked into
/// its `manifest.json`, then update the manifest with post-crawl
/// state (`firstBuiltAt`, `lastSyncedAt`, `pageCount`, `totalBytes`).
/// Background-task scheduling and progress reporting live in the
/// Settings UI layer (P3 commit #3); this type is the pure
/// orchestration substrate.
nonisolated struct ProseCorpusAdder {
    let registry: ProseCorpusRegistry
    let http: any HTTPClient
    /// Injectable clock. Tests pin this so registry/manifest timestamps
    /// are deterministic; production passes `Date.init`.
    let now: @Sendable () -> Date
    /// User-Agent for the verification probe AND for the crawl that
    /// `sync` triggers — kept aligned with the spec §6.1 default so
    /// the host sees one identity across add-time and ongoing syncs.
    let userAgent: String

    init(
        registry: ProseCorpusRegistry,
        http: any HTTPClient,
        userAgent: String = ProseCorpusCrawler.Configuration.defaultUserAgent,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.registry = registry
        self.http = http
        self.userAgent = userAgent
        self.now = now
    }

    private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "ProseCorpusAdder")

    // MARK: - Verify

    /// Probe a candidate seed URL. Fetches the seed and `/robots.txt`,
    /// extracts outbound links, and returns a `SiteVerification` the
    /// UI can present. Always returns a value — never throws — because
    /// every failure mode (DNS, 4xx, timeout, malformed HTML) is
    /// captured in the result so the user sees what went wrong.
    func verify(seedURL: URL) async -> SiteVerification {
        // 1. Robots.txt — fetch first so we can flag a disallowed seed
        //    even before we attempt to fetch the seed page itself.
        let robotsURL = derivedURL(for: seedURL, path: "/robots.txt")
        let robotsResult = await fetch(url: robotsURL)
        let robots: RobotsTxt
        let robotsFetched: Bool
        switch robotsResult {
        case .data(let text):
            robots = RobotsTxt.parse(text, userAgent: userAgent)
            robotsFetched = true
        case .failed, .throttled:
            robots = RobotsTxt.allowAll
            robotsFetched = false
        }

        // 2. Seed page — content + status. We don't currently surface
        //    HTTP status codes through `HTTPClient` so reachability is
        //    a boolean ("we got bytes" vs "we didn't").
        let seedResult = await fetch(url: seedURL)
        switch seedResult {
        case .failed(let reason):
            return SiteVerification(
                seedURL: seedURL,
                reachable: false,
                robotsFetched: robotsFetched,
                seedDisallowedByRobots: robots.isDisallowed(seedURL),
                outboundSameHostLinks: 0,
                outboundExternalLinks: 0,
                seedTitle: nil,
                unreachableReason: reason,
                warnings: ["Seed URL did not return a usable response: \(reason)"]
            )
        case .throttled:
            return SiteVerification(
                seedURL: seedURL,
                reachable: false,
                robotsFetched: robotsFetched,
                seedDisallowedByRobots: robots.isDisallowed(seedURL),
                outboundSameHostLinks: 0,
                outboundExternalLinks: 0,
                seedTitle: nil,
                unreachableReason: "throttled by host (HTTP 429)",
                warnings: ["Host responded with HTTP 429 (throttled). Try again later."]
            )
        case .data(let html):
            let allLinks = LinkExtractor.extract(html: html, baseURL: seedURL)
            var sameHost = 0
            var external = 0
            for link in allLinks {
                if ProseCorpusCrawler.sameRegistrableHost(link, seedURL) {
                    sameHost += 1
                } else {
                    external += 1
                }
            }
            var warnings: [String] = []
            if robots.isDisallowed(seedURL) {
                warnings.append("robots.txt disallows the seed URL itself — the crawl will fetch nothing.")
            }
            if sameHost == 0 {
                warnings.append("No outbound same-host links on the seed page. The crawl will only fetch the seed.")
            }
            return SiteVerification(
                seedURL: seedURL,
                reachable: true,
                robotsFetched: robotsFetched,
                seedDisallowedByRobots: robots.isDisallowed(seedURL),
                outboundSameHostLinks: sameHost,
                outboundExternalLinks: external,
                seedTitle: Self.extractTitle(html: html),
                unreachableReason: nil,
                warnings: warnings
            )
        }
    }

    // MARK: - Commit add

    /// Append a verified corpus to the registry and write its initial
    /// `manifest.json` with `firstBuiltAt: nil` (signalling "added but
    /// never built" to the Settings UI). Idempotent against duplicate
    /// source_id only inasmuch as the caller has used
    /// `registry.availableSourceID(for:)` to derive a fresh id; raw
    /// duplicates throw `RegistryError.duplicateSourceID`.
    ///
    /// Returns an `AddResult` carrying the new entry, a storage handle
    /// for the corpus directory, and the manifest as written.
    @discardableResult
    func commitAdd(
        seedURL: URL,
        displayTitle: String,
        crawlDepth: Int = 4,
        pageBudget: Int = 10_000,
        linkFilter: ProseCorpusCrawler.LinkFilter? = nil
    ) throws -> AddResult {
        let sourceID = try registry.availableSourceID(for: seedURL)
        let nowDate = now()
        let entry = ProseCorpusRegistryEntry(
            sourceID: sourceID,
            displayTitle: displayTitle,
            addedAt: nowDate
        )
        try registry.add(entry)

        let storage = ProseCorpusStorage(
            baseDirectory: registry.baseDirectory,
            sourceID: sourceID
        )
        let manifest = ProseCorpusManifest(
            sourceID: sourceID,
            displayTitle: displayTitle,
            seedURL: seedURL,
            addedByUserAt: nowDate,
            schemaVersion: ProseCorpusManifest.currentSchemaVersion,
            crawlerVersion: ProseCorpusStorage.crawlerVersion,
            crawlDepth: clamp(crawlDepth, min: 1, max: 8),
            linkFilter: linkFilter?.serialised,
            pageBudget: max(1, pageBudget),
            firstBuiltAt: nil,
            lastSyncedAt: nil,
            pageCount: 0,
            totalBytes: 0,
            robotsTxtURL: derivedURL(for: seedURL, path: "/robots.txt"),
            robotsTxtFetchedAt: nil,
            userAgent: userAgent
        )
        try storage.writeManifest(manifest)
        return AddResult(entry: entry, storage: storage, manifest: manifest)
    }

    // MARK: - Sync (run crawl + update manifest)

    /// Run the crawler against an already-added corpus and update its
    /// manifest with post-crawl state. The configuration comes
    /// entirely from the manifest — the user-supplied immutable
    /// add-time fields (`seedURL`, `crawlDepth`, `pageBudget`,
    /// `linkFilter`, `userAgent`) drive the crawl, and the crawl
    /// updates the mutable sync state.
    ///
    /// Returns the `CrawlReport` so the UI can surface stop reasons
    /// (`complete`, `budgetExhausted`, `circuitBreakerExhausted`) and
    /// skip counts. Throws `.unknownSourceID` if no manifest exists for
    /// the id (registry add happened but commitAdd never finished).
    @discardableResult
    func sync(sourceID: String) async throws -> ProseCorpusCrawler.CrawlReport {
        let storage = ProseCorpusStorage(
            baseDirectory: registry.baseDirectory,
            sourceID: sourceID
        )
        guard var manifest = try storage.readManifest() else {
            throw AdderError.unknownSourceID(sourceID)
        }
        let config = ProseCorpusCrawler.Configuration(
            seedURL: manifest.seedURL,
            maxDepth: manifest.crawlDepth,
            pageBudget: manifest.pageBudget,
            linkFilter: ProseCorpusCrawler.LinkFilter(serialised: manifest.linkFilter),
            userAgent: manifest.userAgent
        )
        let crawler = ProseCorpusCrawler(configuration: config, storage: storage, http: http)
        let report = await crawler.crawl()

        // Index refresh — runs over every markdown file the crawler
        // just wrote, content-hash-skipping unchanged pages. Spec
        // §8.2 idempotency means re-running sync against a clean
        // corpus does zero index writes. Failure here is non-fatal:
        // the crawler's pages are on disk; the next sync can retry
        // indexing without re-crawling.
        do {
            let index = try ProseCorpusIndex(path: storage.corpusDirectory.appendingPathComponent("index.sqlite").path)
            let indexer = ProseCorpusIndexer(
                storage: storage,
                index: index,
                gazetteer: LocationGazetteer.shared.all(),
                now: now
            )
            _ = try indexer.refresh()
        } catch {
            // Surface to logs; manifest update still happens so the
            // user sees an updated last_synced_at and page_count.
            Self.logger.error("Index refresh failed for \(sourceID, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        // Update manifest post-crawl. `firstBuiltAt` is set on the
        // first sync that produced at least one page; afterwards it's
        // immutable. `lastSyncedAt` updates every sync.
        let nowDate = now()
        if manifest.firstBuiltAt == nil && report.pagesProcessed > 0 {
            manifest.firstBuiltAt = nowDate
        }
        manifest.lastSyncedAt = nowDate
        manifest.robotsTxtFetchedAt = nowDate
        let stats = try storage.corpusStats()
        manifest.pageCount = stats.pageCount
        manifest.totalBytes = stats.totalBytes
        try storage.writeManifest(manifest)
        return report
    }

    // MARK: - Remove (registry row + corpus directory)

    /// Remove a corpus end-to-end: delete the registry entry and the
    /// entire `<source_id>/` directory tree. Idempotent against
    /// missing source_ids — both halves are no-ops when absent.
    func remove(sourceID: String) throws {
        try registry.remove(sourceID: sourceID)
        try registry.removeCorpusDirectory(sourceID: sourceID)
    }

    // MARK: - Helpers

    /// Construct a sibling URL at a fixed path on the same host as the
    /// seed. Used for `/robots.txt`.
    private func derivedURL(for seedURL: URL, path: String) -> URL {
        guard var components = URLComponents(url: seedURL, resolvingAgainstBaseURL: false) else {
            return seedURL
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url ?? seedURL
    }

    /// One-shot GET that returns the response body decoded as UTF-8
    /// (with a latin-1 fallback for old genealogy sites that serve
    /// windows-1252 without declaring encoding). Mirrors the crawler's
    /// `fetch` semantics so verification behaves like a real crawl
    /// attempt.
    private func fetch(url: URL) async -> FetchOutcome {
        do {
            let data = try await http.get(
                url: url,
                headers: ["User-Agent": userAgent]
            )
            if let s = String(data: data, encoding: .utf8) { return .data(s) }
            if let s = String(data: data, encoding: .isoLatin1) { return .data(s) }
            return .failed("non-decodable response body")
        } catch let error as HTTPError {
            if error.isThrottled { return .throttled }
            return .failed(error.localizedDescription)
        } catch {
            return .failed("\(error)")
        }
    }

    private func clamp(_ v: Int, min: Int, max: Int) -> Int {
        if v < min { return min }
        if v > max { return max }
        return v
    }

    private static func extractTitle(html: String) -> String? {
        let pattern = "<title[^>]*>([\\s\\S]*?)</title\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: html) else { return nil }
        let raw = String(html[r])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\s]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }

    private enum FetchOutcome {
        case data(String)
        case throttled
        case failed(String)
    }

    // MARK: - Output types

    struct AddResult {
        let entry: ProseCorpusRegistryEntry
        let storage: ProseCorpusStorage
        let manifest: ProseCorpusManifest
    }

    enum AdderError: Error, CustomStringConvertible {
        case unknownSourceID(String)

        var description: String {
            switch self {
            case .unknownSourceID(let id):
                return "No manifest found for source ID: \(id)"
            }
        }
    }
}

// MARK: - SiteVerification

/// Result of `ProseCorpusAdder.verify(...)`. Always populated — every
/// failure mode is captured in fields rather than thrown, so the UI
/// has one consistent surface to render.
///
/// Spec §6.2 verification: reachability, robots.txt fetch + seed
/// disallow check, outbound-link count estimate, plus human-readable
/// warnings the UI surfaces alongside the Add button.
nonisolated struct SiteVerification: Sendable, Equatable {
    /// The candidate seed URL the verification was run against.
    let seedURL: URL
    /// Did the seed page return a usable response (any 2xx body)?
    let reachable: Bool
    /// Did `/robots.txt` return a parseable body? `false` does not
    /// fail verification — convention is "no robots.txt = no
    /// restrictions" — but the UI may want to mention it.
    let robotsFetched: Bool
    /// Does the *fetched* robots.txt disallow the seed URL? Always
    /// `false` when `robotsFetched == false` (allow-all default).
    let seedDisallowedByRobots: Bool
    /// Distinct same-host outbound links found on the seed page.
    /// Serves as the user-facing corpus-size estimate (lower bound).
    let outboundSameHostLinks: Int
    /// Distinct external-host outbound links. Informational only —
    /// these will be logged but not followed during the crawl.
    let outboundExternalLinks: Int
    /// `<title>` from the seed page if present. Lets the UI suggest a
    /// sensible default for the corpus display title.
    let seedTitle: String?
    /// One-line reason the seed was unreachable, when `reachable ==
    /// false`. `nil` when the verification succeeded.
    let unreachableReason: String?
    /// Human-readable warnings to surface alongside the Add button —
    /// e.g. "robots.txt disallows the seed URL itself". Empty when the
    /// verification is clean.
    let warnings: [String]

    /// Convenience: is the verification safe to commit unconditionally,
    /// or should the UI require the user to acknowledge warnings?
    var hasBlockingProblems: Bool {
        !reachable || seedDisallowedByRobots
    }
}
