import Testing
import Foundation
@testable import Ancestor_Research

// Disambiguate from Swift Testing's own `Attachment` type.
private typealias Attachment = Ancestor_Research.Attachment

/// M14 §7.15.2 — sensitive flag round-trip + GEDCOM export filter.
struct SensitiveFlagTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeProfile(id: String = "P1") -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: "Test",
            lastName: "Person",
            gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "1900"),
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    // MARK: - Defaults

    @Test func noteSensitiveDefaultsFalse() {
        let note = WorkbenchNote(
            id: UUID(), content: "test", tag: .observation,
            attachedTo: .project, createdAt: Date(), updatedAt: Date()
        )
        #expect(note.sensitive == false)
    }

    @Test func lifeEventSensitiveDefaultsFalse() {
        let event = LifeEvent(
            id: UUID(), profileID: "P1", type: .occupation
        )
        #expect(event.sensitive == false)
    }

    // MARK: - Round trip

    @Test func noteRoundTripsSensitive() throws {
        let db = try makeTempDB()

        let sensitiveNote = WorkbenchNote(
            id: UUID(), content: "private detail", tag: .observation,
            attachedTo: .project, createdAt: Date(), updatedAt: Date(),
            sensitive: true
        )
        try db.addNote(sensitiveNote)

        let publicNote = WorkbenchNote(
            id: UUID(), content: "public observation", tag: .observation,
            attachedTo: .project, createdAt: Date(), updatedAt: Date(),
            sensitive: false
        )
        try db.addNote(publicNote)

        let loaded = try db.loadNotes()
        let loadedSensitive = loaded.first { $0.id == sensitiveNote.id }
        let loadedPublic = loaded.first { $0.id == publicNote.id }

        #expect(loadedSensitive?.sensitive == true)
        #expect(loadedPublic?.sensitive == false)
    }

    @Test func lifeEventRoundTripsSensitive() throws {
        let db = try makeTempDB()

        let sensitive = LifeEvent(
            id: UUID(), profileID: "P1", type: .occupation,
            description: "Sensitive employment",
            sensitive: true
        )
        try db.addLifeEvent(sensitive)

        let standard = LifeEvent(
            id: UUID(), profileID: "P1", type: .residence,
            location: "Belper",
            sensitive: false
        )
        try db.addLifeEvent(standard)

        let loaded = try db.loadLifeEvents(profileID: "P1")
        let loadedSensitive = loaded.first { $0.id == sensitive.id }
        let loadedStandard = loaded.first { $0.id == standard.id }

        #expect(loadedSensitive?.sensitive == true)
        #expect(loadedStandard?.sensitive == false)
    }

    // MARK: - Update toggles sensitive

    @Test func updatingNoteFlipsSensitive() throws {
        let db = try makeTempDB()
        let note = WorkbenchNote(
            id: UUID(), content: "starts public", tag: .observation,
            attachedTo: .project, createdAt: Date(), updatedAt: Date(),
            sensitive: false
        )
        try db.addNote(note)

        var updated = note
        updated.sensitive = true
        try db.updateNote(updated)

        let loaded = try db.loadNotes()
        #expect(loaded.first { $0.id == note.id }?.sensitive == true)
    }

    @Test func updatingLifeEventFlipsSensitive() throws {
        let db = try makeTempDB()
        let event = LifeEvent(
            id: UUID(), profileID: "P1", type: .occupation,
            description: "starts public",
            sensitive: false
        )
        try db.addLifeEvent(event)

        var updated = event
        updated.sensitive = true
        try db.updateLifeEvent(updated)

        let loaded = try db.loadLifeEvents(profileID: "P1")
        #expect(loaded.first { $0.id == event.id }?.sensitive == true)
    }

    // MARK: - GEDCOM export filter

    @Test func gedcomExporterRespectsExcludeSensitiveForLifeEventAttachments() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )

        let sensitiveEvent = LifeEvent(
            id: UUID(), profileID: profile.id, type: .occupation,
            description: "Hidden detail",
            sensitive: true
        )
        let attachment = Attachment(
            id: UUID(), filename: "scan.jpg", mediaType: .photo,
            caption: "Sensitive scan", dateTaken: nil, locationTaken: nil,
            relativePath: "scans/sensitive.jpg",
            attachedTo: .lifeEvent(id: sensitiveEvent.id),
            addedAt: Date()
        )

        // excludeSensitive = false → OBJE present (attachment routes through life event)
        let openExport = GEDCOMExporter.export(
            snapshot,
            attachments: [attachment],
            lifeEvents: [sensitiveEvent],
            excludeSensitive: false
        ).content
        #expect(openExport.contains("2 FILE media/scans/sensitive.jpg"),
                "Without sensitive filter, OBJE for life-event attachment should appear")

        // excludeSensitive = true → OBJE dropped
        let filteredExport = GEDCOMExporter.export(
            snapshot,
            attachments: [attachment],
            lifeEvents: [sensitiveEvent],
            excludeSensitive: true
        ).content
        #expect(!filteredExport.contains("2 FILE media/scans/sensitive.jpg"),
                "With sensitive filter, OBJE for sensitive life-event attachment must be omitted")
    }

    @Test func gedcomExporterKeepsNonSensitiveLifeEventAttachmentsWhenFiltering() {
        let profile = makeProfile()
        let snapshot = FamilyGraphSnapshot(
            profiles: [profile.id: profile],
            relationships: []
        )

        let openEvent = LifeEvent(
            id: UUID(), profileID: profile.id, type: .occupation,
            description: "Routine",
            sensitive: false
        )
        let attachment = Attachment(
            id: UUID(), filename: "scan.jpg", mediaType: .photo,
            caption: "Routine scan", dateTaken: nil, locationTaken: nil,
            relativePath: "scans/routine.jpg",
            attachedTo: .lifeEvent(id: openEvent.id),
            addedAt: Date()
        )

        let filteredExport = GEDCOMExporter.export(
            snapshot,
            attachments: [attachment],
            lifeEvents: [openEvent],
            excludeSensitive: true
        ).content
        #expect(filteredExport.contains("2 FILE media/scans/routine.jpg"),
                "Non-sensitive life-event attachments must survive the sensitive filter")
    }
}
