import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// Pins migration `v31_purge_hash_based_record_ids` (FT-16 follow-up,
/// CONNECTOR_AUDIT_2026-07 §2.3).
///
/// FreeREG and Wirksworth previously built record IDs from `String.hashValue`
/// (per-process seeded), so rows keyed on them — user rejections, evidence
/// `user_status` — were orphaned at every launch. v31 ships in the same build
/// as the stable-ID scheme, so at migration time every `freereg_*` /
/// `wirksworth_*` key is old-scheme and unmatchable: prefix deletion is safe.
///
/// Test shape: migrate a scratch DB `upTo:` v30 via
/// `ProjectDatabase.makeMigrator()`, seed old-scheme rows plus survivors in
/// all four covered tables, complete the chain (running v31), assert the
/// old-scheme rows are gone and the survivors untouched.
nonisolated struct MigrationV31PurgeHashIDsTests {

    /// Old-scheme IDs as the retired code actually shaped them —
    /// `"freereg_\(name.hashValue)_\(date.hashValue)"` and
    /// `"wirksworth_\(key.hashValue)"`, hashValue being a signed Int.
    private static let purgedIDs = [
        "freereg_8234491646556406571_-4988734497341864321",
        "freereg_-123456789012345678_987654321098765432",
        "wirksworth_-5566778899001122334",
        "wirksworth_42",
    ]

    /// Rows that must survive: other connectors' stable IDs, plus a
    /// "freeregister_" lookalike that only survives because the LIKE
    /// pattern escapes the underscore (without ESCAPE, `_` matches any
    /// character and "freeregX..." would be swept up too).
    private static let survivorIDs = [
        "freebmd_1897_belper_7b_615",
        "cwgc_123456",
        "GBPRS/CANT/BAP/12345",
        "freeregister_rows_1",
    ]

    private static var seededIDs: [String] { purgedIDs + survivorIDs }

    /// Scratch DB at v30 with seeded rows, then fully migrated (v31 runs
    /// against the seeded data, exactly as it will against real DBs).
    private func makeMigratedDB() throws -> DatabaseQueue {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        let migrator = ProjectDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v30_publisher_tables")

        try dbQueue.write { db in
            for rid in Self.seededIDs {
                try db.execute(sql: """
                    INSERT INTO record_rejections (profile_id, record_id, rejected_at)
                    VALUES ('p1', ?, ?)
                    """, arguments: [rid, Date()])
                try db.execute(sql: """
                    INSERT INTO evidence_records
                    (id, profile_id, source_id, source_record_id, record_type,
                     verdict, record_json, scored_at, user_status)
                    VALUES (?, 'p1', 'src', ?, 'baptism', 'lead', '{}', ?, 'discarded')
                    """, arguments: ["p1|\(rid)", rid, Date()])
                try db.execute(sql: """
                    INSERT INTO scored_records
                    (id, profile_id, source_record_id, verdict, summary, scored_at)
                    VALUES (?, 'p1', ?, 'lead', 's', ?)
                    """, arguments: [UUID().uuidString, rid, Date()])
                try db.execute(sql: """
                    INSERT INTO research_records
                    (id, profile_id, source_id, record_type, verdict, summary,
                     raw_json, researched_at)
                    VALUES (?, 'p1', 'src', 'baptism', 'lead', 's', '{}', ?)
                    """, arguments: [rid, Date()])
            }
        }

        try migrator.migrate(dbQueue)
        return dbQueue
    }

    @Test func purgesOldSchemeRowsFromAllFourTables() throws {
        let dbQueue = try makeMigratedDB()
        let remaining = try dbQueue.read { db in
            [
                try String.fetchAll(db, sql: "SELECT record_id FROM record_rejections"),
                try String.fetchAll(db, sql: "SELECT source_record_id FROM evidence_records"),
                try String.fetchAll(db, sql: "SELECT source_record_id FROM scored_records"),
                try String.fetchAll(db, sql: "SELECT id FROM research_records"),
            ]
        }
        for (i, ids) in remaining.enumerated() {
            #expect(Set(ids) == Set(Self.survivorIDs), "table index \(i) kept wrong rows")
        }
    }

    /// The composite PK "<profile>|<source_record_id>" rows must be gone too —
    /// the delete goes via the source_record_id column, which clears both.
    @Test func evidenceCompositePKRowsPurgedViaSourceRecordIDColumn() throws {
        let dbQueue = try makeMigratedDB()
        let pks = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM evidence_records")
        }
        #expect(Set(pks) == Set(Self.survivorIDs.map { "p1|\($0)" }))
    }

    /// Survivor evidence rows keep their user_status — the purge deletes
    /// whole unmatchable rows, it never rewrites surviving ones.
    @Test func survivorUserStatusUntouched() throws {
        let dbQueue = try makeMigratedDB()
        let statuses = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT user_status FROM evidence_records")
        }
        #expect(statuses.count == Self.survivorIDs.count)
        #expect(statuses.allSatisfy { $0 == "discarded" })
    }

    /// The escaped underscore is load-bearing: without ESCAPE '\', LIKE's
    /// `_` wildcard would match any character and delete "freeregister_..."
    /// rows from a hypothetical future connector.
    @Test func escapeClausePreservesUnderscoreLookalikes() throws {
        let dbQueue = try makeMigratedDB()
        let lookalike = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM record_rejections
                WHERE record_id = 'freeregister_rows_1'
                """)
        }
        #expect(lookalike == 1)
    }

    @Test func fullChainMigratesCleanlyOnEmptyDatabase() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        try ProjectDatabase.makeMigrator().migrate(dbQueue)
        let applied = try dbQueue.read { db in
            try ProjectDatabase.makeMigrator().appliedIdentifiers(db)
        }
        #expect(applied.contains("v31_purge_hash_based_record_ids"))
    }
}
