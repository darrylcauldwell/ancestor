import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the FreeBMD query-shape contract that was silently broken until
/// 2026-05-20. Two bugs, two pins:
///   1. Multi-word given names (e.g. "Ernest Victor") need stripping to
///      the first token — FreeBMD's `given` field is first-given-only.
///   2. The year range only engages when `sq` (start quarter) and `eq`
///      (end quarter) are also sent — without them FreeBMD silently
///      ignores `start`/`end` and widens to all years.
struct FreeBMDQueryShapeTests {

    // MARK: - firstGivenName

    @Test func firstGivenNameStripsMultiWord() {
        #expect(FreeBMDSource.firstGivenName("Ernest Victor") == "Ernest")
        #expect(FreeBMDSource.firstGivenName("Ernest Victor James") == "Ernest")
    }

    @Test func firstGivenNamePassesSingleWordThrough() {
        #expect(FreeBMDSource.firstGivenName("Ernest") == "Ernest")
        #expect(FreeBMDSource.firstGivenName("Mary-Ann") == "Mary-Ann")
    }

    @Test func firstGivenNameHandlesNilAndEmpty() {
        #expect(FreeBMDSource.firstGivenName(nil) == nil)
        #expect(FreeBMDSource.firstGivenName("") == nil)
        #expect(FreeBMDSource.firstGivenName("   ") == nil)
    }

    @Test func firstGivenNameTrimsLeadingWhitespace() {
        #expect(FreeBMDSource.firstGivenName("  Ernest  ") == "Ernest")
        #expect(FreeBMDSource.firstGivenName(" Ernest Victor") == "Ernest")
    }

    // MARK: - FT-01 — countyid wire value (RegionConfig.freeBMDCountyID)

    @Test func freeBMDCountyIDBuildsCompoundChapmanPlusDistrictIDs() {
        let value = RegionConfig.freeBMDCountyID(forChapmanCode: "DBY")
        #expect(value?.hasPrefix("DBY,") == true,
                "countyid value must lead with the Chapman code; got \(value ?? "nil")")
        let parts = (value ?? "").split(separator: ",").map(String.init)
        // Chapman code + one ID per configured district — the SAME set the
        // per-district loop dispatches today, collapsed into one value.
        #expect(parts.count == 1 + RegionConfig.districts(forChapmanCode: "DBY").count)
        #expect(parts.dropFirst().contains("722"), "Belper's verified code must be present")
        // Deterministic numeric ordering (stable wire value + cache key).
        let ids = parts.dropFirst().compactMap { Int($0) }
        #expect(ids.count == parts.count - 1)
        #expect(ids == ids.sorted())
    }

    @Test func freeBMDCountyIDIsCaseInsensitiveOnInput() {
        #expect(RegionConfig.freeBMDCountyID(forChapmanCode: "dby")
                == RegionConfig.freeBMDCountyID(forChapmanCode: "DBY"))
    }

    @Test func freeBMDCountyIDUnknownOrEmptyChapmanIsNil() {
        // Parity with the district loop: no district knowledge → no query.
        #expect(RegionConfig.freeBMDCountyID(forChapmanCode: "") == nil)
        #expect(RegionConfig.freeBMDCountyID(forChapmanCode: "   ") == nil)
        #expect(RegionConfig.freeBMDCountyID(forChapmanCode: "ZZZ") == nil)
    }

    // MARK: - FT-01 / FT-02 — geographic fan-out axes (SearchDispatcher.freeBMDGeoAxes)

    @Test func geoAxesNationalIsOneAllDistrictsQueryRegardlessOfGate() {
        // FT-02 — the headline fix: .national was 632–996 per-district
        // requests, now exactly ONE districtid="" query. Not behind the
        // FT-01 gate (districtid="" is Python-proven wire behaviour).
        for gate in [false, true] {
            let axes = SearchDispatcher.freeBMDGeoAxes(
                scope: .national, homeChapmanCode: "DBY", countyQueriesEnabled: gate
            )
            #expect(axes.count == 1, "national must be a single query (gate=\(gate)); got \(axes.count)")
            #expect(axes.first?.districtCode == nil)
            #expect(axes.first?.countyCode == nil)
        }
    }

    @Test func geoAxesParishIsEmptyRegardlessOfGate() {
        for gate in [false, true] {
            let axes = SearchDispatcher.freeBMDGeoAxes(
                scope: .parish, homeChapmanCode: "DBY", countyQueriesEnabled: gate
            )
            #expect(axes.isEmpty)
        }
    }

    @Test func geoAxesCountyGateOffKeepsPerDistrictLoop() {
        // The safe default (FT-01 gate off): unchanged pre-audit fan-out.
        let axes = SearchDispatcher.freeBMDGeoAxes(
            scope: .county, homeChapmanCode: "DBY", countyQueriesEnabled: false
        )
        #expect(axes.count == RegionConfig.districts(forChapmanCode: "DBY").count)
        #expect(axes.allSatisfy { $0.countyCode == nil })
        #expect(axes.allSatisfy { ($0.districtCode ?? "").isEmpty == false })
    }

    @Test func geoAxesCountyGateOnEmitsSingleCountyAxis() {
        let axes = SearchDispatcher.freeBMDGeoAxes(
            scope: .county, homeChapmanCode: "DBY", countyQueriesEnabled: true
        )
        #expect(axes.count == 1)
        #expect(axes.first?.districtCode == nil)
        #expect(axes.first?.countyCode == RegionConfig.freeBMDCountyID(forChapmanCode: "DBY"))
    }

    @Test func geoAxesAdjacentGateOnAddsNeighbourCounties() {
        // With county-level queries available, .adjacent stops degrading
        // to home-county-only: one axis per home + neighbour county.
        let axes = SearchDispatcher.freeBMDGeoAxes(
            scope: .adjacent, homeChapmanCode: "DBY", countyQueriesEnabled: true
        )
        let expected = 1 + RegionConfig.adjacentCounties("DBY")
            .compactMap { RegionConfig.freeBMDCountyID(forChapmanCode: $0) }
            .count
        #expect(expected >= 2, "DBY must have at least one resolvable neighbour")
        #expect(axes.count == expected)
        #expect(axes.allSatisfy { $0.districtCode == nil })
        #expect(axes.first?.countyCode == RegionConfig.freeBMDCountyID(forChapmanCode: "DBY"))
    }

    @Test func geoAxesAdjacentGateOffKeepsHomeCountyDistrictLoop() {
        // Gate off preserves the documented honest degradation:
        // .adjacent == .county == home-county district loop.
        let adjacent = SearchDispatcher.freeBMDGeoAxes(
            scope: .adjacent, homeChapmanCode: "DBY", countyQueriesEnabled: false
        )
        let county = SearchDispatcher.freeBMDGeoAxes(
            scope: .county, homeChapmanCode: "DBY", countyQueriesEnabled: false
        )
        #expect(Set(adjacent.compactMap { $0.districtCode }) == Set(county.compactMap { $0.districtCode }))
    }

    @Test func geoAxesUnknownChapmanGateOnEmitsNothing() {
        // Parity with the district loop's zero-query degradation.
        let axes = SearchDispatcher.freeBMDGeoAxes(
            scope: .county, homeChapmanCode: "", countyQueriesEnabled: true
        )
        #expect(axes.isEmpty)
    }

    // MARK: - FT-01 / FT-02 — dispatcher query emission (buildQueriesForTest)

    @MainActor
    @Test func dispatcherCountyScopeDefaultsToDistrictLoop() {
        // FT-01 gate defaults OFF — the dispatcher's real (non-overridden)
        // path must still be the per-district loop with no county axis.
        let dispatcher = SearchDispatcher(registry: SourceRegistry())
        let queries = dispatcher.buildQueriesForTest(
            source: FreeBMDSource(), subject: Self.makeSubject(),
            recordType: .birth, scope: .county
        )
        #expect(queries.count == RegionConfig.districts(forChapmanCode: "DBY").count)
        for q in queries {
            guard case .freeBMD(let p) = q.sourceParams else {
                Issue.record("expected .freeBMD params")
                continue
            }
            #expect(p.countyCode == nil, "gate off must never emit a county axis")
            #expect(!(p.districtCode ?? "").isEmpty)
        }
    }

    @MainActor
    @Test func dispatcherCountyScopeGateOnEmitsOneCountyQuery() {
        let dispatcher = SearchDispatcher(registry: SourceRegistry())
        let queries = dispatcher.buildQueriesForTest(
            source: FreeBMDSource(), subject: Self.makeSubject(),
            recordType: .birth, scope: .county,
            freeBMDCountyQueriesEnabled: true
        )
        #expect(queries.count == 1, "county scope must collapse to one county-level query; got \(queries.count)")
        guard case .freeBMD(let p) = queries.first?.sourceParams else {
            Issue.record("expected .freeBMD params")
            return
        }
        #expect(p.districtCode == nil)
        #expect(p.countyCode == RegionConfig.freeBMDCountyID(forChapmanCode: "DBY"))
    }

    @MainActor
    @Test func dispatcherNationalScopeEmitsExactlyOneQuery() {
        // FT-02 at the dispatcher level: one query, both geo axes empty
        // (→ districtid="" on the wire), instead of one per catalogue
        // district (632 for a birth ±2 window).
        let dispatcher = SearchDispatcher(registry: SourceRegistry())
        let queries = dispatcher.buildQueriesForTest(
            source: FreeBMDSource(), subject: Self.makeSubject(),
            recordType: .birth, scope: .national
        )
        #expect(queries.count == 1, "national scope must be a single all-districts query; got \(queries.count)")
        guard case .freeBMD(let p) = queries.first?.sourceParams else {
            Issue.record("expected .freeBMD params")
            return
        }
        #expect(p.districtCode == nil)
        #expect(p.countyCode == nil)
    }

    @MainActor
    @Test func dispatcherNationalMarriageKeepsSpouseSurnameFanOut() {
        // The surname/spouse-surname multiplication survives the geo
        // collapse — an inverted-wife subject still probes both recorded
        // and maiden spouse surnames, just once each instead of once per
        // district.
        let dispatcher = SearchDispatcher(registry: SourceRegistry())
        let queries = dispatcher.buildQueriesForTest(
            source: FreeBMDSource(), subject: Self.makeSubjectWithInvertedWife(),
            recordType: .marriage, scope: .national
        )
        #expect(queries.count == 2, "expected one query per spouse surname; got \(queries.count)")
        let spouseSurnames = Set(queries.compactMap { q -> String? in
            if case .freeBMD(let p) = q.sourceParams { return p.spouseSurname }
            return nil
        })
        #expect(spouseSurnames == ["Cauldwell", "Ward"])
    }

    // MARK: - FT-01 — focused queries stay per-district (cache-key separation)

    @Test func cacheKeySeparatesCountyLevelFromNationalQueries() {
        // Wire-affecting params must reach the cache key (FT-24 rule):
        // a county-level query and a national query differ only in
        // countyCode — colliding keys would launder one into the other.
        func query(countyCode: String?) -> RecordQuery {
            RecordQuery(
                surname: "Cauldwell", givenName: "Robert", recordType: .birth,
                yearFrom: 1880, yearTo: 1882, gender: .male, region: nil,
                sourceParams: .freeBMD(FreeBMDParams(
                    districtCode: nil, countyCode: countyCode, wildcardSurname: false
                )),
                strictness: .strict
            )
        }
        let national = QueryCache.cacheKey(sourceID: "freebmd", query: query(countyCode: nil))
        let county = QueryCache.cacheKey(sourceID: "freebmd", query: query(countyCode: "DBY,722"))
        #expect(national != county)
    }

    // MARK: - FT-01 — source-side countyid emission

    @MainActor
    @Test func sourceSendsCountyIDFieldWhenCountyCodeSet() async {
        let captured = CapturingHTTPClient()
        let source = FreeBMDSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "John", recordType: .birth,
            yearFrom: 1880, yearTo: 1882, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: nil,
                countyCode: "DBY,406,418,722",
                wildcardSurname: false
            )),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("countyid=DBY,406,418,722"),
                "county-level query must transmit the compound countyid value; body was \(body)")
        #expect(body.contains("districtid=&") || body.hasSuffix("districtid="),
                "county-level query must leave districtid empty; body was \(body)")
    }

    @MainActor
    @Test func sourceOmitsCountyIDFieldEntirelyWhenAbsent() async {
        // FT-06 lesson: never transmit a field we aren't using — Perl CGI
        // presence semantics can read an empty field as "checked".
        let captured = CapturingHTTPClient()
        let source = FreeBMDSource(http: captured)
        let query = RecordQuery(
            surname: "Smith", givenName: "John", recordType: .birth,
            yearFrom: 1880, yearTo: 1882, gender: .male, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: "722",
                wildcardSurname: false
            )),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(!body.contains("countyid"),
                "countyid must be omitted (not sent empty) on district/national queries; body was \(body)")
    }

    // MARK: - FT-02 × FT-05/FT-23 — overflow, adaptive split, truncation honesty
    //
    // County-level and national queries return more rows per request, so
    // the too-many-results interstitial fires more often. These pin that
    // (a) the adaptive year-split recovers records while preserving the
    // geo axis on every sub-request, and (b) unrecoverable overflow
    // surfaces as a truncated envelope — never a silent empty.

    @MainActor
    @Test func countyLevelOverflowSplitsAndAggregatesAcrossHalves() async {
        let http = SequencedFormHTTPClient(responses: [
            Self.overflowPage(),
            Self.resultsPage(page: "101"),
            Self.resultsPage(page: "202"),
        ])
        let source = FreeBMDSource(http: http)
        let envelope = await source.searchWithOutcome(Self.overflowQuery(
            countyCode: "DBY,418,722", yearFrom: 1880, yearTo: 1883
        ))
        #expect(envelope.result.records.count == 2,
                "records from both split halves must aggregate; got \(envelope.result.records.count)")
        #expect(envelope.outcome.truncated == false,
                "a fully recovered overflow is not a truncated answer")
        let posts = http.postedFields
        #expect(posts.count == 3, "expected 1 overflow + 2 half-window fetches; got \(posts.count)")
        #expect(posts.allSatisfy { $0["countyid"] == "DBY,418,722" },
                "every split sub-request must keep the county axis")
        let windows = Set(posts.map { "\($0["start"] ?? "?")-\($0["end"] ?? "?")" })
        #expect(windows == ["1880-1883", "1880-1881", "1882-1883"])
    }

    @MainActor
    @Test func unsplittableOverflowSurfacesTruncationWithClaimedTotal() async {
        // Single-year window — the split guard can't halve it; the
        // envelope must carry the interstitial's own entry count.
        let http = SequencedFormHTTPClient(responses: [Self.overflowPage()])
        let source = FreeBMDSource(http: http)
        let envelope = await source.searchWithOutcome(Self.overflowQuery(
            countyCode: "DBY,418,722", yearFrom: 1880, yearTo: 1880
        ))
        #expect(envelope.result.records.isEmpty)
        #expect(envelope.outcome.truncated == true,
                "unsplittable overflow must read as truncation, not a clean empty")
        #expect(envelope.outcome.totalAvailable == 12345)
        #expect(!envelope.outcome.isConclusive)
        #expect(!envelope.outcome.isCleanNegative)
    }

    @MainActor
    @Test func overflowInEverySplitHalfPropagatesTruncationUpward() async {
        // Every window overflows (script repeats the interstitial): the
        // split runs its course, both halves come back truncated, and the
        // combined envelope stays truncated with no misleading aggregate
        // count (per-window claimed totals don't sum meaningfully).
        let http = SequencedFormHTTPClient(responses: [Self.overflowPage()])
        let source = FreeBMDSource(http: http)
        let envelope = await source.searchWithOutcome(Self.overflowQuery(
            countyCode: "DBY,418,722", yearFrom: 1880, yearTo: 1883
        ))
        #expect(envelope.result.records.isEmpty)
        #expect(envelope.outcome.truncated == true)
        #expect(envelope.outcome.totalAvailable == nil,
                "combined split halves must not carry a per-window claimed total")
        #expect(http.postedFields.count == 3,
                "1880–1883 splits once into two single-pair windows; got \(http.postedFields.count) requests")
    }

    // MARK: - Helpers

    private static func makeSubject() -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: "Cauldwell", givenName: "Robert",
            birthYearFrom: 1880, birthYearTo: 1880,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
    }

    private static func makeSubjectWithInvertedWife() -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: "Cauldwell", givenName: "Ernest",
            birthYearFrom: 1887, birthYearTo: 1887,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil,
            mode: .extend,
            familyContext: FamilyContext(
                spouseName: "Sarah Cauldwell",
                spouseSurname: "Cauldwell",
                spouseGivenName: "Sarah",
                spouseFatherSurname: "Ward",
                childNames: [],
                fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                motherName: nil, motherSurname: nil, motherGivenName: nil
            ),
            homeChapmanCode: "DBY"
        )
    }

    private static func overflowQuery(countyCode: String, yearFrom: Int, yearTo: Int) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: nil, recordType: .birth,
            yearFrom: yearFrom, yearTo: yearTo, gender: nil, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: nil, countyCode: countyCode, wildcardSurname: false
            )),
            strictness: .strict
        )
    }

    /// FreeBMD's too-many-results interstitial shape: no `searchData`
    /// array, >80KB payload, and the site's own entry count in prose.
    private static func overflowPage() -> String {
        "<html><body>Your search returned 12,345 entries."
            + String(repeating: "<!-- interstitial padding -->", count: 4000)
            + "</body></html>"
    }

    /// Minimal single-record results page; `page` varies the row so
    /// records from different split halves get distinct IDs.
    private static func resultsPage(page: String) -> String {
        """
        <html><script>
        var searchData = new Array (
          " ;0;2;1880",
          "41;Cauldwell;Robert;;0;Belper;7b;\(page);9371\(page):1036"
        );
        </script></html>
        """
    }
}

/// Test-only HTTP client that returns a scripted sequence of POST
/// responses (one per `postForm` call, repeating the last when the
/// script runs out) and records every call's form fields. GETs return
/// a minimal page so FreeBMD session establishment proceeds without
/// tokens.
final class SequencedFormHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var _postedFields: [[String: String]] = []

    var postedFields: [[String: String]] { lock.withLock { _postedFields } }

    init(responses: [String]) {
        self.responses = responses
    }

    func get(url: URL, headers: [String: String]) async throws -> Data {
        Data("<html><form></form></html>".utf8)
    }

    func postForm(url: URL, fields: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        let body: String = lock.withLock {
            _postedFields.append(fields)
            guard !responses.isEmpty else { return "" }
            return responses.count == 1 ? responses[0] : responses.removeFirst()
        }
        return Data(body.utf8)
    }
}
