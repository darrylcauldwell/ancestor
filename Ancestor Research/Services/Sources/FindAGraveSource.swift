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
            var params: [String: String] = [
                "ajax": "true",
                "skip": "0",
                "limit": "20",
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
            if let firstGiven = Self.firstGivenName(query.givenName), !firstGiven.isEmpty {
                params["firstname"] = firstGiven
            }
            // Year filtering deliberately omitted. The previous code mapped
            // `query.yearFrom` → `birthyear` and `query.yearTo` → `deathyear`,
            // but those are the bounds of a single search-window axis (e.g.
            // for a burial record type, both refer to death year ±2), not
            // separate birth/death year values. For Ernest the query
            // produced birthyear=2015/deathyear=2019 — a 4-year-old child,
            // returning zero memorial hits.
            //
            // Until FAG gets proper subject-side birth+death year plumbing
            // via FindAGraveParams (§23 work), name-and-location search is
            // the correct narrowing — uncommon UK surnames like Cauldwell
            // return manageable result sets without year filters, and the
            // scorer's date gate catches any wrong-year hits downstream.
            if let location = fagParams.location, !location.isEmpty {
                params["location"] = location
            }

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

    /// Build a one-line description of a FindAGrave query for the live activity feed.
    /// First whitespace-separated token of a given-name string, trimmed.
    /// Used to coerce multi-given names ("Ernest Victor") to Find a Grave's
    /// first-given-only filter. Mirrors `FreeBMDSource.firstGivenName`.
    nonisolated static func firstGivenName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let first = raw.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let trimmed = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
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
            let memorialID = rec["memorialId"] as? Int ?? 0
            let nameForURL = rec["nameForURL"] as? String ?? ""

            // Build burial location
            var locationParts: [String] = []
            for key in ["cemeteryCityName", "cemeteryStateName", "cemeteryCountryName"] {
                if let val = rec[key] as? String, !val.isEmpty {
                    locationParts.append(val)
                }
            }

            let name = rec["titleName"] as? String ?? rec["fullName"] as? String ?? ""
            let nameParts = name.split(separator: " ")
            let surname = nameParts.last.map(String.init)
            let givenName = nameParts.count > 1 ? nameParts.dropLast().joined(separator: " ") : nil

            let birthDate = rec["birthDate"] as? String
            let deathDate = rec["deathDate"] as? String

            let common = RecordCommon(
                id: "findagrave_\(memorialID)",
                sourceID: "findagrave",
                name: name,
                surname: surname,
                givenName: givenName,
                detailURL: "\(baseURL)/memorial/\(memorialID)/\(nameForURL)",
                rawFields: rec.compactMapValues { "\($0)" }
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

        let nameParts = name.split(separator: " ")
        let surname = nameParts.last.map(String.init)
        let givenName = nameParts.count > 1 ? nameParts.dropLast().joined(separator: " ") : nil

        // Extract fields via itemprop regex
        let birthDate = extractItemprop("birthDate", from: html)
        let deathDate = extractItemprop("deathDate", from: html)?.replacingOccurrences(of: #"\s*\(aged.*\)"#, with: "", options: .regularExpression)
        // Birth/death towns from schema.org itemprop blocks. Plumbed
        // through to BurialRecord so the scorer's geography gate can
        // see where the person actually was born/died (often different
        // from where they're buried).
        let birthPlace = extractItempropBlock("birthPlace", from: html)
        let deathPlace = extractItempropBlock("deathPlace", from: html)

        // Cemetery
        let cemetery = extractItempropSpan("name", from: html)

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

        let common = RecordCommon(
            id: "findagrave_\(memorialID)",
            sourceID: "findagrave",
            name: name,
            surname: surname,
            givenName: givenName,
            detailURL: "\(baseURL)/memorial/\(memorialID)",
            rawFields: [
                "birthPlace": birthPlace ?? "",
                "deathPlace": deathPlace ?? "",
                "plot": plot ?? "",
            ].filter { !$0.value.isEmpty }
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
