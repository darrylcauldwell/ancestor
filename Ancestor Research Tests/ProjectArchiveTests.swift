import Testing
import Foundation
@testable import Ancestor_Research

// Disambiguate from Swift Testing's own `Attachment` type.
private typealias Attachment = Ancestor_Research.Attachment

/// Tests for the `.ancestor` archive round-trip (M13 / DESIGN.md §5.15).
/// The archive bundles a project's SQLite file plus its media + thumbnail
/// directories into a zip, then unpacks it back into a fresh project on
/// import. These tests share the global `ProjectStore.projectsDirectory`
/// (Application Support); we run them serially so concurrent migrations
/// on a freshly-created sqlite file don't trip over GRDB's connection
/// pool. Each test cleans up the project IDs it created.
@Suite(.serialized)
struct ProjectArchiveTests {

    // MARK: - Fixtures

    private func makeProfile(id: String, firstName: String, lastName: String) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: lastName,
            gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "1890"),
            birthLocation: "Belper",
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [.firstName: [FieldSource(origin: .manualMemory, raw: firstName, addedAt: Date())]],
            disputes: [:]
        )
    }

    /// Spin up a real project in `ProjectStore.projectsDirectory` so the
    /// archive code's path-derivation logic runs end-to-end. Returns the
    /// project's ID — the caller is responsible for cleaning up via
    /// `ProjectStore.deleteProject` (which we wrap in `cleanup(_:)`).
    private func makeRealProject(name: String, profiles: [Profile]) throws -> UUID {
        let (project, db) = try ProjectStore.createProject(name: name, source: .manual)
        if !profiles.isEmpty {
            try db.addFamily(profiles: profiles, relationships: [], source: .manualMemory)
        }
        return project.id
    }

    /// Best-effort cleanup so we don't leave stale projects in the user's
    /// Application Support directory between test runs.
    private func cleanup(_ ids: [UUID]) {
        for id in ids {
            try? ProjectStore.deleteProject(id)
        }
    }

    private func makeArchiveURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archive-\(UUID().uuidString).ancestor")
    }

    // MARK: - Tests

    @Test func archiveExportProducesNonEmptyFile() throws {
        let id = try makeRealProject(
            name: "Archive Smoke",
            profiles: [makeProfile(id: "p1", firstName: "Alice", lastName: "Adams")]
        )
        defer { cleanup([id]) }

        let dest = makeArchiveURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        try ProjectArchive.export(projectID: id, to: dest)

        #expect(FileManager.default.fileExists(atPath: dest.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        #expect(size > 100)
    }

    @Test func archiveRoundTripPreservesProfiles() throws {
        let original = try makeRealProject(
            name: "Archive Round Trip",
            profiles: [
                makeProfile(id: "p1", firstName: "Alice", lastName: "Adams"),
                makeProfile(id: "p2", firstName: "Bob", lastName: "Brown"),
            ]
        )
        let dest = makeArchiveURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        try ProjectArchive.export(projectID: original, to: dest)
        let imported = try ProjectArchive.importArchive(from: dest)
        defer { cleanup([original, imported]) }

        let (_, db) = try ProjectStore.openProject(imported)
        let snapshot = try db.buildSnapshot()
        #expect(snapshot.profiles.count == 2)
        #expect(snapshot.profiles["p1"]?.firstName == "Alice")
        #expect(snapshot.profiles["p2"]?.firstName == "Bob")
    }

    @Test func importingArchiveCreatesNewProjectID() throws {
        let original = try makeRealProject(
            name: "Archive ID Differs",
            profiles: [makeProfile(id: "p1", firstName: "Carol", lastName: "Clark")]
        )
        let dest = makeArchiveURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        try ProjectArchive.export(projectID: original, to: dest)
        let imported = try ProjectArchive.importArchive(from: dest)
        defer { cleanup([original, imported]) }

        #expect(imported != original)
    }

    @Test func archiveRoundTripPreservesAttachments() throws {
        // Add a real on-disk media file + an attachment row, export, then
        // import — the unpacked project should see both the row and the file.
        let id = try makeRealProject(
            name: "Archive Attachments",
            profiles: [makeProfile(id: "p1", firstName: "Dora", lastName: "Davis")]
        )
        let mediaDir = ProjectStore.mediaDirectory(for: id)
        let mediaFile = mediaDir.appendingPathComponent("dora.txt")
        try "hello".data(using: .utf8)!.write(to: mediaFile)

        let (_, db) = try ProjectStore.openProject(id)
        let attachment = Attachment(
            id: UUID(),
            filename: "dora.txt",
            mediaType: .transcription,
            caption: "Note",
            dateTaken: nil,
            locationTaken: nil,
            relativePath: "dora.txt",
            attachedTo: .profile(id: "p1"),
            addedAt: Date()
        )
        try db.addAttachment(attachment)

        let dest = makeArchiveURL()
        defer { try? FileManager.default.removeItem(at: dest) }

        try ProjectArchive.export(projectID: id, to: dest)
        let imported = try ProjectArchive.importArchive(from: dest)
        defer { cleanup([id, imported]) }

        // Attachment row survived.
        let (_, importedDB) = try ProjectStore.openProject(imported)
        let attachments = try importedDB.loadAttachments()
        #expect(attachments.count == 1)
        #expect(attachments.first?.filename == "dora.txt")

        // Underlying media file survived.
        let importedMedia = ProjectStore.mediaDirectory(for: imported)
            .appendingPathComponent("dora.txt")
        #expect(FileManager.default.fileExists(atPath: importedMedia.path))
    }
}
