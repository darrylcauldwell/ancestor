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
    nonisolated let displayName = "FreeCen"
    nonisolated let descriptiveName = "UK Census Transcriptions (FreeCen)"
    nonisolated let recordTypes: Set<RecordType> = [.census]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1841...1911
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "Census-enumeration-books")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(
        level: .community,
        summary: "Volunteer project — no documented API, no prohibition of programmatic access"
    )

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
    nonisolated private static let validYears: Set<Int> = [1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911]

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        guard query.recordType == .census else { return .outsideCoverage(reason: "FreeCen only provides census records") }
        guard let surname = query.surname, !surname.isEmpty else { return .results([]) }

        let chapmanCode: String
        if case .freeCen(let p) = query.sourceParams, let code = p.chapmanCode {
            chapmanCode = code
        } else {
            chapmanCode = "DBY"
        }
        let year = query.yearFrom  // census year

        let summary = Self.activitySummary(query: query, surname: surname, chapmanCode: chapmanCode, censusYear: year)
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

            let fields: [String: String] = [
                "utf8": "✓",
                "authenticity_token": csrfToken ?? "",
                "search_query[last_name]": surname,
                "search_query[first_name]": query.givenName ?? "",
                "search_query[record_type]": year.map(String.init) ?? "",
                "search_query[fuzzy]": fuzzyFlag,
                "search_query[search_nearby_places]": "0",
                "search_query[disabled]": "0",
                "search_query[start_year]": startYear,
                "search_query[end_year]": endYear,
                "search_query[sex]": sexValue,
                "search_query[marital_status]": "",
                "search_query[occupation]": "",
                "search_query[chapman_codes][]": chapmanCode,
            ]

            let data = try await rateLimitedRequest {
                try await self.http.postForm(
                    url: Self.searchURL,
                    fields: fields,
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
                return .unavailable(reason: "Invalid encoding")
            }
            let results = Self.parseSearchResults(html, censusYear: year)
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
            logger.info("Search returned \(enriched.count) results for \(surname)")
            await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: enriched.count, strictness: query.strictness))
            return .results(enriched)

        } catch {
            lastError = error.localizedDescription
            logger.warning("Search failed: \(error.localizedDescription)")
            sessionCookie = nil
            csrfToken = nil
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription, strictness: query.strictness))
            return .unavailable(reason: error.localizedDescription)
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

        // Extract CSRF token
        let csrfPattern = #"<meta name="csrf-token" content="([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: csrfPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            csrfToken = String(html[range])
        }

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
                id: "freecen_\(recordCensusYear ?? 0)_\(surname ?? "")_\(givenName ?? "")",
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
    nonisolated static func parseHouseholdDetail(_ html: String, recordURL: String) -> SourceRecord? {
        let tablePattern = #"<table[^>]*>(.*?)</table>"#
        guard let tableRegex = try? NSRegularExpression(pattern: tablePattern, options: .dotMatchesLineSeparators) else { return nil }
        let tableMatches = tableRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        var dwelling: [String: String] = [:]
        var members: [HouseholdMember] = []

        let cellPattern = #"<t[dh][^>]*>(.*?)</t[dh]>"#
        guard let cellRegex = try? NSRegularExpression(pattern: cellPattern, options: .dotMatchesLineSeparators) else { return nil }

        // Table 0: dwelling details
        if tableMatches.count >= 1,
           let tableRange = Range(tableMatches[0].range(at: 1), in: html) {
            let table = String(html[tableRange])
            let cells = cellRegex.matches(in: table, range: NSRange(table.startIndex..., in: table))
                .compactMap { match -> String? in
                    guard let range = Range(match.range(at: 1), in: table) else { return nil }
                    return stripHTML(String(table[range]))
                }

            let keys = ["census_year", "county", "district", "parish",
                        "ecclesiastical_parish", "piece", "enumeration_district",
                        "folio", "page", "schedule", "house_number", "address"]

            // Find where numeric year starts
            if let valStart = cells.firstIndex(where: { $0.range(of: #"^1[89]\d\d$"#, options: .regularExpression) != nil }) {
                for (j, key) in keys.enumerated() {
                    let idx = valStart + j
                    if idx < cells.count {
                        dwelling[key] = cells[idx]
                    }
                }
            }
        }

        // Table 1: household members
        if tableMatches.count >= 2,
           let tableRange = Range(tableMatches[1].range(at: 1), in: html) {
            let table = String(html[tableRange])
            let cells = cellRegex.matches(in: table, range: NSRange(table.startIndex..., in: table))
                .compactMap { match -> String? in
                    guard let range = Range(match.range(at: 1), in: table) else { return nil }
                    return stripHTML(String(table[range]))
                }

            // Skip 11 header cells, process data in groups of 11
            let dataCells = Array(cells.dropFirst(11))
            // Handle "person found in your search" marker in first cell
            var processed: [String] = []
            for cell in dataCells {
                if cell.lowercased().contains("person found in your search") {
                    let parts = cell.components(separatedBy: "\n")
                    let surname = parts.first(where: { !$0.lowercased().contains("person found") && !$0.trimmingCharacters(in: .whitespaces).isEmpty })?.trimmingCharacters(in: .whitespaces) ?? ""
                    processed.append(surname)
                } else {
                    processed.append(cell)
                }
            }

            var i = 0
            while i + 10 < processed.count {
                let row = Array(processed[i..<i+11])
                let surname = row[0]
                let forenames = row[1]
                let name = "\(forenames) \(surname)".trimmingCharacters(in: .whitespaces)

                members.append(HouseholdMember(
                    name: name,
                    relationship: row[2],
                    age: Int(row[5]),
                    birthYear: nil,  // computed from census year - age
                    birthPlace: row[8],
                    occupation: row[6],
                    sex: row[4]
                ))
                i += 11
            }
        }

        // Compute birth years from census year and age
        let censusYear = Int(dwelling["census_year"] ?? "") ?? 0
        let membersWithBirthYear = members.map { member in
            HouseholdMember(
                name: member.name,
                relationship: member.relationship,
                age: member.age,
                birthYear: member.age.map { censusYear - $0 },
                birthPlace: member.birthPlace,
                occupation: member.occupation,
                sex: member.sex
            )
        }

        // Build a CensusRecord for the first member (the search target)
        guard let target = membersWithBirthYear.first else { return nil }

        let common = RecordCommon(
            id: "freecen_detail_\(censusYear)_\(target.name)",
            sourceID: "freecen",
            name: target.name,
            surname: target.name.split(separator: " ").last.map(String.init),
            givenName: target.name.split(separator: " ").dropLast().joined(separator: " "),
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
