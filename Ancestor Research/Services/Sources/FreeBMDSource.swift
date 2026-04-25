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
    private var lastRequestTime: ContinuousClock.Instant?
    private let requestDelay: Duration = .milliseconds(500)

    // Session state (CSRF tokens)
    private var sessionCookie: String?
    private var formTokenDB: String?
    private var formTokenV: String?

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

        do {
            try await ensureSession()

            let recordType: String = switch query.recordType {
            case .birth: "Births"
            case .death: "Deaths"
            case .marriage: "Marriages"
            default: "All"
            }

            let fields: [String: String] = [
                "type": recordType,
                "surname": surname,
                "given": query.givenName ?? "",
                "s_surname": "",
                "s_given": "",
                "start": query.yearFrom.map(String.init) ?? "",
                "end": query.yearTo.map(String.init) ?? "",
                "districtid": { if case .freeBMD(let p) = query.sourceParams { return p.districtCode ?? "" }; return "" }(),
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

            guard let html = String(data: data, encoding: .utf8) else { return .unavailable(reason: "Invalid encoding") }
            let results = Self.parseSearchResults(html, recordType: query.recordType)
            lastSuccessfulSearch = Date()
            lastError = nil
            logger.info("Search returned \(results.count) results for \(surname)")
            return .results(results)

        } catch {
            lastError = error.localizedDescription
            logger.warning("Search failed: \(error.localizedDescription)")
            sessionCookie = nil
            formTokenDB = nil
            formTokenV = nil
            return .unavailable(reason: error.localizedDescription)
        }
    }

    // MARK: - Session Management

    /// Fetch a fresh session cookie and hidden form tokens from FreeBMD.
    private func ensureSession() async throws {
        guard sessionCookie == nil else { return }

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

    private func rateLimitedRequest(_ operation: () async throws -> Data) async throws -> Data {
        if let lastTime = lastRequestTime {
            let elapsed = ContinuousClock.now - lastTime
            if elapsed < requestDelay {
                try await Task.sleep(for: requestDelay - elapsed)
            }
        }
        lastRequestTime = .now
        return try await operation()
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
