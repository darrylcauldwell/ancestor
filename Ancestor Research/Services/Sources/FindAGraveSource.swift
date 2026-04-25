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
    private var lastRequestTime: ContinuousClock.Instant?
    private let requestDelay: Duration = .milliseconds(500)  // be polite to volunteer site

    private var lastSuccessfulSearch: Date?
    private var lastError: String?

    // MARK: - Constants

    nonisolated private static let baseURL = "https://www.findagrave.com"
    nonisolated private static let searchURL = "\(baseURL)/memorial/search"
    nonisolated private static let userAgent = "AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        guard recordTypes.contains(query.recordType) else { return .outsideCoverage(reason: "Find a Grave does not provide \(query.recordType.rawValue) records") }

        // Extract source-specific params
        let fagParams: FindAGraveParams
        if case .findAGrave(let p) = query.sourceParams { fagParams = p }
        else { fagParams = FindAGraveParams(yearRangeWidth: 5, location: nil) }

        do {
            var params: [String: String] = [
                "ajax": "true",
                "skip": "0",
                "limit": "20",
            ]

            if let surname = query.surname, !surname.isEmpty {
                params["lastname"] = surname
            }
            if let given = query.givenName, !given.isEmpty {
                params["firstname"] = given
            }
            if let yearFrom = query.yearFrom {
                params["birthyear"] = String(yearFrom)
                params["birthyearfilter"] = String(fagParams.yearRangeWidth)
            }
            if let yearTo = query.yearTo {
                params["deathyear"] = String(yearTo)
                params["deathyearfilter"] = String(fagParams.yearRangeWidth)
            }
            if let location = fagParams.location, !location.isEmpty {
                params["location"] = location
            }

            let urlString = Self.searchURL + "?" + params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
            guard let url = URL(string: urlString) else { return .results([]) }

            let data = try await rateLimitedRequest {
                try await self.http.get(url: url, headers: [
                    "User-Agent": Self.userAgent,
                    "X-Requested-With": "XMLHttpRequest",
                    "Accept": "application/json, text/html, */*",
                ])
            }

            let results = Self.parseSearchResults(data)
            lastSuccessfulSearch = Date()
            lastError = nil
            logger.info("Search returned \(results.count) results")
            return .results(results)

        } catch {
            lastError = error.localizedDescription
            logger.warning("Search failed: \(error.localizedDescription)")
            return .unavailable(reason: error.localizedDescription)
        }
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
            let data = try await rateLimitedRequest {
                try await self.http.get(url: url, headers: ["User-Agent": Self.userAgent])
            }
            guard let html = String(data: data, encoding: .utf8) else {
                return .unavailable(reason: "Invalid encoding in response")
            }
            if let record = Self.parseMemorialDetail(html, memorialID: memorialID) {
                return .results([record])
            }
            return .results([])
        } catch {
            logger.warning("Detail fetch failed for memorial \(memorialID): \(error.localizedDescription)")
            return .unavailable(reason: error.localizedDescription)
        }
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

    // MARK: - Parsing (static, testable with canned data)

    /// Parse JSON search results into SourceRecords.
    nonisolated static func parseSearchResults(_ data: Data) -> [SourceRecord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseCode = json["responseCode"] as? Int, responseCode == 200,
              let records = json["records"] as? [[String: Any]] else {
            return []
        }

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
                burialLocation: locationParts.joined(separator: ", "),
                cemetery: rec["cemeteryName"] as? String,
                memorialID: memorialID,
                inscription: nil,  // only available from detail page
                bio: nil,
                isVeteran: rec["isVeteran"] as? Bool ?? false
            ))
        }
    }

    /// Parse memorial detail HTML into a SourceRecord.
    nonisolated static func parseMemorialDetail(_ html: String, memorialID: Int) -> SourceRecord? {
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
        let birthPlace = extractItempropBlock("birthPlace", from: html) // TODO: add to BurialRecord
        let deathPlace = extractItempropBlock("deathPlace", from: html) // TODO: add to BurialRecord

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
            deathYear: ScoringRules.extractYear(from: deathDate ?? ""),
            birthDate: birthDate,
            birthYear: ScoringRules.extractYear(from: birthDate ?? ""),
            burialLocation: locParts.joined(separator: ", "),
            cemetery: cemetery,
            memorialID: memorialID,
            inscription: inscription,
            bio: bio,
            isVeteran: false  // not available from detail page
        ))
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
