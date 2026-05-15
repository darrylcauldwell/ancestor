import Foundation
import os

/// Commonwealth War Graves Commission — military casualty records
/// https://www.cwgc.org/
/// Access: GET with query params → CSV response
/// Auth: None
/// Coverage: WWI (1914-1918) and WWII (1939-1945), Commonwealth forces
/// ToS: https://www.cwgc.org/about-us/terms-and-conditions/
struct CWGCSource: RecordSource {

    // MARK: - RecordSource Protocol

    nonisolated let sourceID = "cwgc"
    nonisolated let displayName = "CWGC"
    nonisolated let recordTypes: Set<RecordType> = [.death, .burial]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1914...1947
    nonisolated let coverageRegions: Set<Region> = [.commonwealthMilitary]
    nonisolated let dataLineage: SourceLineage = .primaryRecord
    nonisolated let trustTier: SourceTrustTier = .primary
    nonisolated let evidenceDirectness: EvidenceDirectness = .primary
    nonisolated let tosStatus = SourceToSStatus(
        level: .open,
        summary: "Public CSV export endpoint — official government records"
    )

    // MARK: - State

    private let http: any HTTPClient
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "CWGC")

    init(http: any HTTPClient = SourceHTTPClient.shared) {
        self.http = http
    }

    // MARK: - Constants

    // Trailing slash is canonical — without it the server replies 301 to
    // the slashed form. URLSession follows the redirect, but going direct
    // removes a round-trip and a class of redirect-handling failure modes.
    nonisolated private static let exportURL = "https://www.cwgc.org/ExportCasualtySearch/"
    nonisolated private static let userAgent = "AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        guard recordTypes.contains(query.recordType) else {
            return .outsideCoverage(reason: "CWGC only provides death/burial records")
        }
        guard let surname = query.surname, !surname.isEmpty else { return .results([]) }

        let summary = Self.activitySummary(query: query, surname: surname)
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary))

        do {
            var components = URLComponents(string: Self.exportURL)!
            var queryItems = [
                URLQueryItem(name: "Surname", value: surname),
                URLQueryItem(name: "Tab", value: "exact"),
            ]
            if let given = query.givenName, !given.isEmpty {
                queryItems.append(URLQueryItem(name: "Forename", value: given))
            }
            // Map war filter from date range
            if let yearFrom = query.yearFrom, let yearTo = query.yearTo {
                if yearTo <= 1918 {
                    queryItems.append(URLQueryItem(name: "WarSelect", value: "1"))
                } else if yearFrom >= 1939 {
                    queryItems.append(URLQueryItem(name: "WarSelect", value: "2"))
                }
            }
            components.queryItems = queryItems

            guard let url = components.url else {
                await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: 0))
                return .results([])
            }

            let data = try await http.get(url: url, headers: ["User-Agent": Self.userAgent])
            guard let csv = String(data: data, encoding: .utf8) else {
                await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: "Invalid encoding"))
                return .unavailable(reason: "Invalid encoding in CSV response")
            }

            let records = Self.parseCSV(csv)
            logger.info("CWGC search returned \(records.count) records for \(surname)")
            await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: records.count))
            return .results(records)

        } catch let error as HTTPError {
            // CWGC server bug (observed 2026-05): Tab=exact + Forename with
            // zero matches returns HTTP 500 serving the site's branded error
            // page instead of an empty CSV. The signature `<title>500 | CWGC</title>`
            // is unique enough to distinguish this from a genuine outage.
            // Treat it as a successful empty result.
            if case .status(500, let body?) = error,
               let html = String(data: body, encoding: .utf8),
               html.contains("<title>500 | CWGC</title>") {
                logger.info("CWGC returned its empty-results 500 page for \(surname) — treating as zero matches")
                await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: 0))
                return .results([])
            }
            logger.warning("CWGC search failed: \(error.localizedDescription)")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription))
            return .unavailable(reason: error.localizedDescription)
        } catch {
            logger.warning("CWGC search failed: \(error.localizedDescription)")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription))
            return .unavailable(reason: error.localizedDescription)
        }
    }

    /// Build a one-line description of a CWGC query for the live activity feed.
    /// Surfaces the war filter (WWI / WWII / both) so the user can tell which
    /// casualty database each line probed.
    nonisolated static func activitySummary(query: RecordQuery, surname: String) -> String {
        let warLabel: String
        if let yearFrom = query.yearFrom, let yearTo = query.yearTo {
            if yearTo <= 1918 { warLabel = "WWI " }
            else if yearFrom >= 1939 { warLabel = "WWII " }
            else { warLabel = "" }
        } else {
            warLabel = ""
        }
        let searchTerms: String = {
            if let given = query.givenName, !given.isEmpty { return "\(given) \(surname)" }
            return surname
        }()
        return "CWGC \(warLabel)casualties: \(searchTerms)"
    }

    // MARK: - CSV Parsing (static, testable)

    /// Parse CWGC CSV export into SourceRecords.
    /// Ported faithfully from Python's cwgc.py.
    nonisolated static func parseCSV(_ csv: String) -> [SourceRecord] {
        let lines = csv.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > 1 else { return [] }  // header only or empty

        var records: [SourceRecord] = []

        for (index, line) in lines.enumerated() where index > 0 {
            let fields = parseCSVLine(line)
            guard fields.count >= 19 else { continue }

            let casualtyID = fields[0]
            let surname = fields[1]
            let forename = fields[2]
            let initials = fields[3]
            let ageRaw = Int(fields[4]) ?? 0
            let age = ageRaw > 0 ? ageRaw : nil
            let honours = fields[5]
            let dateOfDeath = reformatDate(fields[6])
            let rank = fields[8]
            let regiment = [fields[9], fields[10]].filter { !$0.isEmpty }.joined(separator: " / ")
            let unit = [fields[11], fields[12]].filter { !$0.isEmpty }.joined(separator: " / ")
            let countryOfService = fields[13]
            let serviceNumber = fields[14].replacingOccurrences(of: "'", with: "")
            let burialCountry = fields[15]
            let cemetery = fields[16]
            let graveRef = fields[17]
            let additionalInfo = fields.count > 18 ? fields[18] : ""

            let name = "\(forename) \(surname)".trimmingCharacters(in: .whitespaces)
            let deathYear = ScoringRules.extractYear(from: dateOfDeath ?? "")

            let common = RecordCommon(
                id: "cwgc_\(casualtyID)",
                sourceID: "cwgc",
                name: name,
                surname: surname,
                givenName: forename.isEmpty ? nil : forename,
                detailURL: "https://www.cwgc.org/find-records/find-war-dead/casualty-details/\(casualtyID)/",
                rawFields: [
                    "casualty_id": casualtyID,
                    "initials": initials,
                    "honours": honours,
                    "rank": rank,
                    "regiment": regiment,
                    "unit": unit,
                    "service_number": serviceNumber,
                    "country_of_service": countryOfService,
                    "burial_country": burialCountry,
                    "cemetery": cemetery,
                    "grave_ref": graveRef,
                    "additional_info": additionalInfo,
                    "date_of_death": dateOfDeath ?? "",
                ].filter { !$0.value.isEmpty }
            )

            records.append(.military(MilitaryRecord(
                common: common,
                rank: rank.isEmpty ? nil : rank,
                regiment: regiment.isEmpty ? nil : regiment,
                unit: unit.isEmpty ? nil : unit,
                serviceNumber: serviceNumber.isEmpty ? nil : serviceNumber,
                dateOfDeath: dateOfDeath,
                deathYear: deathYear,
                age: age,
                cemetery: cemetery.isEmpty ? nil : cemetery,
                graveRef: graveRef.isEmpty ? nil : graveRef,
                additionalInfo: additionalInfo.isEmpty ? nil : additionalInfo
            )))
        }

        return records
    }

    /// Parse a CSV line handling quoted fields with commas.
    nonisolated private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    /// Reformat CWGC date from DD/MM/YYYY to "DD Month YYYY".
    nonisolated private static func reformatDate(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "/")
        guard parts.count == 3,
              let day = Int(parts[0]),
              let monthNum = Int(parts[1]),
              let year = Int(parts[2]) else { return raw }

        let months = ["", "January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"]
        guard monthNum >= 1 && monthNum <= 12 else { return raw }

        return "\(day) \(months[monthNum]) \(year)"
    }
}
