import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-07 + T1-12 + T1-06 (query side) + T1-13 (search
/// level) — CWGC's wire shape (CONNECTOR_AUDIT_2026-07.md §6.2).
@MainActor
struct CWGCQueryShapeTests {

    // MARK: - Helpers

    private func query(
        surname: String = "Cauldwell",
        givenName: String? = "Ernest",
        recordType: RecordType = .death,
        yearFrom: Int? = nil,
        yearTo: Int? = nil,
        strictness: SearchStrictness = .strict
    ) -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: givenName,
            recordType: recordType,
            yearFrom: yearFrom, yearTo: yearTo,
            gender: .male, region: nil,
            sourceParams: .cwgc(CWGCParams(conflict: nil)),
            strictness: strictness
        )
    }

    private func wire(_ query: RecordQuery, forename: String? = nil, initials: String? = nil, useQueryForename: Bool = true) -> [String: String] {
        let items = CWGCSource.exportQueryItems(
            query: query,
            surname: query.surname ?? "",
            forename: useQueryForename ? query.givenName : forename,
            initials: initials
        )
        var params: [String: String] = [:]
        for item in items { params[item.name] = item.value }
        return params
    }

    // MARK: - T1-07 — death-year bounds reach the wire

    @Test func paddedWindowSendsDeathYearBounds() {
        // THE regression case: death known 1917 → dispatcher window
        // 1915–1919. Previously this got NO filter at all (yearTo > 1918
        // defeated the WarSelect threshold and no year params existed) —
        // every same-surname casualty across both wars came back.
        let params = wire(query(yearFrom: 1915, yearTo: 1919))
        #expect(params["DateDeathFromYear"] == "1915")
        #expect(params["DateDeathToYear"] == "1919")
        #expect(params["WarSelect"] == "1",
                "1915–1919 intersects only the WW1 span → WarSelect=1")
    }

    @Test func ww2WindowSelectsWarTwo() {
        let params = wire(query(yearFrom: 1943, yearTo: 1946))
        #expect(params["WarSelect"] == "2")
        #expect(params["DateDeathFromYear"] == "1943")
        #expect(params["DateDeathToYear"] == "1946")
    }

    @Test func windowSpanningBothWarsOmitsWarSelect() {
        let params = wire(query(yearFrom: 1916, yearTo: 1946))
        #expect(params["WarSelect"] == nil,
                "a window intersecting both wars must not pick one")
        #expect(params["DateDeathFromYear"] == "1916")
        #expect(params["DateDeathToYear"] == "1946")
    }

    @Test func boundsClampToTheCorpus() {
        let early = wire(query(yearFrom: 1900, yearTo: 1920))
        #expect(early["DateDeathFromYear"] == "1914")
        #expect(early["DateDeathToYear"] == "1920")

        let late = wire(query(yearFrom: 1940, yearTo: 1960))
        #expect(late["DateDeathFromYear"] == "1940")
        #expect(late["DateDeathToYear"] == "1947")
    }

    @Test func noWindowSendsNoYearParams() {
        let params = wire(query())
        #expect(params["DateDeathFromYear"] == nil)
        #expect(params["DateDeathToYear"] == nil)
        #expect(params["WarSelect"] == nil)
    }

    @Test func legacyThresholdCasesStillGetTheRightWar() {
        // The old threshold behaviour survives where it was correct.
        #expect(wire(query(yearFrom: 1914, yearTo: 1918))["WarSelect"] == "1")
        #expect(wire(query(yearFrom: 1939, yearTo: 1945))["WarSelect"] == "2")
    }

    @Test func strictnessControlsTabExact() {
        #expect(wire(query(strictness: .strict))["Tab"] == "exact")
        #expect(wire(query(strictness: .loose))["Tab"] == nil)
    }

    // MARK: - T1-06 (query side) — the initials probe's shape

    @Test func initialsProbeDropsForenameAndCarriesInitials() {
        let params = wire(query(), initials: "E", useQueryForename: false)
        #expect(params["Forename"] == nil)
        #expect(params["Initials"] == "E")
        #expect(params["Surname"] == "Cauldwell")
    }

    @Test func initialsFallbackValueDerivation() {
        #expect(CWGCSource.initialsFallbackValue(givenName: "Ernest") == "E")
        #expect(CWGCSource.initialsFallbackValue(givenName: "ernest victor") == "E")
        #expect(CWGCSource.initialsFallbackValue(givenName: nil) == nil)
        #expect(CWGCSource.initialsFallbackValue(givenName: "") == nil)
        #expect(CWGCSource.initialsFallbackValue(givenName: "  ") == nil)
    }

    // MARK: - T1-12 — one record type, one dispatch

    @Test func cwgcRegistersForDeathOnly() {
        #expect(CWGCSource().recordTypes == [.death],
                "T1-12: .burial produced a byte-identical duplicate query racing past the per-run cache")
    }

    @Test func burialQueryIsOutsideCoverage() async {
        let source = CWGCSource(http: SequencedCWGCHTTPClient([]))
        let result = await source.search(query(recordType: .burial))
        guard case .outsideCoverage = result else {
            Issue.record("burial searches must be declared outside coverage, got \(result)")
            return
        }
    }
}

/// Search-flow tests — fallback probe and the T1-13 sanity check need a
/// sequenced fake transport.
@MainActor
struct CWGCSearchFlowTests {

    private static let header = "Id,Surname,Forename,Initials,AgeAtDeath,Honours,DateOfDeath,DateOfDeath2,Rank,Regiment,SecondaryRegiment,Unit,SecondaryUnit,CountryOfService,ServiceNumber,Burial,Cemetery,GraveRef,AdditionalInfo"

    private static let initialsIndexedRow = "123456,CAULDWELL,,E V,31,,21/03/1918,,Private,Sherwood Foresters,,,,United Kingdom,12345,France,Arras Memorial,Bay 7,"

    private static let forenameRow = "654321,CAULDWELL,ERNEST,E,31,,21/03/1918,,Private,Sherwood Foresters,,,,United Kingdom,54321,France,Arras Memorial,Bay 8,"

    private func query(
        givenName: String? = "Ernest",
        strictness: SearchStrictness = .strict
    ) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: givenName,
            recordType: .death,
            yearFrom: 1915, yearTo: 1919,
            gender: .male, region: nil,
            sourceParams: .cwgc(CWGCParams(conflict: nil)),
            strictness: strictness
        )
    }

    private func data(_ string: String) -> Data { Data(string.utf8) }

    // MARK: - T1-06 — initials fallback probe

    @Test func emptyForenameResultRetriesWithInitials() async {
        let client = SequencedCWGCHTTPClient([
            .success(data(Self.header + "\n")),                              // forename probe: genuine zero
            .success(data(Self.header + "\n" + Self.initialsIndexedRow)),    // initials probe: hit
        ])
        let source = CWGCSource(http: client)
        let result = await source.search(query())
        guard case .results(let records) = result else {
            Issue.record("expected results, got \(result)")
            return
        }
        #expect(records.count == 1)
        #expect(records.first?.id == "cwgc_123456")

        let urls = client.requestedURLs.map(\.absoluteString)
        #expect(urls.count == 2, "zero from the forename probe must trigger exactly one initials retry")
        #expect(urls.first?.contains("Forename=Ernest") == true)
        #expect(urls.last?.contains("Initials=E") == true)
        #expect(urls.last?.contains("Forename=") == false,
                "the fallback probe drops Forename")
    }

    @Test func forenameHitDoesNotTriggerFallback() async {
        let client = SequencedCWGCHTTPClient([
            .success(data(Self.header + "\n" + Self.forenameRow)),
        ])
        let source = CWGCSource(http: client)
        let result = await source.search(query())
        guard case .results(let records) = result else {
            Issue.record("expected results, got \(result)")
            return
        }
        #expect(records.count == 1)
        #expect(client.requestedURLs.count == 1, "a hit must not spend a second request")
    }

    @Test func noGivenNameMeansNoFallbackProbe() async {
        let client = SequencedCWGCHTTPClient([
            .success(data(Self.header + "\n")),
        ])
        let source = CWGCSource(http: client)
        let result = await source.search(query(givenName: nil))
        guard case .results(let records) = result else {
            Issue.record("expected results, got \(result)")
            return
        }
        #expect(records.isEmpty)
        #expect(client.requestedURLs.count == 1)
    }

    @Test func brandedEmpty500StillTriggersFallback() async {
        // The Tab=exact+Forename zero-match quirk serves a branded 500 —
        // it is a genuine zero, so the initials probe should still fire.
        let branded = data("<html><head><title>500 | CWGC</title></head></html>")
        let client = SequencedCWGCHTTPClient([
            .failure(HTTPError.status(code: 500, body: branded)),
            .success(data(Self.header + "\n" + Self.initialsIndexedRow)),
        ])
        let source = CWGCSource(http: client)
        let result = await source.search(query())
        guard case .results(let records) = result else {
            Issue.record("expected results, got \(result)")
            return
        }
        #expect(records.count == 1)
        #expect(client.requestedURLs.count == 2)
    }

    // MARK: - T1-13 — non-CSV bodies are unavailable, not zeros

    @Test func htmlBodyMapsToUnavailable() async {
        let client = SequencedCWGCHTTPClient([
            .success(data("<!DOCTYPE html><html><body>Down for maintenance</body></html>")),
        ])
        let source = CWGCSource(http: client)
        let result = await source.search(query())
        guard case .unavailable = result else {
            Issue.record("a maintenance page must not read as a genuine zero, got \(result)")
            return
        }
    }

    @Test func genuineHTTPFailureMapsToUnavailable() async {
        let client = SequencedCWGCHTTPClient([
            .failure(HTTPError.status(code: 503, body: nil)),
        ])
        let source = CWGCSource(http: client)
        let result = await source.search(query())
        guard case .unavailable = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
    }
}

/// Test transport: returns queued responses in order, records every URL.
/// Exhausted queues return empty bytes (parses as not-CSV).
final class SequencedCWGCHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<Data, Error>]
    private var _requestedURLs: [URL] = []

    var requestedURLs: [URL] { lock.withLock { _requestedURLs } }

    init(_ responses: [Result<Data, Error>]) {
        self.responses = responses
    }

    func get(url: URL, headers: [String: String]) async throws -> Data {
        let next: Result<Data, Error>? = lock.withLock {
            _requestedURLs.append(url)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        guard let next else { return Data() }
        return try next.get()
    }

    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        Data()
    }
}
