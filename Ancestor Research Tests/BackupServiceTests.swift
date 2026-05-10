import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for `BackupService` (M14 / DESIGN.md §7.15.3).
///
/// These tests pollute `ProjectStore.projectsDirectory` (Application Support)
/// with throwaway projects. Each test cleans up the project IDs it creates.
/// Run serialized so concurrent migrations on freshly-created sqlite files
/// don't trip GRDB's connection pool.
@Suite(.serialized)
struct BackupServiceTests {

    // MARK: - Fixtures

    private func makeProfile(id: String, firstName: String) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: "Tester",
            gender: .male,
            attributes: nil,
            birthDate: nil,
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [.firstName: [FieldSource(origin: .manualMemory, raw: firstName, addedAt: Date())]],
            disputes: [:]
        )
    }

    /// Spin up a real project on disk and return its ID. Caller must
    /// invoke `cleanup(_:)` to remove it.
    private func makeRealProject(name: String, profileCount: Int = 1) throws -> UUID {
        let (project, db) = try ProjectStore.createProject(name: name, source: .manual)
        if profileCount > 0 {
            let profiles = (0..<profileCount).map {
                makeProfile(id: "p\($0)", firstName: "Person\($0)")
            }
            try db.addFamily(profiles: profiles, relationships: [], source: .manualMemory)
        }
        return project.id
    }

    private func cleanup(_ ids: [UUID]) {
        for id in ids {
            try? ProjectStore.deleteProject(id)
        }
    }

    /// Open the project SQLite directly and return its profile count. Used
    /// to verify that restore actually replaced the live file.
    private func profileCount(projectID: UUID) throws -> Int {
        let (_, db) = try ProjectStore.openProject(projectID)
        return try db.buildSnapshot().profiles.count
    }

    // MARK: - Tests

    @Test func snapshotBackupCreatesFile() throws {
        let id = try makeRealProject(name: "Backup Smoke")
        defer { cleanup([id]) }

        try BackupService.snapshotBackup(projectID: id)

        let backups = BackupService.backups(for: id)
        #expect(backups.count == 1)
        #expect(backups.first?.sizeBytes ?? 0 > 0)
    }

    @Test func repeatedSnapshotsTrimToTen() throws {
        let id = try makeRealProject(name: "Backup Trim")
        defer { cleanup([id]) }

        // Manually drop 12 distinct backup files into the dir, each with a
        // unique mtime so the trim has stable ordering. Going through
        // snapshotBackup would race against second-resolution timestamps.
        let backupsDir = ProjectStore.backupsDirectory(for: id)
        let sourceURL = ProjectStore.projectsDirectory
            .appendingPathComponent("\(id.uuidString).sqlite")
        let now = Date()
        for i in 0..<12 {
            let dest = backupsDir.appendingPathComponent("\(id.uuidString)-fake\(i).sqlite")
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            // Distinct mtimes — one second apart, oldest first.
            let mtime = now.addingTimeInterval(TimeInterval(i))
            try FileManager.default.setAttributes(
                [.modificationDate: mtime],
                ofItemAtPath: dest.path
            )
        }

        // Sanity: 12 files now exist.
        #expect(BackupService.backups(for: id).count == 12)

        // One more snapshotBackup call triggers the trim.
        try BackupService.snapshotBackup(projectID: id)

        let final = BackupService.backups(for: id)
        #expect(final.count == BackupService.maxBackupsPerProject)
        #expect(final.count == 10)
    }

    @Test func backupsReturnsNewestFirst() throws {
        let id = try makeRealProject(name: "Backup Order")
        defer { cleanup([id]) }

        let backupsDir = ProjectStore.backupsDirectory(for: id)
        let sourceURL = ProjectStore.projectsDirectory
            .appendingPathComponent("\(id.uuidString).sqlite")

        let times: [TimeInterval] = [-300, -200, -100]
        for (i, offset) in times.enumerated() {
            let dest = backupsDir.appendingPathComponent("\(id.uuidString)-order\(i).sqlite")
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(offset)],
                ofItemAtPath: dest.path
            )
        }

        let backups = BackupService.backups(for: id)
        #expect(backups.count == 3)
        // Newest first — the one with offset -100 should sort before -300.
        #expect(backups[0].createdAt > backups[1].createdAt)
        #expect(backups[1].createdAt > backups[2].createdAt)
    }

    @Test func restoreReplacesProjectFile() throws {
        let id = try makeRealProject(name: "Backup Restore", profileCount: 1)
        defer { cleanup([id]) }

        // Snapshot at the 1-profile state.
        try BackupService.snapshotBackup(projectID: id)
        let backup = BackupService.backups(for: id).first
        #expect(backup != nil)

        // Mutate: add a second profile.
        let (_, db) = try ProjectStore.openProject(id)
        try db.addFamily(
            profiles: [makeProfile(id: "p_extra", firstName: "Extra")],
            relationships: [],
            source: .manualMemory
        )
        // Drop the connection so GRDB releases the file before we
        // overwrite it.
        _ = db
        #expect(try profileCount(projectID: id) == 2)

        // Restore should drop us back to 1 profile.
        try BackupService.restore(projectID: id, from: backup!)
        #expect(try profileCount(projectID: id) == 1)
    }

    @Test func isReadableReturnsFalseForCorruptedFile() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backup-corrupt-\(UUID().uuidString).sqlite")
        // 100 bytes of garbage that don't form a valid SQLite header.
        let garbage = Data(repeating: 0xAB, count: 100)
        try garbage.write(to: tmpDir)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(BackupService.isReadable(sqlitePath: tmpDir.path) == false)
    }

    @Test func isReadableReturnsTrueForValidProject() throws {
        let id = try makeRealProject(name: "Backup Valid")
        defer { cleanup([id]) }

        let path = ProjectStore.projectsDirectory
            .appendingPathComponent("\(id.uuidString).sqlite").path
        #expect(BackupService.isReadable(sqlitePath: path) == true)
    }

    @Test func isReadableReturnsFalseForMissingFile() {
        let bogus = NSTemporaryDirectory() + "does-not-exist-\(UUID().uuidString).sqlite"
        #expect(BackupService.isReadable(sqlitePath: bogus) == false)
    }
}
