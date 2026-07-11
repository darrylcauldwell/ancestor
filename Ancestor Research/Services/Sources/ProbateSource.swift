import Foundation
import os

/// England & Wales Probate Calendar — official HMCTS grants of probate
/// https://probatesearch.service.gov.uk/
/// Access: GET with query params → Nuxeo JSON API
/// Auth: None
/// Coverage: ~1996+ digital grants, plus WWI/WWII soldier wills
/// Faithfully ported from Python's sources/probate.py
struct ProbateSource: RecordSource {

    // MARK: - RecordSource Protocol

    nonisolated let sourceID = "probate"
    nonisolated let displayName = "Probate Calendar"
    nonisolated let recordTypes: Set<RecordType> = [.probate]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1858...2026
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .primaryRecord
    nonisolated let trustTier: SourceTrustTier = .primary
    nonisolated let evidenceDirectness: EvidenceDirectness = .primary
    nonisolated let tosStatus = SourceToSStatus(
        level: .open,
        summary: "Public Nuxeo JSON API — official government records"
    )

    // MARK: - State

    private let http: any HTTPClient
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "Probate")

    init(http: any HTTPClient = SourceHTTPClient.shared) {
        self.http = http
    }

    // MARK: - Constants

    nonisolated private static let baseURL = "https://probatesearch.service.gov.uk"
    nonisolated private static let searchEndpoint = "/api/csp/api/v1/search/pp/pp_mainstream_default_search/execute"
    nonisolated private static let userAgent = "AncestorResearch/1.0 (macOS; genealogy research tool; github.com/darrylcauldwell/ancestor)"

    /// Total-results budget across all pages — Python parity
    /// (probate.py:130 `max_results=500`). Internal (not private) so the
    /// paging tests can reference the budget instead of hardcoding it.
    nonisolated static let maxResults = 500
    /// The API's own per-request cap (probate.py:64 `_MAX_PAGE_SIZE`).
    nonisolated private static let maxPageSize = 1000

    // MARK: - Search

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        await searchWithOutcome(query).result
    }

    /// Envelope-aware search (connector-audit T1-01; instances T1-24 /
    /// T1-25). Nuxeo error payloads map to `.unavailable`. Pagination is
    /// a faithful port of Python's paging loop (probate.py:163-191):
    /// page 0 first, read `resultsCount`/`pageCount` from the response,
    /// then loop pages 1..<pageCount accumulating entries until the
    /// 500-record budget or an empty page. `truncated` is false when all
    /// pages were fetched within budget, true (with `totalAvailable`)
    /// when the budget — or an early termination — cut the answer short.
    func searchWithOutcome(_ query: RecordQuery) async -> SourceSearchEnvelope {
        guard query.recordType == .probate else {
            return SourceSearchEnvelope(.outsideCoverage(reason: "Probate Calendar only provides probate records"))
        }
        guard let surname = query.surname, !surname.isEmpty else { return SourceSearchEnvelope(.results([])) }

        let summary = Self.activitySummary(query: query, surname: surname)
        await ResearchActivityBus.shared.publish(.sourceQueryStarted(sourceID: sourceID, summary: summary, strictness: query.strictness))

        // Search params shared by every page request (paging params are
        // appended per page in fetchPage).
        var baseItems = [
            URLQueryItem(name: "hmcts_grant_schema_surname", value: surname.uppercased()),
            URLQueryItem(name: "hmcts_grant_schema_grantdocTypeOf", value: ""),
            URLQueryItem(name: "sortBy", value: ""),
            URLQueryItem(name: "sortOrder", value: ""),
        ]

        if let givenName = query.givenName, !givenName.isEmpty {
            baseItems.append(URLQueryItem(name: "hmcts_grant_schema_firstnames", value: givenName.uppercased()))
        }
        if let yearFrom = query.yearFrom {
            baseItems.append(URLQueryItem(name: "hmcts_grant_schema_dateofdeath_min", value: "\(yearFrom)-01-01T00:00:00.000Z"))
        }
        if let yearTo = query.yearTo {
            baseItems.append(URLQueryItem(name: "hmcts_grant_schema_dateofdeath_max", value: "\(yearTo)-12-31T23:59:59.999Z"))
        }

        do {
            // Page 0 — pageSize = min(budget, API cap), Python parity
            // (probate.py:163-164).
            let data = try await fetchPage(
                baseItems: baseItems,
                pageIndex: 0,
                pageSize: min(Self.maxResults, Self.maxPageSize)
            )

            // T1-25: a 200-status Nuxeo error body ({"hasError":true,…})
            // or a malformed/non-JSON payload is a source failure, not
            // an empty index — mirror the CWGC branded-500 pattern.
            if let errorReason = Self.parseError(data) {
                logger.error("Probate search failed: \(errorReason)")
                await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: errorReason, strictness: query.strictness))
                return SourceSearchEnvelope(.unavailable(reason: errorReason))
            }

            var records = Self.parseJSON(data, surname: surname)
            let totalAvailable = Self.parseTotalCount(data)
            let pageCount = Self.parsePageCount(data) ?? 1

            // T1-24: fetch additional pages if needed — faithful port of
            // probate.py:176-189. Empty entries terminate; a mid-loop
            // error breaks with the partial answer (Python's bare
            // `except: break`), never mapping to `.unavailable` — the
            // truncated flag below keeps the partial answer honest.
            var page = 1
            while page < pageCount && records.count < Self.maxResults {
                do {
                    let remaining = Self.maxResults - records.count
                    let pageData = try await fetchPage(
                        baseItems: baseItems,
                        pageIndex: page,
                        pageSize: min(remaining, Self.maxPageSize)
                    )
                    let pageRecords = Self.parseJSON(pageData, surname: surname)
                    if pageRecords.isEmpty { break }
                    records.append(contentsOf: pageRecords)
                } catch {
                    logger.warning("Probate: page \(page) fetch failed (\(error.localizedDescription)) — returning partial results")
                    break
                }
                page += 1
            }
            if records.count > Self.maxResults {
                records = Array(records.prefix(Self.maxResults))
            }

            // truncated=false when every page was fetched within budget
            // (accumulated count matches the server's own claimed total);
            // true when the 500 budget — or an early break — left claimed
            // records unfetched.
            let truncated = totalAvailable.map { records.count < $0 } ?? false
            logger.info("Probate: \(records.count) of \(totalAvailable ?? records.count) results for \(surname)")
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
            logger.error("Probate search failed: \(error.localizedDescription)")
            await ResearchActivityBus.shared.publish(.sourceError(sourceID: sourceID, summary: summary, reason: error.localizedDescription, strictness: query.strictness))
            return SourceSearchEnvelope(.unavailable(reason: error.localizedDescription))
        }
    }

    /// One Nuxeo page request (Python `_fetch_page`, probate.py:113-126).
    /// Same endpoint, headers, and param set as before — only
    /// `currentPageIndex`/`pageSize` vary per page. Rate politeness is
    /// unchanged: requests are sequential through the shared
    /// retry/backoff `HTTPClient`, exactly like the Python loop.
    private func fetchPage(baseItems: [URLQueryItem], pageIndex: Int, pageSize: Int) async throws -> Data {
        var components = URLComponents(string: Self.baseURL + Self.searchEndpoint)!
        components.queryItems = baseItems + [
            URLQueryItem(name: "currentPageIndex", value: "\(pageIndex)"),
            URLQueryItem(name: "pageSize", value: "\(pageSize)"),
        ]
        return try await http.get(url: components.url!, headers: [
            "User-Agent": Self.userAgent,
            "X-NXproperties": "hmcts_grant_schema",
            "skipAggregates": "true",
        ])
    }

    /// Build a one-line description of a Probate query for the live activity feed.
    nonisolated static func activitySummary(query: RecordQuery, surname: String) -> String {
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
        return "Probate Calendar: \(searchTerms)\(yearLabel)"
    }

    // MARK: - Parsing (nonisolated static — testable)

    /// T1-25 — classify a response body as a source failure. Returns a
    /// human-readable reason, or nil when the body is a well-formed
    /// results payload (which may legitimately contain zero entries).
    /// Ported from Python's `data.get("hasError")` check
    /// (sources/probate.py:168-169), extended to cover malformed/non-JSON
    /// bodies that previously parsed as zero probate records.
    nonisolated static func parseError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "malformed response (not a JSON object)"
        }
        if (json["hasError"] as? Bool) == true {
            let message = (json["errorMessage"] as? String)?.trimmingCharacters(in: .whitespaces)
            return "Probate API error: \((message?.isEmpty == false ? message! : "unknown"))"
        }
        guard json["entries"] is [[String: Any]] else {
            return "malformed response (no entries array)"
        }
        return nil
    }

    /// T1-24 — the response's own claimed total hit count (Nuxeo
    /// `resultsCount`, python parity: probate.py:171). Nil when absent.
    nonisolated static func parseTotalCount(_ data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["resultsCount"] as? Int
    }

    /// T1-24 — the response's claimed page count (Nuxeo `pageCount`,
    /// python parity: probate.py:176, default 1 applied at the call
    /// site). Nil when absent.
    nonisolated static func parsePageCount(_ data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["pageCount"] as? Int
    }

    nonisolated static func parseJSON(_ data: Data, surname: String) -> [SourceRecord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry -> SourceRecord? in
            guard let props = entry["properties"] as? [String: Any] else { return nil }
            let uid = entry["uid"] as? String ?? UUID().uuidString

            let entrySurname = (props["hmctsgrant:surname"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let firstNames = (props["hmctsgrant:firstnames"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let name = firstNames.isEmpty ? entrySurname : "\(firstNames) \(entrySurname)"

            let deathDate = formatDate(props["hmctsgrant:dateofdeath"] as? String)
            let probateDate = formatDate(props["hmctsgrant:dateofprobate"] as? String)
            let birthDate = formatDate(props["hmctsgrant:dateofbirth"] as? String)
            let deathYear = extractYear(from: deathDate)
            let ageAtDeath = props["hmctsgrant:estateage_atdeath"] as? Int

            let address = joinAddress(props)
            let grantType = (props["hmctsgrant:grantdocTypeoOfName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let registry = (props["hmctsgrant:registryofficename"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let probateNumber = (props["hmctsgrant:probatenumber"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let regimentNumber = props["hmctsgrant:regimentnumber"] as? Int

            let common = RecordCommon(
                id: "probate_\(uid)",
                sourceID: "probate",
                name: name,
                surname: entrySurname.isEmpty ? nil : entrySurname,
                givenName: firstNames.isEmpty ? nil : firstNames,
                detailURL: nil,
                rawFields: [
                    "grant_type": grantType,
                    "registry": registry,
                    "address": address,
                ]
            )

            return .probate(ProbateRecord(
                common: common,
                deathDate: deathDate,
                deathYear: deathYear,
                probateDate: probateDate,
                birthDate: birthDate,
                ageAtDeath: ageAtDeath,
                address: address.isEmpty ? nil : address,
                grantType: grantType.isEmpty ? nil : grantType,
                registry: registry.isEmpty ? nil : registry,
                probateNumber: probateNumber.isEmpty ? nil : probateNumber,
                regimentNumber: regimentNumber
            ))
        }
    }

    // MARK: - Helpers

    /// Extract YYYY-MM-DD from an ISO datetime string.
    nonisolated private static func formatDate(_ isoStr: String?) -> String? {
        guard let str = isoStr, str.count >= 10 else { return nil }
        return String(str.prefix(10))
    }

    /// Extract 4-digit year from a date string.
    nonisolated private static func extractYear(from dateStr: String?) -> Int? {
        guard let str = dateStr else { return nil }
        let pattern = #"\b(\d{4})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
              let range = Range(match.range(at: 1), in: str) else { return nil }
        return Int(str[range])
    }

    /// Join address lines from properties.
    nonisolated private static func joinAddress(_ props: [String: Any]) -> String {
        let keys = [
            "hmctsgrant:estateaddressline1",
            "hmctsgrant:estateaddressline2",
            "hmctsgrant:estateaddressline3",
            "hmctsgrant:estateaddressline4",
        ]
        return keys
            .compactMap { (props[$0] as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
