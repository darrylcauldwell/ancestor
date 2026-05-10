import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

// Disambiguate from Swift Testing's own `Attachment` type.
private typealias Attachment = Ancestor_Research.Attachment

/// M14 §7.15.2 — `ProjectDatabase.hardDeleteProfile(id:)` cascades through
/// every table that references the profile. These tests build minimal data
/// fixtures, hard-delete, then verify each cascade target is empty for the
/// removed id.
struct HardDeleteTests {

    // MARK: - Helpers

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    /// Insert a minimal profile via `addProfile` so the migration-managed
    /// schema receives the row through the documented path. We then mark it
    /// deleted only when the test needs it; hard-delete works regardless of
    /// soft-delete state.
    @discardableResult
    private func insertProfile(_ db: ProjectDatabase, id: String = "P1") throws -> Profile {
        let profile = Profile(
            id: id,
            externalIDs: [:],
            firstName: "Test",
            lastName: "Person",
            gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "1900"),
            birthLocation: "Belper",
            deathDate: GenealogicalDate(parsing: "1970"),
            deathLocation: "Wirksworth",
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
        _ = try db.addProfile(profile, source: .manual)
        return profile
    }

    /// Count rows in a table matching a single-column predicate.
    private func countRows(
        _ db: ProjectDatabase, table: String, where clause: String, args: StatementArguments
    ) throws -> Int {
        try db.dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n FROM \(table) WHERE \(clause)", arguments: args)
            return row?["n"] ?? 0
        }
    }

    // MARK: - Tests

    @Test func hardDeletingProfileRemovesProfileRow() throws {
        let db = try makeTempDB()
        let profile = try insertProfile(db)
        // Soft-delete first to mirror the UI flow.
        _ = try db.softDeleteProfiles(ids: [profile.id])
        #expect((try db.loadDeletedProfiles()).contains(where: { $0.id == profile.id }))

        try db.hardDeleteProfile(id: profile.id)

        #expect(try !db.loadDeletedProfiles().contains { $0.id == profile.id })
        let snapshot = try db.buildSnapshot()
        #expect(snapshot.profiles[profile.id] == nil)
    }

    @Test func hardDeletingProfileRemovesLifeEvents() throws {
        let db = try makeTempDB()
        let profile = try insertProfile(db)
        let event = LifeEvent(
            id: UUID(), profileID: profile.id, type: .occupation,
            description: "Framework knitter"
        )
        try db.addLifeEvent(event)
        #expect(try db.loadLifeEvents(profileID: profile.id).count == 1)

        try db.hardDeleteProfile(id: profile.id)

        #expect(try db.loadLifeEvents(profileID: profile.id).isEmpty)
    }

    @Test func hardDeletingProfileRemovesFieldSources() throws {
        let db = try makeTempDB()
        let profile = try insertProfile(db)
        // addProfile inserts field sources for each non-nil profile field
        // through the manual source. Verify some exist before deletion.
        let countBefore = try countRows(
            db, table: "field_sources",
            where: "entity_id = ? AND entity_kind = 'profile'",
            args: [profile.id]
        )
        #expect(countBefore > 0)

        try db.hardDeleteProfile(id: profile.id)

        let countAfter = try countRows(
            db, table: "field_sources",
            where: "entity_id = ? AND entity_kind = 'profile'",
            args: [profile.id]
        )
        #expect(countAfter == 0)
    }

    @Test func hardDeletingProfileRemovesAttachments() throws {
        let db = try makeTempDB()
        let profile = try insertProfile(db)
        let direct = Attachment(
            id: UUID(), filename: "p.jpg", mediaType: .photo,
            caption: nil, dateTaken: nil, locationTaken: nil,
            relativePath: "p.jpg",
            attachedTo: .profile(id: profile.id),
            addedAt: Date()
        )
        let viaField = Attachment(
            id: UUID(), filename: "birth.pdf", mediaType: .document,
            caption: nil, dateTaken: nil, locationTaken: nil,
            relativePath: "birth.pdf",
            attachedTo: .fieldSource(entityID: profile.id, field: .birthDate),
            addedAt: Date()
        )
        try db.addAttachment(direct)
        try db.addAttachment(viaField)
        #expect(try db.loadAttachmentsForProfile(profile.id).count == 2)

        try db.hardDeleteProfile(id: profile.id)

        #expect(try db.loadAttachmentsForProfile(profile.id).isEmpty)
    }

    @Test func hardDeletingProfileRemovesProfileNotes() throws {
        let db = try makeTempDB()
        let profile = try insertProfile(db)
        let note = WorkbenchNote(
            id: UUID(), content: "Some note about this person",
            tag: .observation,
            attachedTo: .profile(id: profile.id),
            createdAt: Date(), updatedAt: Date()
        )
        try db.addNote(note)
        #expect(try db.loadNotes(attachedToKind: "profile", id: profile.id).count == 1)

        try db.hardDeleteProfile(id: profile.id)

        #expect(try db.loadNotes(attachedToKind: "profile", id: profile.id).isEmpty)
    }

    @Test func hardDeletingProfileRemovesRelationships() throws {
        let db = try makeTempDB()
        let parent = try insertProfile(db, id: "PARENT")
        let child = try insertProfile(db, id: "CHILD")
        let rel = Relationship(
            id: UUID(), from: parent.id, to: child.id,
            type: .parent, role: .father, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        _ = try db.addRelationship(rel)

        let countBefore = try countRows(
            db, table: "relationships",
            where: "from_id = ? OR to_id = ?",
            args: [child.id, child.id]
        )
        #expect(countBefore == 1)

        try db.hardDeleteProfile(id: child.id)

        let countAfter = try countRows(
            db, table: "relationships",
            where: "from_id = ? OR to_id = ?",
            args: [child.id, child.id]
        )
        #expect(countAfter == 0)
    }
}
