import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// Pins migration `v32_user_hypothesis_seeds` (RESEARCH_PIPELINE_SPEC
/// §5.15.2, Decision E2 — user-seeded hypotheses, Slice 1).
///
/// Two schema changes ship together:
///   • `user_hypothesis_seeds` — the staging table external surfaces
///     (MCP `submit_hypothesis`, later the Workbench form) write instead
///     of touching the engine-owned `research_hypotheses` directly;
///   • `research_hypotheses.origin` — the Decision E1 provenance column,
///     `NOT NULL DEFAULT 'engine'` so every pre-v32 row (all engine-made
///     by definition) backfills correctly.
///
/// Test shape mirrors `MigrationV31PurgeHashIDsTests`: migrate a scratch
/// DB `upTo:` the prior tail, seed legacy-shaped rows, complete the
/// chain, assert the new schema treats them right.
nonisolated struct MigrationV32UserHypothesisSeedsTests {

    /// Scratch DB migrated `upTo:` v31 with one legacy (pre-origin)
    /// hypothesis row, then fully migrated so v32 runs against seeded
    /// data exactly as it will against real DBs. Returns the path too
    /// so callers can re-open through `ProjectDatabase`.
    private func makeMigratedDB() throws -> (dbQueue: DatabaseQueue, path: String) {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        let migrator = ProjectDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v31_purge_hash_based_record_ids")

        try dbQueue.write { db in
            // Legacy row written by the v26-era code path — no origin
            // column exists at this point in the chain.
            try db.execute(sql: """
                INSERT INTO research_hypotheses
                (id, subject_profile_id, kind_discriminator, kind_payload,
                 verdict, supporting_evidence, contradicting_evidence,
                 reasoning, created_at, last_tested_at, history)
                VALUES ('legacy-h1', NULL, 'siblingExists',
                        '{"siblingExists":{"district":"BELPER","mmn":"HOLMES","yearWindow":[1900,1910]}}',
                        'inconclusive', '[]', '[]', 'legacy row', ?, ?, '[]')
                """, arguments: [Date(), Date()])
        }

        try migrator.migrate(dbQueue)
        return (dbQueue, path)
    }

    @Test func fullChainMigratesCleanlyOnEmptyDatabase() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        try ProjectDatabase.makeMigrator().migrate(dbQueue)
        let applied = try dbQueue.read { db in
            try ProjectDatabase.makeMigrator().appliedIdentifiers(db)
        }
        #expect(applied.contains("v32_user_hypothesis_seeds"))
        // v31 must still be part of the chain — v32 appends, never replaces.
        #expect(applied.contains("v31_purge_hash_based_record_ids"))
    }

    @Test func legacyHypothesisRowsBackfillOriginEngine() throws {
        let (dbQueue, _) = try makeMigratedDB()
        let origin = try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT origin FROM research_hypotheses WHERE id = 'legacy-h1'
                """)
        }
        #expect(origin == "engine")
    }

    @Test func legacyRowLoadsThroughPersistenceWithEngineOrigin() throws {
        let (_, path) = try makeMigratedDB()
        let db = try ProjectDatabase(path: path)
        let loaded = try db.loadHypothesis(id: "legacy-h1")
        #expect(loaded != nil)
        #expect(loaded?.origin == .engine)
    }

    @Test func seedsTableAcceptsAndReturnsRows() throws {
        let (dbQueue, _) = try makeMigratedDB()
        try dbQueue.write { db in
            // FK on profile_id — the seed must reference a real profile.
            try db.execute(sql: """
                INSERT INTO profiles (id, first_name, last_name, is_deleted)
                VALUES ('p1', 'George', 'Wheeldon', 0)
                """)
            try db.execute(sql: """
                INSERT INTO user_hypothesis_seeds
                (id, profile_id, kind_discriminator, payload, requested_by, created_at)
                VALUES ('seed_1', 'p1', 'parentCandidates',
                        '{"father_given":"Bob","mother_given":"Sue"}', 'mcp', ?)
                """, arguments: [Date()])
        }
        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM user_hypothesis_seeds WHERE id = 'seed_1'")
        }
        #expect(row != nil)
        // Status defaults to 'queued'; refusal_reason and hypothesis_id
        // start NULL — the watcher fills them at materialisation time.
        #expect(row?["status"] == "queued")
        #expect((row?["refusal_reason"] as String?) == nil)
        #expect((row?["hypothesis_id"] as String?) == nil)
        #expect(row?["requested_by"] == "mcp")
    }

    @Test func seedsTableRejectsUnknownProfileViaForeignKey() throws {
        let (dbQueue, _) = try makeMigratedDB()
        #expect(throws: (any Error).self) {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO user_hypothesis_seeds
                    (id, profile_id, kind_discriminator, payload, requested_by, created_at)
                    VALUES ('seed_x', 'no-such-profile', 'parentCandidates', '{}', 'mcp', ?)
                    """, arguments: [Date()])
            }
        }
    }

    @Test func originColumnDefaultsToEngineOnBareInsert() throws {
        let (dbQueue, _) = try makeMigratedDB()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO research_hypotheses
                (id, subject_profile_id, kind_discriminator, kind_payload,
                 verdict, supporting_evidence, contradicting_evidence,
                 reasoning, created_at, last_tested_at, history)
                VALUES ('post-v32-h1', NULL, 'siblingExists', '{}',
                        'inconclusive', '[]', '[]', 'r', ?, ?, '[]')
                """, arguments: [Date(), Date()])
        }
        let origin = try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT origin FROM research_hypotheses WHERE id = 'post-v32-h1'
                """)
        }
        #expect(origin == "engine")
    }
}
