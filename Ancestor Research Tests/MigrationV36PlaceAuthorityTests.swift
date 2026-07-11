import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// Migration tests for E3 v36 — the additive, nullable `place_authority_id`
/// landing-slot columns (MODEL_EVOLUTION_SPEC §Change3 / ADR-004 E3).
///
/// The migration is deliberately data-preserving-only: it adds columns and does
/// NOT migrate any stored `*_location_code` value (existing codes keep resolving
/// through the derived authority, AC3), so the assertions are (a) pre-existing
/// location data survives byte-for-byte and (b) the new columns exist and are
/// NULL. Same scratch-DB / migrate-upTo idiom as MigrationV34/V35.
struct MigrationV36PlaceAuthorityTests {

    /// Migrate a scratch DB to just before v36, seed legacy-shaped rows carrying
    /// location codes but no place_authority_id column, then complete the chain.
    private func makeMigratedDB() throws -> DatabaseQueue {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        let migrator = ProjectDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v35_name_forms")

        try dbQueue.write { db in
            // Profile with both a birth and death location code.
            try db.execute(sql: """
                INSERT INTO profiles
                    (id, external_ids, first_name, last_name, is_deleted,
                     birth_location, birth_location_code,
                     death_location, death_location_code)
                VALUES
                    ('p1', '{}', 'George', 'Brooks', 0,
                     'Belper, Derbyshire', 'DBY:Belper',
                     'Derby, Derbyshire', 'DBY:Derby')
                """)
            // A relationship with a marriage location code.
            try db.execute(sql: """
                INSERT INTO relationships
                    (id, from_id, to_id, type,
                     marriage_location, marriage_location_code)
                VALUES
                    ('r1', 'p1', 'p1', 'spouse',
                     'Crich, Derbyshire', 'DBY:Crich')
                """)
            // A life event with a location code.
            try db.execute(sql: """
                INSERT INTO life_events
                    (id, profile_id, type, location, location_code, sources_json)
                VALUES
                    ('e1', 'p1', 'residence', 'Buxton, Derbyshire', 'DBY:Buxton', '[]')
                """)
        }

        try migrator.migrate(dbQueue)
        return dbQueue
    }

    // MARK: - v36 appends to the chain (never replaces v34/v35)

    @Test func migrationRegistersV36AndKeepsPriorMigrations() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        try ProjectDatabase.makeMigrator().migrate(dbQueue)
        let applied = try dbQueue.read { db in
            try ProjectDatabase.makeMigrator().appliedIdentifiers(db)
        }
        #expect(applied.contains("v36_place_authority_id"))
        #expect(applied.contains("v35_name_forms"))
        #expect(applied.contains("v34_external_identifiers"))
    }

    // MARK: - New columns exist and default NULL

    @Test func profileGainsTwoNullablePlaceAuthorityColumns() throws {
        let dbQueue = try makeMigratedDB()
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT birth_place_authority_id, death_place_authority_id
                FROM profiles WHERE id = 'p1'
                """)
            #expect(row != nil)
            #expect((row?["birth_place_authority_id"] as String?) == nil)
            #expect((row?["death_place_authority_id"] as String?) == nil)
        }
    }

    @Test func relationshipGainsNullablePlaceAuthorityColumn() throws {
        let dbQueue = try makeMigratedDB()
        try dbQueue.read { db in
            let v = try String.fetchOne(db, sql: """
                SELECT marriage_place_authority_id FROM relationships WHERE id = 'r1'
                """)
            #expect(v == nil)
        }
    }

    @Test func lifeEventGainsNullablePlaceAuthorityColumn() throws {
        let dbQueue = try makeMigratedDB()
        try dbQueue.read { db in
            let v = try String.fetchOne(db, sql: """
                SELECT place_authority_id FROM life_events WHERE id = 'e1'
                """)
            #expect(v == nil)
        }
    }

    // MARK: - AC3 — existing location codes survive losslessly (no code migration)

    @Test func existingLocationCodesAreUnchangedAfterMigration() throws {
        let dbQueue = try makeMigratedDB()
        try dbQueue.read { db in
            let p = try Row.fetchOne(db, sql: """
                SELECT birth_location, birth_location_code,
                       death_location, death_location_code
                FROM profiles WHERE id = 'p1'
                """)
            #expect((p?["birth_location"] as String?) == "Belper, Derbyshire")
            #expect((p?["birth_location_code"] as String?) == "DBY:Belper")
            #expect((p?["death_location"] as String?) == "Derby, Derbyshire")
            #expect((p?["death_location_code"] as String?) == "DBY:Derby")

            let mCode = try String.fetchOne(db, sql:
                "SELECT marriage_location_code FROM relationships WHERE id = 'r1'")
            #expect(mCode == "DBY:Crich")

            let eCode = try String.fetchOne(db, sql:
                "SELECT location_code FROM life_events WHERE id = 'e1'")
            #expect(eCode == "DBY:Buxton")
        }
    }

    // MARK: - Full chain completes (v36 is the current head)

    @Test func fullMigrationChainReachesV36() throws {
        // A fresh DB migrated all the way must include v36; profiles table has
        // the new columns.
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        try ProjectDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.read { db in
            let hasColumn = try db.columns(in: "profiles")
                .contains { $0.name == "birth_place_authority_id" }
            #expect(hasColumn)
        }
    }

    // MARK: - The stored codes still resolve through the derived authority
    // after migration (AC3 end-to-end: no code migration, same county answer).

    @Test func storedCodesStillResolveToTheirCountyPostMigration() throws {
        _ = try makeMigratedDB() // migration ran; codes are unchanged strings.
        // The authority derivation is runtime, from bundled seed data, so the
        // county a stored code resolves to is independent of the DB row — this
        // asserts the E3 promise that DBY:Belper etc. still roll up to
        // Derbyshire without any stored-code migration.
        let gaz = LocationGazetteer.shared
        #expect(gaz.countyName(forCode: "DBY:Belper") == "Derbyshire")
        #expect(gaz.chapmanCode(forCode: "DBY:Crich") == "DBY")
    }
}
