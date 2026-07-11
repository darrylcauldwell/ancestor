import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// Connector-audit T1-04 — persistence round-trip for the cross-run
/// negative-search cache. Covers the v33 migration (per-query key unique
/// index + UPSERT) and the `saveNegativeSearch` (write) →
/// `loadNegativeSearchKeys` (read) round-trip the reader depends on.
nonisolated struct NegativeSearchPersistenceTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    // MARK: - v33 migration

    @Test func fullChainAppliesV33() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        try ProjectDatabase.makeMigrator().migrate(dbQueue)
        let applied = try dbQueue.read { db in
            try ProjectDatabase.makeMigrator().appliedIdentifiers(db)
        }
        #expect(applied.contains("v33_negative_search_query_key_index"))
        // v33 appends — the prior tail must remain in the chain.
        #expect(applied.contains("v32_user_hypothesis_seeds"))
    }

    @Test func v33CollapsesPreExistingDuplicateKeyRows() throws {
        // Seed the pre-v33 shape: two rows with the SAME
        // (profile, source, type, search_params) that the new UNIQUE
        // index would reject — the migration must dedupe them first.
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        let migrator = ProjectDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v32_user_hypothesis_seeds")
        try dbQueue.write { db in
            for _ in 0..<2 {
                try db.execute(sql: """
                    INSERT INTO negative_searches (profile_id, source_id, record_type, searched_at, search_params)
                    VALUES ('p1', 'freebmd', 'birth', ?, 'dup-key')
                    """, arguments: [Date()])
            }
        }
        // Must not throw when building the unique index.
        try migrator.migrate(dbQueue)
        let count = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM negative_searches
                WHERE profile_id = 'p1' AND search_params = 'dup-key'
                """)
        }
        #expect(count == 1, "duplicate key rows must collapse to one before the unique index; got \(String(describing: count))")
    }

    // MARK: - write → read round-trip

    @Test func saveAndLoadPerQueryKeyRoundTrips() throws {
        let db = try makeDB()
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "birth", params: "wire-key-1")
        let rows = try db.loadNegativeSearchKeys(profileID: "p1")
        #expect(rows.count == 1)
        #expect(rows.first?.sourceID == "freebmd")
        #expect(rows.first?.recordType == "birth")
        #expect(rows.first?.queryKey == "wire-key-1")
    }

    @Test func reSavingSameKeyUpsertsRatherThanDuplicates() throws {
        let db = try makeDB()
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "birth", params: "k")
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "birth", params: "k")
        let rows = try db.loadNegativeSearchKeys(profileID: "p1")
        #expect(rows.count == 1, "re-running the same clean-negative query must UPSERT, not accumulate rows")
    }

    @Test func upsertAdvancesTheFreshnessTimestamp() throws {
        let db = try makeDB()
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "birth", params: "k")
        let first = try db.loadNegativeSearchKeys(profileID: "p1").first?.date
        Thread.sleep(forTimeInterval: 0.02)
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "birth", params: "k")
        let second = try db.loadNegativeSearchKeys(profileID: "p1").first?.date
        #expect(first != nil && second != nil)
        #expect(second! > first!, "the UPSERT must advance searched_at so freshness re-verifies from the latest run")
    }

    @Test func nilParamRowsAreExcludedFromKeyReader() throws {
        // The `__whole_tree__` resume-state writer and legacy pair-level
        // rows carry non-key params or NULL — the key reader must skip
        // anything that can't suppress a specific wire query.
        let db = try makeDB()
        // A real per-query negative.
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "birth", params: "real-key")
        // A NULL-param row (legacy pair-level shape).
        try db.saveNegativeSearch(profileID: "p1", sourceID: "cwgc", recordType: "death", params: nil)
        let rows = try db.loadNegativeSearchKeys(profileID: "p1")
        #expect(rows.count == 1)
        #expect(rows.first?.queryKey == "real-key")
    }

    @Test func loaderIsProfileScoped() throws {
        let db = try makeDB()
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "birth", params: "k1")
        try db.saveNegativeSearch(profileID: "p2", sourceID: "freebmd", recordType: "birth", params: "k2")
        let p1 = try db.loadNegativeSearchKeys(profileID: "p1")
        #expect(p1.count == 1)
        #expect(p1.first?.queryKey == "k1")
    }

    @Test func wholeTreeResumeStateCoexistsWithPerQueryNegatives() throws {
        // The resume-state hack lives under profile_id "__whole_tree__"
        // with JSON params and must not be disturbed by, or leak into,
        // the per-query key reader for a real profile.
        let db = try makeDB()
        try db.saveNegativeSearch(
            profileID: "__whole_tree__", sourceID: "resume_state",
            recordType: "whole_tree", params: #"{"currentIndex":3}"#
        )
        try db.saveNegativeSearch(profileID: "p1", sourceID: "freebmd", recordType: "birth", params: "k")
        let p1Keys = try db.loadNegativeSearchKeys(profileID: "p1")
        #expect(p1Keys.count == 1)
        #expect(p1Keys.first?.queryKey == "k")
        // The resume row is still fetchable via the legacy reader.
        let resume = try db.loadNegativeSearches(profileID: "__whole_tree__")
        #expect(resume.contains { $0.sourceID == "resume_state" })
    }

    // MARK: - end-to-end: aggregator → save → cache → suppress

    @Test func genuineNegativeKeysPersistAndSuppressNextRun() throws {
        let db = try makeDB()
        let query = RecordQuery(
            surname: "Cauldwell", givenName: "Robert", recordType: .birth,
            yearFrom: 1880, yearTo: 1882, gender: .male, region: .englandAndWales,
            sourceParams: .freeBMD(FreeBMDParams(districtCode: "722", wildcardSurname: false))
        )
        let key = QueryCache.cacheKey(sourceID: "freebmd", query: query)
        let outcomes = [
            SearchOutcomeEntry(sourceID: "freebmd", recordType: .birth, strictness: .strict,
                               queryKey: key, outcome: SearchOutcome(resultCount: 0)),
        ]
        // Persist exactly as ResearchRunService.persist does.
        for neg in NegativeSearchAggregator.genuineNegativeKeys(outcomes: outcomes, scoredRecords: []) {
            try db.saveNegativeSearch(profileID: "p1", sourceID: neg.sourceID,
                                      recordType: neg.recordType.rawValue, params: neg.queryKey)
        }
        // Reload as the pipeline would, and confirm the identical query is
        // suppressed on the next run.
        let rows = try db.loadNegativeSearchKeys(profileID: "p1")
        let cache = NegativeSearchCache.load(profileID: "p1", rows: rows, forceRefresh: false, now: Date())
        let recomputed = QueryCache.cacheKey(sourceID: "freebmd", query: query)
        #expect(cache.suppression(forQueryKey: recomputed) != nil,
                "a persisted clean negative must suppress the identical query on the next run")
    }
}
