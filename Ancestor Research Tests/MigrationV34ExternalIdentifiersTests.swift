import Testing
import Foundation
import GRDB
@testable import AncestorKit
@testable import Ancestor_Research

/// Pins migration `v34_external_identifiers` (MODEL_EVOLUTION_SPEC §Change1 /
/// ADR-004 E1 — typed external-identifier records with a deprecation
/// lifecycle).
///
/// Two things ship together and must both be proven:
///   • the new `external_identifiers` JSON column on `profiles`;
///   • the backfill that converts every existing `external_ids` string-map
///     entry into a `.primary` record, losslessly.
///
/// Test shape mirrors `MigrationV32UserHypothesisSeedsTests`: migrate a
/// scratch DB `upTo:` the prior tail (v33), seed a legacy-shaped profile row
/// carrying only the old `external_ids` column, complete the chain so v34 runs
/// against seeded data exactly as it will against real DBs, then assert the
/// backfill and the persistence round-trip.
nonisolated struct MigrationV34ExternalIdentifiersTests {

    /// Scratch DB migrated `upTo:` v33 with two legacy profile rows (one with
    /// a wikitree id, one with an empty map), then fully migrated so v34 runs
    /// against seeded data. Returns the path so callers can re-open through
    /// `ProjectDatabase`.
    private func makeMigratedDB() throws -> (dbQueue: DatabaseQueue, path: String) {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        let migrator = ProjectDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v33_negative_search_query_key_index")

        try dbQueue.write { db in
            // Legacy rows: `external_identifiers` column does not exist yet at
            // this point in the chain; only the v1 `external_ids` map exists.
            try db.execute(sql: """
                INSERT INTO profiles (id, external_ids, first_name, last_name, is_deleted)
                VALUES ('p-wt', '{"wikitree":"Smith-123"}', 'John', 'Smith', 0)
                """)
            try db.execute(sql: """
                INSERT INTO profiles (id, external_ids, first_name, last_name, is_deleted)
                VALUES ('p-empty', '{}', 'Jane', 'Doe', 0)
                """)
            try db.execute(sql: """
                INSERT INTO profiles (id, external_ids, first_name, last_name, is_deleted)
                VALUES ('p-multi', '{"wikitree":"Jones-9","gedcom":"@I7@"}', 'Amy', 'Jones', 0)
                """)
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
        #expect(applied.contains("v34_external_identifiers"))
        // v33 must still be part of the chain — v34 appends, never replaces.
        #expect(applied.contains("v33_negative_search_query_key_index"))
    }

    @Test func newColumnExistsAfterMigration() throws {
        let (dbQueue, _) = try makeMigratedDB()
        let hasColumn = try dbQueue.read { db in
            try db.columns(in: "profiles").contains { $0.name == "external_identifiers" }
        }
        #expect(hasColumn)
    }

    // MARK: Backfill (AC 4 — every entry converted losslessly)

    @Test func legacyWikitreeIdBackfillsAsPrimaryRecord() throws {
        let (dbQueue, _) = try makeMigratedDB()
        let json = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT external_identifiers FROM profiles WHERE id = 'p-wt'")
        }
        let records = try JSONDecoder().decode([ExternalIdentifier].self, from: Data((json ?? "[]").utf8))
        #expect(records.count == 1)
        #expect(records.first?.system == "wikitree")
        #expect(records.first?.value == "Smith-123")
        #expect(records.first?.kind == .primary)
    }

    @Test func emptyLegacyMapBackfillsToEmptyArray() throws {
        let (dbQueue, _) = try makeMigratedDB()
        let json = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT external_identifiers FROM profiles WHERE id = 'p-empty'")
        }
        let records = try JSONDecoder().decode([ExternalIdentifier].self, from: Data((json ?? "x").utf8))
        #expect(records.isEmpty)
    }

    @Test func multiSystemLegacyMapBackfillsAllEntries() throws {
        let (dbQueue, _) = try makeMigratedDB()
        let json = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT external_identifiers FROM profiles WHERE id = 'p-multi'")
        }
        let records = try JSONDecoder().decode([ExternalIdentifier].self, from: Data((json ?? "[]").utf8))
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.kind == .primary })
        #expect(records.contains { $0.system == "wikitree" && $0.value == "Jones-9" })
        #expect(records.contains { $0.system == "gedcom" && $0.value == "@I7@" })
    }

    @Test func legacyColumnFrozenInPlaceForRollback() throws {
        // The old external_ids column must still carry the original map (spec:
        // "the old column freezes in place for one release as rollback
        // insurance").
        let (dbQueue, _) = try makeMigratedDB()
        let legacy = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT external_ids FROM profiles WHERE id = 'p-wt'")
        }
        #expect(legacy == #"{"wikitree":"Smith-123"}"#)
    }

    // MARK: Persistence round-trip through ProjectDatabase (AC 4)

    @Test func legacyRowLoadsThroughPersistenceWithWikiTreeIDIntact() throws {
        let (_, path) = try makeMigratedDB()
        let db = try ProjectDatabase(path: path)
        let profile = try db.loadProfile(id: "p-wt")
        #expect(profile != nil)
        #expect(profile?.wikiTreeID == "Smith-123")
        #expect(profile?.externalIDs == ["wikitree": "Smith-123"])
        #expect(profile?.externalIdentifiers.count == 1)
        #expect(profile?.externalIdentifiers.first?.kind == .primary)
    }

    @Test func deprecatedIdentifierSurvivesFullPersistenceRoundTrip() throws {
        // Insert a profile carrying a deprecation chain, read it back, confirm
        // the chain resolves — proving the new column persists typed records
        // (not just the projected string map).
        let (_, path) = try makeMigratedDB()
        let db = try ProjectDatabase(path: path)

        let profile = Profile(
            id: "p-fs",
            externalIdentifiers: [
                ExternalIdentifier(system: "familysearch", value: "LZZZ-NEW", kind: .primary),
                ExternalIdentifier(system: "familysearch", value: "LYYY-OLD",
                                   kind: .deprecated, supersededBy: "LZZZ-NEW"),
            ],
            firstName: "Fred", lastName: "Search",
            isDeleted: false, sources: [:], disputes: [:])
        let snapshot = FamilyGraphSnapshot(profiles: ["p-fs": profile], relationships: [])
        _ = try db.importSnapshot(snapshot, source: "test")

        let loaded = try db.loadProfile(id: "p-fs")
        #expect(loaded?.externalIdentifiers.count == 2)
        // The deprecated value forwards to the survivor after a full DB round-trip.
        #expect(loaded?.externalIdentifiers.resolveCurrentValue(from: "LYYY-OLD", system: "familysearch") == "LZZZ-NEW")
        // The projection surfaces only the primary.
        #expect(loaded?.externalIDs["familysearch"] == "LZZZ-NEW")
        #expect(loaded?.externalIDs.count == 1)
    }
}
