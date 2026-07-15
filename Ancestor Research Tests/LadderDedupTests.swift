import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-03 (CONNECTOR_AUDIT_2026-07.md §6.1): the strictness
/// ladder re-fires WIRE-IDENTICAL queries at `.loose`/`.variant` for sources
/// whose outbound request doesn't vary by strictness (FindAGrave, Probate,
/// Wirksworth). They read `query.strictness` only to label activity-bus
/// events; the HTTP request is byte-identical across tiers.
///
/// The task's question: was T1-03 already incidentally covered by the
/// per-run QueryCache? Answer — NO. `QueryCache.cacheKey` included
/// `query.strictness.rawValue`, so `.strict` and `.loose` for the same
/// wire request produced DIFFERENT keys → a cache MISS on the second tier
/// → a duplicate HTTP call. These tests both prove that was the case
/// (the fix is load-bearing) and lock in the fix: `normalizedWireStrictness`
/// collapses wire-invariant sources' tiers to one canonical value, so the
/// wire-identical re-fire is now a cache HIT — one HTTP call, not N.
struct LadderDedupTests {

    // MARK: - The fix: wire-invariant sources share one key across tiers

    @Test func probateStrictAndLooseShareOneCacheKey() {
        let strict = QueryCache.cacheKey(sourceID: "probate", query: probateQuery(strictness: .strict))
        let loose = QueryCache.cacheKey(sourceID: "probate", query: probateQuery(strictness: .loose))
        #expect(strict == loose,
                "Probate ignores strictness on the wire — its tiers must share one cache key")
    }

    @Test func probateStrictLooseVariantAllShareOneKey() {
        let keys = Set([SearchStrictness.strict, .loose, .variant].map {
            QueryCache.cacheKey(sourceID: "probate", query: probateQuery(strictness: $0))
        })
        #expect(keys.count == 1,
                "all three Probate ladder tiers are one wire request; got \(keys.count) distinct key(s)")
    }

    @Test func findAGraveStrictAndLooseShareOneCacheKey() {
        let strict = QueryCache.cacheKey(sourceID: "findagrave", query: fagQuery(strictness: .strict))
        let loose = QueryCache.cacheKey(sourceID: "findagrave", query: fagQuery(strictness: .loose))
        #expect(strict == loose,
                "FindAGrave ignores strictness on the wire — its tiers must share one cache key")
    }

    // MARK: - The proof: .strict then .loose = ONE HTTP call (Probate)

    @Test func probateLadderReFireIsCacheHitNotSecondRequest() async {
        // The T1-03 headline: a Probate query issued at .strict then .loose
        // (the .extend ladder for a wire-invariant source) must hit the
        // per-run cache the second time — one HTTP call, not two.
        let cache = QueryCache()
        let source = CountingWireSource(sourceID: "probate")
        _ = await QueryCache.wrappedSearch(source: source, query: probateQuery(strictness: .strict), cache: cache)
        _ = await QueryCache.wrappedSearch(source: source, query: probateQuery(strictness: .loose), cache: cache)
        let calls = await source.searchCount
        #expect(calls == 1,
                "Probate .strict then .loose must be one HTTP call (T1-03); got \(calls)")
        let stats = await cache.stats()
        #expect(stats.hits == 1 && stats.misses == 1,
                "expected 1 hit / 1 miss for the wire-identical re-fire; got \(stats)")
    }

    @Test func findAGraveLadderReFireIsCacheHitNotSecondRequest() async {
        let cache = QueryCache()
        let source = CountingWireSource(sourceID: "findagrave")
        _ = await QueryCache.wrappedSearch(source: source, query: fagQuery(strictness: .strict), cache: cache)
        _ = await QueryCache.wrappedSearch(source: source, query: fagQuery(strictness: .loose), cache: cache)
        let calls = await source.searchCount
        #expect(calls == 1,
                "FindAGrave .strict then .loose must be one HTTP call (T1-03); got \(calls)")
    }

    // MARK: - Guard: sources that DO vary by strictness keep distinct tiers

    @Test func freeBMDStrictAndLooseRemainDistinctKeys() {
        // FreeBMD adds sndx=on on .loose — a genuine wire
        // difference. Normalization must NOT collapse it, or a phonetic
        // search would be served the exact-match cache entry.
        let strict = QueryCache.cacheKey(sourceID: "freebmd", query: freeBMDQuery(strictness: .strict))
        let loose = QueryCache.cacheKey(sourceID: "freebmd", query: freeBMDQuery(strictness: .loose))
        #expect(strict != loose,
                "FreeBMD's sndx field differs by strictness — tiers must stay distinct")
    }

    @Test func cwgcStrictAndLooseRemainDistinctKeys() {
        // CWGC drops Tab=exact off .strict — a genuine wire difference.
        let strict = QueryCache.cacheKey(sourceID: "cwgc", query: cwgcQuery(strictness: .strict))
        let loose = QueryCache.cacheKey(sourceID: "cwgc", query: cwgcQuery(strictness: .loose))
        #expect(strict != loose,
                "CWGC's Tab=exact differs by strictness — tiers must stay distinct")
    }

    @Test func freeCenStrictAndLooseRemainDistinctKeys() {
        // FreeCen flips a soundex flag on .loose.
        let strict = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery(strictness: .strict))
        let loose = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery(strictness: .loose))
        #expect(strict != loose)
    }

    @Test func freeREGStrictAndLooseRemainDistinctKeys() {
        let strict = QueryCache.cacheKey(sourceID: "freereg", query: freeREGQuery(strictness: .strict))
        let loose = QueryCache.cacheKey(sourceID: "freereg", query: freeREGQuery(strictness: .loose))
        #expect(strict != loose)
    }

    @Test func familySearchStrictAndLooseRemainDistinctKeys() {
        // FamilySearch changes its surname wildcard by strictness.
        let strict = QueryCache.cacheKey(sourceID: "familysearch", query: fsQuery(strictness: .strict))
        let loose = QueryCache.cacheKey(sourceID: "familysearch", query: fsQuery(strictness: .loose))
        #expect(strict != loose)
    }

    // MARK: - Helpers

    private func probateQuery(strictness: SearchStrictness) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Ernest", recordType: .probate,
            yearFrom: 1918, yearTo: 1922, gender: .male, region: .englandAndWales,
            sourceParams: .probate(ProbateParams()), strictness: strictness
        )
    }

    private func fagQuery(strictness: SearchStrictness) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Ernest", recordType: .burial,
            yearFrom: 1914, yearTo: 1918, gender: .male, region: .englandAndWales,
            sourceParams: .findAGrave(FindAGraveParams(yearRangeWidth: 5, location: "Belper")),
            strictness: strictness
        )
    }

    private func freeBMDQuery(strictness: SearchStrictness) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Ernest", recordType: .birth,
            yearFrom: 1880, yearTo: 1882, gender: .male, region: .englandAndWales,
            sourceParams: .freeBMD(FreeBMDParams(districtCode: "722", wildcardSurname: false)),
            strictness: strictness
        )
    }

    private func cwgcQuery(strictness: SearchStrictness) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Ernest", recordType: .death,
            yearFrom: 1914, yearTo: 1918, gender: .male, region: .englandAndWales,
            sourceParams: .cwgc(CWGCParams()), strictness: strictness
        )
    }

    private func freeCenQuery(strictness: SearchStrictness) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Ernest", recordType: .census,
            yearFrom: 1901, yearTo: 1901, gender: .male, region: .englandAndWales,
            sourceParams: .freeCen(FreeCenParams(chapmanCode: "DBY", censusYear: 1901)),
            strictness: strictness
        )
    }

    private func freeREGQuery(strictness: SearchStrictness) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Ernest", recordType: .parish,
            yearFrom: 1850, yearTo: 1900, gender: .male, region: .englandAndWales,
            sourceParams: .freeREG(FreeREGParams(chapmanCode: "DBY")),
            strictness: strictness
        )
    }

    private func fsQuery(strictness: SearchStrictness) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Ernest", recordType: .birth,
            yearFrom: 1880, yearTo: 1882, gender: .male, region: .englandAndWales,
            sourceParams: .generic, strictness: strictness
        )
    }
}

/// Counts `search(...)` calls and returns a real empty result — lets a
/// test assert whether a wire-identical ladder re-fire hit the cache or
/// went back to the network.
private actor CountingWireSource: RecordSource {
    nonisolated let sourceID: String
    nonisolated let scopeHandling: ScopeHandling = .inherentlyNational(reason: "test double")
    nonisolated let displayName = "Counting Wire Source"
    nonisolated let recordTypes: Set<RecordType> = [.birth, .death, .burial, .probate, .census, .parish]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "test")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(level: .open, summary: "test stub")

    private(set) var searchCount = 0

    init(sourceID: String) { self.sourceID = sourceID }

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        searchCount += 1
        // One record so the result is cached (only .results is cached).
        let common = RecordCommon(
            id: "stub-\(searchCount)", sourceID: sourceID, name: "Stub",
            surname: query.surname, givenName: query.givenName,
            detailURL: nil, rawFields: [:]
        )
        return .results([.birth(BirthRecord(common: common, birthYear: 1880))])
    }
}
