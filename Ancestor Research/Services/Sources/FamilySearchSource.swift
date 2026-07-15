import Foundation
import os

/// FamilySearch — 2000+ historical-record collections, parish registers,
/// civil registration, censuses (UK + global), military, probate,
/// immigration, etc.
/// https://www.familysearch.org
/// Access: cookie-authenticated website backend until App Store / Partner
/// approval lands and OAuth becomes available.
/// Auth: session cookies captured via WKWebView (`FamilySearchAuthView`),
/// persisted in Keychain via `FamilySearchCookieStore`.
/// Coverage: globally vast; we treat as worldwide with date range nil.
///
/// See AncestorApp/FAMILYSEARCH_SOURCE_SPEC.md for the full design.
/// First-cut scope per §9.1: search-only, multi-persona parse,
/// nine RecordType cases, collection-title pattern trust tiering.
actor FamilySearchSource: RecordSource, AuthenticatingSource {

    // MARK: - RecordSource protocol

    nonisolated let sourceID = "familysearch"
    // SOURCE_WEIGHTING Change 4 — scope steers the place-axis LEVEL
    // (county-level soft axes at bounded scopes; country-level at
    // national, so remote true records aren't rank-demoted below the
    // single fetched page). FS place params are documented single-value
    // fuzzy matches ("records within three jurisdiction levels", Tree
    // Person Search resource, fetched 2026-07-15) — no multi-county OR
    // exists, so .adjacent is a disclosed residual equal to .county
    // (pinned in ScopeContractTests).
    nonisolated let scopeHandling: ScopeHandling = .scoped
    nonisolated let displayName = "FamilySearch"
    nonisolated let recordTypes: Set<RecordType> = [
        .birth, .death, .marriage, .census, .burial,
        .military, .probate, .baptism, .christening, .parish,
    ]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales, .scotland, .ireland, .commonwealthMilitary]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "various")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(
        level: .restricted,
        summary: "Authenticated; cookie-based until OAuth API access is approved"
    )

    // MARK: - AuthenticatingSource protocol

    nonisolated let credentialLabel = "FamilySearch session cookies"

    func setCredential(_ value: String) async {
        // Cookies are managed by FamilySearchCookieStore; this hook is here
        // for protocol completeness. The Settings UI captures via WKWebView
        // and writes to the cookie store directly.
    }

    func clearCredentials() async {
        await FamilySearchCookieStore.shared.clear()
    }

    // MARK: - State

    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FamilySearch")

    /// Rate-limit pacing — 1 req/sec is the conservative start per §10 of
    /// the spec; FamilySearch publishes no rate limits for the cookie path.
    private var nextRequestSlot: ContinuousClock.Instant?
    private let requestDelay: Duration = .seconds(1)

    /// 429 circuit-breaker mirroring the FreeBMDSource pattern. Same
    /// philosophy: when throttled, stop hitting them rather than retry
    /// harder.
    private var consecutive429s: Int = 0
    private var circuitOpenUntil: ContinuousClock.Instant?
    private let circuit429Threshold: Int = 3
    private let circuitCooldownLadder: [Duration] = [.seconds(60), .seconds(300), .seconds(900)]
    private var circuitTripCount: Int = 0
    private var giveUpRequests: Bool = false

    private var lastSuccessfulSearch: Date?
    private var lastError: String?

    // MARK: - Constants

    nonisolated private static let searchURL = URL(string: "https://www.familysearch.org/service/search/hr/v2/personas")!
    nonisolated private static let arkBase = "https://www.familysearch.org/ark:/61903/1:1:"
    /// Documented hard max per page for this endpoint family
    /// (FAMILYSEARCH_SOURCE_SPEC §15.7: count 1–100). Shared by the URL
    /// builder and the truncation rule.
    nonisolated static let pageSize = 100
    /// Safari UA mirrors what the Python plugin sends — FamilySearch rejects
    /// default URLSession UAs as bot traffic.
    nonisolated private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3.1 Safari/605.1.15"

    /// Above this span (years) a death/burial window is a birth-derived guess
    /// (`ResearchSubject.yearRange` returns birth+15..birth+95 when no death
    /// year is known) rather than a known death year (~4-year span from ±2).
    /// A wide guess must not pin `q.deathLikeDate`, or FamilySearch excludes
    /// Funeral-Notices personas — which carry a Funeral fact, not a Death fact,
    /// and so never match the deathLike date axis — server-side.
    nonisolated static let deathDateWindowThreshold = 15

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        await searchWithOutcome(query).result
    }

    /// Envelope-aware search (connector-audit T1-01;
    /// FAMILYSEARCH_READ_LEG_PLAN #Change3). Surfaces the response's own
    /// total-hit count (top-level `results`) as `totalAvailable` and flags
    /// page-1 truncation — previously a 100-record page of a
    /// multi-thousand-hit query read as a conclusive, complete answer in
    /// GPS accounting and ladder decisions. Deliberately NO pagination
    /// loop here: that lands with the OAuth transport (#Change5) so the
    /// interim cookie path gains no new request volume.
    func searchWithOutcome(_ query: RecordQuery) async -> SourceSearchEnvelope {
        guard recordTypes.contains(query.recordType) else {
            return SourceSearchEnvelope(.outsideCoverage(reason: "FamilySearch does not surface \(query.recordType.rawValue) records via this plugin"))
        }
        guard let surname = query.surname, !surname.isEmpty else {
            return SourceSearchEnvelope(.results([]))
        }

        guard let cookieHeader = await FamilySearchCookieStore.shared.cookieHeader() else {
            return SourceSearchEnvelope(.requiresAuth(message: "Sign in to FamilySearch in Settings to enable this source"))
        }

        if giveUpRequests {
            return SourceSearchEnvelope(.unavailable(reason: "FamilySearch throttle exhausted; giving up for this process"))
        }
        await awaitCircuitClosed()
        await throttleIfNeeded()

        let summary = Self.activitySummary(query: query, surname: surname)
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary, strictness: query.strictness))

        let url = Self.buildSearchURL(query: query, surname: surname)

        do {
            let data = try await fetch(url: url, cookieHeader: cookieHeader)
            let parsed = try Self.parseSearchResponseWithTotal(data: data, query: query)
            lastSuccessfulSearch = Date()
            lastError = nil
            recordSuccess()
            let truncated = Self.isTruncated(entryCount: parsed.entryCount, totalAvailable: parsed.totalAvailable)
            logger.info("\(summary, privacy: .public) → \(parsed.records.count) records (total \(parsed.totalAvailable.map(String.init) ?? "?", privacy: .public)\(truncated ? ", truncated" : ""))")
            await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: parsed.records.count, strictness: query.strictness))
            return SourceSearchEnvelope(
                result: .results(parsed.records),
                outcome: SearchOutcome(
                    resultCount: parsed.records.count,
                    totalAvailable: parsed.totalAvailable,
                    truncated: truncated
                )
            )
        } catch is CancellationError {
            return SourceSearchEnvelope(.unavailable(reason: "cancelled"))
        } catch let httpError as HTTPError where httpError.isThrottled {
            recordThrottle()
            lastError = "HTTP 429 (throttled)"
            logger.warning("Search throttled — advancing circuit breaker")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: "throttled", strictness: query.strictness))
            return SourceSearchEnvelope(
                result: .unavailable(reason: "throttled"),
                outcome: SearchOutcome(resultCount: 0, availability: .throttled)
            )
        } catch HTTPError.unauthorized {
            // Cookie expired or invalidated — distinct from "never had cookies",
            // and the UI should distinguish so the user knows to re-auth rather
            // than guess what's wrong. Don't clear cookies automatically — the
            // user might want to inspect them.
            lastError = "session expired"
            logger.warning("Search failed: session expired")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: "session expired", strictness: query.strictness))
            return SourceSearchEnvelope(.requiresAuth(message: "FamilySearch session expired — re-authenticate in Settings"))
        } catch {
            lastError = error.localizedDescription
            logger.warning("Search failed: \(error.localizedDescription)")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription, strictness: query.strictness))
            return SourceSearchEnvelope(.unavailable(reason: error.localizedDescription))
        }
    }

    /// A page is truncated when the server claims more hits than the page
    /// carries, or when a full page arrives without a claimed total (a
    /// full page is a suspected partial — the endpoint caps `count` at
    /// `pageSize`). Pure and static for testability.
    nonisolated static func isTruncated(entryCount: Int, totalAvailable: Int?) -> Bool {
        if let total = totalAvailable { return total > entryCount }
        return entryCount >= pageSize
    }

    // MARK: - URL construction

    nonisolated static func buildSearchURL(query: RecordQuery, surname: String) -> URL {
        // Mirrors the Python plugin's parameter shape. Per §10 open questions,
        // server-side `q.recordType` and `q.collectionId` filtering remain
        // untested — first cut sends only the parameters the Python plugin
        // confirmed working, and filters record-type client-side via
        // per-persona fact inspection in the parser.
        //
        // Per spec §4.3 the `~` modifier opts out of FamilySearch's default
        // phonetic/Soundex matching on a name field. At .strict we send it
        // on surname so Cauldwell stops matching Colwell/Caldwell/Calkins;
        // given names stay phonetic so Ernest can still match Ernie etc.
        let surnameValue = query.strictness == .strict ? "\(surname)~" : surname
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "q.surname", value: surnameValue),
            // pageSize (100) is the documented hard max for this endpoint's
            // pagination (FAMILYSEARCH_SOURCE_SPEC.md §15.7) — was 20, which
            // silently truncated broad queries to FamilySearch's first page
            // of server-ranked relevance.
            URLQueryItem(name: "count", value: String(pageSize)),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "m.defaultFacets", value: "on"),
        ]
        if let given = query.givenName, !given.isEmpty {
            items.append(URLQueryItem(name: "q.givenName", value: given))
        }
        if let gender = query.gender {
            items.append(URLQueryItem(name: "q.sex", value: gender == .male ? "Male" : "Female"))
        }
        // Map the recordType to the most relevant date/place axis. The
        // server doesn't strictly filter on these but it does score
        // relevance against them.
        if let from = query.yearFrom, let to = query.yearTo {
            switch query.recordType {
            case .birth, .baptism, .christening:
                items.append(URLQueryItem(name: "q.birthLikeDate.from", value: String(from)))
                items.append(URLQueryItem(name: "q.birthLikeDate.to", value: String(to)))
            case .death, .burial:
                // Only pin q.deathLikeDate for a narrow (known-death-year)
                // window. When the window is a wide birth-derived guess
                // (span > deathDateWindowThreshold), omit the death-date axis
                // entirely: FamilySearch does not match a "Funeral Notices"
                // persona (a Funeral fact, not a Death fact) against the
                // deathLike axis, so a hard window silently excludes real
                // funeral/obituary records server-side. Mirrors the dispatcher's
                // FindAGrave rule ("no real death window → no death filter").
                if to - from <= deathDateWindowThreshold {
                    items.append(URLQueryItem(name: "q.deathLikeDate.from", value: String(from)))
                    items.append(URLQueryItem(name: "q.deathLikeDate.to", value: String(to)))
                }
            case .marriage:
                items.append(URLQueryItem(name: "q.marriageLikeDate.from", value: String(from)))
                items.append(URLQueryItem(name: "q.marriageLikeDate.to", value: String(to)))
            case .census:
                items.append(URLQueryItem(name: "q.residenceDate.from", value: String(from)))
                items.append(URLQueryItem(name: "q.residenceDate.to", value: String(to)))
            default:
                items.append(URLQueryItem(name: "q.anyDate.from", value: String(from)))
                items.append(URLQueryItem(name: "q.anyDate.to", value: String(to)))
            }
        }

        // Family-context axes (spec §23). Each is optional on RecordQuery
        // and only emitted when the dispatcher populated it from subject
        // + FamilyContext. Every additional axis tightens the search:
        // q.birthLikePlace narrows from "Cauldwells in the world" to
        // "Cauldwells in Derbyshire"; q.spouseSurname can find Ernest's
        // marriage in one query without enumerating all his year ranges.
        if let p = query.birthPlace, !p.isEmpty {
            items.append(URLQueryItem(name: "q.birthLikePlace", value: p))
        }
        if let p = query.deathPlace, !p.isEmpty {
            items.append(URLQueryItem(name: "q.deathLikePlace", value: p))
        }
        // #Change6 — residence (census scoping) and marriage place. The
        // Python plugin confirmed both param names live
        // (sources/familysearch.py: q.residenceLikePlace / q.marriageLikePlace).
        if let p = query.residencePlace, !p.isEmpty {
            items.append(URLQueryItem(name: "q.residenceLikePlace", value: p))
        }
        if let p = query.marriagePlace, !p.isEmpty {
            items.append(URLQueryItem(name: "q.marriageLikePlace", value: p))
        }
        // Soft country/region axis to bias ranking toward the subject's home
        // nation and thin the tail of same-surname records from other
        // countries. Re-rank only — never a hard filter — so it can't drop the
        // true local record.
        if let p = query.anyPlace, !p.isEmpty {
            items.append(URLQueryItem(name: "q.anyPlace", value: p))
        }
        if let s = query.spouseSurname, !s.isEmpty {
            items.append(URLQueryItem(name: "q.spouseSurname", value: s))
        }
        if let g = query.spouseGivenName, !g.isEmpty {
            items.append(URLQueryItem(name: "q.spouseGivenName", value: g))
        }
        if let s = query.fatherSurname, !s.isEmpty {
            items.append(URLQueryItem(name: "q.fatherSurname", value: s))
        }
        if let g = query.fatherGivenName, !g.isEmpty {
            items.append(URLQueryItem(name: "q.fatherGivenName", value: g))
        }
        if let s = query.motherSurname, !s.isEmpty {
            items.append(URLQueryItem(name: "q.motherSurname", value: s))
        }
        if let g = query.motherGivenName, !g.isEmpty {
            items.append(URLQueryItem(name: "q.motherGivenName", value: g))
        }

        components.queryItems = items
        return components.url!
    }

    // MARK: - HTTP

    private func fetch(url: URL, cookieHeader: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.familysearch.org/en/search/record/results", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 401, 403: throw HTTPError.unauthorized
        case 429: throw HTTPError.throttled
        case 200...299: return data
        default: throw HTTPError.status(code: status, body: data)
        }
    }

    // MARK: - Circuit breaker

    private func awaitCircuitClosed() async {
        while let openUntil = circuitOpenUntil {
            let now = ContinuousClock.now
            if openUntil <= now {
                circuitOpenUntil = nil
                consecutive429s = 0
                logger.info("FamilySearch circuit breaker closed — resuming")
                return
            }
            try? await Task.sleep(until: openUntil, clock: .continuous)
        }
    }

    private func recordThrottle() {
        consecutive429s += 1
        guard consecutive429s >= circuit429Threshold && circuitOpenUntil == nil else { return }
        if circuitTripCount >= circuitCooldownLadder.count {
            giveUpRequests = true
            logger.warning("FamilySearch throttle ladder exhausted after \(self.circuitTripCount) trips — giving up for this process")
            return
        }
        let cooldown = circuitCooldownLadder[circuitTripCount]
        circuitOpenUntil = ContinuousClock.now.advanced(by: cooldown)
        circuitTripCount += 1
        logger.warning("FamilySearch circuit breaker trip #\(self.circuitTripCount) — pausing for \(cooldown.components.seconds)s")
    }

    private func recordSuccess() {
        if consecutive429s > 0 { consecutive429s = 0 }
        if circuitTripCount > 0 { circuitTripCount = 0 }
        if circuitOpenUntil != nil {
            circuitOpenUntil = nil
            logger.info("FamilySearch circuit breaker closed early — successful response")
        }
    }

    /// Synchronously advance the request slot so concurrent callers get
    /// distinct timings — mirrors FreeBMDSource's race-safe pacing.
    private func throttleIfNeeded() async {
        let now = ContinuousClock.now
        let mySlot: ContinuousClock.Instant
        if let scheduled = nextRequestSlot, scheduled > now {
            mySlot = scheduled
            nextRequestSlot = scheduled.advanced(by: requestDelay)
        } else {
            mySlot = now
            nextRequestSlot = now.advanced(by: requestDelay)
        }
        if mySlot > now {
            try? await Task.sleep(until: mySlot, clock: .continuous)
        }
    }

    // MARK: - Activity summary

    nonisolated static func activitySummary(query: RecordQuery, surname: String) -> String {
        let given = query.givenName.flatMap { $0.isEmpty ? nil : $0 } ?? ""
        let person = given.isEmpty ? surname : "\(given) \(surname)"
        let kind = query.recordType.rawValue
        var axes: [String] = []
        if let s = query.spouseSurname, !s.isEmpty { axes.append("spouse=\(s)") }
        if let s = query.fatherSurname, !s.isEmpty { axes.append("father=\(s)") }
        if let s = query.motherSurname, !s.isEmpty { axes.append("mother=\(s)") }
        if let p = query.birthPlace, !p.isEmpty { axes.append("birthPlace=\(p)") }
        if let p = query.deathPlace, !p.isEmpty { axes.append("deathPlace=\(p)") }
        if let g = query.gender { axes.append("sex=\(g == .male ? "M" : "F")") }
        let axisSuffix = axes.isEmpty ? "" : " [\(axes.joined(separator: ", "))]"
        if let from = query.yearFrom, let to = query.yearTo {
            return "FamilySearch \(kind): \(person) \(from)–\(to)\(axisSuffix)"
        }
        return "FamilySearch \(kind): \(person)\(axisSuffix)"
    }
}

// MARK: - GEDCOMx parser (multi-persona, §5.0)

extension FamilySearchSource {

    /// Parse a `/service/search/hr/v2/personas` JSON response into
    /// `[SourceRecord]`. Per spec §5.0, every persona in an entry's
    /// `persons[]` produces one candidate SourceRecord; relationships[]
    /// is used to tag household-role context on each.
    nonisolated static func parseSearchResponse(data: Data, query: RecordQuery) throws -> [SourceRecord] {
        try parseSearchResponseWithTotal(data: data, query: query).records
    }

    /// Full parse including the envelope's own accounting: `totalAvailable`
    /// is the top-level `results` integer (the server's claimed total hit
    /// count — decoded since first cut but previously discarded), and
    /// `entryCount` is the number of entries actually carried on this page.
    /// Both feed the #Change3 honesty envelope; `records` is the per-persona
    /// expansion after the client-side surname guard.
    nonisolated static func parseSearchResponseWithTotal(
        data: Data, query: RecordQuery
    ) throws -> (records: [SourceRecord], totalAvailable: Int?, entryCount: Int) {
        let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        // Acceptable surnames for this query. At .strict and .variant the set
        // contains only the dispatcher-supplied surname. At .loose it is
        // broadened to the registered transcription variants from
        // surname-variants.json — but NOT the long tail of phonetic / Soundex
        // matches FamilySearch widens to server-side (Colwell, Owens, Calkins
        // …) which add noise without evidence. Household personas with
        // non-matching surnames are still preserved as siblingsAndKin context
        // on the principal's record; they just don't become standalone
        // SourceRecord candidates for the subject's identity.
        let allowedSurnames = Self.allowedSurnames(for: query)
        var out: [SourceRecord] = []
        for entry in envelope.entries ?? [] {
            let gx = entry.content?.gedcomx
            guard let persons = gx?.persons, !persons.isEmpty else { continue }

            let collectionTitle = gx?.sourceDescriptions?.first?.titles?.first?.value ?? ""
            let collectionARK = gx?.sourceDescriptions?.first?.about ?? ""
            let completeness = gx?.sourceDescriptions?.first?.coverage?.first?.completeness

            // Build a person-id → index lookup for relationship tagging.
            var idToIndex: [String: Int] = [:]
            for (i, p) in persons.enumerated() {
                if let id = p.id { idToIndex[id] = i }
            }
            let householdRoles = Self.deriveHouseholdRoles(
                persons: persons,
                relationships: gx?.relationships ?? [],
                idToIndex: idToIndex
            )

            for (i, persona) in persons.enumerated() {
                if let allowed = allowedSurnames {
                    guard let personaSurname = personaSurname(persona), allowed.contains(personaSurname) else { continue }
                }
                guard let record = buildRecord(
                    persona: persona,
                    personaIndex: i,
                    householdRole: householdRoles[persona.id ?? ""],
                    siblingsAndKin: persons.enumerated().compactMap { (j, other) in
                        j == i ? nil : (other, householdRoles[other.id ?? ""])
                    },
                    relationships: gx?.relationships ?? [],
                    collectionTitle: collectionTitle,
                    collectionARK: collectionARK,
                    collectionCompleteness: completeness,
                    queryRecordType: query.recordType
                ) else { continue }
                out.append(record)
            }
        }
        return (out, envelope.results, (envelope.entries ?? []).count)
    }

    /// Extract a Find a Grave memorial id from a FAG-collection persona's
    /// raw fields. Returns nil when the collection isn't Find a Grave, or
    /// when no parseable ExtRecordId is present. Public for testing.
    nonisolated static func extractFindAGraveMemorialID(
        collectionTitle: String,
        rawFields: [String: String]
    ) -> Int? {
        let title = collectionTitle.lowercased()
        guard title.contains("find a grave") || title.contains("findagrave") else { return nil }
        // Only ExtRecordId is reliable. The earlier persona-id fallback
        // ("p_<digits>" → strip-and-parse) was based on a wrong assumption:
        // FS's persona id is an internal opaque identifier (12 digits) with
        // no relationship to FAG's actual memorial numbering (typically 7–9
        // digits). Verified by manual check on memorial 271612558 vs FS
        // persona p_304726395949 — different orders of magnitude, different
        // namespaces. The fallback was generating IDs that always 404'd.
        // When ExtRecordId is absent, the right path is FindAGraveSource's
        // own `search()` (with first-given-only fix applied), not a
        // speculative bridge.
        let candidates = [
            rawFields["field.ExtRecordId.original"],
            rawFields["field.ExtRecordId.interpreted"],
            rawFields["field.ExtRecordId"],
        ]
        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            if let id = Int(raw) { return id }
            // FAG memorial IDs sometimes arrive prefixed (e.g. "memorial-12345").
            // Pull the trailing run of digits as a fallback.
            if let digits = raw.split(whereSeparator: { !$0.isNumber }).last, let id = Int(digits) {
                return id
            }
        }
        return nil
    }

    /// Acceptable surnames for `query`, lowercased. `nil` means "no surname
    /// filter — accept everything" (when the query itself has no surname).
    /// At .strict / .variant only the dispatcher-supplied surname is allowed.
    /// At .loose, the registered transcription variants from
    /// surname-variants.json are also allowed; phonetic / Soundex matches the
    /// server returns beyond that set are rejected client-side.
    nonisolated static func allowedSurnames(for query: RecordQuery) -> Set<String>? {
        guard let want = query.surname?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !want.isEmpty else { return nil }
        switch query.strictness {
        case .strict, .variant:
            return [want]
        case .loose:
            var set: Set<String> = [want]
            for variant in SurnameVariants.shared.variants(of: want) {
                set.insert(variant)
            }
            return set
        }
    }

    /// Lowercased surname for a persona, preferring the structured Surname
    /// part and falling back to the last whitespace-separated token of
    /// `fullText` when the parts array is absent.
    nonisolated private static func personaSurname(_ persona: GxPerson) -> String? {
        let nameForm = persona.names?.first?.nameForms?.first
        if let surname = nameForm?.parts?.first(where: { ($0.type ?? "").hasSuffix("/Surname") })?.value {
            return surname.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let full = nameForm?.fullText, let last = full.split(separator: " ").last {
            return String(last).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Decide the record's household role for each persona based on the
    /// relationships array: ParentChild flagging on the child side, Couple
    /// for spouses. Other roles fall through to "household_member" as a
    /// catch-all that survives until §8.1's hypothesis kinds enrich it.
    nonisolated private static func deriveHouseholdRoles(
        persons: [GxPerson],
        relationships: [GxRelationship],
        idToIndex: [String: Int]
    ) -> [String: String] {
        var roles: [String: String] = [:]
        // First persona is typically the primary subject; others default
        // to "household_member" until a relationship promotes them.
        for (i, p) in persons.enumerated() {
            guard let id = p.id else { continue }
            roles[id] = i == 0 ? "principal" : "household_member"
        }
        for rel in relationships {
            let type = rel.type?.split(separator: "/").last.map(String.init) ?? ""
            guard let p1 = rel.person1?.resourceId, let p2 = rel.person2?.resourceId else { continue }
            switch type {
            case "ParentChild":
                // person1 = parent, person2 = child
                if roles[p1] == "household_member" { roles[p1] = "parent" }
                if roles[p2] == "household_member" { roles[p2] = "child" }
            case "Couple":
                if roles[p1] == "household_member" { roles[p1] = "spouse" }
                if roles[p2] == "household_member" { roles[p2] = "spouse" }
            default:
                break
            }
        }
        return roles
    }

    /// Build a single SourceRecord for one persona. Returns nil if the
    /// persona has no extractable identity (no name AND no facts).
    nonisolated private static func buildRecord(
        persona: GxPerson,
        personaIndex: Int,
        householdRole: String?,
        siblingsAndKin: [(GxPerson, String?)],
        relationships: [GxRelationship],
        collectionTitle: String,
        collectionARK: String,
        collectionCompleteness: Double?,
        queryRecordType: RecordType
    ) -> SourceRecord? {
        let nameForm = persona.names?.first?.nameForms?.first
        let fullName = nameForm?.fullText
        let givenName = nameForm?.parts?.first(where: { ($0.type ?? "").hasSuffix("/Given") })?.value
        let surname = nameForm?.parts?.first(where: { ($0.type ?? "").hasSuffix("/Surname") })?.value
        // `sex` is captured into rawFields below; not yet a first-class
        // RecordCommon field (spec §5.2 notes this as a future addition).
        let sex: String? = persona.gender?.type.flatMap { $0.split(separator: "/").last.map(String.init) }
        _ = sex

        // Determine the record's primary event type from the persona's
        // facts. Per spec §5.0 this varies per persona — a child in a
        // census record gets `.census`; their christening date (if also
        // surfaced) doesn't override.
        let primaryFact = pickPrimaryFact(facts: persona.facts ?? [], queryHint: queryRecordType)
        let mappedFactType = primaryFact.flatMap { recordType(forGedcomxFact: $0.type ?? "") }
        let recordRecordType = mappedFactType ?? queryRecordType

        // Collect every fact as a rawFields entry — even when the typed
        // record struct doesn't surface it. Preserves the long-tail
        // GEDCOMx vocabulary for later promotion (spec §9.1 "log
        // unmapped types in rawFields").
        var rawFields: [String: String] = [:]
        for fact in persona.facts ?? [] {
            let typeName = fact.type?.split(separator: "/").last.map(String.init) ?? "fact"
            if let date = fact.date?.original {
                rawFields["fact.\(typeName).date"] = date
            }
            if let formal = fact.date?.formal {
                rawFields["fact.\(typeName).date.formal"] = formal
            }
            if let place = fact.place?.original {
                rawFields["fact.\(typeName).place"] = place
            }
            if let placeARK = fact.place?.normalized?.first?.description {
                rawFields["fact.\(typeName).placeARK"] = placeARK
            }
        }
        for field in persona.fields ?? [] {
            let typeName = field.type?.split(separator: "/").last.map(String.init) ?? "field"
            // Capture both Original and Interpreted when both present;
            // per spec §5.2 the cost is two extra string-stores.
            for value in field.values ?? [] {
                let kind = value.type?.split(separator: "/").last.map(String.init) ?? ""
                if kind == "Original" {
                    rawFields["field.\(typeName).original"] = value.text ?? ""
                } else if kind == "Interpreted" {
                    rawFields["field.\(typeName).interpreted"] = value.text ?? ""
                } else if let v = value.text {
                    rawFields["field.\(typeName)"] = v
                }
            }
        }

        if let personaID = persona.id {
            rawFields["ark"] = "\(arkBase)\(personaID)"
            rawFields["personaID"] = personaID
        }
        rawFields["collection.title"] = collectionTitle
        if !collectionARK.isEmpty { rawFields["collection.ark"] = collectionARK }
        if let c = collectionCompleteness { rawFields["collection.completeness"] = String(c) }
        // Observability for the defer-enum-sprawl rule (spec §9.1): when the
        // primary fact's type isn't in the explicit map and we fell back to
        // the query hint, record the suffix so second-cut RecordType decisions
        // are driven by observed data, not guesswork.
        if mappedFactType == nil,
           let suffix = primaryFact?.type?.split(separator: "/").last.map(String.init) {
            rawFields["unmappedFactType"] = suffix
        }
        if let role = householdRole { rawFields["household.role"] = role }
        rawFields["primary"] = personaIndex == 0 ? "true" : "false"
        if let principal = persona.principal, principal { rawFields["principal"] = "true" }

        // Stable per-persona record ID; falls back to the ARK + index when
        // persona.id is missing (defensive — spec assumes it's present).
        // Avoids Swift's process-randomised `hashValue`, which would produce
        // a different id on every launch and break cross-run dedup.
        let recordID = persona.id ?? "fs-\(collectionARK)-\(personaIndex)"
        let detailURL = persona.id.map { "\(arkBase)\($0)" }
        // #Change7 — promote the two secondary-metadata values FS already
        // gives us to first-class RecordCommon fields: collection coverage
        // completeness (§7.4) and the primary fact's place-authority ARK,
        // stored as the bare `ark:/…` path segment only (§17.1).
        let primaryPlaceARK: String? = primaryFact?.place?.normalized?.first?.description.flatMap { raw in
            guard let r = raw.range(of: "ark:/") else { return nil }
            return String(raw[r.lowerBound...])
        }
        let common = RecordCommon(
            id: recordID,
            sourceID: "familysearch",
            name: fullName,
            surname: surname,
            givenName: givenName,
            detailURL: detailURL,
            rawFields: rawFields,
            placeARK: primaryPlaceARK,
            collectionCompleteness: collectionCompleteness
        )

        // Extract date/place fields into typed record struct fields
        // when the record type maps to one of the typed structs.
        let date = primaryFact?.date?.original
        let formalYear = primaryFact?.date?.formal.flatMap(Self.yearFromFormal)
        let yearFromOriginal = date.flatMap(Self.yearFromOriginal)
        let year = formalYear ?? yearFromOriginal
        let place = primaryFact?.place?.original

        switch recordRecordType {
        case .birth, .baptism, .christening:
            // Map christening/baptism to the parish-record struct since it
            // carries `eventType`. Pure birth records → .birth.
            if recordRecordType == .birth {
                let mmn = extractMothersMaidenName(relationships: relationships, personaID: persona.id, allPersons: siblingsAndKin.map(\.0))
                return .birth(BirthRecord(
                    common: common,
                    birthYear: year, birthDate: date,
                    birthPlace: place,
                    quarter: nil, district: nil, volume: nil, page: nil,
                    mothersMaidenName: mmn
                ))
            } else {
                return .parish(ParishRecord(
                    common: common,
                    eventType: recordRecordType.rawValue,
                    eventDate: date, eventYear: year,
                    parish: place, county: nil,
                    fatherName: nil, motherName: nil
                ))
            }
        case .death:
            return .death(DeathRecord(
                common: common,
                deathYear: year, deathDate: date,
                deathPlace: place,
                age: extractAge(rawFields: rawFields),
                quarter: nil, district: nil, volume: nil, page: nil,
                spouseSurname: nil
            ))
        case .burial:
            // When this persona came via the FamilySearch aggregator on a
            // Find a Grave collection, the GEDCOMx fields carry the FAG
            // memorial id in `ExtRecordId`. Surface it as `memorialID` so
            // the pipeline's FAG bridge (ResearchPipeline.enrichFagBridge,
            // spec §22) can schedule a follow-up FindAGraveSource.fetchDetail
            // and mine the inscription / bio for the death year that the FS
            // search response doesn't carry.
            let memorialID = Self.extractFindAGraveMemorialID(
                collectionTitle: collectionTitle,
                rawFields: rawFields
            )
            // FAG-collection burials keep nil dates: the FS search response
            // doesn't carry them, and the enrichFagBridge guard
            // (`burial.deathYear == nil`) is what schedules the memorial-page
            // fetch that does. Every other burial/cremation record (parish
            // burial registers, cremation indexes) carries the event date in
            // its primary fact — surface it as the death year so the scorer's
            // date gate can evaluate it (±2yr burial tolerance) instead of
            // auto-failing on "insufficient date information".
            let isFagBridge = memorialID != nil
            return .burial(BurialRecord(
                common: common,
                deathDate: isFagBridge ? nil : date,
                deathYear: isFagBridge ? nil : year,
                birthDate: nil, birthYear: nil,
                // FamilySearch's burial-collection records don't carry
                // birth/death-town separate from the cemetery location.
                birthPlace: nil, deathPlace: nil,
                burialLocation: place, cemetery: nil,
                memorialID: memorialID, inscription: nil, bio: nil,
                isVeteran: false
            ))
        case .marriage:
            // Spouse name from relationships[].Couple — for personas that
            // are one half of a couple-relationship inside this record.
            let spouseName = extractSpouseName(relationships: relationships, personaID: persona.id, otherPersons: siblingsAndKin.map(\.0))
            return .marriage(MarriageRecord(
                common: common,
                marriageYear: year, marriageDate: date,
                marriagePlace: place,
                quarter: nil, district: nil, volume: nil, page: nil,
                spouseName: spouseName
            ))
        case .census:
            // Build typed household members from the sibling personas.
            let household = siblingsAndKin.map { (other, role) -> HouseholdMember in
                let nm = other.names?.first?.nameForms?.first?.fullText ?? ""
                let ageStr = other.fields?.first(where: { ($0.type ?? "").hasSuffix("/Age") })?.values?.first?.text
                let age = ageStr.flatMap(Int.init)
                return HouseholdMember(
                    name: nm,
                    relationship: role ?? "household_member",
                    age: age,
                    birthYear: nil,
                    birthPlace: nil,
                    occupation: nil,
                    sex: other.gender?.type.flatMap { $0.split(separator: "/").last.map(String.init) }
                )
            }
            // Pull the persona's own birth fact (separate from the
            // census fact). Mirrors Python `sources/familysearch.py:
            // 333-335` — when the FamilySearch persona on a census
            // record carries a Birth/BirthRegistration/Christening/
            // Baptism fact alongside the Census fact, capture its
            // place and year onto the typed CensusRecord. Without
            // this, the geography gate has no birthPlace to read on
            // a FamilySearch census record and can't fail foreign-
            // residence subjects.
            let birthFact = (persona.facts ?? []).first { fact in
                let typeName = fact.type?.split(separator: "/").last.map(String.init) ?? ""
                return ["Birth", "BirthRegistration", "Christening", "Baptism"].contains(typeName)
            }
            let censusBirthPlace = birthFact?.place?.original
            let censusAge = extractAge(rawFields: rawFields)
            // Age-derived fallback (2026-07-15): a persona with age but no
            // usable birth fact previously carried birthYear nil, so the
            // date gate could only soft-signal — age 68 on a 1950 census
            // IS a birth year (~1882), and deriving it lets the gate rule
            // impossibility against the subject's known window.
            let censusBirthYear = birthFact?.date?.formal.flatMap(Self.yearFromFormal)
                ?? birthFact?.date?.original.flatMap(Self.yearFromOriginal)
                ?? year.flatMap { y in censusAge.map { y - $0 } }
            return .census(CensusRecord(
                common: common,
                censusYear: year ?? 0,
                age: censusAge,
                birthYear: censusBirthYear,
                birthPlace: censusBirthPlace,
                birthCounty: nil,
                relationship: householdRole,
                occupation: rawFields["fact.Occupation.date"] ?? rawFields["fact.Occupation.place"],
                address: nil, parish: nil, district: nil,
                household: household.isEmpty ? nil : household
            ))
        case .probate:
            return .probate(ProbateRecord(
                common: common,
                deathDate: nil, deathYear: nil,
                probateDate: date, birthDate: nil,
                ageAtDeath: extractAge(rawFields: rawFields),
                address: place, grantType: nil,
                registry: nil, probateNumber: nil,
                regimentNumber: nil
            ))
        case .military:
            return .military(MilitaryRecord(
                common: common,
                rank: nil, regiment: nil, unit: nil,
                serviceNumber: nil, dateOfDeath: date,
                deathYear: year,
                age: extractAge(rawFields: rawFields),
                cemetery: nil, graveRef: nil,
                additionalInfo: nil
            ))
        case .parish:
            return .parish(ParishRecord(
                common: common,
                eventType: primaryFact?.type?.split(separator: "/").last.map(String.init),
                eventDate: date, eventYear: year,
                parish: place, county: nil,
                fatherName: nil, motherName: nil
            ))
        case .pedigree:
            return .pedigree(PedigreeRecord(
                common: common,
                birthYear: nil, deathYear: nil,
                spouse: nil, marriageYear: nil,
                occupation: nil, location: nil, generation: nil
            ))
        }
    }

    /// Choose the per-persona record's primary fact. Prefer a fact whose
    /// type aligns with the query's record-type hint; fall back to first
    /// available fact when no aligned fact exists (still a useful
    /// candidate for clustering).
    nonisolated private static func pickPrimaryFact(facts: [GxFact], queryHint: RecordType) -> GxFact? {
        let hintedTypes: Set<String> = {
            switch queryHint {
            case .birth: return ["Birth", "BirthRegistration", "BirthNotice"]
            case .baptism, .christening: return ["Baptism", "Christening", "AdultChristening", "Blessing"]
            case .death: return ["Death", "DeathRegistration", "Funeral"]
            case .burial: return ["Burial", "Cremation"]
            case .marriage: return ["Marriage", "MarriageBanns", "MarriageRegistration",
                                    "MarriageLicense", "MarriageContract", "MarriageNotice",
                                    "CommonLawMarriage"]
            case .census: return ["Census", "Residence"]
            case .probate: return ["Probate", "Will"]
            case .military: return ["MilitaryService", "MilitaryDischarge", "MilitaryDraftRegistration", "MilitaryInduction", "MilitaryAward"]
            case .parish: return ["Baptism", "Christening", "Burial", "Marriage"]
            case .pedigree: return []
            }
        }()
        if let hit = facts.first(where: { fact in
            guard let suffix = fact.type?.split(separator: "/").last else { return false }
            return hintedTypes.contains(String(suffix))
        }) {
            return hit
        }
        return facts.first
    }

    /// Map a GEDCOMx fact-type URI to a RecordType case, or nil when the
    /// suffix isn't explicitly modelled — callers fall back to the query's
    /// record type (the parser's outer loop already established the broad
    /// axis) and stamp `rawFields["unmappedFactType"]` for observability.
    /// This function and `pickPrimaryFact`'s hinted-types sets are a
    /// MIRRORED PAIR — update both in the same commit (FAMILYSEARCH_READ_LEG_PLAN
    /// Change 1).
    ///
    /// Deliberately unmapped (see the build plan's decision log):
    /// - Funeral → .death, diverging from spec §3.1's `.burial` row: a
    ///   funeral notice dates death to within days and must stay eligible
    ///   to write .deathDate via ApplyEngine (.burial never writes profile
    ///   date fields).
    /// - The divorce family (Divorce/DivorceFiling/Annulment/Engagement/
    ///   Separation) never maps to .marriage: a divorce year flowing into
    ///   the spouse-edge marriage fill and "marriage:<year>" convergence
    ///   pooling would assert a wrong marriage date.
    /// - Obituary is not promoted cross-hint (publication can trail death
    ///   across a year boundary against the .death ±1 tolerance); under a
    ///   .death query it already classifies .death via the hint fallback.
    nonisolated private static func recordType(forGedcomxFact uri: String) -> RecordType? {
        let suffix = uri.split(separator: "/").last.map(String.init) ?? ""
        switch suffix {
        case "Birth", "BirthRegistration", "BirthNotice": return .birth
        case "Baptism", "Blessing": return .baptism
        case "Christening", "AdultChristening": return .christening
        case "Death", "DeathRegistration", "Funeral": return .death
        case "Burial", "Cremation": return .burial
        case "Marriage", "MarriageBanns", "MarriageRegistration",
             "MarriageLicense", "MarriageContract", "MarriageNotice",
             "CommonLawMarriage": return .marriage
        case "Census", "Residence": return .census
        case "Probate", "Will": return .probate
        case "MilitaryService", "MilitaryDischarge", "MilitaryDraftRegistration",
             "MilitaryInduction", "MilitaryAward": return .military
        default: return nil
        }
    }

    /// Parse a year from a `date.formal` value like "+1875-03-12" or "+1875".
    nonisolated private static func yearFromFormal(_ formal: String) -> Int? {
        let trimmed = formal.hasPrefix("+") ? String(formal.dropFirst()) : formal
        let yearPart = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        return Int(yearPart)
    }

    /// Heuristic year extraction from a `date.original` string like
    /// "12 Mar 1875" or "abt 1875".
    nonisolated private static func yearFromOriginal(_ original: String) -> Int? {
        // Find a 3-or-4-digit substring that's a plausible year.
        let pattern = #"\b(1[5-9]\d{2}|20\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(original.startIndex..., in: original)
        if let match = regex.firstMatch(in: original, range: range),
           let r = Range(match.range, in: original) {
            return Int(original[r])
        }
        return nil
    }

    /// Pull an Age field from the rawFields dict (where the parser already
    /// preserved it). FamilySearch census records carry the age as a
    /// per-persona `Age` field; non-census records typically don't.
    nonisolated private static func extractAge(rawFields: [String: String]) -> Int? {
        if let s = rawFields["field.Age"] ?? rawFields["field.Age.interpreted"] ?? rawFields["field.Age.original"] {
            return Int(s.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Try to pull a spouse's name from the relationships array — the
    /// persona who shares a `Couple` relationship with us.
    nonisolated private static func extractSpouseName(relationships: [GxRelationship], personaID: String?, otherPersons: [GxPerson]) -> String? {
        guard let pid = personaID else { return nil }
        for rel in relationships {
            let type = rel.type?.split(separator: "/").last.map(String.init) ?? ""
            guard type == "Couple" else { continue }
            let p1 = rel.person1?.resourceId
            let p2 = rel.person2?.resourceId
            let spouseID = (p1 == pid) ? p2 : (p2 == pid ? p1 : nil)
            guard let sid = spouseID, let spouse = otherPersons.first(where: { $0.id == sid }) else { continue }
            return spouse.names?.first?.nameForms?.first?.fullText
        }
        return nil
    }

    /// Mother's maiden name extraction — find the mother via ParentChild
    /// relationship, then take her surname. Surfaced specifically because
    /// `BirthRecord.mothersMaidenName` is load-bearing for sibling
    /// inference (see `SiblingInferenceEngine`).
    nonisolated private static func extractMothersMaidenName(relationships: [GxRelationship], personaID: String?, allPersons: [GxPerson]) -> String? {
        guard let pid = personaID else { return nil }
        for rel in relationships {
            let type = rel.type?.split(separator: "/").last.map(String.init) ?? ""
            guard type == "ParentChild" else { continue }
            // ParentChild: person1 = parent, person2 = child
            guard rel.person2?.resourceId == pid else { continue }
            guard let parentID = rel.person1?.resourceId,
                  let parent = allPersons.first(where: { $0.id == parentID }) else { continue }
            // Heuristic: mother is the female parent. Fall back to the
            // first parent if gender isn't surfaced.
            let isMother = parent.gender?.type.flatMap { $0.split(separator: "/").last.map(String.init) } == "Female"
            if isMother {
                return parent.names?.first?.nameForms?.first?.parts?.first(where: {
                    ($0.type ?? "").hasSuffix("/Surname")
                })?.value
            }
        }
        return nil
    }
}

// MARK: - GEDCOMx envelope (Codable)

/// Top-level shape of the `/service/search/hr/v2/personas` response.
/// Only the fields the parser reads are modelled; everything else falls
/// through and is ignored by Codable's default behaviour.
nonisolated private struct SearchEnvelope: Decodable {
    let entries: [SearchEntry]?
    let results: Int?
}

nonisolated private struct SearchEntry: Decodable {
    let content: EntryContent?
    let score: Double?
    let id: String?
    let title: String?
}

nonisolated private struct EntryContent: Decodable {
    let gedcomx: GxRoot?
}

nonisolated private struct GxRoot: Decodable {
    let persons: [GxPerson]?
    let relationships: [GxRelationship]?
    let sourceDescriptions: [GxSourceDescription]?
}

nonisolated private struct GxPerson: Decodable {
    let id: String?
    let names: [GxName]?
    let gender: GxGender?
    let facts: [GxFact]?
    let fields: [GxField]?
    let principal: Bool?
}

nonisolated private struct GxName: Decodable {
    let nameForms: [GxNameForm]?
}

nonisolated private struct GxNameForm: Decodable {
    let fullText: String?
    let parts: [GxNamePart]?
}

nonisolated private struct GxNamePart: Decodable {
    let type: String?
    let value: String?
}

nonisolated private struct GxGender: Decodable {
    let type: String?
}

nonisolated private struct GxFact: Decodable {
    let type: String?
    let date: GxDate?
    let place: GxPlace?
}

nonisolated private struct GxDate: Decodable {
    let original: String?
    let formal: String?
}

nonisolated private struct GxPlace: Decodable {
    let original: String?
    let normalized: [GxNormalizedPlace]?
}

nonisolated private struct GxNormalizedPlace: Decodable {
    let value: String?
    let description: String?  // place ARK
}

nonisolated private struct GxField: Decodable {
    let type: String?
    let values: [GxFieldValue]?
}

nonisolated private struct GxFieldValue: Decodable {
    let type: String?
    let text: String?
}

nonisolated private struct GxRelationship: Decodable {
    let type: String?
    let person1: GxPersonRef?
    let person2: GxPersonRef?
    let facts: [GxFact]?
}

nonisolated private struct GxPersonRef: Decodable {
    let resourceId: String?
}

nonisolated private struct GxSourceDescription: Decodable {
    let id: String?
    let about: String?
    let titles: [GxValue]?
    let coverage: [GxCoverage]?
}

nonisolated private struct GxValue: Decodable {
    let value: String?
}

nonisolated private struct GxCoverage: Decodable {
    let completeness: Double?
}
