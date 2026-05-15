import Foundation
import os

/// FreeBMD — volunteer transcription of England & Wales civil registration indexes 1837–1983
/// https://www.freebmd.org.uk
/// Access: POST form with session cookie + hidden form tokens
/// Auth: None (session cookie obtained automatically)
/// Coverage: Birth/death/marriage registrations, England & Wales, 1837–1983
///
/// Data notes (from Python):
///   - Mother's maiden name (births) only from Sep 1911
///   - Spouse surname (marriages) only from Sep 1912
///   - Bakewell district has no coverage before 1941
///   - Coverage is incomplete, especially pre-1865
actor FreeBMDSource: RecordSource {

    // MARK: - RecordSource Protocol

    nonisolated let sourceID = "freebmd"
    nonisolated let displayName = "FreeBMD"
    nonisolated let recordTypes: Set<RecordType> = [.birth, .death, .marriage]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1837...1983
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "GRO-indexes")
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
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FreeBMD")
    /// Scheduled time for the next allowable request. Each caller synchronously
    /// (without await) advances this and reads its own slot — guarantees serial
    /// timing even when many search() calls arrive at the actor concurrently.
    /// The previous lastRequestTime-then-await pattern was racy under actor
    /// reentrancy: many callers read the same stale value, all slept ~500ms,
    /// then woke nearly simultaneously and fired together.
    private var nextRequestSlot: ContinuousClock.Instant?
    private let requestDelay: Duration = .milliseconds(500)

    // Session state (CSRF tokens)
    private var sessionCookie: String?
    private var formTokenDB: String?
    private var formTokenV: String?
    /// In-flight session-establishment task. Multiple concurrent search() calls
    /// all hit ensureSession() before any one has cached the cookie. Without
    /// this latch they'd each fetch the form HTML in parallel (12+ duplicate
    /// requests per pipeline iteration), occasionally exhausting connection
    /// pools and causing timeouts. Concurrent callers now await the same task.
    private var sessionEstablishmentTask: Task<Void, Error>?

    private var lastSuccessfulSearch: Date?
    private var lastError: String?

    // MARK: - Constants

    nonisolated private static let searchFormURL = URL(string: "https://www.freebmd.org.uk/search")!
    nonisolated private static let searchURL = URL(string: "https://www.freebmd.org.uk/cgi/search.pl")!
    nonisolated private static let userAgent = "AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"
    nonisolated private static let quarterNames = ["1": "Mar", "2": "Jun", "3": "Sep", "4": "Dec"]

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        guard recordTypes.contains(query.recordType) else { return .outsideCoverage(reason: "FreeBMD does not cover \(query.recordType.rawValue)") }
        guard let surname = query.surname, !surname.isEmpty else { return .results([]) }

        // Build a human-readable summary like "FreeBMD Belper marriages:
        // Cauldwell × Holmes 1946–1977" for the activity feed.
        let summary = Self.activitySummary(query: query, surname: surname)
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary))

        do {
            try await ensureSession()

            let recordType: String = switch query.recordType {
            case .birth: "Births"
            case .death: "Deaths"
            case .marriage: "Marriages"
            default: "All"
            }

            // Pull source-specific params. `spouseSurname` powers marriage
            // enrichment — "Cauldwell × Holmes" marriages get found by setting
            // surname=Cauldwell and s_surname=Holmes (or vice versa).
            let params: FreeBMDParams? = {
                if case .freeBMD(let p) = query.sourceParams { return p } else { return nil }
            }()
            let fields: [String: String] = [
                "type": recordType,
                "surname": surname,
                "given": query.givenName ?? "",
                "s_surname": params?.spouseSurname ?? "",
                "s_given": "",
                "start": query.yearFrom.map(String.init) ?? "",
                "end": query.yearTo.map(String.init) ?? "",
                "districtid": params?.districtCode ?? "",
                "db": formTokenDB ?? "",
                "v": formTokenV ?? "",
                "find.x": "1",
                "find.y": "1",
            ]

            let data = try await rateLimitedRequest {
                try await self.http.postForm(
                    url: Self.searchURL,
                    fields: fields,
                    headers: [
                        "User-Agent": Self.userAgent,
                        "Cookie": self.sessionCookie ?? "",
                    ]
                )
            }

            guard let html = String(data: data, encoding: .utf8) else {
                await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: "Invalid encoding"))
                return .unavailable(reason: "Invalid encoding")
            }
            let results = Self.parseSearchResults(html, recordType: query.recordType)
            lastSuccessfulSearch = Date()
            lastError = nil
            logger.info("Search returned \(results.count) results for \(surname)")
            await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: results.count))
            return .results(results)

        } catch {
            lastError = error.localizedDescription
            logger.warning("Search failed: \(error.localizedDescription)")
            sessionCookie = nil
            formTokenDB = nil
            formTokenV = nil
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription))
            return .unavailable(reason: error.localizedDescription)
        }
    }

    /// Build a one-line description of a FreeBMD query for the live activity feed.
    /// Resolves the district code to its display name when possible (catalogue
    /// covers all 1125 UK districts) and includes the search terms so the user
    /// can tell what each line means.
    nonisolated static func activitySummary(query: RecordQuery, surname: String) -> String {
        let recordTypeLabel: String = switch query.recordType {
        case .birth: "births"
        case .death: "deaths"
        case .marriage: "marriages"
        default: query.recordType.rawValue
        }

        var districtName = "national"
        var spouseSurname: String?
        if case .freeBMD(let params) = query.sourceParams {
            if let code = params.districtCode, !code.isEmpty {
                districtName = FreeBMDDistrictCatalogue.shared.all()
                    .first(where: { $0.code == code })?.name ?? "district \(code)"
            }
            if let ss = params.spouseSurname, !ss.isEmpty {
                spouseSurname = ss
            }
        }

        let searchTerms: String = {
            if let spouse = spouseSurname { return "\(surname) × \(spouse)" }
            if let given = query.givenName, !given.isEmpty { return "\(given) \(surname)" }
            return surname
        }()

        let yearLabel: String
        switch (query.yearFrom, query.yearTo) {
        case let (yf?, yt?) where yf == yt:
            yearLabel = " \(yf)"
        case let (yf?, yt?):
            yearLabel = " \(yf)–\(yt)"
        default:
            yearLabel = ""
        }

        return "FreeBMD \(districtName) \(recordTypeLabel): \(searchTerms)\(yearLabel)"
    }

    // MARK: - Session Management

    /// Fetch a fresh session cookie and hidden form tokens from FreeBMD.
    /// Concurrent callers all await the same establishment task — only one
    /// network fetch ever happens at a time even when 12+ search() calls
    /// queue at the actor.
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

    /// The actual fetch. Only ever called from inside the single in-flight task.
    private func performSessionEstablishment() async throws {
        let data = try await http.get(url: Self.searchFormURL, headers: ["User-Agent": Self.userAgent])
        guard let html = String(data: data, encoding: .utf8) else {
            throw HTTPError.status(code: 0, body: nil)
        }

        // Extract hidden form tokens
        formTokenDB = Self.extractFormValue(named: "db", from: html)
        formTokenV = Self.extractFormValue(named: "v", from: html)

        // Session cookie — FreeBMD sets it on the search form page
        // The HTTP client follows redirects, so we get the cookie via URLSession's cookie storage
        if let cookies = HTTPCookieStorage.shared.cookies(for: Self.searchFormURL) {
            sessionCookie = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        logger.info("Session established (db=\(self.formTokenDB ?? "nil"), v=\(self.formTokenV ?? "nil"))")
    }

    // MARK: - Rate Limiting

    /// Serializes requests with a strict 500ms gap between consecutive calls.
    ///
    /// Slot-reservation pattern: each caller atomically advances `nextRequestSlot`
    /// to its scheduled wall-clock time, then sleeps until that moment before
    /// firing. Because the slot advancement happens entirely synchronously on
    /// the actor (no `await` between read and write), 12 concurrent search()
    /// calls each get a unique slot 500ms apart — they don't pile up and hit
    /// the volunteer source simultaneously.
    ///
    /// FreeBMD is a single-volunteer transcription project; we deliberately do
    /// not run requests in parallel. 12 districts × 0.5s = ~6s per record type
    /// per pipeline iteration. That's well-behaved (2 req/sec, similar to a
    /// human browsing).
    private func rateLimitedRequest(_ operation: () async throws -> Data) async throws -> Data {
        let scheduledFor = reserveNextSlot()
        let now = ContinuousClock.now
        if scheduledFor > now {
            try await Task.sleep(until: scheduledFor, clock: .continuous)
        }
        return try await operation()
    }

    /// Atomically (within the actor's serial section, no await) compute the
    /// next available slot and advance `nextRequestSlot` past it.
    private func reserveNextSlot() -> ContinuousClock.Instant {
        let now = ContinuousClock.now
        let scheduledFor: ContinuousClock.Instant
        if let nextSlot = nextRequestSlot, nextSlot > now {
            // Queue forms — schedule after the previous reservation.
            scheduledFor = nextSlot
        } else {
            // No queue — go now.
            scheduledFor = now
        }
        nextRequestSlot = scheduledFor.advanced(by: requestDelay)
        return scheduledFor
    }

    // MARK: - Parsing (static, testable)

    /// Parse the searchData JavaScript array from a FreeBMD results page.
    /// Ported faithfully from Python's _parse_html().
    nonisolated static func parseSearchResults(_ html: String, recordType: RecordType) -> [SourceRecord] {
        // Extract JavaScript array: var searchData = new Array ("row1","row2",...);
        let arrayPattern = #"var searchData = new Array \((.*?)\);"#
        guard let regex = try? NSRegularExpression(pattern: arrayPattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return []
        }

        let arrayContent = String(html[range])

        // Extract individual quoted strings
        let rowPattern = #""([^"]*)""#
        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern) else { return [] }
        let rowMatches = rowRegex.matches(in: arrayContent, range: NSRange(arrayContent.startIndex..., in: arrayContent))

        var records: [SourceRecord] = []
        var currentYear: Int?
        var currentQuarter: String?

        for rowMatch in rowMatches {
            guard let rowRange = Range(rowMatch.range(at: 1), in: arrayContent) else { continue }
            let row = String(arrayContent[rowRange])
            let parts = row.components(separatedBy: ";")

            // Separator rows: parts[1] in ("0","1","2"), parts[2] is quarter (1-4), parts[3] is year
            if parts.count >= 4,
               ["0", "1", "2"].contains(parts[1]),
               ["1", "2", "3", "4"].contains(parts[2]) {
                currentQuarter = quarterNames[parts[2]]
                currentYear = Int(parts[3])
                continue
            }

            // Data rows: confidence;surname;firstname;spouse_or_mother;flag;district;vol;page;id
            if parts.count >= 8,
               !parts[2].isEmpty,
               parts[2] != "Q",
               !parts[2].hasPrefix("/") {

                let surname = parts[1]
                let firstname = parts[2].removingPercentEncoding ?? parts[2]
                let spouseOrMother = (parts[3].removingPercentEncoding ?? parts[3]).trimmingCharacters(in: .whitespaces)
                let district = parts[5]
                let vol = parts[6]
                let page = parts[7]
                let recordID = parts.count > 8 ? parts[8].components(separatedBy: ":").first ?? "" : ""

                let common = RecordCommon(
                    id: "freebmd_\(recordType.rawValue)_\(vol)_\(page)_\(recordID)",
                    sourceID: "freebmd",
                    name: "\(firstname) \(surname)",
                    surname: surname,
                    givenName: firstname,
                    detailURL: nil,
                    rawFields: [
                        "quarter": currentQuarter ?? "",
                        "year": currentYear.map(String.init) ?? "",
                        "spouse_or_mother": spouseOrMother,
                        "district": district,
                        "vol": vol,
                        "page": page,
                    ]
                )

                let record: SourceRecord = switch recordType {
                case .birth:
                    .birth(BirthRecord(
                        common: common,
                        birthYear: currentYear,
                        birthDate: nil,
                        birthPlace: nil,
                        quarter: currentQuarter,
                        district: district,
                        volume: vol,
                        page: page,
                        mothersMaidenName: spouseOrMother.isEmpty ? nil : spouseOrMother
                    ))
                case .death:
                    .death(DeathRecord(
                        common: common,
                        deathYear: currentYear,
                        deathDate: nil,
                        deathPlace: nil,
                        age: Int(spouseOrMother),  // FreeBMD puts age in spouse_or_mother for deaths
                        quarter: currentQuarter,
                        district: district,
                        volume: vol,
                        page: page,
                        spouseSurname: Int(spouseOrMother) == nil ? spouseOrMother : nil
                    ))
                case .marriage:
                    .marriage(MarriageRecord(
                        common: common,
                        marriageYear: currentYear,
                        marriageDate: nil,
                        marriagePlace: nil,
                        quarter: currentQuarter,
                        district: district,
                        volume: vol,
                        page: page,
                        spouseName: spouseOrMother.isEmpty ? nil : spouseOrMother
                    ))
                default:
                    .birth(BirthRecord(
                        common: common,
                        birthYear: currentYear,
                        birthDate: nil, birthPlace: nil,
                        quarter: currentQuarter, district: district,
                        volume: vol, page: page, mothersMaidenName: nil
                    ))
                }

                records.append(record)
            }
        }

        return records
    }

    /// Extract a hidden form field value by name.
    nonisolated private static func extractFormValue(named name: String, from html: String) -> String? {
        let pattern = "name=\"\(name)\"\\s+value=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }
}
