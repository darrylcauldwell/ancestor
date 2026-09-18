import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// EV27 — `v63_collapse_duplicate_parent_edges`, the one-time repair for TWIN
/// parent edges. Until this release `addRelationshipIfAbsent`'s dedup was
/// role-SENSITIVE and matched `(role = ? OR role IS NULL)`, which never
/// matched the string 'unspecified' that `.unspecified` persists as — so a
/// role-less or re-roled proposal inserted a SECOND row for a pair that
/// already had an edge (owner dogfood: one profile carrying three parent
/// edges, with `parentEdgeID`'s `.first` making the twin near-unremovable
/// from the UI).
///
/// The repair is information-preserving: same-parent twins collapse onto the
/// concrete role, and a father-vs-mother pair — a real contradiction, not a
/// duplicate — is left for the human. Same scratch-DB / migrate-upTo idiom as
/// MigrationV34/V35/V36/V41.
struct MigrationV63DuplicateParentEdgesTests {

    /// A scratch DB migrated to just BEFORE v63, with the two profiles the
    /// twin edges hang off. The caller seeds relationship rows the old write
    /// path could produce, then calls `finishMigration`.
    private func makeDBBeforeV63() throws -> DatabaseQueue {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        try ProjectDatabase.makeMigrator()
            .migrate(dbQueue, upTo: "v62_pending_relationships_marriage")
        try dbQueue.write { db in
            for (id, given, surname) in [("p", "Hannah", "Hewkin"),
                                         ("p2", "Sarah", "Oates"),
                                         ("c", "Frances", "Gladwin")] {
                try db.execute(sql: """
                    INSERT INTO profiles (id, external_ids, first_name, last_name, is_deleted)
                    VALUES (?, '{}', ?, ?, 0)
                    """, arguments: [id, given, surname])
            }
        }
        return dbQueue
    }

    private func finishMigration(_ dbQueue: DatabaseQueue) throws {
        try ProjectDatabase.makeMigrator().migrate(dbQueue)
    }

    /// A parent edge plus the existence-provenance row that says why it
    /// exists — the row the repair must re-point rather than orphan.
    private static func addEdge(
        _ db: Database, id: String, from: String = "p", to: String = "c",
        role: String?, note: String
    ) throws {
        try db.execute(sql: """
            INSERT INTO relationships (id, from_id, to_id, type, role, subtype)
            VALUES (?, ?, ?, 'parent', ?, 'biological')
            """, arguments: [id, from, to, role])
        try db.execute(sql: """
            INSERT INTO field_sources
                (entity_id, entity_kind, field, origin, raw, added_at)
            VALUES (?, 'relationship', 'existence', 'test', ?, ?)
            """, arguments: [id, note, Date()])
    }

    private func parentEdgeIDs(_ dbQueue: DatabaseQueue) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM relationships WHERE type = 'parent' ORDER BY rowid ASC
                """)
        }
    }

    private func role(_ dbQueue: DatabaseQueue, edgeID: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT role FROM relationships WHERE id = ?", arguments: [edgeID])
        }
    }

    private func existenceNotes(_ dbQueue: DatabaseQueue, edgeID: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT raw FROM field_sources
                WHERE entity_id = ? AND entity_kind = 'relationship' AND field = 'existence'
                ORDER BY rowid ASC
                """, arguments: [edgeID])
        }
    }

    @Test func collapseKeepsTheConcreteRoleAndRepointsExistenceProvenance() throws {
        let dbQueue = try makeDBBeforeV63()
        try dbQueue.write { db in
            try Self.addEdge(db, id: "E1", role: "father", note: "A")
            try Self.addEdge(db, id: "E2", role: "unspecified", note: "B")
        }
        try finishMigration(dbQueue)

        #expect(try parentEdgeIDs(dbQueue) == ["E1"], "the twin is gone, the OLDEST row survives")
        #expect(try role(dbQueue, edgeID: "E1") == "father", "the concrete role is preserved")
        #expect(try existenceNotes(dbQueue, edgeID: "E1") == ["A", "B"],
                "the victim's 'why this edge exists' citation is re-pointed, never orphaned")
    }

    @Test func collapseFillsTheSurvivorsEmptyRoleFromTheVictim() throws {
        // Reverse ordering: the role-less row landed first, the concrete one
        // second. Fill only — a stated role is never overwritten.
        let dbQueue = try makeDBBeforeV63()
        try dbQueue.write { db in
            try Self.addEdge(db, id: "E1", role: nil, note: "A")
            try Self.addEdge(db, id: "E2", role: "mother", note: "B")
        }
        try finishMigration(dbQueue)

        #expect(try parentEdgeIDs(dbQueue) == ["E1"])
        #expect(try role(dbQueue, edgeID: "E1") == "mother")
    }

    @Test func collapseLeavesAFatherVersusMotherPairForTheHuman() throws {
        // One person cannot be both parents of one child — a real
        // contradiction, not a duplicate. Both rows stay so
        // `ExcessParentEdgesRule` keeps flagging it.
        let dbQueue = try makeDBBeforeV63()
        try dbQueue.write { db in
            try Self.addEdge(db, id: "E1", role: "father", note: "A")
            try Self.addEdge(db, id: "E2", role: "mother", note: "B")
        }
        try finishMigration(dbQueue)

        #expect(try parentEdgeIDs(dbQueue) == ["E1", "E2"])
    }

    @Test func distinctParentPairsAreNeverTouched() throws {
        let dbQueue = try makeDBBeforeV63()
        try dbQueue.write { db in
            try Self.addEdge(db, id: "E1", from: "p", role: "mother", note: "A")
            try Self.addEdge(db, id: "E2", from: "p2", role: "mother", note: "B")
        }
        try finishMigration(dbQueue)

        #expect(try parentEdgeIDs(dbQueue) == ["E1", "E2"],
                "two DIFFERENT parents in one role are two edges — when in doubt, split")
    }

    @Test func collapseIsIdempotent() throws {
        let dbQueue = try makeDBBeforeV63()
        try dbQueue.write { db in
            try Self.addEdge(db, id: "E1", role: "father", note: "A")
            try Self.addEdge(db, id: "E2", role: "unspecified", note: "B")
            try Self.addEdge(db, id: "E3", role: nil, note: "C")
        }
        try finishMigration(dbQueue)
        #expect(try parentEdgeIDs(dbQueue) == ["E1"])

        // Re-running the maintenance hook over already-repaired data changes
        // nothing and reports zero deletions.
        let second = try dbQueue.write { db in
            try ProjectDatabase.collapseDuplicateParentEdges(db)
        }
        #expect(second == 0)
        #expect(try parentEdgeIDs(dbQueue) == ["E1"])
        #expect(try existenceNotes(dbQueue, edgeID: "E1") == ["A", "B", "C"])
    }
}
