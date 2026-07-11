import Foundation
import os

/// Find a Grave — world's largest gravesite collection (230M+ memorials)
/// https://www.findagrave.com
/// Access: Internal JSON API (search) + HTML scraping (detail)
/// Auth: None
/// Coverage: Worldwide, volunteer-contributed, strongest for military cemeteries
actor FindAGraveSource: RecordSource, DetailFetchingSource {

    // MARK: - RecordSource Protocol

    nonisolated let sourceID = "findagrave"
    nonisolated let displayName = "Find a Grave"
    nonisolated let recordTypes: Set<RecordType> = [.burial]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil  // unbounded
    nonisolated let coverageRegions: Set<Region> = []  // worldwide
    nonisolated let dataLineage: SourceLineage = .communityEdited
    nonisolated let trustTier: SourceTrustTier = .community
    nonisolated let evidenceDirectness: EvidenceDirectness = .derivative
    nonisolated let tosStatus = SourceToSStatus(
        level: .restricted,
        summary: "ToS restricts automated access — uses internal AJAX API, not a documented public API"
    )

    // MARK: - State

    private let http: any HTTPClient

    init(http: any HTTPClient = SourceHTTPClient.shared) {
        self.http = http
    }
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FindAGrave")
    /// Scheduled time for the next allowable request. Slot-reservation pattern
    /// (same as FreeBMD): each caller synchronously advances `nextRequestSlot`
    /// to its own scheduled instant before any await. Concurrent search() calls
    /// pick up unique slots 500 ms apart instead of all reading the same stale
    /// `lastRequestTime` and waking simultaneously.
    private var nextRequestSlot: ContinuousClock.Instant?
    private let requestDelay: Duration = .milliseconds(500)  // be polite to volunteer site

    private var lastSuccessfulSearch: Date?
    private var lastError: String?

    // MARK: - Constants

    nonisolated private static let baseURL = "https://www.findagrave.com"
    nonisolated private static let searchURL = "\(baseURL)/memorial/search"
    /// Real Safari UA. The prior bot-identifying UA ("AncestorResearch/1.0
    /// … genealogy research tool …") was triggering Find a Grave's anti-bot
    /// stack — detail fetches were returning the block page instead of the
    /// memorial. The UA alone isn't enough (FAG also fingerprints headers
    /// and TLS), but it removes the most obvious self-tell.
    nonisolated private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3.1 Safari/605.1.15"

    /// Browser-shaped request headers for navigation-style GETs (memorial
    /// detail pages). The Sec-Fetch-* set is what Safari sends on a normal
    /// in-tab page load — omitting them is itself a bot signal these days.
    nonisolated private static let browserHeaders: [String: String] = [
        "User-Agent": userAgent,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-GB,en;q=0.9",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "none",
        "Sec-Fetch-User": "?1",
        "Upgrade-Insecure-Requests": "1",
    ]

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        await searchWithOutcome(query).result
    }

    /// Envelope-aware search (connector-audit T1-01; instances T1-15 /
    /// T1-16). Cloudflare block pages and API error codes map to
    /// `.unavailable` — never a clean zero — and the response's own
    /// `total`/`tooMany` are parsed so the pinned limit=20 page is
    /// flagged as truncated when more memorials exist. Raising the
    /// limit / paging via skip is deferred to the efficiency series.
    func searchWithOutcome(_ query: RecordQuery) async -> SourceSearchEnvelope {
        guard recordTypes.contains(query.recordType) else { return SourceSearchEnvelope(.outsideCoverage(reason: "Find a Grave does not provide \(query.recordType.rawValue) records")) }

        // Extract source-specific params
        let fagParams: FindAGraveParams
        if case .findAGrave(let p) = query.sourceParams { fagParams = p }
        else { fagParams = FindAGraveParams(yearRangeWidth: 5, location: nil) }

        let summary = Self.activitySummary(query: query, params: fagParams)
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary, strictness: query.strictness))

        do {
            let params = Self.searchRequestParams(query: query, params: fagParams)
            let urlString = Self.searchURL + "?" + params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
            guard let url = URL(string: urlString) else {
                // T1-15: an internal failure is not "no memorial exists".
                await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: "invalid search URL", strictness: query.strictness))
                return SourceSearchEnvelope(.unavailable(reason: "invalid search URL"))
            }

            // All FAG fetches go through WKWebView (spec §22). URLSession's
            // TLS fingerprint differs from Safari's and Cloudflare scores
            // it as a bot; mixing surfaces is structurally fragile because
            // cookies captured by WKWebView don't carry the TLS profile
            // URLSession then re-presents. WKWebView IS Safari, so the
            // surface is consistent end-to-end.
            //
            // For the search endpoint (ajax=true → JSON response),
            // WKWebView's built-in JSON viewer renders the response into
            // the DOM; `document.body.textContent` extracts the raw JSON
            // text which parseSearchResults can consume directly.
            let jsonText = try await rateLimitedRequest {
                try await FindAGraveBrowserFetcher.fetchText(url: url)
            }
            let data = Data(jsonText.utf8)
            switch Self.parseSearchResponse(data) {
            case .blockPage:
                // T1-15: a non-JSON body from the browser fetcher is
                // FAG's anti-bot challenge (or another HTML shell), not
                // an empty index. Recording it as zero results would
                // read "no memorial exists" during a Cloudflare storm.
                let reason = "non-JSON response (likely Cloudflare block page)"
                lastError = reason
                logger.warning("Search blocked: \(reason)")
                await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: reason, strictness: query.strictness))
                return SourceSearchEnvelope(
                    result: .unavailable(reason: reason),
                    outcome: SearchOutcome(resultCount: 0, availability: .blocked(reason: reason))
                )
            case .apiError(let code):
                let reason = "Find a Grave API error (code \(code.map(String.init) ?? "unknown"))"
                lastError = reason
                logger.warning("Search failed: \(reason)")
                await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: reason, strictness: query.strictness))
                return SourceSearchEnvelope(.unavailable(reason: reason))
            case .success(let results, let total, let tooMany):
                lastSuccessfulSearch = Date()
                lastError = nil
                // T1-16 (honesty slice): the request is pinned to
                // limit=20/skip=0 — when the API's own total (or its
                // tooMany flag) says more memorials exist, the page is
                // a partial answer.
                let truncated = tooMany || (total.map { results.count < $0 } ?? false)
                logger.info("Search returned \(results.count) of \(total ?? results.count) results")
                await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: results.count, strictness: query.strictness))
                return SourceSearchEnvelope(
                    result: .results(results),
                    outcome: SearchOutcome(
                        resultCount: results.count,
                        totalAvailable: total,
                        truncated: truncated
                    )
                )
            }

        } catch {
            lastError = error.localizedDescription
            logger.warning("Search failed: \(error.localizedDescription)")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription, strictness: query.strictness))
            return SourceSearchEnvelope(.unavailable(reason: error.localizedDescription))
        }
    }

    // MARK: - Search request shape (T1-16 / T1-23)

    /// FAG's year-filter tolerance vocabulary — live-form ground truth,
    /// mirrored by the Python reference (sources/findagrave.py:134):
    /// `0` means exact (the filter param is omitted entirely), otherwise
    /// one of these discrete widths goes out as
    /// `birthyearfilter`/`deathyearfilter`.
    nonisolated static let yearFilterLadder = [1, 2, 3, 5, 10, 25]

    /// Resolve a subject-side year window into FAG's (center, tolerance)
    /// wire shape (T1-16).
    ///
    /// - center: midpoint of the window (the `birthyear`/`deathyear`
    ///   value).
    /// - tolerance: smallest ladder rung ≥ max(`floor`, window
    ///   half-span) — the filter may be WIDER than needed (recall-safe;
    ///   the scorer's date gate rejects wrong-year hits downstream) but
    ///   never narrower than the window. nil tolerance = exact match,
    ///   filter param omitted (Python parity: `if year_range:`).
    ///
    /// Returns nil when there is no window, or when the window's
    /// half-span exceeds the widest rung (±25): a filter that cannot
    /// cover the window would EXCLUDE plausible years — false negatives
    /// by construction — so an unrepresentable window goes out
    /// unfiltered instead.
    nonisolated static func yearAxis(
        range: ClosedRange<Int>?,
        floor toleranceFloor: Int
    ) -> (center: Int, tolerance: Int?)? {
        guard let range else { return nil }
        let center = (range.lowerBound + range.upperBound) / 2
        let halfSpan = max(center - range.lowerBound, range.upperBound - center)
        let needed = max(toleranceFloor, halfSpan)
        if needed == 0 { return (center, nil) }
        guard let tolerance = yearFilterLadder.first(where: { $0 >= needed }) else {
            return nil
        }
        return (center, tolerance)
    }

    /// The complete wire-param set for a search request — the single
    /// seam the query-shape tests pin (FindAGraveQueryShapeTests).
    ///
    /// Year-axis history (T1-16): year filtering was REMOVED here after
    /// a real bug — the old code mapped `query.yearFrom` → `birthyear`
    /// and `query.yearTo` → `deathyear`, but those are the bounds of a
    /// single record-type search window (for `.burial`, both are death
    /// year ± slack), not separate birth/death facts. For Ernest
    /// (died ~2017) the query produced birthyear=2015/deathyear=2019 —
    /// a 4-year-old child, zero memorial hits. The RESTORED design
    /// reads subject-side windows from `FindAGraveParams` only;
    /// `query.yearFrom`/`yearTo` are deliberately never consulted for
    /// year params, and each axis carries its own tolerance via
    /// `yearAxis`.
    nonisolated static func searchRequestParams(
        query: RecordQuery,
        params fagParams: FindAGraveParams
    ) -> [String: String] {
        var params: [String: String] = [
            "ajax": "true",
            "skip": "0",
            // T1-16: dispatcher-settable page size, clamped to FAG's
            // accepted band (~100 max — sources/findagrave.py:135).
            "limit": String(min(max(fagParams.limit, 1), 100)),
        ]

        if let surname = query.surname, !surname.isEmpty {
            params["lastname"] = surname
        }
        // Find a Grave's `firstname` parameter does prefix matching
        // against the first registered given name only. Memorials with
        // names like "Ernest Victor Cauldwell" are indexed as
        // firstname="Ernest" + middlename="Victor"; sending the full
        // multi-given string ("Ernest Victor") returns zero matches.
        // Strip to the first token so the dispatcher's `Ernest Victor`
        // subject becomes a usable FAG query — mirrors the fix for
        // FreeBMD's `given` field.
        if let firstGiven = firstGivenName(query.givenName), !firstGiven.isEmpty {
            params["firstname"] = firstGiven
            // T1-18: match `firstname` against registered nicknames too.
            // FAG's prefix match runs against the first registered given
            // name only, so firstname=John can never retrieve a memorial
            // registered "Jack Smith" — even though the scorer's
            // equivalence table (ScoringRules.nicknameEquivalents) knows
            // Jack=John downstream. Ground truth is the live search
            // form's "Include nickname" checkbox (checkbox-presence
            // semantics, same provenance as includeMaidenName below).
            // Broadening-only: extra hits are scored downstream, so a
            // server-side no-op costs nothing and can never manufacture
            // a false negative. Only meaningful alongside a firstname.
            params["includeNickName"] = "true"
        }
        // T1-16: separate subject-side year axes. A burial search keys
        // on the death year when one is known; the birth year rides
        // along as an independent narrowing. Absent windows emit no
        // year params at all — name-and-location search remains the
        // fallback narrowing, with the scorer's date gate catching
        // wrong-year hits downstream.
        if let birth = yearAxis(range: fagParams.birthYearRange, floor: fagParams.yearRangeWidth) {
            params["birthyear"] = String(birth.center)
            if let tolerance = birth.tolerance {
                params["birthyearfilter"] = String(tolerance)
            }
        }
        if let death = yearAxis(range: fagParams.deathYearRange, floor: fagParams.yearRangeWidth) {
            params["deathyear"] = String(death.center)
            if let tolerance = death.tolerance {
                params["deathyearfilter"] = String(tolerance)
            }
        }
        if let location = fagParams.location, !location.isEmpty {
            params["location"] = location
        }
        // T1-23: match `lastname` against the memorial's maiden-name
        // field too (checkbox-presence semantics — the live form only
        // sends the param when ticked). Broadening-only; see the
        // FindAGraveParams doc for provenance.
        if fagParams.includeMaidenName {
            params["includeMaidenName"] = "true"
        }
        return params
    }

    /// First whitespace-separated token of a given-name string, trimmed.
    /// Used to coerce multi-given names ("Ernest Victor") to Find a Grave's
    /// first-given-only filter. Mirrors `FreeBMDSource.firstGivenName`.
    nonisolated static func firstGivenName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let first = raw.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let trimmed = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Name derivation (T1-23 response side)

    /// Generational/honorific suffixes that must never be mistaken for a
    /// surname when a display name is split on whitespace (T1-23):
    /// "John Smith Jr." previously yielded surname "Jr.". Lower-cased
    /// comparison set; conservative on purpose — a rare genuine surname
    /// colliding with this set costs one widened name-gate comparison,
    /// while a missed suffix hard-fails the gate on a nonsense surname.
    nonisolated private static let nameSuffixes: Set<String> = [
        "jr", "jr.", "sr", "sr.", "ii", "iii", "iv", "esq", "esq.",
    ]

    /// Derive (surname, givenName) for a search-payload record (T1-23
    /// response side). Prefers the payload's own structured name keys —
    /// the fixture corpus shows discrete `firstName`/`middleName`/
    /// `lastName`/`maidenName` fields (e.g. lastName "Brook-Cauldwell",
    /// maidenName "Rollins") that the old last-token display-name split
    /// mangled: hyphen-free compound surnames collapsed and FAG's
    /// maiden-name-in-display-name convention was absorbed into
    /// givenName. Falls back to `splitDisplayName` when the structured
    /// keys are absent. `maidenName` itself needs no plumbing here — the
    /// stringified payload lands in rawFields verbatim, so the name gate
    /// can consult rawFields["maidenName"] as an alternate surname.
    /// (Key names pending confirmation against a live payload — audit
    /// §6.3 T1-23 note — same follow-up pattern as the not-found
    /// markers in `classifyMemorialDetail`.)
    nonisolated static func deriveNameFields(
        record rec: [String: Any],
        displayName: String
    ) -> (surname: String?, givenName: String?, ambiguousSplit: Bool) {
        let lastName = nonEmptyString(rec["lastName"])
        let firstName = nonEmptyString(rec["firstName"])
        let middleName = nonEmptyString(rec["middleName"])
        if lastName != nil || firstName != nil {
            let given = [firstName, middleName].compactMap { $0 }.joined(separator: " ")
            return (lastName, given.isEmpty ? nil : given, false)
        }
        return splitDisplayName(displayName)
    }

    /// Last-token display-name split, suffix-aware (T1-23). Trailing
    /// generational suffixes are stripped before the split so they can
    /// never become the surname. `ambiguous` is true when 3+ tokens
    /// remain: middle names, compound surnames, and FAG's maiden-name
    /// convention are indistinguishable from whitespace alone, so the
    /// flag is surfaced (rawFields["nameSplitAmbiguous"]) for the name
    /// gate to widen tolerance rather than hard-fail.
    nonisolated static func splitDisplayName(
        _ name: String
    ) -> (surname: String?, givenName: String?, ambiguousSplit: Bool) {
        var tokens = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while let last = tokens.last, nameSuffixes.contains(last.lowercased()) {
            tokens.removeLast()
        }
        guard let surname = tokens.last else { return (nil, nil, false) }
        let given = tokens.dropLast().joined(separator: " ")
        return (surname, given.isEmpty ? nil : given, tokens.count > 2)
    }

    nonisolated private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func activitySummary(query: RecordQuery, params: FindAGraveParams) -> String {
        let searchTerms: String = {
            let surname = query.surname ?? ""
            if let given = query.givenName, !given.isEmpty { return "\(given) \(surname)".trimmingCharacters(in: .whitespaces) }
            return surname
        }()
        let locationLabel = (params.location?.isEmpty == false) ? " \(params.location!)" : ""
        let yearLabel: String
        switch (query.yearFrom, query.yearTo) {
        case let (yf?, yt?) where yf == yt: yearLabel = " \(yf)"
        case let (yf?, yt?): yearLabel = " \(yf)–\(yt)"
        default: yearLabel = ""
        }
        return "Find a Grave\(locationLabel) burials: \(searchTerms)\(yearLabel)"
    }

    // MARK: - Detail Fetching

    func fetchDetail(recordID: String) async -> SourceQueryResult {
        guard let memorialID = Int(recordID.replacingOccurrences(of: "findagrave_", with: "")) else {
            return .unavailable(reason: "Invalid memorial ID: \(recordID)")
        }
        let urlString = "\(Self.baseURL)/memorial/\(memorialID)"
        guard let url = URL(string: urlString) else {
            return .unavailable(reason: "Invalid URL for memorial \(memorialID)")
        }

        do {
            // All FAG fetches via WKWebView — see search() for rationale.
            // Detail pages are HTML; `documentElement.outerHTML` gives us
            // the schema.org markup parseMemorialDetail expects.
            let html = try await rateLimitedRequest {
                try await FindAGraveBrowserFetcher.fetchHTML(url: url)
            }
            return Self.classifyMemorialDetail(html, memorialID: memorialID)
        } catch {
            logger.warning("Detail fetch failed for memorial \(memorialID): \(error.localizedDescription)")
            return .unavailable(reason: error.localizedDescription)
        }
    }

    /// T1-15 (detail half): when the memorial-marker guard fails, only a
    /// body carrying FAG's genuine not-found copy is an honest empty —
    /// anything else (Cloudflare challenge, generic site shell) is the
    /// source refusing to answer and must surface as `.unavailable`,
    /// not "no memorial exists".
    nonisolated static func classifyMemorialDetail(_ html: String, memorialID: Int) -> SourceQueryResult {
        if let record = parseMemorialDetail(html, memorialID: memorialID) {
            return .results([record])
        }
        // Genuine not-found markers (memorial deleted / merged / bad ID).
        // Conservative substring set; confirm against a live capture in
        // the next live-probe session (audit §5.6).
        // (No bare "404" substring — a block page's asset URLs could
        // contain it, and misclassifying a block as a clean empty is the
        // exact failure this guard exists to prevent.)
        let notFoundMarkers = [
            "does not exist",
            "may have been removed",
            "page not found",
        ]
        let lowered = html.lowercased()
        if notFoundMarkers.contains(where: { lowered.contains($0) }) {
            return .results([])
        }
        return .unavailable(reason: "memorial page unrecognized (no memorial or not-found markers) — likely block page")
    }

    // MARK: - Cloudflare clearance (§22)
    //
    // Find a Grave is fronted by Cloudflare's JS-challenge bot management.
    // URLSession can't solve the challenge alone, so the first time we
    // need to talk to FAG in this process we spawn a hidden WKWebView via
    // `FindAGraveCloudflareClearance`, let it execute the JS, capture the
    // `cf_clearance` cookie, and reuse it for subsequent URLSession
    // requests. The cookie persists in Keychain across launches (~30 day
    // Cloudflare lifetime) so most runs don't pay the WKWebView cost.

    private func ensureCloudflareClearance() async -> String? {
        if await FindAGraveCookieStore.shared.hasValidClearance(),
           let header = await FindAGraveCookieStore.shared.cookieHeader() {
            return header
        }
        do {
            let cookies = try await FindAGraveCloudflareClearance.acquire()
            await FindAGraveCookieStore.shared.store(cookies)
            return await FindAGraveCookieStore.shared.cookieHeader()
        } catch {
            logger.warning("Cloudflare clearance acquisition failed: \(error.localizedDescription) — Find a Grave requests will run without cookies and likely return zero results")
            return nil
        }
    }

    // MARK: - Rate Limiting

    /// Serializes requests with a strict gap between consecutive calls.
    /// Slot-reservation pattern (see FreeBMDSource for the rationale): each
    /// caller synchronously advances `nextRequestSlot` so 12+ concurrent
    /// search()/fetchDetail() calls get unique slots instead of all reading
    /// the same stale `lastRequestTime` and waking simultaneously.
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

    // MARK: - Parsing (static, testable with canned data)

    /// Typed search-response classification (connector-audit T1-15).
    /// Python parity: findagrave.py:174-188 distinguishes "Failed to
    /// parse response" / "API error (code N)" / total / tooMany.
    nonisolated enum SearchParse: Sendable {
        /// Well-formed API payload. `total` is the API's own claimed hit
        /// count; `tooMany` its overflow flag.
        case success(records: [SourceRecord], total: Int?, tooMany: Bool)
        /// Body is not a JSON object — via the browser fetcher this is
        /// almost always Cloudflare's challenge / an HTML shell.
        case blockPage
        /// JSON payload with a non-200 embedded responseCode.
        case apiError(code: Int?)
    }

    /// Classify a search response body. Never conflates failure shapes
    /// with an empty result set.
    nonisolated static func parseSearchResponse(_ data: Data) -> SearchParse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .blockPage
        }
        guard let responseCode = json["responseCode"] as? Int else {
            return .apiError(code: nil)
        }
        guard responseCode == 200 else {
            return .apiError(code: responseCode)
        }
        // Missing "records" on a 200 payload is a genuine empty set
        // (python parity: data.get("records", [])).
        let rawRecords = json["records"] as? [[String: Any]] ?? []
        let total = json["total"] as? Int
        let tooMany = json["tooMany"] as? Bool ?? false
        return .success(records: parseRecordArray(rawRecords), total: total, tooMany: tooMany)
    }

    /// Records-only convenience preserved for callers/tests that don't
    /// consume the envelope — failure shapes collapse to [] here.
    nonisolated static func parseSearchResults(_ data: Data) -> [SourceRecord] {
        if case .success(let records, _, _) = parseSearchResponse(data) {
            return records
        }
        return []
    }

    nonisolated private static func parseRecordArray(_ records: [[String: Any]]) -> [SourceRecord] {
        return records.compactMap { rec -> SourceRecord? in
            // T1-27: record IDs are the dedup keys everywhere (evidence
            // rows, rejection lookups, deterministic LifeEvent IDs). The
            // old `?? 0` fallback collapsed every id-less record to
            // "findagrave_0" — dedup then reduced them to one survivor
            // with a broken detailURL. A record we cannot stably
            // identify is a record we cannot safely keep: skip it.
            guard let memorialID = memorialID(from: rec) else { return nil }
            let nameForURL = rec["nameForURL"] as? String ?? ""

            // Build burial location
            var locationParts: [String] = []
            for key in ["cemeteryCityName", "cemeteryStateName", "cemeteryCountryName"] {
                if let val = rec[key] as? String, !val.isEmpty {
                    locationParts.append(val)
                }
            }

            let name = rec["titleName"] as? String ?? rec["fullName"] as? String ?? ""
            // T1-23 (response side): structured name keys beat the
            // last-token display-name split.
            let derived = deriveNameFields(record: rec, displayName: name)

            let birthDate = rec["birthDate"] as? String
            let deathDate = rec["deathDate"] as? String

            var rawFields = rec.compactMapValues { "\($0)" }
            if derived.ambiguousSplit {
                rawFields["nameSplitAmbiguous"] = "true"
            }

            let common = RecordCommon(
                id: "findagrave_\(memorialID)",
                sourceID: "findagrave",
                name: name,
                surname: derived.surname,
                givenName: derived.givenName,
                detailURL: "\(baseURL)/memorial/\(memorialID)/\(nameForURL)",
                rawFields: rawFields
            )

            return .burial(BurialRecord(
                common: common,
                deathDate: deathDate,
                deathYear: ScoringRules.extractYear(from: deathDate ?? ""),
                birthDate: birthDate,
                birthYear: ScoringRules.extractYear(from: birthDate ?? ""),
                // Birth/death towns are only in the detail page's
                // schema.org itemprop blocks, not the search-results
                // payload. Leave nil here; the detail-page parse path
                // populates them.
                birthPlace: nil,
                deathPlace: nil,
                burialLocation: locationParts.joined(separator: ", "),
                cemetery: rec["cemeteryName"] as? String,
                memorialID: memorialID,
                inscription: nil,  // only available from detail page
                bio: nil,
                isVeteran: rec["isVeteran"] as? Bool ?? false
            ))
        }
    }

    /// Positive memorial identity from a search-payload record (T1-27).
    /// The API sends an integer; a numeric string is tolerated. Missing,
    /// non-numeric, and non-positive values all mean "no stable
    /// identity" — the caller skips the record rather than minting the
    /// colliding "findagrave_0".
    nonisolated static func memorialID(from rec: [String: Any]) -> Int? {
        let parsed: Int?
        if let intValue = rec["memorialId"] as? Int {
            parsed = intValue
        } else if let stringValue = rec["memorialId"] as? String {
            parsed = Int(stringValue)
        } else {
            parsed = nil
        }
        guard let parsed, parsed > 0 else { return nil }
        return parsed
    }

    /// Parse memorial detail HTML into a SourceRecord. Returns nil when the
    /// HTML doesn't look like a memorial page (e.g. Find a Grave's anti-bot
    /// block page returns a generic site shell with the title "Find a Grave
    /// - Millions of Cemetery Records" and none of the schema.org memorial
    /// markup). Without this guard a block response would parse into a
    /// garbage record carrying raw HTML in the name field, score impossible
    /// for the wrong reason, and clutter evidence.
    nonisolated static func parseMemorialDetail(_ html: String, memorialID: Int) -> SourceRecord? {
        // Memorial-page sanity check. Real memorials carry at least one of:
        //   - schema.org itemprop birthDate / deathDate / name
        //   - the in-page inscription / fullBio / partBio / memPhoto markers
        // Block pages and captcha shells carry none of these. Bail early so
        // we don't synthesise a half-parsed record.
        let memorialMarkers = [
            #"itemprop="birthDate""#,
            #"itemprop="deathDate""#,
            #"id="inscriptionValue""#,
            #"id="fullBio""#,
            #"id="partBio""#,
            #"id="memPhoto""#,
        ]
        guard memorialMarkers.contains(where: { html.contains($0) }) else {
            return nil
        }

        // Name from <title>
        let name: String
        if let match = html.range(of: #"<title>([^(]+)\s*\("#, options: .regularExpression) {
            let captured = html[match]
            name = captured.replacingOccurrences(of: "<title>", with: "")
                .replacingOccurrences(of: " (", with: "")
                .replacingOccurrences(of: " - Find a Grave Memorial", with: "")
                .trimmingCharacters(in: .whitespaces)
        } else {
            name = ""
        }

        // T1-23: same suffix-aware split as the search parse — the
        // <title> name has no structured fields to prefer.
        let derived = splitDisplayName(name)
        let surname = derived.surname
        let givenName = derived.givenName

        // Extract fields via itemprop regex
        let birthDate = extractItemprop("birthDate", from: html)
        // T1-22 (in-scope slice): the "(aged NN)" suffix is the only
        // birth-year evidence on many older stones (death date + age,
        // no birth date). Capture it BEFORE stripping — it lands in
        // rawFields["aged"] below; promoting it onto BurialRecord and
        // into the scorer's recordedAge is the RecordTypes/RecordScorer
        // half of T1-22 (same edit slot as T1-02's military age).
        let rawDeathDate = extractItemprop("deathDate", from: html)
        let agedAtDeath = extractAgedValue(from: rawDeathDate)
        let deathDate = rawDeathDate?.replacingOccurrences(of: #"\s*\(aged.*\)"#, with: "", options: .regularExpression)
        // Birth/death towns from schema.org itemprop blocks. Plumbed
        // through to BurialRecord so the scorer's geography gate can
        // see where the person actually was born/died (often different
        // from where they're buried).
        let birthPlace = extractItempropBlock("birthPlace", from: html)
        let deathPlace = extractItempropBlock("deathPlace", from: html)

        // Cemetery
        let cemetery = extractItempropSpan("name", from: html)
        // T1-19 (in-scope slice): the cemetery's own page URL — Python
        // parity (findagrave.py:268-270). Enables the CWGC→FAG
        // cemetery-corroboration join downstream without re-deriving
        // the cemetery id from free text.
        let cemeteryURL = extractCemeteryURL(from: html)

        // Burial location from address schema
        var locParts: [String] = []
        for prop in ["addressLocality", "addressRegion", "addressCountry"] {
            if let val = extractItemprop(prop, from: html) {
                locParts.append(val)
            }
        }

        // Bio
        let bio = extractDivContent("fullBio", from: html) ?? extractDivContent("partBio", from: html)

        // Inscription
        let inscription = extractDivContent("inscriptionValue", from: html)

        // Plot
        let plot = extractDivContent("plotValueLabel", from: html)

        // Structured itemprop dates first; fall back to mining inscription
        // and bio when a memorial omits the schema.org markup but carries
        // dates in the free-text inscription ("1919 — 2017") or biography.
        // Without this fallback, otherwise-perfect name+place matches can't
        // be promoted past the 4-gate scorer's year axis.
        let itempropBirthYear = ScoringRules.extractYear(from: birthDate ?? "")
        let itempropDeathYear = ScoringRules.extractYear(from: deathDate ?? "")
        let (textBirthYear, textDeathYear): (Int?, Int?) = (itempropBirthYear == nil || itempropDeathYear == nil)
            ? extractYearsFromMemorialText([inscription, bio].compactMap { $0 }.joined(separator: "\n"))
            : (nil, nil)
        let finalBirthYear = itempropBirthYear ?? textBirthYear
        let finalDeathYear = itempropDeathYear ?? textDeathYear

        var rawFields = [
            "birthPlace": birthPlace ?? "",
            "deathPlace": deathPlace ?? "",
            "plot": plot ?? "",
            "cemeteryURL": cemeteryURL ?? "",
        ].filter { !$0.value.isEmpty }
        if let agedAtDeath {
            rawFields["aged"] = String(agedAtDeath)
        }
        if derived.ambiguousSplit {
            rawFields["nameSplitAmbiguous"] = "true"
        }
        // T1-20: the Family Members block — parent/spouse/sibling/child
        // links between memorials, volunteer-curated with citable URLs.
        // Evidence Firewall: these are RECORD FIELDS only. Nothing here
        // writes relationships; a downstream consumer may propose
        // lead-tier relationships through the firewall queues, and the
        // deterministic sandwich decides.
        let familyLinks = parseFamilyLinks(html)
        if !familyLinks.isEmpty, let encoded = encodeFamilyLinks(familyLinks) {
            rawFields["familyLinks"] = encoded
        }

        let common = RecordCommon(
            id: "findagrave_\(memorialID)",
            sourceID: "findagrave",
            name: name,
            surname: surname,
            givenName: givenName,
            detailURL: "\(baseURL)/memorial/\(memorialID)",
            rawFields: rawFields
        )

        return .burial(BurialRecord(
            common: common,
            deathDate: deathDate,
            deathYear: finalDeathYear,
            birthDate: birthDate,
            birthYear: finalBirthYear,
            birthPlace: birthPlace,
            deathPlace: deathPlace,
            burialLocation: locParts.joined(separator: ", "),
            cemetery: cemetery,
            memorialID: memorialID,
            inscription: inscription,
            bio: bio,
            isVeteran: false  // not available from detail page
        ))
    }

    // MARK: - Detail-page field extraction (T1-19 / T1-20 / T1-22)

    /// T1-22 (in-scope slice): the death-date itemprop's "(aged NN)"
    /// suffix, read before the display-date strip discards it.
    nonisolated static func extractAgedValue(from rawDeathDate: String?) -> Int? {
        guard let rawDeathDate else { return nil }
        let pattern = #"\(aged\s+(\d{1,3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: rawDeathDate, range: NSRange(rawDeathDate.startIndex..., in: rawDeathDate)),
              let range = Range(match.range(at: 1), in: rawDeathDate) else { return nil }
        return Int(rawDeathDate[range])
    }

    /// T1-19 (in-scope slice): absolute URL of the memorial's cemetery
    /// page. Faithful port of the Python pattern
    /// (findagrave.py:268-270): `<a href="(/cemetery/\d+/[^"]+)"` with
    /// `itemprop="url"` on the same tag.
    nonisolated static func extractCemeteryURL(from html: String) -> String? {
        let pattern = #"<a href="(/cemetery/\d+/[^"]+)"[^>]*itemprop="url""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return baseURL + String(html[range])
    }

    // MARK: - Family Members parsing (T1-20)

    /// One entry from a memorial page's Family Members block: a
    /// volunteer-curated link from this memorial to a relative's
    /// memorial. Record-field data only — the Evidence Firewall means
    /// these are never written as relationships by the connector.
    nonisolated struct FamilyLink: Codable, Sendable, Equatable {
        /// Normalised group label: parent | spouse | sibling |
        /// halfSibling | child.
        let relation: String
        let name: String
        let memorialID: Int
        /// Displayed year span, verbatim (e.g. "1850–1920",
        /// "unknown–1944"); nil when the block shows no years.
        let years: String?
    }

    /// Recognised Family Members group headings → normalised relation.
    /// Order matters: "Half Siblings" must match before "Siblings".
    nonisolated private static let familyGroupHeadings: [(pattern: String, relation: String)] = [
        ("Half[\\s-]?Siblings", "halfSibling"),
        ("Siblings", "sibling"),
        ("Parents", "parent"),
        ("Spouses?", "spouse"),
        ("Children", "child"),
    ]

    /// Extract the Family Members block into structured tuples (T1-20).
    /// Neither the Python reference nor the pre-audit Swift parsed this
    /// section, so there is no port to copy — the parser keys on FAG's
    /// structural invariants instead of exact markup: a "Family Members"
    /// heading, group labels (Parents/Spouse/Siblings/…) as tag text,
    /// and `/memorial/<id>/…` anchors under each label. Links before
    /// the first recognised group label are ignored; the scan is
    /// bounded at the section's structural close so unrelated memorial
    /// links elsewhere on the page (suggestions, sponsor modules) can't
    /// bleed in. (Markup pending confirmation against a live capture —
    /// same follow-up pattern as `classifyMemorialDetail`'s not-found
    /// markers.)
    nonisolated static func parseFamilyLinks(_ html: String) -> [FamilyLink] {
        guard let heading = html.range(of: "Family Members", options: .caseInsensitive) else {
            return []
        }
        let tail = html[heading.upperBound...]
        // Bound the section: first structural close after the heading,
        // else a conservative cap — FAG family blocks are far smaller.
        var sectionEnd = tail.index(tail.startIndex, offsetBy: 30_000, limitedBy: tail.endIndex) ?? tail.endIndex
        for marker in ["</section>", "</aside>"] {
            if let close = tail.range(of: marker), close.lowerBound < sectionEnd {
                sectionEnd = close.lowerBound
            }
        }
        let section = String(tail[..<sectionEnd])
        let nsSection = section as NSString
        let fullRange = NSRange(location: 0, length: nsSection.length)

        // Locate group labels as tag text (">Parents<") so prose
        // mentions can't open a group.
        var groups: [(location: Int, relation: String)] = []
        for (pattern, relation) in familyGroupHeadings {
            guard let regex = try? NSRegularExpression(pattern: ">\\s*(\(pattern))\\s*<", options: .caseInsensitive) else { continue }
            for match in regex.matches(in: section, range: fullRange) {
                // First label wins where patterns overlap (Half Siblings
                // also contains "Siblings" — but ">…<" anchoring plus
                // ordering means the same text can't match twice at one
                // location unless the broader pattern already claimed it).
                if !groups.contains(where: { $0.location == match.range.location }) {
                    groups.append((match.range.location, relation))
                }
            }
        }
        guard !groups.isEmpty else { return [] }
        groups.sort { $0.location < $1.location }

        guard let anchorRegex = try? NSRegularExpression(
            pattern: #"<a[^>]*href="/memorial/(\d+)/[^"]*"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }

        var links: [FamilyLink] = []
        var seen = Set<String>()
        for match in anchorRegex.matches(in: section, range: fullRange) {
            // Group = nearest recognised label above the anchor.
            guard let group = groups.last(where: { $0.location < match.range.location }) else {
                continue
            }
            guard let idRange = Range(match.range(at: 1), in: section),
                  let bodyRange = Range(match.range(at: 2), in: section),
                  let memorialID = Int(section[idRange]), memorialID > 0 else {
                continue
            }
            let body = String(section[bodyRange])
            let (name, years) = familyMemberNameAndYears(fromAnchorBody: body)
            guard !name.isEmpty else { continue }
            let key = "\(group.relation)|\(memorialID)"
            guard seen.insert(key).inserted else { continue }
            links.append(FamilyLink(relation: group.relation, name: name, memorialID: memorialID, years: years))
        }
        return links
    }

    /// Name + year-span from a family-member anchor's inner HTML.
    /// Prefers `itemprop="name"`; falls back to tag-stripped text with
    /// the year span (if any) removed.
    nonisolated private static func familyMemberNameAndYears(
        fromAnchorBody body: String
    ) -> (name: String, years: String?) {
        // Dash may arrive as a character or an HTML entity — FAG's
        // server-rendered markup is not consistent about it.
        let yearsPattern = #"\b((?:\d{4}|unknown)\s*(?:[–—-]|&ndash;|&mdash;|&#8211;|&#8212;)\s*(?:\d{4}|unknown))\b"#
        var years: String? = nil
        if let regex = try? NSRegularExpression(pattern: yearsPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let range = Range(match.range(at: 1), in: body) {
            years = String(body[range]).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }

        var name = extractItemprop("name", from: body) ?? {
            var text = body.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            if let years {
                text = text.replacingOccurrences(of: years, with: " ")
            }
            return text
        }()
        name = name
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The fallback text may still carry the span when whitespace
        // inside it differs from the normalised form — strip any
        // residual year-span tokens defensively.
        if let regex = try? NSRegularExpression(pattern: yearsPattern, options: .caseInsensitive) {
            let nsName = name as NSString
            name = regex.stringByReplacingMatches(in: name, range: NSRange(location: 0, length: nsName.length), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (name, years)
    }

    /// Deterministic JSON serialisation of family links for
    /// rawFields["familyLinks"] — sorted keys, document order preserved.
    nonisolated static func encodeFamilyLinks(_ links: [FamilyLink]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(links) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Extract birth and death years from free-text memorial inscription or
    /// biography. Find a Grave memorials sometimes lack schema.org itemprop
    /// dates but carry dates in the inscription ("1919 — 2017") or bio
    /// ("born 18 August 1919, died 6 January 2017"). Best-effort fallback;
    /// returns (nil, nil) when no plausible year can be extracted.
    ///
    /// Strategy, in priority order — first hit wins per axis:
    ///   1. Explicit "born/birth ... YEAR" → birth; "died/death ... YEAR" → death.
    ///   2. A year range like "YEAR-YEAR" / "YEAR — YEAR" / "YEAR to YEAR"
    ///      with the earlier year as birth and the later as death.
    ///   3. Two or more distinct years in the text — earliest → birth,
    ///      latest → death.
    ///   4. A lone year is treated as the death year (memorials emphasise it).
    nonisolated static func extractYearsFromMemorialText(_ text: String) -> (birth: Int?, death: Int?) {
        guard !text.isEmpty else { return (nil, nil) }
        let normalised = text
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")

        var birth: Int? = nil
        var death: Int? = nil

        // (1) Explicit prefixes — match a year within ~30 chars of the keyword
        // so "born in 1919" / "died 6 January 2017" both hit.
        if let m = firstYear(matching: #"\b(?:born|birth)\b[^\n.;]{0,30}?\b(1[0-9]\d{2}|20[0-2]\d)\b"#, in: normalised) {
            birth = m
        }
        if let m = firstYear(matching: #"\b(?:died|death|deceased)\b[^\n.;]{0,30}?\b(1[0-9]\d{2}|20[0-2]\d)\b"#, in: normalised) {
            death = m
        }

        // (2) Year range — "1919-2017", "1919 — 2017", "1919 to 2017".
        if birth == nil || death == nil {
            let rangePattern = #"\b(1[0-9]\d{2}|20[0-2]\d)\s*(?:-|to)\s*(1[0-9]\d{2}|20[0-2]\d)\b"#
            if let regex = try? NSRegularExpression(pattern: rangePattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: normalised, range: NSRange(normalised.startIndex..., in: normalised)),
               let r1 = Range(match.range(at: 1), in: normalised),
               let r2 = Range(match.range(at: 2), in: normalised),
               let a = Int(normalised[r1]), let b = Int(normalised[r2]),
               a <= b {
                if birth == nil { birth = a }
                if death == nil { death = b }
            }
        }

        // (3) and (4) — distinct years scanned out of any free-text remainder.
        if birth == nil || death == nil {
            let years = allYears(in: normalised)
            if years.count >= 2 {
                if birth == nil { birth = years.min() }
                if death == nil { death = years.max() }
            } else if let only = years.first, death == nil {
                death = only
            }
        }

        // Cross-check — a death year before a birth year is nonsense and
        // probably means we picked up unrelated dates from bio prose
        // (e.g. "served WWII 1939-1945" elsewhere in a long biography).
        if let b = birth, let d = death, d < b {
            return (nil, nil)
        }
        return (birth, death)
    }

    nonisolated private static func firstYear(matching pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    nonisolated private static func allYears(in text: String) -> [Int] {
        let pattern = #"\b(1[0-9]\d{2}|20[0-2]\d)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { Int(nsText.substring(with: $0.range)) }
    }

    // MARK: - HTML Parsing Helpers

    nonisolated private static func extractItemprop(_ prop: String, from html: String) -> String? {
        let pattern = "itemprop=\"\(prop)\">([^<]+)<"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range]).trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func extractItempropBlock(_ prop: String, from html: String) -> String? {
        let pattern = "itemprop=\"\(prop)\">\\s*(.*?)\\s*</div>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        var text = String(html[range])
        // Strip HTML tags
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func extractItempropSpan(_ prop: String, from html: String) -> String? {
        let pattern = "itemprop=\"\(prop)\">([^<]+)</span>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range]).trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func extractDivContent(_ divID: String, from html: String) -> String? {
        let pattern = "id=\"\(divID)\"[^>]*>(.*?)</(?:div|span)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        var text = String(html[range])
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</p>\s*<p>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
