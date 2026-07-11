import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// FT-25 / FT-28 — dispatcher-side batching wiring for FreeCen/FreeREG
/// (CONNECTOR_AUDIT_2026-07 §2.4). The transport primitive
/// (`postForm(multiFields:)`, preserving repeated keys) shipped separately;
/// these tests pin the connector + dispatcher + cache wiring that rides it:
///
/// - FT-25 query-shape: when a batch of chapman codes is present, the
///   connector emits one repeated `search_query[chapman_codes][]` key PER
///   code on the wire (not a collapsed single value); a single code stays a
///   single key (byte-identical to the pre-FT-25 shape).
/// - FT-28 grouping: the dispatcher batches broad-scope fan-out into
///   conservative groups (default gate OFF → one code per query; gate ON →
///   groups of `batchGroupSize`).
/// - Cache-key distinctness: a batched multi-county query is a DIFFERENT wire
///   request from a single-county one, so `QueryCache.cacheKey` keys the SET
///   of codes — and a lone code keys exactly as before FT-25.
/// - Geography-scoring survives a batched response: each returned row still
///   carries its OWN county/place, so per-record geography is unaffected by
///   how the counties were requested.
/// - Truncation-honesty survives a batched response: a batched query whose
///   response claims more hits than parsed still sets `truncated`.

// MARK: - Shared fixtures

private nonisolated enum BatchFixtures {
    static let fcFormURL = URL(string: "https://www.freecen.org.uk/search_records")!
    static let fcPostURL = URL(string: "https://www.freecen.org.uk/search_queries")!
    static let frFormURL = URL(string: "https://www.freereg.org.uk/search_queries/new")!
    static let frPostURL = URL(string: "https://www.freereg.org.uk/search_queries")!

    static let fcCSRF = #"<meta name="csrf-token" content="test-token">"#
    static let frCSRF = #"<meta name="csrf-token" content="test-token">"#

    /// A batched FreeCen response covering rows from THREE different census
    /// counties (Derbyshire, Lancashire, Yorkshire) — proves per-row
    /// geography is intact regardless of how the counties were requested.
    /// Claims 3 hits, shows 3 → not truncated.
    static let fcBatchedResults = """
    We found 3 Results
    <table>
    <tr><th>View</th><th>Name</th><th>Birth County</th><th>Birth Place</th><th>Birth Year</th><th>Census Year</th><th>County</th><th>District</th></tr>
    <tr><td><a href="/search_records/aaa111">View</a></td><td>John Smith</td><td>Derbyshire</td><td>Belper</td><td>1850</td><td>1891</td><td>Derbyshire</td><td>Belper</td></tr>
    <tr><td><a href="/search_records/bbb222">View</a></td><td>John Smith</td><td>Lancashire</td><td>Bolton</td><td>1852</td><td>1891</td><td>Lancashire</td><td>Bolton</td></tr>
    <tr><td><a href="/search_records/ccc333">View</a></td><td>John Smith</td><td>Yorkshire</td><td>Leeds</td><td>1849</td><td>1891</td><td>Yorkshire</td><td>Leeds</td></tr>
    </table>
    """

    /// A batched FreeCen response that claims 40 hits but shows 2 and has NO
    /// next page — the honest-truncation path when the count can't be walked.
    static let fcBatchedTruncated = """
    We found 40 Results
    <table>
    <tr><th>View</th><th>Name</th><th>Birth County</th><th>Birth Place</th><th>Birth Year</th><th>Census Year</th><th>County</th><th>District</th></tr>
    <tr><td><a href="/search_records/aaa111">View</a></td><td>John Smith</td><td>Derbyshire</td><td>Belper</td><td>1850</td><td>1891</td><td>Derbyshire</td><td>Belper</td></tr>
    <tr><td><a href="/search_records/bbb222">View</a></td><td>John Smith</td><td>Lancashire</td><td>Bolton</td><td>1852</td><td>1891</td><td>Lancashire</td><td>Bolton</td></tr>
    </table>
    """

    /// A batched FreeREG response spanning two counties.
    static let frBatchedResults = """
    We found 2 results
    <table>
    <tr><th>Name</th><th>Date</th><th>Parish</th><th>County</th><th>Record Type</th></tr>
    <tr><td><a href="/search_records/abc123">Sarah Kenworthy</a></td><td>12 Mar 1850</td><td>Belper</td><td>Derbyshire</td><td>Baptism</td></tr>
    <tr><td><a href="/search_records/def456">Thomas Kenworthy</a></td><td>3 Jun 1852</td><td>Bolton</td><td>Lancashire</td><td>Baptism</td></tr>
    </table>
    """

    static func fcQuery(params: FreeCenParams) -> RecordQuery {
        RecordQuery(
            surname: "Smith", givenName: "John",
            recordType: .census,
            yearFrom: 1891, yearTo: 1891, gender: .male, region: nil,
            sourceParams: .freeCen(params),
            strictness: .strict
        )
    }

    static func frQuery(params: FreeREGParams) -> RecordQuery {
        RecordQuery(
            surname: "Kenworthy", givenName: nil,
            recordType: .baptism,
            yearFrom: nil, yearTo: nil, gender: nil, region: nil,
            sourceParams: .freeREG(params),
            strictness: .strict
        )
    }

    /// Count of `key=` occurrences in an ordered pair list.
    static func count(_ pairs: [(String, String)]?, key: String) -> Int {
        (pairs ?? []).filter { $0.0 == key }.count
    }

    /// Values emitted for a repeated key, in order.
    static func values(_ pairs: [(String, String)]?, key: String) -> [String] {
        (pairs ?? []).filter { $0.0 == key }.map { $0.1 }
    }
}

// MARK: - FT-25 query-shape: batched multi-code emission via multiFields

@MainActor
struct FreeCenBatchedEmissionTests {

    @Test func batchedResidenceCodesEmitOneRepeatedKeyPerCode() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = BatchFixtures.fcQuery(params: FreeCenParams(
            chapmanCode: nil,
            chapmanCodes: ["DBY", "LAN", "YKS"],
            censusYear: 1891
        ))
        _ = await source.search(query)
        // One repeated key per code, values in dispatcher order.
        #expect(BatchFixtures.count(captured.lastMultiFields, key: "search_query[chapman_codes][]") == 3,
                "a 3-code batch must put THREE repeated chapman_codes[] keys on the wire")
        #expect(BatchFixtures.values(captured.lastMultiFields, key: "search_query[chapman_codes][]") == ["DBY", "LAN", "YKS"],
                "order must be preserved on the wire")
        // No birth-axis filter when only residence codes are batched.
        #expect(BatchFixtures.count(captured.lastMultiFields, key: "search_query[birth_chapman_codes][]") == 0)
    }

    @Test func singleResidenceCodeStaysOneKeyByteIdenticalToPreFT25() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        _ = await source.search(BatchFixtures.fcQuery(params: FreeCenParams(chapmanCode: "DBY", censusYear: 1891)))
        #expect(BatchFixtures.count(captured.lastMultiFields, key: "search_query[chapman_codes][]") == 1,
                "a single code must emit exactly one repeated key (no batch)")
        #expect(BatchFixtures.values(captured.lastMultiFields, key: "search_query[chapman_codes][]") == ["DBY"])
    }

    @Test func batchWinsOverSingleWhenBothSet() async {
        // Defensive: a future caller that sets both must not silently drop
        // the batch. The batch supersedes the scalar.
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = BatchFixtures.fcQuery(params: FreeCenParams(
            chapmanCode: "STS", chapmanCodes: ["DBY", "LAN"], censusYear: 1891
        ))
        _ = await source.search(query)
        #expect(BatchFixtures.values(captured.lastMultiFields, key: "search_query[chapman_codes][]") == ["DBY", "LAN"],
                "a non-empty batch supersedes the scalar residence code")
    }

    @Test func blanksInBatchAreDroppedOnTheWire() async {
        let captured = CapturingHTTPClient()
        let source = FreeCenSource(http: captured)
        let query = BatchFixtures.fcQuery(params: FreeCenParams(
            chapmanCode: nil, chapmanCodes: ["DBY", "", "LAN"], censusYear: 1891
        ))
        _ = await source.search(query)
        #expect(BatchFixtures.values(captured.lastMultiFields, key: "search_query[chapman_codes][]") == ["DBY", "LAN"],
                "a blank code must never become an empty repeated key on the wire")
    }
}

@MainActor
struct FreeREGBatchedEmissionTests {

    @Test func batchedCodesEmitOneRepeatedKeyPerCode() async {
        let captured = CapturingHTTPClient()
        let source = FreeREGSource(http: captured)
        let query = BatchFixtures.frQuery(params: FreeREGParams(chapmanCodes: ["DBY", "LAN"]))
        _ = await source.search(query)
        #expect(BatchFixtures.count(captured.lastMultiFields, key: "search_query[chapman_codes][]") == 2)
        #expect(BatchFixtures.values(captured.lastMultiFields, key: "search_query[chapman_codes][]") == ["DBY", "LAN"])
    }

    @Test func singleCodeStaysOneKey() async {
        let captured = CapturingHTTPClient()
        let source = FreeREGSource(http: captured)
        _ = await source.search(BatchFixtures.frQuery(params: FreeREGParams(chapmanCode: "DBY")))
        #expect(BatchFixtures.values(captured.lastMultiFields, key: "search_query[chapman_codes][]") == ["DBY"])
    }

    @Test func noCodeIsOutsideCoverageWithoutTouchingTheWire() async {
        let captured = CapturingHTTPClient()
        let source = FreeREGSource(http: captured)
        let envelope = await source.searchWithOutcome(BatchFixtures.frQuery(params: FreeREGParams()))
        guard case .outsideCoverage = envelope.result else {
            Issue.record("expected .outsideCoverage, got \(envelope.result)")
            return
        }
        #expect(captured.lastMultiFields == nil && captured.lastFormBody == nil,
                "no POST may fire without a chapman axis")
    }
}

// MARK: - FT-28 dispatcher grouping

@MainActor
struct ChapmanBatchGroupingTests {

    @Test func gateOffEmitsOneCodePerGroup() {
        let codes = (1...25).map { "C\($0)" }
        let fcGroups = SearchDispatcher.freeCenResidenceGroups(codes, batchingEnabled: false, groupSize: 10)
        let frGroups = SearchDispatcher.freeREGChapmanGroups(codes, batchingEnabled: false, groupSize: 10)
        #expect(fcGroups.count == 25, "gate off (default) must preserve the proven one-code-per-query fan-out")
        #expect(fcGroups.allSatisfy { $0.count == 1 })
        #expect(frGroups.count == 25)
        #expect(frGroups.allSatisfy { $0.count == 1 })
    }

    @Test func gateOnChunksIntoConservativeGroups() {
        let codes = (1...25).map { "C\($0)" }
        let groups = SearchDispatcher.freeCenResidenceGroups(codes, batchingEnabled: true, groupSize: 10)
        #expect(groups.count == 3, "25 codes / 10 = 3 groups (10, 10, 5)")
        #expect(groups.map(\.count) == [10, 10, 5])
        // No code is lost or duplicated.
        #expect(groups.flatMap { $0 } == codes)
    }

    @Test func gateOnBelowGroupSizeIsOneGroup() {
        let codes = ["DBY", "LAN", "YKS"]
        let groups = SearchDispatcher.freeREGChapmanGroups(codes, batchingEnabled: true, groupSize: 10)
        #expect(groups == [["DBY", "LAN", "YKS"]], "a fan-out smaller than the group size batches into ONE request")
    }

    @Test func blanksDroppedBeforeGrouping() {
        let groups = SearchDispatcher.freeCenResidenceGroups(["DBY", "", "LAN"], batchingEnabled: true, groupSize: 10)
        #expect(groups == [["DBY", "LAN"]])
        // Gate off drops blanks too — no empty single-element group.
        let off = SearchDispatcher.freeCenResidenceGroups(["", "DBY"], batchingEnabled: false, groupSize: 10)
        #expect(off == [["DBY"]])
    }

    @Test func emptyInputIsNoGroups() {
        #expect(SearchDispatcher.freeCenResidenceGroups([], batchingEnabled: true, groupSize: 10).isEmpty)
        #expect(SearchDispatcher.freeREGChapmanGroups([""], batchingEnabled: true, groupSize: 10).isEmpty)
    }

    @Test func defaultGateIsOffPendingLiveProbe() {
        // The repeated-key idiom is standard Rails but UNVERIFIED against
        // FreeCen/FreeREG's specific forms (audit FT-27). Default OFF flags
        // for a probe rather than enabling blind — the FreeBMD
        // countyQueryEnabled pattern.
        #expect(FreeCenParams.multiCodeBatchEnabled == false)
        #expect(FreeREGParams.multiCodeBatchEnabled == false)
    }
}

// MARK: - Cache-key distinctness for different code sets

@MainActor
struct BatchedCacheKeyTests {

    @Test func batchedSetDiffersFromEachSingleCounty() {
        let single = BatchFixtures.fcQuery(params: FreeCenParams(chapmanCode: "DBY", censusYear: 1891))
        let batched = BatchFixtures.fcQuery(params: FreeCenParams(
            chapmanCode: nil, chapmanCodes: ["DBY", "LAN"], censusYear: 1891
        ))
        let kSingle = QueryCache.cacheKey(sourceID: "freecen", query: single)
        let kBatch = QueryCache.cacheKey(sourceID: "freecen", query: batched)
        #expect(kSingle != kBatch,
                "a batched multi-county query is a different wire request than a single-county one — keys must differ")
    }

    @Test func differentCodeSetsGetDifferentKeys() {
        let batchA = BatchFixtures.fcQuery(params: FreeCenParams(chapmanCodes: ["DBY", "LAN"], censusYear: 1891))
        let batchB = BatchFixtures.fcQuery(params: FreeCenParams(chapmanCodes: ["DBY", "YKS"], censusYear: 1891))
        #expect(QueryCache.cacheKey(sourceID: "freecen", query: batchA)
                != QueryCache.cacheKey(sourceID: "freecen", query: batchB),
                "batches over different county sets are different wire requests")
    }

    @Test func singleCodeKeyUnchangedByFT25() {
        // A lone code (batch nil) must key exactly as it did before FT-25 —
        // the bare code — so historical one-code cache entries never collide
        // with a batch nor miss a legitimate hit. Pin the component form.
        #expect(QueryCache.residenceChapmanKeyComponent(single: "DBY", batch: nil) == "DBY")
        #expect(QueryCache.residenceChapmanKeyComponent(single: "DBY", batch: []) == "DBY",
                "an empty batch falls back to the scalar")
        #expect(QueryCache.residenceChapmanKeyComponent(single: nil, batch: ["DBY", "LAN"]) == "DBY+LAN")
        #expect(QueryCache.residenceChapmanKeyComponent(single: "STS", batch: ["DBY", "LAN"]) == "DBY+LAN",
                "a non-empty batch supersedes the scalar in the key, matching the wire")
    }

    @Test func freeREGBatchedKeyDistinctFromSingle() {
        let single = BatchFixtures.frQuery(params: FreeREGParams(chapmanCode: "DBY"))
        let batched = BatchFixtures.frQuery(params: FreeREGParams(chapmanCodes: ["DBY", "LAN"]))
        #expect(QueryCache.cacheKey(sourceID: "freereg", query: single)
                != QueryCache.cacheKey(sourceID: "freereg", query: batched))
    }

    @Test func batchedQueryIsCacheableAndDistinctlyReserved() async {
        // End-to-end: a batched query and a single-county query must not
        // serve each other's results out of the run cache.
        let cache = QueryCache()
        let singleSource = FreeCenSource(http: FixtureHTTPClient(
            getFixtures: [BatchFixtures.fcFormURL: Data(BatchFixtures.fcCSRF.utf8)],
            postFixtures: [BatchFixtures.fcPostURL: Data("We found 0 Results".utf8)]
        ))
        let batchSource = FreeCenSource(http: FixtureHTTPClient(
            getFixtures: [BatchFixtures.fcFormURL: Data(BatchFixtures.fcCSRF.utf8)],
            postFixtures: [BatchFixtures.fcPostURL: Data(BatchFixtures.fcBatchedResults.utf8)]
        ))
        let singleQuery = BatchFixtures.fcQuery(params: FreeCenParams(chapmanCode: "DBY", censusYear: 1891))
        let batchQuery = BatchFixtures.fcQuery(params: FreeCenParams(chapmanCodes: ["DBY", "LAN", "YKS"], censusYear: 1891))
        let singleRecords = await QueryCache.wrappedSearch(source: singleSource, query: singleQuery, cache: cache)
        let batchRecords = await QueryCache.wrappedSearch(source: batchSource, query: batchQuery, cache: cache)
        #expect(singleRecords.isEmpty, "single-county query saw its own (empty) response")
        #expect(batchRecords.count == 3, "batched query saw its own 3-county response, not the cached single-county empty")
    }
}

// MARK: - Geography-scoring survives a batched response

@MainActor
struct BatchedGeographyTests {

    @Test func eachRowCarriesItsOwnCountyRegardlessOfHowRequested() async {
        // The whole point of the correctness constraint: batching counties
        // into ONE request must not smear geography — every parsed row still
        // carries its own census county/place from its own table cells.
        let http = FixtureHTTPClient(
            getFixtures: [BatchFixtures.fcFormURL: Data(BatchFixtures.fcCSRF.utf8)],
            postFixtures: [BatchFixtures.fcPostURL: Data(BatchFixtures.fcBatchedResults.utf8)]
        )
        let source = FreeCenSource(http: http)
        let query = BatchFixtures.fcQuery(params: FreeCenParams(chapmanCodes: ["DBY", "LAN", "YKS"], censusYear: 1891))
        let envelope = await source.searchWithOutcome(query)
        guard case .results(let records) = envelope.result else {
            Issue.record("expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 3)
        // Pull the per-row census county from rawFields — the field the
        // geography gate scores against.
        let counties = records.compactMap { record -> String? in
            guard case .census(let c) = record else { return nil }
            return c.common.rawFields["census_county"]
        }
        #expect(Set(counties) == ["Derbyshire", "Lancashire", "Yorkshire"],
                "batched rows keep their own distinct counties; geography scoring is unaffected")
    }

    @Test func freeREGBatchedRowsKeepOwnCounty() async {
        let http = FixtureHTTPClient(
            getFixtures: [BatchFixtures.frFormURL: Data(BatchFixtures.frCSRF.utf8)],
            postFixtures: [BatchFixtures.frPostURL: Data(BatchFixtures.frBatchedResults.utf8)]
        )
        let source = FreeREGSource(http: http)
        let query = BatchFixtures.frQuery(params: FreeREGParams(chapmanCodes: ["DBY", "LAN"]))
        let envelope = await source.searchWithOutcome(query)
        guard case .results(let records) = envelope.result else {
            Issue.record("expected .results, got \(envelope.result)")
            return
        }
        let counties = records.compactMap { record -> String? in
            guard case .parish(let p) = record else { return nil }
            return p.county
        }
        #expect(Set(counties) == ["Derbyshire", "Lancashire"])
    }
}

// MARK: - Truncation-honesty on a batched query

@MainActor
struct BatchedTruncationHonestyTests {

    @Test func batchedResponseClaimingMoreHitsIsTruncated() async {
        // Wider (batched) queries make first-page truncation more likely —
        // FT-22/FT-23's honesty envelope must still fire on a batched query:
        // 40 claimed, 2 parsed, no next page → truncated, not conclusive.
        let http = FixtureHTTPClient(
            getFixtures: [BatchFixtures.fcFormURL: Data(BatchFixtures.fcCSRF.utf8)],
            postFixtures: [BatchFixtures.fcPostURL: Data(BatchFixtures.fcBatchedTruncated.utf8)]
        )
        let source = FreeCenSource(http: http)
        let query = BatchFixtures.fcQuery(params: FreeCenParams(chapmanCodes: ["DBY", "LAN", "YKS"], censusYear: 1891))
        let envelope = await source.searchWithOutcome(query)
        guard case .results(let records) = envelope.result else {
            Issue.record("expected .results, got \(envelope.result)")
            return
        }
        #expect(records.count == 2)
        #expect(envelope.outcome.totalAvailable == 40)
        #expect(envelope.outcome.truncated == true, "a batched query returning fewer rows than claimed must flag truncation")
        #expect(!envelope.outcome.isConclusive, "a truncated batched answer must not count as a complete search")
        #expect(!envelope.outcome.isCleanNegative)
    }

    @Test func completeBatchedResponseIsConclusive() async {
        let http = FixtureHTTPClient(
            getFixtures: [BatchFixtures.fcFormURL: Data(BatchFixtures.fcCSRF.utf8)],
            postFixtures: [BatchFixtures.fcPostURL: Data(BatchFixtures.fcBatchedResults.utf8)]
        )
        let source = FreeCenSource(http: http)
        let query = BatchFixtures.fcQuery(params: FreeCenParams(chapmanCodes: ["DBY", "LAN", "YKS"], censusYear: 1891))
        let envelope = await source.searchWithOutcome(query)
        #expect(envelope.outcome.totalAvailable == 3)
        #expect(envelope.outcome.truncated == false)
        #expect(envelope.outcome.isConclusive, "3 claimed, 3 parsed → the batched answer is complete")
    }
}
