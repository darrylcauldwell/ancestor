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

    @Test func freeBMDCountyIDComesFromCapturedLiveFormTable() {
        // FT-01 — the countyid vocabulary is the live form's own option
        // values (captured 2026-07-10), NOT the district-select IDs.
        // The 2026-07-11 probe proved a reconstructed value returns a
        // valid-but-empty result. Pin the captured DBY value verbatim.
        #expect(RegionConfig.freeBMDCountyID(forChapmanCode: "DBY")
                == "DBY,47,77,78,91,113,136,137,149,172,173")
        #expect(RegionConfig.freeBMDCountyID(forChapmanCode: "dby ")
                == "DBY,47,77,78,91,113,136,137,149,172,173",
                "lookup must normalise case/whitespace")
        #expect(RegionConfig.freeBMDCountyID(forChapmanCode: "ZZZ") == nil)
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
        // FT-09: umbrella neighbours (YKS) expand to their ridings and the
        // set is deduped by countyid, so the expected count is the number
        // of DISTINCT countyid values across home + expanded neighbours.
        let axes = SearchDispatcher.freeBMDGeoAxes(
            scope: .adjacent, homeChapmanCode: "DBY", countyQueriesEnabled: true
        )
        var expectedIDs: Set<String> = []
        for code in ["DBY"] + RegionConfig.adjacentCounties("DBY") {
            expectedIDs.formUnion(RegionConfig.freeBMDCountyIDs(forChapmanCode: code))
        }
        #expect(expectedIDs.count >= 2, "DBY must have at least one resolvable neighbour")
        #expect(axes.count == expectedIDs.count)
        #expect(Set(axes.compactMap { $0.countyCode }) == expectedIDs)
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
    @Test func dispatcherCountyScopeDefaultsToCountyQuery() {
        // FT-01 gate is ON (probe-validated 2026-07-11) — the default
        // .county path is now ONE county-level query carrying the
        // captured live-form countyid value.
        let dispatcher = SearchDispatcher(registry: SourceRegistry(defaults: .ephemeralSuite()))
        let queries = dispatcher.buildQueriesForTest(
            source: FreeBMDSource(), subject: Self.makeSubject(),
            recordType: .birth, scope: .county
        )
        #expect(queries.count == 1)
        guard case .freeBMD(let p) = queries.first?.sourceParams else {
            Issue.record("expected .freeBMD params"); return
        }
        #expect(p.countyCode == RegionConfig.freeBMDCountyID(forChapmanCode: "DBY"))
        #expect(p.districtCode == nil, "county query must not also carry a district")
    }

    @MainActor
    @Test func dispatcherCountyScopeWithGateOffUsesDistrictLoop() {
        // The pre-FT-01 per-district path stays available behind the flag
        // (surgical fallback if the live form's vocabulary drifts).
        // FT-09: the loop is now era-filtered — for an 1880 subject the
        // post-1974/1994/1997 composite districts (High Peak, Ilkeston,
        // Amber Valley, South Derbyshire) can't hold a match and are
        // dropped, so the count is the year-valid subset, not the full 12.
        let dispatcher = SearchDispatcher(registry: SourceRegistry(defaults: .ephemeralSuite()))
        let queries = dispatcher.buildQueriesForTest(
            source: FreeBMDSource(), subject: Self.makeSubject(),
            recordType: .birth, scope: .county,
            freeBMDCountyQueriesEnabled: false
        )
        let allCodes = Array(RegionConfig.districts(forChapmanCode: "DBY").values)
        // For a .birth window the dispatcher pads ±2 → ~1878–1882.
        let expectedCodes = SearchDispatcher.eraFilterDistrictCodes(
            allCodes, yearFrom: 1878, yearTo: 1882
        )
        #expect(queries.count == expectedCodes.count)
        #expect(expectedCodes.count < allCodes.count,
                "era filter must drop at least one post-1974 composite for an 1880 subject")
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
        let dispatcher = SearchDispatcher(registry: SourceRegistry(defaults: .ephemeralSuite()))
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
        let dispatcher = SearchDispatcher(registry: SourceRegistry(defaults: .ephemeralSuite()))
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
        let dispatcher = SearchDispatcher(registry: SourceRegistry(defaults: .ephemeralSuite()))
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

    // MARK: - FT-03 — vol/pgno page-lookup wire emission

    @MainActor
    @Test func sourceSendsVolAndPgnoWhenBothSet() async {
        // FT-03 — a same-page page-lookup transmits the GRO reference pair
        // so FreeBMD returns the couple registered on that page.
        let captured = CapturingHTTPClient()
        let source = FreeBMDSource(http: captured)
        let query = RecordQuery(
            surname: "", givenName: nil, recordType: .marriage,
            yearFrom: 1901, yearTo: 1901, gender: nil, region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: nil, countyCode: nil, wildcardSurname: false,
                volume: "7b", page: "1397"
            )),
            strictness: .strict
        )
        _ = await source.search(query)
        let body = captured.lastFormBody ?? ""
        #expect(body.contains("vol=7b"),
                "page-lookup must transmit the volume; body was \(body)")
        #expect(body.contains("pgno=1397"),
                "page-lookup must transmit the page; body was \(body)")
    }

    @MainActor
    @Test func sourceOmitsVolPgnoWhenEitherMissing() async {
        // A lone vol or page is not a usable page key — the pair is emitted
        // only when BOTH are present (mirrors the FT-06 presence caution).
        for params in [
            FreeBMDParams(wildcardSurname: false, volume: "7b", page: nil),
            FreeBMDParams(wildcardSurname: false, volume: nil, page: "1397"),
            FreeBMDParams(wildcardSurname: false, volume: "", page: "1397"),
        ] {
            let captured = CapturingHTTPClient()
            let source = FreeBMDSource(http: captured)
            let query = RecordQuery(
                surname: "Smith", givenName: nil, recordType: .marriage,
                yearFrom: 1901, yearTo: 1901, gender: nil, region: nil,
                sourceParams: .freeBMD(params), strictness: .strict
            )
            _ = await source.search(query)
            let body = captured.lastFormBody ?? ""
            #expect(!body.contains("vol=") && !body.contains("pgno="),
                    "vol/pgno must be omitted unless both are non-empty; body was \(body)")
        }
    }

    @Test func cacheKeySeparatesPageLookupFromOrdinaryQuery() {
        // FT-03 — the vol/pgno pair is wire-affecting, so a page-lookup and
        // an ordinary surname query for the same subject/year must not
        // collide on one cache entry (FT-24 rule).
        func query(volume: String?, page: String?) -> RecordQuery {
            RecordQuery(
                surname: "Cauldwell", givenName: nil, recordType: .marriage,
                yearFrom: 1901, yearTo: 1901, gender: nil, region: nil,
                sourceParams: .freeBMD(FreeBMDParams(
                    districtCode: nil, countyCode: nil, wildcardSurname: false,
                    volume: volume, page: page
                )),
                strictness: .strict
            )
        }
        let ordinary = QueryCache.cacheKey(sourceID: "freebmd", query: query(volume: nil, page: nil))
        let pageLookup = QueryCache.cacheKey(sourceID: "freebmd", query: query(volume: "7b", page: "1397"))
        let otherPage = QueryCache.cacheKey(sourceID: "freebmd", query: query(volume: "7b", page: "1398"))
        #expect(ordinary != pageLookup, "page-lookup must key distinctly from an ordinary query")
        #expect(pageLookup != otherPage, "different pages must key distinctly")
        // A lone value (not a valid page key) keys identically to none —
        // no cache regression on historical non-page queries.
        let loneVol = QueryCache.cacheKey(sourceID: "freebmd", query: query(volume: "7b", page: nil))
        #expect(loneVol == ordinary, "a lone vol must not perturb the key")
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
