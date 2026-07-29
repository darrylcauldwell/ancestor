import CryptoKit
import Foundation
import os

/// FreeREG — volunteer-transcribed parish register records
/// https://www.freereg.org.uk/
/// Access: POST form with CSRF token → HTML table results
/// Auth: CSRF token from search form
/// Coverage: ~1500–1900, England & Wales parish registers (baptism, marriage, burial)
/// Faithfully ported from Python's sources/freereg_search.py
/// Detail fetching (FT-18): mirrors FreeCen's cap-1 enrichment pattern —
/// the top search hit's detail page is fetched through the same 1000 ms
/// pacing and its parent names (baptisms) / extra fields populate the
/// record. Python reference: freereg_search.py:298-331 fetch_record_detail.
actor FreeREGSource: RecordSource, DetailFetchingSource {

    // MARK: - RecordSource Protocol

    nonisolated let sourceID = "freereg"
    nonisolated let scopeHandling: ScopeHandling = .scoped
    nonisolated let displayName = "FreeREG"
    nonisolated let descriptiveName = "UK Parish Registers (FreeREG)"
    nonisolated let recordTypes: Set<RecordType> = [.baptism, .marriage, .burial, .parish]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1500...1900
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "parish-registers")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    // Verified against the PUBLISHED terms 2026-07-27 (not /help — the clause is
    // on /terms-and-conditions): "Access to the data held by FreeREG is only
    // permitted manually via the search page. The use of front end programs or
    // sites to enter search parameters is strictly forbidden" AND "Data extracted
    // from FreeREG must not be reproduced in any form." Level stays `.restricted`
    // — the terms genuinely restrict automated access — identical to FreeBMD/
    // FreeCEN (same charity, same wording). Owner decision 2026-07-29: FreeREG
    // operates under the ADR-008 §Decision-2 ask-first, respectful-interim
    // posture (like its two siblings) — active for personal research at tiny
    // volume, conservative pacing + daily cap, records linked back to source,
    // permission request pending — NOT retired to a link-out.
    nonisolated let tosStatus = SourceToSStatus(
        level: .restricted,
        summary: "Terms forbid programmatic search (\"front end programs… strictly forbidden\", freereg.org.uk/terms-and-conditions) — personal-research interim use, permission request to Free UK Genealogy pending, ADR-008"
    )

    /// Conservative daily budget (ENGINE_FOUNDATION #Change5). FreeREG is
    /// volunteer-run with no documented quota; treat it like FreeCen — a
    /// chapman fan-out can multiply requests per subject, so a conservative
    /// daily ceiling parks the source until UTC midnight once a sustained
    /// run has exceeded a normal session.
    nonisolated let budgetPolicy = SourceBudgetPolicy(dailyLimit: 300, reset: .utcMidnight)

    // MARK: - State

    private let http: any HTTPClient
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FreeREG")
    private var csrfToken: String?
    /// Scheduled time for the next allowable request. Slot-reservation pattern
    /// — see FreeBMDSource for the full rationale.
    private var nextRequestSlot: ContinuousClock.Instant?
    private let requestDelay: Duration = .milliseconds(1000)
    /// In-flight session-establishment task. Concurrent search() calls all
    /// await the same fetch instead of each independently grabbing the CSRF.
    private var sessionEstablishmentTask: Task<Void, Error>?

    init(http: any HTTPClient = SourceHTTPClient.shared) {
        self.http = http
    }

    // MARK: - Constants

    nonisolated private static let baseURL = "https://www.freereg.org.uk"
    nonisolated private static let searchFormURL = "https://www.freereg.org.uk/search_queries/new"
    nonisolated private static let searchPostURL = "https://www.freereg.org.uk/search_queries"
    nonisolated private static let userAgent = "AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"
    /// FT-22 (fetching half) — total-results budget across pagination,
    /// mirroring `ProbateSource.maxResults` (Python parity:
    /// probate.py:130 `max_results=500`), plus a defensive page cap:
    /// FreeREG's per-page size is unverified (audit FT-27), so the page
    /// cap bounds worst-case volunteer-source load even if pages turn
    /// out tiny. Every page fetch rides the existing 1000 ms politeness
    /// pacing. Internal so the paging tests reference the budgets.
    nonisolated static let maxResults = 500
    nonisolated static let maxPages = 10

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        await searchWithOutcome(query).result
    }

    /// Envelope-aware search (connector-audit T1-01; instances FT-22 /
    /// FT-23). Parses the results page's own "N results" hit count and
    /// flags page-1 truncation (rows < N, or a pagination nav present)
    /// — multi-page fetching is deferred to the efficiency series.
    func searchWithOutcome(_ query: RecordQuery) async -> SourceSearchEnvelope {
        guard recordTypes.contains(query.recordType) else {
            return SourceSearchEnvelope(.outsideCoverage(reason: "FreeREG provides parish register records only"))
        }

        // Map record type to FreeREG form value
        let recordTypeValue: String
        switch query.recordType {
        case .baptism, .christening: recordTypeValue = "ba"
        case .marriage: recordTypeValue = "ma"
        case .burial: recordTypeValue = "bu"
        default: recordTypeValue = ""  // All types
        }

        // Get chapman code(s) from query params.
        // Dispatcher passes a freeREG param (from .national scope fan-out) or, for
        // backwards-compat with older call sites, accept a freeCen param too.
        // FreeREG is chapman-coded: without a county code the query cannot
        // be scoped, so degrade honestly instead of guessing a county.
        //
        // FT-25 — the dispatcher may pass a BATCH of codes (`chapmanCodes`)
        // to carry in one request via repeated `chapman_codes[]` keys;
        // when present and non-empty it supersedes the single `chapmanCode`.
        // Order is preserved so the wire shape and cache key stay stable.
        let rawChapmanCodes: [String]
        let regParams: FreeREGParams?
        switch query.sourceParams {
        case .freeREG(let params):
            rawChapmanCodes = Self.resolveChapmanCodes(batch: params.chapmanCodes, single: params.chapmanCode)
            regParams = params
        case .freeCen(let params):
            // Back-compat call site: a FreeCen param carries only the chapman
            // axis into a FreeREG search; the capability axes stay unset.
            rawChapmanCodes = Self.resolveChapmanCodes(batch: params.chapmanCodes, single: params.chapmanCode)
            regParams = nil
        default:
            rawChapmanCodes = []
            regParams = nil
        }
        // MyopicVicar (the live engine) caps a query at 3 counties — Channel
        // Islands quartet exempt (FREEREG_INTEGRATION_SPEC §0, resolves FT-27).
        // Enforce defensively even if the dispatcher over-fans.
        let chapmanCodes = FreeREGParams.cappedChapmanCodes(rawChapmanCodes)

        // Capability axes + surname policy (FREEREG_INTEGRATION_SPEC §1).
        // `place_ids` are valid only with a SINGLE county (the form's cascading
        // Places box); `search_nearby_places` needs a place; `no_surname` needs
        // forename + county + place — only then does the engine return rows
        // instead of a validation reject.
        let placeIDs = (regParams?.placeIDs ?? []).filter { !$0.isEmpty }
        let placesEmitted = chapmanCodes.count == 1 && !placeIDs.isEmpty
        let given = query.givenName ?? ""
        let noSurnameValid = (regParams?.noSurname ?? false) && !given.isEmpty && placesEmitted

        let surname: String
        if let s = query.surname, !s.isEmpty {
            surname = s
        } else if noSurnameValid {
            surname = ""   // a legitimate surname-less search (search_query[no_surname])
        } else {
            // No surname and not a valid no-surname query — nothing to search.
            return SourceSearchEnvelope(.results([]))
        }

        guard !chapmanCodes.isEmpty else {
            return SourceSearchEnvelope(.outsideCoverage(reason: "No home county (Chapman code) available to scope a FreeREG search"))
        }

        let summary = Self.activitySummary(query: query, surname: surname, chapmanCode: Self.scopeLabel(chapmanCodes))
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary, strictness: query.strictness))

        do {
            try await ensureSession()

            // FT-25 — ordered pairs (not a dict) so the repeated
            // `search_query[chapman_codes][]` key survives on the wire when
            // the dispatcher batched several counties into one request.
            var fields: [(String, String)] = [
                ("search_query[last_name]", surname),
            ]
            // One repeated key per code — a single-code query emits exactly
            // one pair, byte-identical to the pre-FT-25 single-value shape.
            for code in chapmanCodes {
                fields.append(("search_query[chapman_codes][]", code))
            }
            fields.append(("commit", "Search"))
            // RESEARCH_AXES_SPEC Change 5/6: FreeREG exposes a Name Soundex
            // checkbox at `search_query[fuzzy]` (form value `"true"`).
            // .loose enables it. .variant is the dispatcher tier marker —
            // the surname has been substituted to a variant before arriving,
            // so the variant probe is exact-match (no fuzzy field).
            if query.strictness == .loose {
                fields.append(("search_query[fuzzy]", "true"))
            }
            if let token = csrfToken {
                fields.append(("authenticity_token", token))
            }
            if let givenName = query.givenName, !givenName.isEmpty {
                fields.append(("search_query[first_name]", givenName))
            }
            if !recordTypeValue.isEmpty {
                fields.append(("search_query[record_type]", recordTypeValue))
            }
            if let yearFrom = query.yearFrom {
                fields.append(("search_query[start_year]", String(yearFrom)))
            }
            if let yearTo = query.yearTo {
                fields.append(("search_query[end_year]", String(yearTo)))
            }

            // FT-19 / FT-21 capability axes (gates computed above). NB:
            // `search_query[region]` is a bot HONEYPOT — deliberately NEVER
            // emitted anywhere in this method (a test asserts it stays off wire).
            if placesEmitted {
                for pid in placeIDs {
                    fields.append(("search_query[place_ids][]", pid))
                }
                if regParams?.searchNearbyPlaces == true {
                    fields.append(("search_query[search_nearby_places]", "true"))
                }
            }
            if regParams?.includeWitnesses == true {
                fields.append(("search_query[witness]", "true"))
            }
            if regParams?.includeFamilyMembers == true {
                fields.append(("search_query[inclusive]", "true"))
            }
            if noSurnameValid {
                fields.append(("search_query[no_surname]", "true"))
            }

            let data = try await rateLimitedRequest {
                try await self.http.postForm(
                    url: URL(string: Self.searchPostURL)!,
                    multiFields: fields,
                    headers: [
                        "User-Agent": Self.userAgent,
                        "X-CSRF-Token": self.csrfToken ?? "",
                        "Referer": Self.searchFormURL,
                    ]
                )
            }

            let html = String(data: data, encoding: .utf8) ?? ""

            // FT-26 / FT-20 — page-state triage (Python parity:
            // freereg_search.py:182-226 checks "error prohibited"
            // validation banners and "no results" copy before parsing
            // tables). Only a positively identified results page may
            // yield records, and only a positively identified
            // no-results page may yield a clean empty; validation
            // errors, login walls and layout drift are `.unavailable`,
            // never a cacheable [].
            switch Self.classifyResultsPage(html) {
            case .empty:
                logger.info("FreeREG: 0 results for \(surname)")
                await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: 0, strictness: query.strictness))
                return SourceSearchEnvelope(result: .results([]), outcome: SearchOutcome(resultCount: 0))
            case .validationError(let reason), .unparseable(let reason):
                logger.warning("FreeREG page not parseable as results: \(reason)")
                await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: reason, strictness: query.strictness))
                return SourceSearchEnvelope(.unavailable(reason: reason))
            case .results:
                break
            }

            var records = Self.parseResults(html, recordType: query.recordType)
            // FT-23: the site's own claimed hit count.
            let totalAvailable = Self.parseResultCount(html)

            // FT-22 (fetching half) — walk the pagination nav through
            // the existing 1000 ms pacing, bounded by the record budget
            // and the defensive page cap. Stops on: no next link, a page
            // yielding no parsable rows, or budget exhaustion.
            var nextPage = Self.nextPageURL(html)
            var pagesFetched = 1
            while let next = nextPage.flatMap(URL.init(string:)),
                  pagesFetched < Self.maxPages,
                  records.count < Self.maxResults {
                // A failed follow-up page must not discard the pages
                // already in hand — break and let `truncated` say the
                // answer is partial.
                guard let pageData = try? await rateLimitedRequest({
                    try await self.http.get(url: next, headers: [
                        "User-Agent": Self.userAgent,
                    ])
                }), let pageHTML = String(data: pageData, encoding: .utf8) else { break }
                let pageRecords = Self.parseResults(pageHTML, recordType: query.recordType)
                guard !pageRecords.isEmpty else { break }
                records += pageRecords
                pagesFetched += 1
                nextPage = Self.nextPageURL(pageHTML)
            }

            // Honest truncation AFTER paging (FT-22/FT-23): trust the
            // site's own count when parsed; otherwise an unconsumed
            // next-link means the budget (or a parse miss) cut the
            // answer short.
            let truncated = totalAvailable.map { records.count < $0 }
                ?? (nextPage != nil)

            // FT-18 — enrich the top hit with its detail page (parents
            // for baptisms; extra transcribed fields for all types).
            records = await enrichWithDetail(records, cap: 1)

            logger.info("FreeREG: \(records.count) of \(totalAvailable ?? records.count) results for \(surname)")
            await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: records.count, strictness: query.strictness))
            return SourceSearchEnvelope(
                result: .results(records),
                outcome: SearchOutcome(
                    resultCount: records.count,
                    totalAvailable: totalAvailable,
                    truncated: truncated
                )
            )
        } catch {
            csrfToken = nil  // Reset on error
            logger.error("FreeREG search failed: \(error.localizedDescription)")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription, strictness: query.strictness))
            return SourceSearchEnvelope(.unavailable(reason: error.localizedDescription))
        }
    }

    /// FT-25 — resolve the chapman code(s) to put on the wire. A non-empty
    /// batch (`chapmanCodes`, blanks dropped) wins over the single code; a
    /// non-empty single code is the sole fallback. Empty in both = no axis.
    /// nonisolated + static so the query-shape tests can pin the precedence.
    nonisolated static func resolveChapmanCodes(batch: [String]?, single: String?) -> [String] {
        if let batch {
            let cleaned = batch.filter { !$0.isEmpty }
            if !cleaned.isEmpty { return cleaned }
        }
        if let single, !single.isEmpty { return [single] }
        return []
    }

    /// Activity-feed label for one or many codes: the single code, or
    /// "N counties" for a batch (keeps the feed line short).
    nonisolated static func scopeLabel(_ codes: [String]) -> String {
        codes.count == 1 ? codes[0] : "\(codes.count) counties"
    }

    /// Build a one-line description of a FreeREG query for the live activity feed.
    nonisolated static func activitySummary(query: RecordQuery, surname: String, chapmanCode: String) -> String {
        let recordTypeLabel: String = switch query.recordType {
        case .baptism, .christening: "baptisms"
        case .marriage: "marriages"
        case .burial: "burials"
        default: "parish records"
        }
        let searchTerms: String = {
            if let given = query.givenName, !given.isEmpty { return "\(given) \(surname)" }
            return surname
        }()
        let yearLabel: String
        switch (query.yearFrom, query.yearTo) {
        case let (yf?, yt?) where yf == yt: yearLabel = " \(yf)"
        case let (yf?, yt?): yearLabel = " \(yf)–\(yt)"
        default: yearLabel = ""
        }
        return "FreeREG \(chapmanCode) \(recordTypeLabel): \(searchTerms)\(yearLabel)"
    }

    // MARK: - Session Management

    /// Fetch the CSRF token for FreeREG. Concurrent callers all await the
    /// same in-flight establishment task — only one network round-trip even
    /// when many search() calls queue at the actor.
    private func ensureSession() async throws {
        if csrfToken != nil { return }
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
        let data = try await http.get(url: URL(string: Self.searchFormURL)!, headers: [
            "User-Agent": Self.userAgent,
        ])
        let html = String(data: data, encoding: .utf8) ?? ""

        // Extract CSRF token from <meta name="csrf-token" content="...">
        let metaPattern = #"<meta\s+name="csrf-token"\s+content="([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: metaPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            csrfToken = String(html[range])
        }

        // Fallback: look for hidden input
        if csrfToken == nil {
            let inputPattern = #"<input[^>]+name="authenticity_token"[^>]+value="([^"]+)""#
            if let regex = try? NSRegularExpression(pattern: inputPattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                csrfToken = String(html[range])
            }
        }
    }

    // MARK: - Rate Limiting

    /// Slot-reservation request pacing. See FreeBMDSource for the rationale.
    private func rateLimitedRequest<T>(_ operation: () async throws -> T) async throws -> T {
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

    // MARK: - Detail Fetching (FT-18)

    /// Replace the first `cap` parish records with their detail-enriched
    /// form. Mirrors FreeCen's cap-1 household pattern
    /// (`FreeCenSource.enrichWithHousehold` — the volunteer-budget
    /// rule): records past the cap or without a detail URL pass through
    /// untouched; detail failures fall back to the un-enriched record.
    /// Merging preserves the record's identity — same ID, same name —
    /// so enrichment can never flip evidence keys (the FT-12 lesson).
    private func enrichWithDetail(_ records: [SourceRecord], cap: Int) async -> [SourceRecord] {
        var out: [SourceRecord] = []
        out.reserveCapacity(records.count)
        var enrichedCount = 0
        for record in records {
            guard enrichedCount < cap,
                  case .parish(let parish) = record,
                  let urlString = parish.common.detailURL, !urlString.isEmpty,
                  let url = URL(string: urlString),
                  parish.fatherName == nil, parish.motherName == nil else {
                out.append(record)
                continue
            }
            enrichedCount += 1
            do {
                let data = try await rateLimitedRequest {
                    try await self.http.get(url: url, headers: ["User-Agent": Self.userAgent])
                }
                let html = String(data: data, encoding: .utf8) ?? ""
                let fields = Self.parseDetailFields(html)
                if !fields.isEmpty {
                    out.append(Self.mergedDetailRecord(base: parish, detailFields: fields))
                } else {
                    // Detail page had no extractable pairs (layout
                    // drift, error page) — keep the search-result row.
                    out.append(record)
                }
            } catch {
                logger.warning("FreeREG detail enrichment failed: \(error.localizedDescription)")
                out.append(record)
            }
        }
        return out
    }

    /// DetailFetchingSource — `recordID` is the detail URL (same
    /// contract as FreeCenSource.fetchDetail). Builds a standalone
    /// record from the detail page alone, for callers that don't hold
    /// the search row; the in-search enrichment path uses
    /// `mergedDetailRecord` instead so the search row's identity wins.
    func fetchDetail(recordID: String) async -> SourceQueryResult {
        guard let url = URL(string: recordID) else {
            return .unavailable(reason: "Invalid URL: \(recordID)")
        }
        do {
            let data = try await rateLimitedRequest {
                try await self.http.get(url: url, headers: ["User-Agent": Self.userAgent])
            }
            let html = String(data: data, encoding: .utf8) ?? ""
            let fields = Self.parseDetailFields(html)
            guard !fields.isEmpty,
                  let record = Self.detailRecord(fields: fields, recordURL: recordID) else {
                return .results([])
            }
            return .results([record])
        } catch {
            logger.warning("FreeREG detail fetch failed: \(error.localizedDescription)")
            return .unavailable(reason: error.localizedDescription)
        }
    }

    // MARK: - Parsing (nonisolated static — testable)

    /// FT-23 — FreeREG's own claimed hit count. Python parity:
    /// freereg_search.py:204-207 matches `\d+\s+result` on the page's
    /// strings (the exact copy varies; the digits-before-"result(s)"
    /// shape is stable). Widened to tolerate thousands separators.
    /// Nil when no count text is present. Guarded against matching
    /// "no results" copy (no digits there, so the regex can't anyway).
    nonisolated static func parseResultCount(_ html: String) -> Int? {
        let pattern = #"([\d,]+)\s+results?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
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

    /// FT-26 / FT-20 — page-state triage, ported from Python
    /// freereg_search.py:parse_results: Rails validation banners
    /// ("error prohibited …" / "… prohibited this …"), explicit
    /// no-results copy, then a results table; login walls and layout
    /// drift are unparseable. The Swift port had dropped the error
    /// check entirely — a rejected POST was indistinguishable from a
    /// genuine no-hit and flowed into negative-evidence reasoning.
    nonisolated enum PageState: Equatable {
        case results
        case empty
        case validationError(reason: String)
        case unparseable(reason: String)
    }

    nonisolated static func classifyResultsPage(_ html: String) -> PageState {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unparseable(reason: "Empty response body")
        }
        if html.range(of: #"error prohibited|prohibited this"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            // Surface the first error <li> when the banner carries one
            // (Python extracts the whole list; one is enough for a reason).
            var reason = "FreeREG rejected the search (validation error)"
            let liPattern = #"<ul[^>]*class="[^"]*error[^"]*"[^>]*>.*?<li[^>]*>(.*?)</li>"#
            if let regex = try? NSRegularExpression(pattern: liPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let detail = stripTags(String(html[range]))
                if !detail.isEmpty { reason = "FreeREG rejected the search: \(detail)" }
            }
            return .validationError(reason: reason)
        }
        if html.range(of: #"no results|no records found"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            return .empty
        }
        if let count = parseResultCount(html), count == 0 { return .empty }
        // A results table needs header cells — the row parser skips
        // everything until it has seen a <th> header row anyway.
        if html.contains("<th") { return .results }
        if html.range(of: #"sign in|log in"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            return .unparseable(reason: "FreeREG page appears to require login")
        }
        return .unparseable(reason: "Could not parse FreeREG results page")
    }

    /// FT-22 (fetching half) — next-page link. Mechanics shared with
    /// FreeCen (`FreeCenSource.nextPaginationHref`): the two Rails
    /// sites emit the same kaminari/will_paginate nav shapes.
    nonisolated static func nextPageURL(_ html: String) -> String? {
        FreeCenSource.nextPaginationHref(in: html, base: baseURL)
    }

    /// Parse FreeREG search results HTML table.
    nonisolated static func parseResults(_ html: String, recordType: RecordType) -> [SourceRecord] {
        var records: [SourceRecord] = []

        // Find table rows with data
        let rowPattern = #"<tr[^>]*>(.*?)</tr>"#
        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern, options: .dotMatchesLineSeparators) else {
            return []
        }

        let cellPattern = #"<t[dh][^>]*>(.*?)</t[dh]>"#
        guard let cellRegex = try? NSRegularExpression(pattern: cellPattern, options: .dotMatchesLineSeparators) else {
            return []
        }

        // Extract link pattern for detail URLs
        let linkPattern = #"href="(/(?:search_records|freereg1_csv_entries)/[^"]+)""#
        let linkRegex = try? NSRegularExpression(pattern: linkPattern)

        var headers: [String] = []
        let rowMatches = rowRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for rowMatch in rowMatches {
            guard let rowRange = Range(rowMatch.range(at: 1), in: html) else { continue }
            let rowHTML = String(html[rowRange])

            let cellMatches = cellRegex.matches(in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML))
            let cells = cellMatches.compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: rowHTML) else { return nil }
                return stripTags(String(rowHTML[range]))
            }

            guard !cells.isEmpty else { continue }

            // Header row detection
            if rowHTML.contains("<th") {
                headers = cells
                continue
            }

            // Skip rows without headers
            guard !headers.isEmpty else { continue }

            // Build row dict
            var row: [String: String] = [:]
            for (i, header) in headers.enumerated() where i < cells.count {
                row[header.lowercased()] = cells[i]
            }

            // Extract detail URL
            var detailURL: String?
            if let linkRegex,
               let linkMatch = linkRegex.firstMatch(in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML)),
               let range = Range(linkMatch.range(at: 1), in: rowHTML) {
                detailURL = "\(baseURL)\(rowHTML[range])"
            }

            // Build record
            let date = row["date"] ?? ""
            let parish = row["parish"] ?? ""
            let county = row["county"] ?? ""
            let type = row["record type"] ?? row["type"] ?? ""

            // FT-17 — resolve name/surname/given from the site's own
            // columns where present; otherwise last-token-surname.
            guard let resolved = Self.resolveRowName(row) else { continue }
            let name = resolved.name
            let givenName = resolved.givenName
            let surname = resolved.surname

            let eventYear = extractYear(from: date)
            let eventType = type.isEmpty ? recordType.rawValue : type.lowercased()

            let common = RecordCommon(
                id: stableRecordID(
                    detailURL: detailURL,
                    name: name, date: date, parish: parish,
                    county: county, eventType: eventType
                ),
                sourceID: "freereg",
                name: name, surname: surname, givenName: givenName,
                detailURL: detailURL,
                rawFields: ["parish": parish, "county": county, "event_type": eventType, "date": date]
            )

            records.append(.parish(ParishRecord(
                common: common,
                eventType: eventType,
                eventDate: date.isEmpty ? nil : date,
                eventYear: eventYear,
                parish: parish.isEmpty ? nil : parish,
                county: county.isEmpty ? nil : county,
                fatherName: nil,
                motherName: nil
            )))
        }

        return records
    }

    /// FT-17 — resolve (display name, givenName, surname) for a result
    /// row. Prefers FreeREG's own explicit Surname/Forenames columns
    /// (Python keeps the site's columns, freereg_search.py:259-261);
    /// falls back to splitting the combined display name with the LAST
    /// token as surname — FreeCen's convention — replacing the old
    /// maxSplits:1 split that pushed every middle name into the
    /// surname field ("Sarah Jane Kenworthy" → surname "Jane
    /// Kenworthy"), corrupting the scorer's identity gates.
    nonisolated static func resolveRowName(_ row: [String: String]) -> (name: String, givenName: String?, surname: String?)? {
        let explicitSurname = row["surname"].flatMap { $0.isEmpty ? nil : $0 }
        let explicitGiven = ["forenames", "forename", "first name(s)", "first names", "first name", "given name"]
            .compactMap { row[$0] }
            .first { !$0.isEmpty }
        let display = row["name"].flatMap { $0.isEmpty ? nil : $0 }

        if let explicitSurname {
            let given: String? = explicitGiven ?? display.flatMap { d in
                // Combined display alongside an explicit surname column:
                // given = display minus trailing surname tokens (only
                // when they match — otherwise don't guess).
                let tokens = d.split(separator: " ").map(String.init)
                let surTokens = explicitSurname.split(separator: " ").map(String.init)
                guard tokens.count > surTokens.count,
                      tokens.suffix(surTokens.count).map({ $0.lowercased() }) == surTokens.map({ $0.lowercased() })
                else { return nil }
                return tokens.dropLast(surTokens.count).joined(separator: " ")
            }
            let name = display ?? [given, explicitSurname].compactMap { $0 }.joined(separator: " ")
            guard !name.isEmpty else { return nil }
            return (name, given, explicitSurname)
        }

        guard let display else { return nil }
        let tokens = display.split(separator: " ")
        guard let last = tokens.last.map(String.init) else { return nil }
        let given = tokens.count > 1 ? tokens.dropLast().joined(separator: " ") : nil
        return (display, given, last)
    }

    // MARK: - Detail parsing (FT-18, nonisolated static — testable)

    /// Extract the transcribed field pairs from a FreeREG record detail
    /// page. The pages render as definition lists (`<dt>Key</dt>
    /// <dd>Value</dd>`) and/or two-cell table rows — Python's
    /// fetch_record_detail walks exactly these two shapes
    /// (freereg_search.py:308-321). Keys are normalised to lowercase
    /// snake_case with apostrophes stripped ("Father's Forename" →
    /// "fathers_forename").
    nonisolated static func parseDetailFields(_ html: String) -> [String: String] {
        var fields: [String: String] = [:]
        let pairPatterns = [
            #"<dt[^>]*>(.*?)</dt>\s*<dd[^>]*>(.*?)</dd>"#,
            #"<tr[^>]*>\s*<t[dh][^>]*>(.*?)</t[dh]>\s*<td[^>]*>(.*?)</td>\s*</tr>"#,
        ]
        for pattern in pairPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { continue }
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let keyRange = Range(match.range(at: 1), in: html),
                      let valueRange = Range(match.range(at: 2), in: html) else { continue }
                let key = normaliseDetailKey(stripTags(String(html[keyRange])))
                let value = stripTags(String(html[valueRange]))
                if !key.isEmpty, !value.isEmpty, fields[key] == nil {
                    fields[key] = value
                }
            }
        }
        return fields
    }

    /// "Father's Forename:" → "fathers_forename"
    nonisolated static func normaliseDetailKey(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
    }

    /// Assemble a parent name from a detail-field map for `role`
    /// ("father"/"mother") — single combined field first, then
    /// forename+surname assembly.
    nonisolated static func extractParent(_ fields: [String: String], role: String) -> String? {
        for key in ["\(role)s_name", "\(role)_name", role] {
            if let value = fields[key], !value.isEmpty { return value }
        }
        let forename = fields.first {
            $0.key.hasPrefix(role) && ($0.key.contains("forename") || $0.key.contains("first_name") || $0.key.contains("given"))
        }?.value
        let surname = fields.first {
            $0.key.hasPrefix(role) && ($0.key.contains("surname") || $0.key.contains("last_name"))
        }?.value
        let combined = [forename, surname].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return combined.isEmpty ? nil : combined
    }

    /// Build a standalone record from a detail page alone (the public
    /// `fetchDetail` path). Best-effort: principal name from the page's
    /// own Forename/Surname fields; event date/type from the kind-named
    /// date field; parents via `extractParent`. Nil when no principal
    /// name could be read — an unidentifiable record is worse than none.
    nonisolated static func detailRecord(fields: [String: String], recordURL: String) -> SourceRecord? {
        let surname = fields["surname"] ?? fields["persons_surname"]
        let given = fields["forename"] ?? fields["forenames"] ?? fields["first_name"]
        let name = [given, surname].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !name.isEmpty else { return nil }

        let eventPairs: [(key: String, type: String)] = [
            ("baptism_date", "baptism"), ("date_of_baptism", "baptism"),
            ("marriage_date", "marriage"), ("date_of_marriage", "marriage"),
            ("burial_date", "burial"), ("date_of_burial", "burial"),
            ("date", ""),
        ]
        var date = ""
        var eventType = ""
        for pair in eventPairs {
            if let value = fields[pair.key], !value.isEmpty {
                date = value
                eventType = pair.type
                break
            }
        }
        if eventType.isEmpty {
            eventType = fields["record_type"]?.lowercased() ?? ""
        }
        let parish = fields["parish"] ?? ""
        let county = fields["county"] ?? ""
        let common = RecordCommon(
            id: stableRecordID(
                detailURL: recordURL,
                name: name, date: date, parish: parish,
                county: county, eventType: eventType
            ),
            sourceID: "freereg",
            name: name,
            surname: surname,
            givenName: given,
            detailURL: recordURL,
            rawFields: fields
        )
        return .parish(ParishRecord(
            common: common,
            eventType: eventType.isEmpty ? nil : eventType,
            eventDate: date.isEmpty ? nil : date,
            eventYear: extractYear(from: date),
            parish: parish.isEmpty ? nil : parish,
            county: county.isEmpty ? nil : county,
            fatherName: extractParent(fields, role: "father"),
            motherName: extractParent(fields, role: "mother")
        ))
    }

    /// Merge a detail-page field map into a search-row record. The ID,
    /// name and detail URL are the BASE record's — enrichment must
    /// never flip a record's identity (the FT-12 lesson, and the ID is
    /// already URL-derived on both paths per FT-16). Detail fields land
    /// in rawFields (search-row keys win on collision); parents are
    /// promoted to the typed fatherName/motherName the scorer and
    /// hypothesis engine read.
    nonisolated static func mergedDetailRecord(base: ParishRecord, detailFields: [String: String]) -> SourceRecord {
        var raw = base.common.rawFields
        for (key, value) in detailFields where raw[key] == nil {
            raw[key] = value
        }
        let common = RecordCommon(
            id: base.common.id,
            sourceID: base.common.sourceID,
            name: base.common.name,
            surname: base.common.surname,
            givenName: base.common.givenName,
            detailURL: base.common.detailURL,
            rawFields: raw
        )
        return .parish(ParishRecord(
            common: common,
            eventType: base.eventType,
            eventDate: base.eventDate,
            eventYear: base.eventYear,
            parish: base.parish ?? detailFields["parish"],
            county: base.county ?? detailFields["county"],
            fatherName: extractParent(detailFields, role: "father"),
            motherName: extractParent(detailFields, role: "mother")
        ))
    }

    /// Stable record ID (connector-audit FT-16). Record IDs are load-bearing
    /// across app launches — `record_rejections` and `evidence_records.user_status`
    /// are keyed on them — so they must never be built from `String.hashValue`,
    /// which is SipHash with a per-process random seed (a different ID every
    /// launch silently orphans user discard decisions). Same rule as
    /// FamilySearchSource's persona-ID fallback.
    ///
    /// Preference order:
    /// 1. The server-stable entry ID embedded in the detail URL
    ///    (`/search_records/<id>` or `/freereg1_csv_entries/<id>`).
    /// 2. A deterministic SHA256 digest of the normalised record content
    ///    (`name|date|parish|county|event_type`), truncated to 16 hex chars.
    nonisolated static func stableRecordID(
        detailURL: String?,
        name: String, date: String, parish: String,
        county: String, eventType: String
    ) -> String {
        if let detailURL, let url = URL(string: detailURL) {
            // lastPathComponent drops any query string; guard against a
            // degenerate href like "/search_records/?q=…" where the last
            // path segment is the route name rather than an entry ID.
            let segment = url.lastPathComponent
            if !segment.isEmpty, segment != "/",
               segment != "search_records", segment != "freereg1_csv_entries" {
                return "freereg_\(segment)"
            }
        }
        let normalised = [name, date, parish, county, eventType]
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(normalised.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "freereg_\(hex)"
    }

    nonisolated private static func stripTags(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return html }
        return regex.stringByReplacingMatches(
            in: html, range: NSRange(html.startIndex..., in: html), withTemplate: ""
        ).trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func extractYear(from dateStr: String) -> Int? {
        let pattern = #"\b(\d{4})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: dateStr, range: NSRange(dateStr.startIndex..., in: dateStr)),
              let range = Range(match.range(at: 1), in: dateStr) else { return nil }
        return Int(dateStr[range])
    }
}
