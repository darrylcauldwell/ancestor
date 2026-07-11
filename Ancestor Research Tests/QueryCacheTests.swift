import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit findings FT-24 + T1-21 (CONNECTOR_AUDIT_2026-07.md §2.4 / §6):
/// the cache key must cover every wire-affecting `sourceParams` field.
/// Two queries with identical keys must produce identical HTTP requests —
/// FreeCen's chapmanCode / censusYear / birthYearRange, FreeREG's
/// chapmanCode, and FindAGrave's location all change the outbound request,
/// so they must produce distinct keys (and separate cache entries), while
/// genuinely identical queries must still dedupe to one source call.
struct QueryCacheTests {

    // MARK: - FT-24 (a) — chapman-only difference is a distinct query

    @Test func freeCenChapmanCodeProducesDistinctKeys() {
        let dby = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery(chapman: "DBY"))
        let ntt = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery(chapman: "NTT"))
        #expect(dby != ntt,
                "queries differing only in chapman code must not share a cache key")
    }

    @Test func freeCenChapmanCodeDifferenceHitsSourceTwice() async {
        let cache = QueryCache()
        let source = CountingRecordSource(sourceID: "freecen")
        _ = await QueryCache.wrappedSearch(source: source, query: freeCenQuery(chapman: "DBY"), cache: cache)
        _ = await QueryCache.wrappedSearch(source: source, query: freeCenQuery(chapman: "NTT"), cache: cache)
        let calls = await source.searchCount
        #expect(calls == 2,
                "adjacent-county fan-out must reach the wire per county; got \(calls) call(s)")
    }

    // MARK: - FT-24 (b) — birth-year-range-only difference is a distinct query

    @Test func freeCenBirthYearRangeProducesDistinctKeys() {
        let wide = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery(birthYearRange: 1875...1895))
        let narrow = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery(birthYearRange: 1883...1885))
        #expect(wide != narrow,
                "a narrowed birth-year probe must not be served the wide query's cached results")
    }

    @Test func freeCenBirthYearRangeDifferenceHitsSourceTwice() async {
        let cache = QueryCache()
        let source = CountingRecordSource(sourceID: "freecen")
        _ = await QueryCache.wrappedSearch(source: source, query: freeCenQuery(birthYearRange: 1875...1895), cache: cache)
        _ = await QueryCache.wrappedSearch(source: source, query: freeCenQuery(birthYearRange: 1883...1885), cache: cache)
        let calls = await source.searchCount
        #expect(calls == 2,
                "refineSubject's narrowed probe must reach the wire; got \(calls) call(s)")
    }

    @Test func freeCenNilBirthYearRangeIsDistinctFromPopulated() {
        let none = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery(birthYearRange: nil))
        let some = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery(birthYearRange: 1880...1890))
        #expect(none != some)
    }

    // MARK: - FT-24 — censusYear and FreeREG chapman are also wire-affecting

    @Test func freeCenCensusYearProducesDistinctKeys() {
        let y1901 = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery(censusYear: 1901))
        let y1911 = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery(censusYear: 1911))
        #expect(y1901 != y1911)
    }

    @Test func freeREGChapmanCodeProducesDistinctKeys() {
        let dby = QueryCache.cacheKey(sourceID: "freereg", query: freeREGQuery(chapman: "DBY"))
        let lei = QueryCache.cacheKey(sourceID: "freereg", query: freeREGQuery(chapman: "LEI"))
        #expect(dby != lei,
                "FreeREG county fan-out must not collapse to one cached county")
    }

    // MARK: - T1-21 — FindAGrave location is wire-affecting

    @Test func findAGraveLocationProducesDistinctKeys() {
        let death = QueryCache.cacheKey(sourceID: "findagrave", query: fagQuery(location: "Derby, Derbyshire"))
        let district = QueryCache.cacheKey(sourceID: "findagrave", query: fagQuery(location: "Belper"))
        #expect(death != district,
                "a location-narrowed FocusedQuery probe must not be served the dispatcher's cached results")
    }

    @Test func findAGraveNilLocationIsDistinctFromPopulated() {
        let none = QueryCache.cacheKey(sourceID: "findagrave", query: fagQuery(location: nil))
        let some = QueryCache.cacheKey(sourceID: "findagrave", query: fagQuery(location: "Belper"))
        #expect(none != some)
    }

    // MARK: - FT-24 (c) — identical queries still dedupe

    @Test func identicalFreeCenQueriesShareOneKey() {
        let a = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery())
        let b = QueryCache.cacheKey(sourceID: "freecen", query: freeCenQuery())
        #expect(a == b)
    }

    @Test func identicalQueriesDedupeToOneSourceCall() async {
        let cache = QueryCache()
        let source = CountingRecordSource(sourceID: "freecen")
        let first = await QueryCache.wrappedSearch(source: source, query: freeCenQuery(), cache: cache)
        let second = await QueryCache.wrappedSearch(source: source, query: freeCenQuery(), cache: cache)
        let calls = await source.searchCount
        #expect(calls == 1, "identical queries must be served from cache; got \(calls) call(s)")
        #expect(first.count == 1 && second.count == 1,
                "cache hit must return the original results")
        let stats = await cache.stats()
        #expect(stats.hits == 1 && stats.misses == 1 && stats.entries == 1,
                "expected 1 hit / 1 miss / 1 entry; got \(stats)")
    }

    // MARK: - Regression — pre-existing key components unchanged

    @Test func freeBMDDistrictCodeStillProducesDistinctKeys() {
        let belper = QueryCache.cacheKey(sourceID: "freebmd", query: freeBMDQuery(district: "BELPER"))
        let derby = QueryCache.cacheKey(sourceID: "freebmd", query: freeBMDQuery(district: "DERBY"))
        #expect(belper != derby)
    }

    // MARK: - Helpers

    private func freeCenQuery(
        chapman: String? = "DBY",
        censusYear: Int? = 1901,
        birthYearRange: ClosedRange<Int>? = 1880...1890
    ) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Robert",
            recordType: .census,
            yearFrom: 1901, yearTo: 1901,
            gender: .male, region: .englandAndWales,
            sourceParams: .freeCen(FreeCenParams(
                chapmanCode: chapman,
                censusYear: censusYear,
                birthYearRange: birthYearRange
            ))
        )
    }

    private func freeREGQuery(chapman: String?) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Robert",
            recordType: .parish,
            yearFrom: 1880, yearTo: 1890,
            gender: .male, region: .englandAndWales,
            sourceParams: .freeREG(FreeREGParams(chapmanCode: chapman))
        )
    }

    private func fagQuery(location: String?) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Robert",
            recordType: .burial,
            yearFrom: 1914, yearTo: 1918,
            gender: .male, region: .englandAndWales,
            sourceParams: .findAGrave(FindAGraveParams(yearRangeWidth: 5, location: location))
        )
    }

    private func freeBMDQuery(district: String?) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Robert",
            recordType: .birth,
            yearFrom: 1880, yearTo: 1882,
            gender: .male, region: .englandAndWales,
            sourceParams: .freeBMD(FreeBMDParams(districtCode: district, wildcardSurname: false))
        )
    }
}

/// Stub source that counts `search(...)` calls so tests can assert whether
/// a query reached the wire or was served from the cache.
private actor CountingRecordSource: RecordSource {
    nonisolated let sourceID: String
    nonisolated let displayName = "Counting Source"
    nonisolated let recordTypes: Set<RecordType> = [.birth, .census, .burial, .parish]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "test")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(level: .open, summary: "test stub")

    private(set) var searchCount = 0

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        searchCount += 1
        let common = RecordCommon(
            id: "stub-\(searchCount)",
            sourceID: sourceID,
            name: "Stub",
            surname: query.surname,
            givenName: query.givenName,
            detailURL: nil,
            rawFields: [:]
        )
        return .results([.military(MilitaryRecord(
            common: common,
            rank: nil, regiment: nil, unit: nil, serviceNumber: nil,
            dateOfDeath: nil, deathYear: nil, age: nil,
            cemetery: nil, graveRef: nil, additionalInfo: nil
        ))])
    }
}
