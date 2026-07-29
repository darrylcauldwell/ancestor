import Foundation
import os

/// FreeCen — volunteer transcription of England & Wales census records 1841–1911
/// https://www.freecen.org.uk
/// Access: POST form with CSRF token
/// Auth: None (CSRF token obtained automatically)
/// Coverage: Census records 1841–1911, coverage varies by county
actor FreeCenSource: RecordSource, DetailFetchingSource {

    // MARK: - RecordSource Protocol

    nonisolated let sourceID = "freecen"
    nonisolated let scopeHandling: ScopeHandling = .scoped
    nonisolated let displayName = "FreeCen"
    nonisolated let descriptiveName = "UK Census Transcriptions (FreeCen)"
    nonisolated let recordTypes: Set<RecordType> = [.census]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1841...1911
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "Census-enumeration-books")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(
        level: .restricted,
        summary: "Terms forbid programmatic search (\"front end programs… strictly forbidden\") — permission request to Free UK Genealogy pending, ADR-008"
    )

    /// Conservative daily budget (ENGINE_FOUNDATION #Change5). FreeCen is
    /// volunteer-run with no documented quota; observed behaviour is that
    /// sustained sweeps get rate-limited. A per-census-year × chapman
    /// fan-out means one subject can fire many FreeCen requests, so we set
    /// a conservative ceiling that parks the source until UTC midnight once
    /// a sustained run has taken more than a normal session's worth.
    nonisolated let budgetPolicy = SourceBudgetPolicy(dailyLimit: 300, reset: .utcMidnight)

    // MARK: - State

    private let http: any HTTPClient

    init(http: any HTTPClient = SourceHTTPClient.shared) {
        self.http = http
    }
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FreeCen")
    /// Scheduled time for the next allowable request. Slot-reservation pattern
    /// (see FreeBMDSource for the full rationale): callers advance the slot
    /// synchronously inside the actor so concurrent search() calls each get a
    /// unique wakeup instant rather than reading the same stale timestamp.
    private var nextRequestSlot: ContinuousClock.Instant?
    private let requestDelay: Duration = .milliseconds(500)

    // Session state
    private var sessionCookie: String?
    private var csrfToken: String?
    /// In-flight session-establishment task. Without this latch, concurrent
    /// search() calls all race past the `sessionCookie == nil` check and each
    /// fetch the form page independently — wasteful and occasionally trips the
    /// connection pool. With the latch, the first caller does the fetch and
    /// every other caller awaits the same task.
    private var sessionEstablishmentTask: Task<Void, Error>?

    private var lastSuccessfulSearch: Date?
    private var lastError: String?

    // MARK: - Constants

    nonisolated private static let baseURL = "https://www.freecen.org.uk"
    nonisolated private static let searchFormURL = URL(string: "\(baseURL)/search_records")!
    nonisolated private static let searchURL = URL(string: "\(baseURL)/search_queries")!
    nonisolated private static let userAgent = "AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"
    /// FreeCen's `record_type` select only has options for the census
    /// years — enforced by the FT-14 guard in `searchWithOutcome`.
    /// Internal (not private) so the guard tests can reference the set.
    nonisolated static let validYears: Set<Int> = [1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911]
    /// FT-22 (fetching half) — total-results budget across pagination,
    /// mirroring `ProbateSource.maxResults` (Python parity:
    /// probate.py:130 `max_results=500`), plus a defensive page cap:
    /// FreeCen's per-page size is unverified (audit FT-27 — the live
    /// form payload never arrived), so the page cap bounds worst-case
    /// volunteer-source load even if pages turn out tiny. Every page
    /// fetch rides the existing 500 ms politeness pacing. Internal so
    /// the paging tests reference the budgets instead of hardcoding.
    nonisolated static let maxResults = 500
    nonisolated static let maxPages = 10

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        await searchWithOutcome(query).result
    }

    /// Envelope-aware search (connector-audit T1-01; instances FT-22 /
    /// FT-23). Parses the site's own "We found N Results" hit count,
    /// triages the page state (FT-20/FT-26), and walks the pagination
    /// nav up to a conservative budget (FT-22 fetching half) so a
    /// multi-page answer is no longer silently truncated to page 1.
    func searchWithOutcome(_ query: RecordQuery) async -> SourceSearchEnvelope {
        guard query.recordType == .census else { return SourceSearchEnvelope(.outsideCoverage(reason: "FreeCen only provides census records")) }
        guard let surname = query.surname, !surname.isEmpty else { return SourceSearchEnvelope(.results([])) }

        // FreeCen is chapman-coded on two axes (FT-11): residence
        // (`chapman_codes[]` — where the subject lived at census time)
        // and birth county (`birth_chapman_codes[]` — where they were
        // born, the tree-known stable fact). Without at least one axis
        // the query cannot be scoped, so degrade honestly instead of
        // guessing a county.
        // FT-25 — the residence axis (`chapman_codes[]`) may carry a BATCH
        // of codes in one request via repeated keys; the birth axis
        // (`birth_chapman_codes[]`) stays single (the dispatcher scopes
        // broad census sweeps by birth county as ONE code, so there is no
        // birth-axis fan-out to batch). A non-empty batch supersedes the
        // single residence code; order is preserved for a stable wire shape.
        var residenceChapmanCodes: [String] = []
        var birthChapman: String?
        if case .freeCen(let p) = query.sourceParams {
            residenceChapmanCodes = FreeCenSource.resolveResidenceCodes(batch: p.chapmanCodes, single: p.chapmanCode)
            if let code = p.birthChapmanCode, !code.isEmpty { birthChapman = code }
        }
        guard !residenceChapmanCodes.isEmpty || birthChapman != nil else {
            return SourceSearchEnvelope(.outsideCoverage(reason: "No home county (Chapman code) available to scope a FreeCen search"))
        }

        // FT-14 — resolve the census year: prefer the typed param
        // (previously write-only), fall back to `query.yearFrom` (the
        // main dispatcher sets both identically; the strategist's
        // FocusedQuery path sets only yearFrom). Then guard: FreeCen's
        // `record_type` select only has options for the census years,
        // so an off-year (an MLX-suggested "FreeCen 1885") would put a
        // non-existent option value on the wire — a silent zero or a
        // Rails validation page. Python guards exactly this ("Invalid
        // census year", sources/freecen.py:165-166). `.outsideCoverage`
        // names the valid set and is never cached as a negative.
        let paramCensusYear: Int? = {
            if case .freeCen(let p) = query.sourceParams { return p.censusYear }
            return nil
        }()
        let year = paramCensusYear ?? query.yearFrom
        if let requested = year, !Self.validYears.contains(requested) {
            let valid = Self.validYears.sorted().map(String.init).joined(separator: ", ")
            return SourceSearchEnvelope(.outsideCoverage(
                reason: "\(requested) is not a census year FreeCen holds (valid: \(valid))"
            ))
        }

        let scopeLabel = Self.residenceScopeLabel(residenceChapmanCodes)
            ?? birthChapman.map { "born \($0)" } ?? ""
        let summary = Self.activitySummary(query: query, surname: surname, chapmanCode: scopeLabel, censusYear: year)
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary, strictness: query.strictness))

        do {
            try await ensureSession()

            // RESEARCH_AXES_SPEC Change 5/6: FreeCen exposes a soundex toggle
            // (the form's "Name Soundex" checkbox). .loose flips it on for
            // server-side fuzzy matching. .variant is the dispatcher tier
            // marker — the surname has already been substituted to a variant
            // before arriving here, so the variant probe is exact-match.
            let fuzzyFlag = query.strictness == .loose ? "1" : "0"

            // Sex filter: FreeCen's select takes "M"/"F"/"" — narrows
            // common-name results (Smith, Jones) by ~50%. Unknown/other
            // genders fall through to empty so we don't accidentally
            // erase legitimate hits. Spec §23.
            let sexValue: String = {
                switch query.gender {
                case .male: return "M"
                case .female: return "F"
                default: return ""
                }
            }()

            // FreeCenParams.birthYearRange narrows the census-year sweep
            // by birth year. Without it FreeCen returns every census-year
            // record of every "John Smith" — useless for disambiguation.
            // start_year / end_year are inclusive integer years; absent
            // params leave them blank for backwards compatibility.
            let (startYear, endYear): (String, String) = {
                guard case .freeCen(let p) = query.sourceParams,
                      let range = p.birthYearRange else { return ("", "") }
                return (String(range.lowerBound), String(range.upperBound))
            }()

            // FT-25 — ordered pairs (not a dict) so a batched residence
            // axis emits one repeated `search_query[chapman_codes][]` key
            // per code and they all survive on the wire.
            var fields: [(String, String)] = [
                ("utf8", "✓"),
                ("authenticity_token", csrfToken ?? ""),
                ("search_query[last_name]", surname),
                ("search_query[first_name]", query.givenName ?? ""),
                ("search_query[record_type]", year.map(String.init) ?? ""),
                ("search_query[fuzzy]", fuzzyFlag),
                ("search_query[search_nearby_places]", "0"),
                ("search_query[disabled]", "0"),
                ("search_query[start_year]", startYear),
                ("search_query[end_year]", endYear),
                ("search_query[sex]", sexValue),
                ("search_query[marital_status]", ""),
                ("search_query[occupation]", ""),
            ]
            // FT-11 — the two county axes are independent. The residence
            // filter is OMITTED entirely when scoping by birth county
            // (an absent Rails array param means "no residence filter"),
            // letting one request cover every residence county server-side.
            // FT-25 — one repeated residence key per batched code; a single
            // residence code emits exactly one pair (byte-identical to the
            // pre-FT-25 single-value shape).
            for code in residenceChapmanCodes {
                fields.append(("search_query[chapman_codes][]", code))
            }
            if let birthChapman {
                fields.append(("search_query[birth_chapman_codes][]", birthChapman))
            }

            let data = try await rateLimitedRequest {
                try await self.http.postForm(
                    url: Self.searchURL,
                    multiFields: fields,
                    headers: [
                        "User-Agent": Self.userAgent,
                        "Cookie": self.sessionCookie ?? "",
                        "Referer": "\(Self.baseURL)/search_records",
                    ],
                    timeout: 60
                )
            }

            guard let html = String(data: data, encoding: .utf8) else {
                await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: "Invalid encoding", strictness: query.strictness))
                return SourceSearchEnvelope(.unavailable(reason: "Invalid encoding"))
            }

            // FT-26 / FT-20 — page-state triage. Only a positively
            // identified results page may yield records, and only a
            // positively identified no-results page may yield a clean
            // empty; anything else (validation error, login wall,
            // layout drift) is `.unavailable`, never a cacheable [].
            switch Self.classifyResultsPage(html) {
            case .empty:
                lastSuccessfulSearch = Date()
                lastError = nil
                logger.info("Search returned 0 results for \(surname)")
                await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: 0, strictness: query.strictness))
                return SourceSearchEnvelope(result: .results([]), outcome: SearchOutcome(resultCount: 0))
            case .unparseable(let reason):
                lastError = reason
                logger.warning("FreeCen page not parseable as results: \(reason)")
                await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: reason, strictness: query.strictness))
                return SourceSearchEnvelope(.unavailable(reason: reason))
            case .results:
                break
            }

            var results = Self.parseSearchResults(html, censusYear: year)
            // FT-23: the site's own claimed hit count.
            let totalAvailable = Self.parseResultCount(html)

            // FT-22 (fetching half) — walk the pagination nav through the
            // existing 500 ms pacing, bounded by the record budget and the
            // defensive page cap. Stops on: no next link, a page that
            // yields no parsable rows, or budget exhaustion.
            var nextPage = Self.nextPageURL(html)
            var pagesFetched = 1
            while let next = nextPage.flatMap(URL.init(string:)),
                  pagesFetched < Self.maxPages,
                  results.count < Self.maxResults {
                // A failed follow-up page must not discard the pages
                // already in hand — break and let `truncated` say the
                // answer is partial.
                guard let pageData = try? await rateLimitedRequest({
                    try await self.http.get(url: next, headers: [
                        "User-Agent": Self.userAgent,
                        "Cookie": self.sessionCookie ?? "",
                    ])
                }), let pageHTML = String(data: pageData, encoding: .utf8) else { break }
                let pageRecords = Self.parseSearchResults(pageHTML, censusYear: year)
                guard !pageRecords.isEmpty else { break }
                results += pageRecords
                pagesFetched += 1
                nextPage = Self.nextPageURL(pageHTML)
            }

            // Honest truncation AFTER paging (FT-22/FT-23): trust the
            // site's own count when parsed; otherwise an unconsumed
            // next-link means the budget (or a parse miss) cut the
            // answer short.
            let truncated = totalAvailable.map { results.count < $0 }
                ?? (nextPage != nil)
            // Enrich the top hit with household composition so the
            // verdict-emitter has parent-surname tokens to intersect.
            // Python's pattern caps at 5 (agent/discover.py:195), but
            // FreeCen's rate-limited detail fetches blow up wall time
            // on common surnames at that cap — a single 12-subject
            // harness run took ~3h. The verdict-emitter only needs
            // *one* household with parent surnames; the top hit is
            // ranked by name+year match and almost always the right
            // person. Higher cap stays available for future per-
            // subject deepening.
            let enriched = await enrichWithHousehold(results, cap: 1)
            lastSuccessfulSearch = Date()
            lastError = nil
            logger.info("Search returned \(enriched.count) of \(totalAvailable ?? enriched.count) results for \(surname)")
            await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: enriched.count, strictness: query.strictness))
            return SourceSearchEnvelope(
                result: .results(enriched),
                outcome: SearchOutcome(
                    resultCount: enriched.count,
                    totalAvailable: totalAvailable,
                    truncated: truncated
                )
            )

        } catch {
            lastError = error.localizedDescription
            logger.warning("Search failed: \(error.localizedDescription)")
            sessionCookie = nil
            csrfToken = nil
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription, strictness: query.strictness))
            return SourceSearchEnvelope(.unavailable(reason: error.localizedDescription))
        }
    }

    /// FT-25 — resolve the RESIDENCE chapman code(s) for the wire. A
    /// non-empty batch (`chapmanCodes`, blanks dropped) wins over the
    /// single residence code; a non-empty single code is the sole
    /// fallback. Empty in both = no residence axis (the birth axis, if
    /// set, scopes the query instead). nonisolated + static so the
    /// query-shape tests can pin the precedence.
    nonisolated static func resolveResidenceCodes(batch: [String]?, single: String?) -> [String] {
        if let batch {
            let cleaned = batch.filter { !$0.isEmpty }
            if !cleaned.isEmpty { return cleaned }
        }
        if let single, !single.isEmpty { return [single] }
        return []
    }

    /// Activity-feed label for the residence axis: the single code, or
    /// "N counties" for a batch; nil when the residence axis is empty (the
    /// caller falls back to the birth-axis label).
    nonisolated static func residenceScopeLabel(_ codes: [String]) -> String? {
        switch codes.count {
        case 0: return nil
        case 1: return codes[0]
        default: return "\(codes.count) counties"
        }
    }

    /// Build a one-line description of a FreeCen query for the live activity feed.
    nonisolated static func activitySummary(query: RecordQuery, surname: String, chapmanCode: String, censusYear: Int?) -> String {
        let searchTerms: String = {
            if let given = query.givenName, !given.isEmpty { return "\(given) \(surname)" }
            return surname
        }()
        let yearLabel = censusYear.map { " \($0) census" } ?? " census"
        return "FreeCen \(chapmanCode)\(yearLabel): \(searchTerms)"
    }

    /// Replace the first `cap` census records with their household-
    /// enriched form (via fetchDetail). Records past the cap or
    /// without a usable detail URL pass through untouched. Detail
    /// failures fall back to the un-enriched record.
    private func enrichWithHousehold(_ records: [SourceRecord], cap: Int) async -> [SourceRecord] {
        var out: [SourceRecord] = []
        out.reserveCapacity(records.count)
        var enrichedCount = 0
        for record in records {
            guard enrichedCount < cap,
                  case .census(let census) = record,
                  let url = census.common.detailURL,
                  !url.isEmpty,
                  census.household == nil else {
                out.append(record)
                continue
            }
            enrichedCount += 1
            let result = await fetchDetail(recordID: url)
            if case .results(let detailRecords) = result,
               let detail = detailRecords.first {
                out.append(detail)
            } else {
                // Couldn't enrich (rate limit, parser miss, etc.).
                // Keep the original search-result row.
                out.append(record)
            }
        }
        return out
    }

    // MARK: - Detail Fetching (household)

    func fetchDetail(recordID: String) async -> SourceQueryResult {
        // recordID is the full URL
        // This method is called with the detailURL from the search result
        guard let url = URL(string: recordID) else {
            return .unavailable(reason: "Invalid URL: \(recordID)")
        }

        do {
            let data = try await rateLimitedRequest {
                try await self.http.get(url: url, headers: ["User-Agent": Self.userAgent])
            }
            guard let html = String(data: data, encoding: .utf8) else {
                return .unavailable(reason: "Invalid encoding")
            }
            if let record = Self.parseHouseholdDetail(html, recordURL: recordID) {
                return .results([record])
            }
            return .results([])
        } catch {
            logger.warning("Detail fetch failed: \(error.localizedDescription)")
            return .unavailable(reason: error.localizedDescription)
        }
    }

    // MARK: - Session Management

    /// Fetch a fresh session cookie and CSRF token from FreeCen.
    /// Concurrent callers all await the same establishment task — only one
    /// network fetch happens at a time even when many search() calls queue
    /// at the actor.
    private func ensureSession() async throws {
        if sessionCookie != nil { return }
        if let inFlight = sessionEstablishmentTask {
            try await inFlight.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            try await self?.performSessionEstablishment()
        }
        sessionEstablishmentTask = task
        defer { sessionEstablishmentTask = nil }
        try await task.value
    }

    private func performSessionEstablishment() async throws {
        let data = try await http.get(url: Self.searchFormURL, headers: ["User-Agent": Self.userAgent])
        guard let html = String(data: data, encoding: .utf8) else {
            throw HTTPError.status(code: 0, body: nil)
        }

        // Extract CSRF token — shared MyopicVicar helper (meta tag first,
        // hidden authenticity_token input as fallback).
        csrfToken = MyopicVicarParsing.csrfToken(fromHTML: html)

        // Session cookie
        if let cookies = HTTPCookieStorage.shared.cookies(for: Self.searchFormURL) {
            sessionCookie = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        logger.info("Session established (csrf=\(self.csrfToken?.prefix(20) ?? "nil")...)")
    }

    // MARK: - Rate Limiting

    /// Slot-reservation request pacing. See FreeBMDSource for the rationale.
    private func rateLimitedRequest(_ operation: () async throws -> Data) async throws -> Data {
        let scheduledFor = reserveNextSlot()
        let now = ContinuousClock.now
        if scheduledFor > now {
            try await Task.sleep(until: scheduledFor, clock: .continuous)
        }
        return try await operation()
    }

    private func reserveNextSlot() -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        let scheduledFor: ContinuousClock.Instant
        if let nextSlot = nextRequestSlot, nextSlot > now {
            scheduledFor = nextSlot
        } else {
            scheduledFor = now
        }
        nextRequestSlot = scheduledFor.advanced(by: requestDelay)
        return scheduledFor
    }

    // MARK: - Parsing (static, testable)

    /// FT-23 — FreeCen's own claimed hit count. The results page states
    /// "We found N Results"; python parity: freecen.py:90
    /// (`re.search(r"We found (\d+)\s+Results?", html)`), widened to
    /// tolerate thousands separators. Nil when the marker is absent
    /// (not a results page).
    nonisolated static func parseResultCount(_ html: String) -> Int? {
        let pattern = #"We found ([\d,]+)\s+Results?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return Int(html[range].replacingOccurrences(of: ",", with: ""))
    }

    /// FT-22 — fallback truncation signal when no hit count parsed:
    /// a Rails pagination nav (will_paginate/kaminari emit
    /// `class="pagination"`; kaminari also `rel="next"`) means more
    /// pages exist beyond the one we fetched.
    nonisolated static func hasPaginationNav(_ html: String) -> Bool {
        html.contains(#"class="pagination"#) || html.contains(#"rel="next""#)
    }

    /// FT-26 / FT-20 — page-state triage, Python parity with
    /// sources/freecen.py `_parse_results`: the count marker means a
    /// results page ("We found 0 Results" is a genuine empty), the
    /// explicit "No results found" copy is a genuine empty, and
    /// ANYTHING else — validation error, login wall, maintenance page,
    /// layout drift — is unparseable and must surface as
    /// `.unavailable`, never flow into negative-evidence reasoning.
    nonisolated enum PageState: Equatable {
        case results
        case empty
        case unparseable(reason: String)
    }

    nonisolated static func classifyResultsPage(_ html: String) -> PageState {
        if let count = parseResultCount(html) {
            return count == 0 ? .empty : .results
        }
        if html.contains("No results found") { return .empty }
        // Rails validation banner (same copy family as FreeREG's) —
        // classified separately only for the reason string.
        if MyopicVicarParsing.hasValidationBanner(html) {
            return .unparseable(reason: "FreeCen rejected the search (validation error)")
        }
        return .unparseable(reason: "Could not parse FreeCen results page")
    }

    /// FT-22 (fetching half) — extract the next-page link from a Rails
    /// pagination nav. Handles kaminari (`rel="next"`, either attribute
    /// order) and will_paginate (`class="next_page"` — its disabled
    /// state is a `<span>`, so it never matches an `<a>`). Hrefs are
    /// HTML-attribute-escaped on the page, so `&amp;` is unescaped.
    /// Returns an absolute URL, or nil when no next page exists.
    nonisolated static func nextPageURL(_ html: String) -> String? {
        nextPaginationHref(in: html, base: baseURL)
    }

    /// Shared mechanics for `nextPageURL` — also used verbatim by
    /// FreeREGSource (the two Rails sites emit the same nav shapes;
    /// duplication follows the existing hasPaginationNav idiom).
    nonisolated static func nextPaginationHref(in html: String, base: String) -> String? {
        // Shared MyopicVicar machinery (both Rails sites emit the same
        // kaminari/will_paginate shapes) — kept as a shim because
        // FreeREGSource and the paging tests call through this name.
        MyopicVicarParsing.nextPaginationHref(in: html, base: base)
    }

    /// Parse FreeCen search results HTML table.
    nonisolated static func parseSearchResults(_ html: String, censusYear: Int?) -> [SourceRecord] {
        // Check for "No results found"
        guard html.contains("We found") else { return [] }

        // Extract table rows
        let rowPattern = #"<tr[^>]*>(.*?)</tr>"#
        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern, options: .dotMatchesLineSeparators) else { return [] }
        let rowMatches = rowRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        let cellPattern = #"<td[^>]*>(.*?)</td>"#
        guard let cellRegex = try? NSRegularExpression(pattern: cellPattern, options: .dotMatchesLineSeparators) else { return [] }

        var records: [SourceRecord] = []

        for rowMatch in rowMatches {
            guard let rowRange = Range(rowMatch.range(at: 1), in: html) else { continue }
            let row = String(html[rowRange])

            let cellMatches = cellRegex.matches(in: row, range: NSRange(row.startIndex..., in: row))
            guard cellMatches.count >= 8 else { continue }

            let cells = cellMatches.compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: row) else { return nil }
                return stripHTML(String(row[range]))
            }

            guard cells.count >= 8 else { continue }

            // Extract record URL from first cell
            let linkPattern = #"href="(/search_records/[^"]+)""#
            var recordURL: String?
            if let linkRegex = try? NSRegularExpression(pattern: linkPattern),
               let linkMatch = linkRegex.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)),
               let linkRange = Range(linkMatch.range(at: 1), in: row) {
                recordURL = "\(baseURL)\(row[linkRange])"
            }

            let name = cells[1]
            let birthCounty = cells[2]
            let birthPlace = cells[3]
            let birthYear = Int(cells[4])
            let recordCensusYear = Int(cells[5]) ?? censusYear
            let censusCounty = cells[6]
            let censusDistrict = cells[7]

            let nameParts = name.split(separator: " ")
            let surname = nameParts.last.map(String.init)
            let givenName = nameParts.count > 1 ? nameParts.dropLast().joined(separator: " ") : nil

            let common = RecordCommon(
                id: stableRecordID(
                    detailURL: recordURL,
                    censusYear: recordCensusYear,
                    surname: surname,
                    givenName: givenName
                ),
                sourceID: "freecen",
                name: name,
                surname: surname,
                givenName: givenName,
                detailURL: recordURL,
                rawFields: [
                    "birth_county": birthCounty,
                    "birth_place": birthPlace,
                    "census_county": censusCounty,
                    "census_district": censusDistrict,
                ]
            )

            records.append(.census(CensusRecord(
                common: common,
                censusYear: recordCensusYear ?? 0,
                age: nil,
                birthYear: birthYear,
                birthPlace: birthPlace,
                birthCounty: birthCounty,
                relationship: nil,
                occupation: nil,
                address: nil,
                parish: nil,
                district: censusDistrict,
                household: nil  // populated via fetchDetail
            )))
        }

        return records
    }

    /// Parse household detail from a FreeCen record page.
    /// Map a dwelling/census-header label to the legacy rawFields key.
    /// Labels vary by render path and year (VLD "Census" vs CSV "Census
    /// Year"; Scotland's "Quaord Sacra" [sic]); unknown labels pass
    /// through snake_cased so year-specific extras (Rooms, Walls…) are
    /// kept rather than dropped.
    nonisolated static func dwellingKey(_ label: String) -> String {
        switch label.lowercased() {
        case "census", "census year": return "census_year"
        case "county": return "county"
        case "district", "census district": return "district"
        case "civil parish": return "parish"
        case "ecclesiastical parish", "quaord sacra", "quoad sacra": return "ecclesiastical_parish"
        case "piece": return "piece"
        case "enumeration district": return "enumeration_district"
        case "folio": return "folio"
        case "page": return "page"
        case "schedule": return "schedule"
        case "house number": return "house_number"
        case "house or street name": return "address"
        default:
            return label.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
        }
    }

    nonisolated static func parseHouseholdDetail(_ html: String, recordURL: String) -> SourceRecord? {
        // Parse every table into rows of stripped cells (shared MyopicVicar
        // primitive). Tables are then identified by their HEADERS, not
        // their position: the VLD path renders dwelling + members
        // (2 tables), the FreeCEN2 CSV path renders census header +
        // address + members (3 tables) — a position-based parse mistakes
        // the CSV address table for the roster. Header-keyed columns also
        // fix the year-specific layouts the old fixed-11-column parse
        // silently mis-read (1841 has 7 member columns, 1911 E&W has 20).
        let tables = MyopicVicarParsing.tables(in: html)

        var dwelling: [String: String] = [:]
        var memberRows: [[String]] = []
        var memberHeaders: [String] = []

        for table in tables {
            guard let headerRow = table.first else { continue }
            let lower = headerRow.map { $0.lowercased() }
            if lower.contains("surname") && lower.contains("forenames") {
                memberHeaders = lower
                memberRows = Array(table.dropFirst())
            } else if table.count >= 2 {
                // A metadata table: header row + value row → key/value.
                let values = table[1]
                for (i, header) in headerRow.enumerated() where i < values.count {
                    let key = Self.dwellingKey(header)
                    let value = values[i]
                    if !key.isEmpty, !value.isEmpty, dwelling[key] == nil {
                        dwelling[key] = value
                    }
                }
            }
        }

        let censusYear = Int(dwelling["census_year"] ?? "") ?? 0

        var members: [HouseholdMember] = []
        for rawRow in memberRows {
            var row = rawRow
            // "person found in your search" accessibility marker rides
            // inside the marked member's surname cell (FT-10) — strip it
            // and remember the row as the search target.
            var isTarget = false
            if let markerIndex = row.firstIndex(where: { $0.lowercased().contains("person found in your search") }) {
                let parts = row[markerIndex].components(separatedBy: "\n")
                row[markerIndex] = parts.first(where: {
                    !$0.lowercased().contains("person found") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
                })?.trimmingCharacters(in: .whitespaces) ?? ""
                isTarget = true
            }

            /// First non-empty cell under any of the given header names.
            func cell(_ names: String...) -> String? {
                for name in names {
                    if let i = memberHeaders.firstIndex(of: name), i < row.count {
                        let value = row[i]
                        if !value.isEmpty { return value }
                    }
                }
                return nil
            }

            let surname = cell("surname") ?? ""
            let forenames = cell("forenames") ?? ""
            let name = "\(forenames) \(surname)".trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            let ageText = cell("age") ?? ""
            let ageInt = Int(ageText)

            members.append(HouseholdMember(
                name: name,
                // 1841 has no Relationship column — empty, never guessed.
                relationship: cell("relationship") ?? "",
                age: ageInt,
                birthYear: (censusYear > 0) ? ageInt.map { censusYear - $0 } : nil,
                birthPlace: cell("birth place"),
                occupation: cell("occupation"),
                sex: cell("sex"),
                maritalStatus: cell("marital status"),
                birthCounty: cell("birth county"),
                disability: cell("disability"),
                notes: cell("notes"),
                isTarget: isTarget,
                // Age text that isn't a clean integer ("3m", "6w", "unk")
                // is preserved as transcribed instead of being dropped.
                rawAge: (ageInt == nil && !ageText.isEmpty) ? ageText : nil,
                yearsMarried: cell("years married"),
                childrenBornAlive: cell("children born alive").flatMap(Int.init),
                childrenLiving: cell("children living").flatMap(Int.init),
                childrenDeceased: cell("children deceased").flatMap(Int.init),
                industry: cell("industry"),
                nationality: cell("nationality"),
                language: cell("language"),
                disabilityNotes: cell("disability notes")
            ))
        }

        let membersWithBirthYear = members

        // Build a CensusRecord for the search target (FT-10). FreeCen lists
        // households head-first, so the member the results page marked as
        // "the person found in your search" is the subject — the first
        // member is only correct as a no-marker fallback (Python selects on
        // is_target the same way, sources/freecen.py:318).
        guard let target = membersWithBirthYear.first(where: { $0.isTarget == true })
                ?? membersWithBirthYear.first else { return nil }

        let targetSurname = target.name.split(separator: " ").last.map(String.init)
        let targetGivenName = target.name.split(separator: " ").dropLast().joined(separator: " ")

        let common = RecordCommon(
            id: stableRecordID(
                detailURL: recordURL,
                censusYear: censusYear,
                surname: targetSurname,
                givenName: targetGivenName
            ),
            sourceID: "freecen",
            name: target.name,
            surname: targetSurname,
            givenName: targetGivenName,
            detailURL: recordURL,
            rawFields: dwelling
        )

        return .census(CensusRecord(
            common: common,
            censusYear: censusYear,
            age: target.age,
            birthYear: target.birthYear,
            birthPlace: target.birthPlace,
            birthCounty: dwelling["county"],
            relationship: target.relationship,
            occupation: target.occupation,
            address: dwelling["address"],
            parish: dwelling["parish"],
            district: dwelling["district"],
            household: membersWithBirthYear
        ))
    }

    /// Stable record ID (connector-audit FT-12). Record IDs are load-bearing
    /// across runs and across enrichment: `evidence_records` keys on
    /// `"<profile>|<source_record_id>"` and rejectionLookup suppresses user
    /// discards by `SourceRecord.id` — so the same census entry must carry
    /// the same ID whether it is the bare search row or the household-
    /// enriched detail record, and two same-name people must never collapse
    /// to one ID. Same idiom as FreeREGSource.stableRecordID (FT-16).
    ///
    /// Preference order:
    /// 1. The server-stable entry ID embedded in the detail URL
    ///    (`/search_records/<id>`) — shared by the search row and the
    ///    detail page, so enrichment no longer flips the ID.
    /// 2. The legacy name composite (`freecen_<year>_<surname>_<given>`),
    ///    only when no detail link was parsed — keeping pre-existing
    ///    evidence keys for link-less rows intact.
    nonisolated static func stableRecordID(
        detailURL: String?,
        censusYear: Int?, surname: String?, givenName: String?
    ) -> String {
        if let detailURL, let url = URL(string: detailURL) {
            // lastPathComponent drops any query string; guard against a
            // degenerate href like "/search_records/?q=…" where the last
            // path segment is the route name rather than an entry ID.
            let segment = url.lastPathComponent
            if !segment.isEmpty, segment != "/", segment != "search_records" {
                return "freecen_\(segment)"
            }
        }
        return "freecen_\(censusYear ?? 0)_\(surname ?? "")_\(givenName ?? "")"
    }

    // MARK: - HTML Helpers

    nonisolated private static func stripHTML(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
