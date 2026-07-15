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
    /// Cached records plus the honesty envelope they arrived with
    /// (T1-01). Truncated-but-ok results ARE cached — re-issuing the
    /// identical query would fetch the identical partial page — but the
    /// outcome preserves `truncated`/`totalAvailable` so a cache hit
    /// never launders a partial answer into a complete one.
    private struct Entry {
        let records: [SourceRecord]
        let outcome: SearchOutcome
    }

    private var cache: [String: Entry] = [:]
    private var hits = 0
    private var misses = 0

    func get(_ key: String) -> [SourceRecord]? {
        getEntry(key)?.records
    }

    private func getEntry(_ key: String) -> Entry? {
        if let v = cache[key] {
            hits += 1
            return v
        }
        misses += 1
        return nil
    }

    func set(_ key: String, results: [SourceRecord]) {
        set(key, results: results, outcome: SearchOutcome(resultCount: results.count))
    }

    private func set(_ key: String, results: [SourceRecord], outcome: SearchOutcome) {
        cache[key] = Entry(records: results, outcome: outcome)
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
    ///
    /// Records-only convenience — callers that consume the honesty
    /// envelope (T1-01) use `wrappedSearchWithOutcome` instead.
    static func wrappedSearch(
        source: any RecordSource,
        query: RecordQuery,
        cache: QueryCache?
    ) async -> [SourceRecord] {
        await wrappedSearchWithOutcome(source: source, query: query, cache: cache).records
    }

    /// Envelope-preserving variant of `wrappedSearch` (T1-01). Same
    /// caching policy — only clean `.results` are cached (with their
    /// outcome, so a truncated page-1 answer stays flagged on cache
    /// hits); errors/throttles/blocks return an empty record list plus
    /// the outcome that says WHY it's empty, and are never cached.
    static func wrappedSearchWithOutcome(
        source: any RecordSource,
        query: RecordQuery,
        cache: QueryCache?
    ) async -> (records: [SourceRecord], outcome: SearchOutcome) {
        guard let cache else {
            let envelope = await source.searchWithOutcome(query)
            return (envelope.result.records, envelope.outcome)
        }
        let key = cacheKey(sourceID: source.sourceID, query: query)
        if let hit = await cache.getEntry(key) { return (hit.records, hit.outcome) }
        let envelope = await source.searchWithOutcome(query)
        guard case .results(let records) = envelope.result else {
            // Don't poison the cache with transient failures.
            return ([], envelope.outcome)
        }
        await cache.set(key, results: records, outcome: envelope.outcome)
        return (records, envelope.outcome)
    }

    /// The strictness value that actually reaches the wire for a given
    /// source (connector-audit T1-03). Most sources vary their outbound
    /// request by name-match strictness — FreeBMD toggles Phonetic on
    /// `.loose`, CWGC drops `Tab=exact` off `.strict`, FreeCen/FreeREG
    /// flip a soundex flag on `.loose`, FamilySearch changes its surname
    /// wildcard — so their tiers are genuinely distinct wire requests and
    /// keep their own strictness in the key.
    ///
    /// But Probate, FindAGrave, and Wirksworth read `query.strictness`
    /// ONLY to label activity-bus events; their outbound request is
    /// byte-identical across every tier. The strictness ladder still
    /// walks `.strict` then `.loose` (extend) or `.loose` then `.variant`
    /// (discover) for them, and without this normalization each tier is a
    /// distinct cache key → a cache MISS → a duplicate HTTP call for a
    /// wire-identical request (T1-03: 2 duplicate requests per empty
    /// strict tier in extend, 3 in all-mode). Collapsing every tier to a
    /// single canonical value turns the wire-identical re-fire into a
    /// cache HIT — one request, not N.
    ///
    /// Conservative direction: normalize only where the source is PROVEN
    /// wire-invariant. Any source not listed keeps its exact strictness,
    /// so a source that DOES branch on the wire can never be collapsed
    /// into serving one tier's results for another.
    nonisolated static func normalizedWireStrictness(
        sourceID: String,
        strictness: SearchStrictness
    ) -> SearchStrictness {
        switch sourceID {
        case "probate", "findagrave", "wirksworth":
            // Wire output does not vary by strictness — every tier is the
            // same request. Canonicalise to `.strict` so all tiers share
            // one cache entry.
            return .strict
        default:
            // FreeBMD / CWGC / FreeCen / FreeREG / FamilySearch and any
            // future source: preserve the exact tier — it may change the
            // wire.
            return strictness
        }
    }

    /// FT-25/FT-28 — the residence chapman key component for FreeCen and
    /// FreeREG. A batched query (`chapmanCodes`, blanks dropped, non-empty)
    /// is a DIFFERENT wire request from any single-county query, so its SET
    /// of codes must reach the key: they are joined with `+` in the order
    /// the dispatcher emits them (that order reaches the wire and is
    /// deterministic). A single `chapmanCode` with no batch returns the bare
    /// code — byte-identical to the pre-FT-25 key, so historical one-code
    /// entries never collide with a batch and never miss a legitimate hit.
    /// Empty in both = "" (no residence axis; the birth axis keys the query).
    nonisolated static func residenceChapmanKeyComponent(single: String?, batch: [String]?) -> String {
        if let batch {
            let cleaned = batch.filter { !$0.isEmpty }
            if !cleaned.isEmpty { return cleaned.joined(separator: "+") }
        }
        return single ?? ""
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
        var countyCode = ""
        var chapmanCode = ""
        var birthChapmanCode = ""
        var censusYear = ""
        var birthYearRange = ""
        var fagLocation = ""
        var fagBirthYearRange = ""
        var fagDeathYearRange = ""
        var fagLimit = ""
        var fagYearWidth = ""
        var fagMaiden = ""
        var freeBMDVolPage = ""
        switch query.sourceParams {
        case .freeBMD(let p):
            if let ss = p.spouseSurname, !ss.isEmpty { spouseSurname = ss }
            if let ms = p.motherSurname, !ms.isEmpty { motherSurname = ms }
            districtCode = p.districtCode ?? ""
            // FT-01: countyCode changes the outbound `countyid` field —
            // without it a county-level query and a national query for
            // the same subject collide on one cache entry.
            countyCode = p.countyCode ?? ""
            // FT-03: the vol/pgno page-lookup pair changes the outbound
            // `vol`/`pgno` fields — a page-scoped query and an ordinary
            // surname query for the same subject/year must never collide
            // on one cache entry. Keyed as a joined pair only when BOTH
            // are present (mirrors the source's emit gate); a lone value
            // keys as "" so historical non-page queries are unaffected.
            if let v = p.volume?.trimmingCharacters(in: .whitespaces), !v.isEmpty,
               let pg = p.page?.trimmingCharacters(in: .whitespaces), !pg.isEmpty {
                freeBMDVolPage = "\(v)/\(pg)"
            }
        case .freeCen(let p):
            // FT-25/FT-28: the residence axis may carry a BATCH of codes
            // (`chapmanCodes`) in one repeated-key request — a different
            // wire request from any single-county query, so the SET of codes
            // must reach the key or a batched multi-county result would be
            // served for a single-county probe (and vice versa). A single
            // `chapmanCode` (batch nil) keys exactly as before FT-25, so no
            // cache regression on the historical one-code path.
            chapmanCode = Self.residenceChapmanKeyComponent(single: p.chapmanCode, batch: p.chapmanCodes)
            // FT-11: birth-county axis (`birth_chapman_codes[]`) is a
            // distinct wire field from the residence chapman — an
            // .adjacent/.national birth-scoped query must not collide
            // with a residence-scoped one for the same subject.
            birthChapmanCode = p.birthChapmanCode ?? ""
            censusYear = p.censusYear.map(String.init) ?? ""
            birthYearRange = p.birthYearRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? ""
        case .freeREG(let p):
            // register type is derived from query.recordType (already
            // keyed); the dead registerType/parish params were removed by
            // SOURCE_WEIGHTING Change 3.
            // FT-25/FT-28: same batched-set keying as FreeCen's residence
            // axis — a batched multi-county query is a distinct wire request.
            chapmanCode = Self.residenceChapmanKeyComponent(single: p.chapmanCode, batch: p.chapmanCodes)
        case .findAGrave(let p):
            // T1-16 / T1-23: every one of these changes the outbound
            // search URL — year axes (birthyear/deathyear + their
            // filter tolerances), page size, and the maiden-name flag.
            // Keying `limit` means a truncated-page raise (20 → 100)
            // is a genuine re-fetch, never served the cached partial
            // page. `yearRangeWidth` now reaches the wire as the
            // filter-tolerance floor whenever a year range is present;
            // it is keyed unconditionally — a conservative key
            // (distinct keys for occasionally-identical requests)
            // costs a cache hit, never correctness.
            fagLocation = p.location ?? ""
            fagBirthYearRange = p.birthYearRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? ""
            fagDeathYearRange = p.deathYearRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? ""
            fagLimit = String(p.limit)
            fagYearWidth = String(p.yearRangeWidth)
            fagMaiden = p.includeMaidenName ? "maiden" : ""
        case .cwgc, .probate, .generic:
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
            // T1-03 — normalise to the source's EFFECTIVE wire strictness
            // so wire-invariant sources (Probate/FindAGrave/Wirksworth)
            // don't get a distinct key per ladder tier and re-fire an
            // identical request. Sources that vary output by strictness
            // keep their exact tier (see `normalizedWireStrictness`).
            normalizedWireStrictness(sourceID: sourceID, strictness: query.strictness).rawValue,
            // FT-24 / T1-21 additions — appended so untouched components
            // keep their positions (grep-able log format preserved).
            chapmanCode,
            censusYear,
            birthYearRange,
            fagLocation,
            // FT-01 addition — appended, preserving prior positions.
            countyCode,
            // T1-16 / T1-23 additions — appended, preserving prior
            // positions (grep-able log format preserved).
            fagBirthYearRange,
            fagDeathYearRange,
            fagLimit,
            fagYearWidth,
            fagMaiden,
            // FT-11 addition — appended, preserving prior positions.
            birthChapmanCode,
            // FT-03 addition — appended, preserving prior positions.
            freeBMDVolPage,
            // #Change6 additions — appended, preserving prior positions.
            // Wire-affecting for FamilySearch (q.residenceLikePlace /
            // q.marriageLikePlace), so they must reach the key or a
            // place-narrowed query would collide with the unnarrowed one.
            // One-time cost: this changes every key's shape, so historical
            // negative_searches keys stop matching once (they age out of
            // the freshness window) — same accepted cost as prior additions.
            query.residencePlace ?? "",
            query.marriagePlace ?? "",
            // #Change6-followup — soft country axis (FS q.anyPlace). Appended,
            // preserving prior positions; wire-affecting for FamilySearch.
            query.anyPlace ?? "",
        ]
        return parts.joined(separator: "|")
    }
}
