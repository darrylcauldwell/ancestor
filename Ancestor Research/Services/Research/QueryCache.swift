import Foundation

/// Per-pipeline-run cache preventing duplicate queries to the same source.
/// Keyed by searchKey (source + record type + normalised wire params).
/// Discarded at pipeline end — not a persistent cache.
///
/// Two callers benefit:
///   1. `SearchDispatcher.dispatchToSource` — re-issues the same district
///      fan-out per iteration. 4 iterations × 12 DBY districts × 3 record
///      types = 144 identical queries per profile. Cache cuts these to 36.
///   2. `ResearchPipeline.dispatchMarriageQuery` — parent-marriage flow
///      reissued every iteration; results are stable.
///
/// Hit / miss accounting is recorded for observability; `stats()` exposes
/// the totals so a pipeline can log cache effectiveness post-run.
actor QueryCache {
    private var cache: [String: [SourceRecord]] = [:]
    private var hits = 0
    private var misses = 0

    func get(_ key: String) -> [SourceRecord]? {
        if let v = cache[key] {
            hits += 1
            return v
        }
        misses += 1
        return nil
    }

    func set(_ key: String, results: [SourceRecord]) {
        cache[key] = results
    }

    func contains(_ key: String) -> Bool {
        cache[key] != nil
    }

    func clear() {
        cache.removeAll()
        hits = 0
        misses = 0
    }

    func stats() -> (hits: Int, misses: Int, entries: Int) {
        (hits, misses, cache.count)
    }

    /// Run `source.search(query)` through the cache. Identical queries
    /// (same wire payload) within the cache's lifetime are served from
    /// memory; misses fall through to the source and are populated.
    ///
    /// Errors / unavailable / outsideCoverage results are NOT cached —
    /// only `.results(records)`. A transient throttling or session
    /// expiry would otherwise pin a bad answer for the rest of the run.
    static func wrappedSearch(
        source: any RecordSource,
        query: RecordQuery,
        cache: QueryCache?
    ) async -> [SourceRecord] {
        guard let cache else {
            return await source.search(query).records
        }
        let key = cacheKey(sourceID: source.sourceID, query: query)
        if let hit = await cache.get(key) { return hit }
        let result = await source.search(query)
        guard case .results(let records) = result else {
            // Don't poison the cache with transient failures.
            return []
        }
        await cache.set(key, results: records)
        return records
    }

    /// Stable wire-determining key. Two queries with identical keys must
    /// produce identical HTTP requests. Field ordering matters for
    /// future-you reading logs: keep it surname-first so a `grep` finds
    /// all probes for one person.
    nonisolated static func cacheKey(sourceID: String, query: RecordQuery) -> String {
        // FreeBMD's spouse-surname / mother-surname / district-code live
        // in sourceParams, FamilySearch's are on the top-level family-
        // context axes. Read whichever is populated.
        //
        // FT-24 + T1-21: every wire-affecting sourceParams field must
        // reach the key — FreeCen's chapman/censusYear/birthYearRange and
        // FreeREG's chapman change the outbound POST (under .adjacent /
        // .national scopes distinct county probes used to collide on one
        // cached county), and FAG's location changes the search URL (the
        // strategist's location-narrowed probe used to no-op against the
        // dispatcher's cached result). The switch is deliberately
        // exhaustive (no `default`) so adding a params case forces a
        // decision here.
        var spouseSurname = query.spouseSurname ?? ""
        var motherSurname = query.motherSurname ?? ""
        var districtCode = ""
        var chapmanCode = ""
        var censusYear = ""
        var birthYearRange = ""
        var fagLocation = ""
        switch query.sourceParams {
        case .freeBMD(let p):
            if let ss = p.spouseSurname, !ss.isEmpty { spouseSurname = ss }
            if let ms = p.motherSurname, !ms.isEmpty { motherSurname = ms }
            districtCode = p.districtCode ?? ""
        case .freeCen(let p):
            chapmanCode = p.chapmanCode ?? ""
            censusYear = p.censusYear.map(String.init) ?? ""
            birthYearRange = p.birthYearRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? ""
        case .freeREG(let p):
            // registerType is derived from query.recordType (already keyed);
            // parish never reaches the wire request.
            chapmanCode = p.chapmanCode ?? ""
        case .findAGrave(let p):
            // yearRangeWidth never reaches the wire request.
            fagLocation = p.location ?? ""
        case .cwgc, .probate, .wirksworth, .generic:
            // CWGC conflict / Probate courtType / Wirksworth parishHint
            // never reach the wire request.
            break
        }
        let parts: [String] = [
            sourceID,
            query.recordType.rawValue,
            query.surname ?? "",
            query.givenName ?? "",
            spouseSurname,
            query.spouseGivenName ?? "",
            query.fatherSurname ?? "",
            query.fatherGivenName ?? "",
            motherSurname,
            query.motherGivenName ?? "",
            districtCode,
            query.yearFrom.map(String.init) ?? "",
            query.yearTo.map(String.init) ?? "",
            query.birthPlace ?? "",
            query.deathPlace ?? "",
            query.strictness.rawValue,
            // FT-24 / T1-21 additions — appended so untouched components
            // keep their positions (grep-able log format preserved).
            chapmanCode,
            censusYear,
            birthYearRange,
            fagLocation,
        ]
        return parts.joined(separator: "|")
    }
}
