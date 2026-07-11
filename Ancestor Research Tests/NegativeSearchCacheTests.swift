import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-04 (CONNECTOR_AUDIT_2026-07.md §6.1 / §5.2) — the
/// CROSS-RUN persistent negative-search reader. The honesty envelope
/// (a6e9c6d) made `negative_searches` a genuine WRITER; T1-04 adds the
/// READER: before re-firing a query on a later run, skip it if a prior
/// run proved it cleanly empty and it's still fresh.
///
/// Correctness guards under test (see `NegativeSearchCache` doc):
///   (a) only clean prior negatives suppress — never error/throttle/
///       truncation, and a suppressed replay is never re-counted;
///   (b) a freshness window so stale negatives re-verify;
///   (c) a force-refresh escape hatch;
///   (d) write/read params normalization is the same `QueryCache.cacheKey`
///       shape, so a round-trip matches.
struct NegativeSearchCacheTests {

    // MARK: - (a) only clean prior negatives are ever stored to suppress

    @Test func cleanNegativeSuppressesNextRun() {
        let key = "freebmd|birth|Cauldwell|Robert|…"
        let cache = NegativeSearchCache(
            rows: [(sourceID: "freebmd", recordType: "birth", queryKey: key, date: Date())],
            window: .default, now: Date()
        )
        let outcome = cache.suppression(forQueryKey: key)
        #expect(outcome != nil, "a fresh clean prior negative must suppress the re-fire")
        #expect(outcome?.availability == .ok)
        #expect(outcome?.resultCount == 0)
        #expect(outcome?.suppressed == true)
        #expect(outcome?.suppressionReason?.contains("prior clean negative") == true)
        // The suppressed outcome is a conclusive empty (ladder broadens on
        // it) but NOT a clean negative (never re-persisted).
        #expect(outcome?.isConclusive == true)
        #expect(outcome?.isCleanNegative == false)
    }

    @Test func unknownKeyDoesNotSuppress() {
        let cache = NegativeSearchCache(
            rows: [(sourceID: "freebmd", recordType: "birth", queryKey: "stored-key", date: Date())],
            window: .default, now: Date()
        )
        #expect(cache.suppression(forQueryKey: "a-different-key") == nil,
                "a query never proved empty must go to the wire")
    }

    /// The writer (`NegativeSearchAggregator`) is what decides an error /
    /// truncated / throttled outcome NEVER becomes a stored negative — so
    /// it can never be read back as a suppression. Prove the write side
    /// filters them out (the read side only ever sees clean rows).

    @Test func errorOutcomeNeverBecomesAStoredNegative() {
        let outcomes = [
            entry(source: "freebmd", type: .birth, key: "k1", outcome: SearchOutcome(resultCount: 0)),
            entry(source: "freebmd", type: .birth, key: "k2",
                  outcome: SearchOutcome(resultCount: 0, availability: .error(reason: "outage"))),
        ]
        let keys = NegativeSearchAggregator.genuineNegativeKeys(outcomes: outcomes, scoredRecords: [])
        #expect(keys.isEmpty,
                "one errored query leaves the whole pair unproven — no key is stored to suppress later")
    }

    @Test func truncatedOutcomeNeverBecomesAStoredNegative() {
        let outcomes = [
            entry(source: "freecen", type: .census, key: "k1",
                  outcome: SearchOutcome(resultCount: 0, totalAvailable: 5000, truncated: true)),
        ]
        let keys = NegativeSearchAggregator.genuineNegativeKeys(outcomes: outcomes, scoredRecords: [])
        #expect(keys.isEmpty, "a truncated page is not a proven empty — never stored")
    }

    @Test func throttledOutcomeNeverBecomesAStoredNegative() {
        let outcomes = [
            entry(source: "findagrave", type: .burial, key: "k1",
                  outcome: SearchOutcome(resultCount: 0, availability: .throttled)),
        ]
        let keys = NegativeSearchAggregator.genuineNegativeKeys(outcomes: outcomes, scoredRecords: [])
        #expect(keys.isEmpty)
    }

    @Test func suppressedReplayIsNotReStored() {
        // A query suppressed THIS run (its outcome is a suppressed replay
        // of an earlier negative) must not be re-persisted — it would
        // double-count the absence and refresh the freshness window
        // without re-verifying (guard (a)).
        let outcomes = [
            entry(source: "freebmd", type: .birth, key: "k1",
                  outcome: .suppressedNegative(reason: "prior clean negative 2026-06-30")),
        ]
        let keys = NegativeSearchAggregator.genuineNegativeKeys(outcomes: outcomes, scoredRecords: [])
        #expect(keys.isEmpty, "a suppressed replay is the same absence already on disk — not re-stored")
    }

    @Test func recordInHandVetoesTheWholePairsKeys() {
        // Pair-veto parity with genuineNegatives: a record found by any
        // flow for the same (source, type) means the pair isn't a
        // negative — none of its keys are stored.
        let outcomes = [
            entry(source: "freebmd", type: .birth, key: "k1", outcome: SearchOutcome(resultCount: 0)),
        ]
        let scored = [scoredRecord(sourceID: "freebmd")]
        let keys = NegativeSearchAggregator.genuineNegativeKeys(outcomes: outcomes, scoredRecords: scored)
        #expect(keys.isEmpty)
    }

    @Test func distinctCleanKeysInACleanPairAreAllStored() {
        // Two districts, both clean-zero — each distinct wire key is a
        // suppressible negative next run.
        let outcomes = [
            entry(source: "freebmd", type: .birth, key: "belper", outcome: SearchOutcome(resultCount: 0)),
            entry(source: "freebmd", type: .birth, key: "derby", outcome: SearchOutcome(resultCount: 0)),
        ]
        let keys = NegativeSearchAggregator.genuineNegativeKeys(outcomes: outcomes, scoredRecords: [])
        #expect(Set(keys.map(\.queryKey)) == ["belper", "derby"])
    }

    @Test func duplicateKeysAcrossTiersCollapseToOneRow() {
        // The same wire query repeated across ladder tiers (T1-03 makes
        // strict/loose collapse for some sources) yields ONE durable row.
        let outcomes = [
            entry(source: "probate", type: .probate, key: "same", strictness: .strict,
                  outcome: SearchOutcome(resultCount: 0)),
            entry(source: "probate", type: .probate, key: "same", strictness: .loose,
                  outcome: SearchOutcome(resultCount: 0)),
        ]
        let keys = NegativeSearchAggregator.genuineNegativeKeys(outcomes: outcomes, scoredRecords: [])
        #expect(keys.count == 1, "the same wire key across two tiers is one durable negative row")
    }

    // MARK: - (b) freshness window: stale negatives re-verify

    @Test func staleNegativeReVerifies() {
        let now = Date()
        let old = now.addingTimeInterval(-100 * 24 * 60 * 60)  // 100 days ago
        let cache = NegativeSearchCache(
            rows: [(sourceID: "freebmd", recordType: "birth", queryKey: "k", date: old)],
            window: .days(90), now: now
        )
        #expect(cache.suppression(forQueryKey: "k") == nil,
                "a 100-day-old negative is outside the 90-day window — must re-verify")
    }

    @Test func negativeExactlyAtWindowEdgeStillSuppresses() {
        let now = Date()
        let edge = now.addingTimeInterval(-90 * 24 * 60 * 60)  // exactly 90 days
        let cache = NegativeSearchCache(
            rows: [(sourceID: "freebmd", recordType: "birth", queryKey: "k", date: edge)],
            window: .days(90), now: now
        )
        #expect(cache.suppression(forQueryKey: "k") != nil,
                "a negative exactly at the window edge is still within it")
    }

    @Test func freshNegativeInsideWindowSuppresses() {
        let now = Date()
        let recent = now.addingTimeInterval(-10 * 24 * 60 * 60)  // 10 days ago
        let cache = NegativeSearchCache(
            rows: [(sourceID: "freebmd", recordType: "birth", queryKey: "k", date: recent)],
            window: .days(90), now: now
        )
        #expect(cache.suppression(forQueryKey: "k") != nil)
    }

    @Test func tighterWindowReVerifiesSooner() {
        let now = Date()
        let fiveDaysAgo = now.addingTimeInterval(-5 * 24 * 60 * 60)
        // Same-session-style tight window: a 5-day-old negative already
        // re-verifies.
        let tight = NegativeSearchCache(
            rows: [(sourceID: "freebmd", recordType: "birth", queryKey: "k", date: fiveDaysAgo)],
            window: .days(1), now: now
        )
        #expect(tight.suppression(forQueryKey: "k") == nil)
    }

    // MARK: - (c) force-refresh escape hatch

    @Test func disabledCacheSuppressesNothing() {
        #expect(NegativeSearchCache.disabled.suppression(forQueryKey: "anything") == nil)
        #expect(NegativeSearchCache.disabled.isEmpty)
    }

    @Test func forceRefreshLoadYieldsDisabledCache() {
        let rows = [(sourceID: "freebmd", recordType: "birth", queryKey: "k", date: Date())]
        let cache = NegativeSearchCache.load(
            profileID: "p1", rows: rows, forceRefresh: true, now: Date()
        )
        #expect(cache.suppression(forQueryKey: "k") == nil,
                "force-refresh must ignore stored negatives and re-fire everything")
        #expect(cache.isEmpty)
    }

    @Test func nilProfileYieldsDisabledCache() {
        let rows = [(sourceID: "freebmd", recordType: "birth", queryKey: "k", date: Date())]
        let cache = NegativeSearchCache.load(
            profileID: nil, rows: rows, forceRefresh: false, now: Date()
        )
        #expect(cache.suppression(forQueryKey: "k") == nil,
                "manual-input / lead subjects have no profile — nothing to suppress against")
    }

    @Test func normalLoadHonoursStoredNegatives() {
        let rows = [(sourceID: "freebmd", recordType: "birth", queryKey: "k", date: Date())]
        let cache = NegativeSearchCache.load(
            profileID: "p1", rows: rows, forceRefresh: false, now: Date()
        )
        #expect(cache.suppression(forQueryKey: "k") != nil)
    }

    @Test func verifyModeConfigForcesRefresh() {
        // `.verify` always re-verifies (guard (c) wiring).
        #expect(ResearchConfig.verify.forceRefreshNegatives == true)
        // The growth modes consult the cache by default.
        #expect(ResearchConfig.extend.forceRefreshNegatives == false)
        #expect(ResearchConfig.discover.forceRefreshNegatives == false)
        #expect(ResearchConfig.all.forceRefreshNegatives == false)
    }

    @Test func forceRefreshFlagSurvivesScopeBuilder() {
        let cfg = ResearchConfig.extend.with(scope: .national)
        #expect(cfg.forceRefreshNegatives == false)
        let forced = ResearchConfig(maxIterations: 4, maxFacts: 50, mode: .extend, forceRefreshNegatives: true)
        #expect(forced.with(scope: .county).forceRefreshNegatives == true)
    }

    // MARK: - (d) write/read normalization round-trips

    @Test func cacheKeyRoundTripsWriteToRead() {
        // The KEY the writer stores is exactly the KEY the reader matches
        // — one `QueryCache.cacheKey` shape, no drift (guard (d)).
        let query = RecordQuery(
            surname: "Cauldwell", givenName: "Robert", recordType: .birth,
            yearFrom: 1880, yearTo: 1882, gender: .male, region: .englandAndWales,
            sourceParams: .freeBMD(FreeBMDParams(districtCode: "722", wildcardSurname: false)),
            strictness: .strict
        )
        let writtenKey = QueryCache.cacheKey(sourceID: "freebmd", query: query)
        // Reader loaded that key from the DB.
        let cache = NegativeSearchCache(
            rows: [(sourceID: "freebmd", recordType: "birth", queryKey: writtenKey, date: Date())],
            window: .default, now: Date()
        )
        // A next-run dispatch recomputes the identical key and matches.
        let readKey = QueryCache.cacheKey(sourceID: "freebmd", query: query)
        #expect(cache.suppression(forQueryKey: readKey) != nil,
                "the recomputed cacheKey must match the stored one verbatim")
    }

    @Test func differentParamsDoNotRoundTripMatch() {
        // A district that WASN'T proved empty must not be suppressed by a
        // different district's stored negative — normalization is
        // param-sensitive, not just (source, type).
        let stored = RecordQuery(
            surname: "Cauldwell", givenName: "Robert", recordType: .birth,
            yearFrom: 1880, yearTo: 1882, gender: .male, region: .englandAndWales,
            sourceParams: .freeBMD(FreeBMDParams(districtCode: "722", wildcardSurname: false))
        )
        let other = RecordQuery(
            surname: "Cauldwell", givenName: "Robert", recordType: .birth,
            yearFrom: 1880, yearTo: 1882, gender: .male, region: .englandAndWales,
            sourceParams: .freeBMD(FreeBMDParams(districtCode: "999", wildcardSurname: false))
        )
        let cache = NegativeSearchCache(
            rows: [(sourceID: "freebmd", recordType: "birth",
                    queryKey: QueryCache.cacheKey(sourceID: "freebmd", query: stored), date: Date())],
            window: .default, now: Date()
        )
        #expect(cache.suppression(forQueryKey: QueryCache.cacheKey(sourceID: "freebmd", query: other)) == nil)
    }

    @Test func mostRecentDateWinsForRepeatedKey() {
        let now = Date()
        let old = now.addingTimeInterval(-100 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-1 * 24 * 60 * 60)
        // Same key twice (rows arrive newest-first, but pass out of order
        // to prove the max is taken). The recent date must win, so the
        // 90-day window still suppresses.
        let cache = NegativeSearchCache(
            rows: [
                (sourceID: "freebmd", recordType: "birth", queryKey: "k", date: old),
                (sourceID: "freebmd", recordType: "birth", queryKey: "k", date: recent),
            ],
            window: .days(90), now: now
        )
        #expect(cache.suppression(forQueryKey: "k") != nil,
                "the most-recent proof-of-empty must set the freshness age")
    }

    // MARK: - Helpers

    private func entry(
        source: String, type: RecordType, key: String,
        strictness: SearchStrictness = .strict, outcome: SearchOutcome
    ) -> SearchOutcomeEntry {
        SearchOutcomeEntry(
            sourceID: source, recordType: type, strictness: strictness,
            queryKey: key, outcome: outcome
        )
    }

    private func scoredRecord(sourceID: String) -> ScoredRecord {
        let rec = SourceRecord.birth(BirthRecord(
            common: RecordCommon(
                id: "r1", sourceID: sourceID, name: "Stub",
                surname: "Cauldwell", givenName: "Robert", detailURL: nil, rawFields: [:]
            ),
            birthYear: 1880
        ))
        return ScoredRecord(id: rec.id, record: rec, verdict: .lead, gates: [], summary: "test")
    }
}
