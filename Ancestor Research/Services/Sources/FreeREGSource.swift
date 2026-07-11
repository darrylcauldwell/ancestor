import CryptoKit
import Foundation
import os

/// FreeREG — volunteer-transcribed parish register records
/// https://www.freereg.org.uk/
/// Access: POST form with CSRF token → HTML table results
/// Auth: CSRF token from search form
/// Coverage: ~1500–1900, England & Wales parish registers (baptism, marriage, burial)
/// Faithfully ported from Python's sources/freereg_search.py
actor FreeREGSource: RecordSource {

    // MARK: - RecordSource Protocol

    nonisolated let sourceID = "freereg"
    nonisolated let displayName = "FreeREG"
    nonisolated let descriptiveName = "UK Parish Registers (FreeREG)"
    nonisolated let recordTypes: Set<RecordType> = [.baptism, .marriage, .burial, .parish]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1500...1900
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "parish-registers")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(
        level: .community,
        summary: "Volunteer transcription project — no API, no explicit prohibition"
    )

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

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        guard recordTypes.contains(query.recordType) else {
            return .outsideCoverage(reason: "FreeREG provides parish register records only")
        }
        guard let surname = query.surname, !surname.isEmpty else { return .results([]) }

        // Map record type to FreeREG form value
        let recordTypeValue: String
        switch query.recordType {
        case .baptism, .christening: recordTypeValue = "ba"
        case .marriage: recordTypeValue = "ma"
        case .burial: recordTypeValue = "bu"
        default: recordTypeValue = ""  // All types
        }

        // Get chapman code from query params.
        // Dispatcher passes a freeREG param (from .national scope fan-out) or, for
        // backwards-compat with older call sites, accept a freeCen param too.
        // FreeREG is chapman-coded: without a county code the query cannot
        // be scoped, so degrade honestly instead of guessing a county.
        let chapmanCode: String
        if case .freeREG(let params) = query.sourceParams, let code = params.chapmanCode, !code.isEmpty {
            chapmanCode = code
        } else if case .freeCen(let params) = query.sourceParams, let code = params.chapmanCode, !code.isEmpty {
            chapmanCode = code
        } else {
            return .outsideCoverage(reason: "No home county (Chapman code) available to scope a FreeREG search")
        }

        let summary = Self.activitySummary(query: query, surname: surname, chapmanCode: chapmanCode)
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary, strictness: query.strictness))

        do {
            try await ensureSession()

            var fields: [String: String] = [
                "search_query[last_name]": surname,
                "search_query[chapman_codes][]": chapmanCode,
                "commit": "Search",
            ]
            // RESEARCH_AXES_SPEC Change 5/6: FreeREG exposes a Name Soundex
            // checkbox at `search_query[fuzzy]` (form value `"true"`).
            // .loose enables it. .variant is the dispatcher tier marker —
            // the surname has been substituted to a variant before arriving,
            // so the variant probe is exact-match (no fuzzy field).
            if query.strictness == .loose {
                fields["search_query[fuzzy]"] = "true"
            }
            if let token = csrfToken {
                fields["authenticity_token"] = token
            }
            if let givenName = query.givenName, !givenName.isEmpty {
                fields["search_query[first_name]"] = givenName
            }
            if !recordTypeValue.isEmpty {
                fields["search_query[record_type]"] = recordTypeValue
            }
            if let yearFrom = query.yearFrom {
                fields["search_query[start_year]"] = String(yearFrom)
            }
            if let yearTo = query.yearTo {
                fields["search_query[end_year]"] = String(yearTo)
            }

            let data = try await rateLimitedRequest {
                try await self.http.postForm(
                    url: URL(string: Self.searchPostURL)!,
                    fields: fields,
                    headers: [
                        "User-Agent": Self.userAgent,
                        "X-CSRF-Token": self.csrfToken ?? "",
                        "Referer": Self.searchFormURL,
                    ]
                )
            }

            let html = String(data: data, encoding: .utf8) ?? ""
            let records = Self.parseResults(html, recordType: query.recordType)
            logger.info("FreeREG: \(records.count) results for \(surname)")
            await ResearchActivityBus.shared.publish(.sourceQueryCompleted(sourceID: sourceID, summary: summary, resultCount: records.count, strictness: query.strictness))
            return .results(records)
        } catch {
            csrfToken = nil  // Reset on error
            logger.error("FreeREG search failed: \(error.localizedDescription)")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription, strictness: query.strictness))
            return .unavailable(reason: error.localizedDescription)
        }
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

    // MARK: - Parsing (nonisolated static — testable)

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
            let name = row["name"] ?? row["surname"] ?? ""
            let date = row["date"] ?? ""
            let parish = row["parish"] ?? ""
            let county = row["county"] ?? ""
            let type = row["record type"] ?? row["type"] ?? ""

            guard !name.isEmpty else { continue }

            let parts = name.split(separator: " ", maxSplits: 1)
            let givenName = parts.count > 0 ? String(parts[0]) : nil
            let surname = parts.count > 1 ? String(parts[1]) : name

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
