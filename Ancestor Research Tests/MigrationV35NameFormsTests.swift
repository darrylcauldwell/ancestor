import Testing
import Foundation
import GRDB
@testable import AncestorKit
@testable import Ancestor_Research

/// Pins migration `v35_name_forms` (MODEL_EVOLUTION_SPEC §Change2 / ADR-004 E2 —
/// typed repeatable name forms).
///
/// Two things ship together and must both be proven:
///   • the new `name_forms` JSON column on `profiles`;
///   • the backfill that derives a `.birth` form (and, where a distinct married
///     surname exists, a `.married` form) from every existing row's flat name
///     columns, losslessly — so a legacy profile's variants are captured while
///     the flat search keys and `displayName` are untouched.
///
/// Test shape mirrors `MigrationV34ExternalIdentifiersTests`: migrate a scratch
/// DB `upTo:` the prior tail (v34), seed legacy-shaped profile rows carrying
/// only flat name columns, complete the chain so v35 runs against seeded data
/// exactly as it will against real DBs, then assert the backfill and a
/// persistence round-trip.
nonisolated struct MigrationV35NameFormsTests {

    private func makeMigratedDB() throws -> (dbQueue: DatabaseQueue, path: String) {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        let migrator = ProjectDatabase.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v34_external_identifiers")

        try dbQueue.write { db in
            // Legacy rows: `name_forms` column does not exist yet at this point.
            // A married woman (maiden Land, married Brooks).
            try db.execute(sql: """
                INSERT INTO profiles (id, external_ids, first_name, last_name, married_surname, is_deleted)
                VALUES ('p-married', '{}', 'Grace', 'Land', 'Brooks', 0)
                """)
            // A birth-name-only person (no married surname).
            try db.execute(sql: """
                INSERT INTO profiles (id, external_ids, first_name, middle_name, last_name, is_deleted)
                VALUES ('p-birth', '{}', 'John', 'Robert', 'Smith', 0)
                """)
            // A person with no name parts at all → empty list.
            try db.execute(sql: """
                INSERT INTO profiles (id, external_ids, is_deleted)
                VALUES ('p-nameless', '{}', 0)
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
        #expect(applied.contains("v35_name_forms"))
        // v34 must still be part of the chain — v35 appends, never replaces.
        #expect(applied.contains("v34_external_identifiers"))
    }

    @Test func newColumnExistsAfterMigration() throws {
        let (dbQueue, _) = try makeMigratedDB()
        let hasColumn = try dbQueue.read { db in
            try db.columns(in: "profiles").contains { $0.name == "name_forms" }
        }
        #expect(hasColumn)
    }

    // MARK: Backfill (AC 2 / AC 3 — lossless, flat fields unchanged)

    @Test func marriedWomanBackfillsBirthAndMarriedForms() throws {
        let (dbQueue, _) = try makeMigratedDB()
        let json = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT name_forms FROM profiles WHERE id = 'p-married'")
        }
        let forms = try JSONDecoder().decode([NameForm].self, from: Data((json ?? "[]").utf8))
        #expect(forms.count == 2)
        #expect(forms.contains { $0.type == .birth && $0.surname == "Land" })
        #expect(forms.contains { $0.type == .married && $0.surname == "Brooks" })
    }

    @Test func birthOnlyPersonBackfillsSingleBirthForm() throws {
        let (dbQueue, _) = try makeMigratedDB()
        let json = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT name_forms FROM profiles WHERE id = 'p-birth'")
        }
        let forms = try JSONDecoder().decode([NameForm].self, from: Data((json ?? "[]").utf8))
        #expect(forms.count == 1)
        #expect(forms.first?.type == .birth)
        #expect(forms.first?.given == "John Robert")
        #expect(forms.first?.surname == "Smith")
    }

    @Test func namelessPersonBackfillsEmptyArray() throws {
        let (dbQueue, _) = try makeMigratedDB()
        let json = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT name_forms FROM profiles WHERE id = 'p-nameless'")
        }
        let forms = try JSONDecoder().decode([NameForm].self, from: Data((json ?? "x").utf8))
        #expect(forms.isEmpty)
    }

    @Test func backfillLeavesFlatNameColumnsUntouched() throws {
        // The flat search keys — the deterministic engine's inputs — must be
        // byte-for-byte what they were before the migration.
        let (dbQueue, _) = try makeMigratedDB()
        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT first_name, last_name, married_surname FROM profiles WHERE id = 'p-married'
                """)
        }
        #expect(row?["first_name"] == "Grace")
        #expect(row?["last_name"] == "Land")
        #expect(row?["married_surname"] == "Brooks")
    }

    // MARK: Persistence round-trip through ProjectDatabase (AC 2)

    @Test func legacyRowLoadsThroughPersistenceWithFormsAndUnchangedProjections() throws {
        let (_, path) = try makeMigratedDB()
        let db = try ProjectDatabase(path: path)
        let profile = try db.loadProfile(id: "p-married")
        #expect(profile != nil)
        // Forms materialised from the flat fields.
        #expect(profile?.nameForms.count == 2)
        #expect(profile?.nameForms.contains { $0.type == .married && $0.surname == "Brooks" } == true)
        // Projections identical to a pure flat-field profile.
        #expect(profile?.displayName == "Grace Land")
        #expect(profile?.lastName == "Land")
        #expect(profile?.marriedSurname == "Brooks")
    }

    @Test func explicitNameFormsSurviveFullPersistenceRoundTrip() throws {
        // Insert a profile carrying two married forms (a twice-married woman),
        // read it back, confirm both survive and the flat winner is intact.
        let (_, path) = try makeMigratedDB()
        let db = try ProjectDatabase(path: path)

        let profile = Profile(
            id: "p-twice", firstName: "Eleanor", lastName: "Vaughan",
            marriedSurname: "Whitfield",
            nameForms: [
                NameForm(type: .birth, fullText: "Eleanor Vaughan", surname: "Vaughan"),
                NameForm(type: .married, fullText: "Eleanor Ashby", surname: "Ashby"),
                NameForm(type: .married, fullText: "Eleanor Whitfield", surname: "Whitfield"),
            ],
            isDeleted: false, sources: [:], disputes: [:])
        let snapshot = FamilyGraphSnapshot(profiles: ["p-twice": profile], relationships: [])
        _ = try db.importSnapshot(snapshot, source: "test")

        let loaded = try db.loadProfile(id: "p-twice")
        #expect(loaded?.nameForms.filter { $0.type == .married }.count == 2)
        #expect(loaded?.nameForms.marriedSurnames.sorted() == ["Ashby", "Whitfield"])
        // Flat married-surname search key unchanged after a DB round-trip.
        #expect(loaded?.marriedSurname == "Whitfield")
        #expect(loaded?.displayName == "Eleanor Vaughan")
    }
}
