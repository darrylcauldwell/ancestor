import Foundation

/// Lightweight metadata about a single backup file. Identified by filename
/// — the filename embeds project ID and timestamp.
nonisolated struct BackupInfo: Identifiable, Sendable, Hashable {
    var id: String { fileURL.lastPathComponent }
    let fileURL: URL
    let createdAt: Date
    let sizeBytes: Int64
}

/// Per-project SQLite backup management. Per DESIGN.md §7.15.3:
///  - Snapshot the project SQLite on every successful open.
///  - Keep the 10 most recent (LRU trim).
///  - Detect corruption on open and surface a manual restore flow.
///
/// Backups live in `ProjectStore.backupsDirectory(for:)` and are named
/// `{projectID}-{ISO8601-with-no-colons}.sqlite`. Colons are stripped from
/// the timestamp because they are illegal on FAT/exFAT and can cause
/// problems for downstream tools.
nonisolated enum BackupService {
    /// Maximum number of backups retained per project. Older backups are
    /// trimmed in LRU fashion after each new snapshot.
    static let maxBackupsPerProject: Int = 10

    // MARK: - Snapshot

    /// Copy the project's SQLite file into the project's backups dir,
    /// timestamped. Trims oldest backups beyond `maxBackupsPerProject`.
    /// Idempotent across repeated calls within the same minute (the
    /// timestamp granularity is 1s, so calls within the same second
    /// overwrite the existing file).
    static func snapshotBackup(projectID: UUID) throws {
        let sqliteURL = ProjectStore.projectsDirectory
            .appendingPathComponent("\(projectID.uuidString).sqlite")
        guard FileManager.default.fileExists(atPath: sqliteURL.path) else {
            throw BackupError.sourceMissing
        }

        let backupsDir = ProjectStore.backupsDirectory(for: projectID)
        let timestamp = isoTimestamp(Date())
        let destURL = backupsDir
            .appendingPathComponent("\(projectID.uuidString)-\(timestamp).sqlite")

        // Idempotent: overwrite if a backup already exists at the same
        // second-resolution timestamp. copyItem does not overwrite, so
        // remove first.
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sqliteURL, to: destURL)

        trim(projectID: projectID)
    }

    // MARK: - Listing

    /// All backups for a project, newest first.
    static func backups(for projectID: UUID) -> [BackupInfo] {
        let dir = ProjectStore.backupsDirectory(for: projectID)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.pathExtension == "sqlite" }
            .compactMap { url -> BackupInfo? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let mtime = values?.contentModificationDate ?? Date.distantPast
                let size = Int64(values?.fileSize ?? 0)
                return BackupInfo(fileURL: url, createdAt: mtime, sizeBytes: size)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Restore

    /// Restore: replace the project's SQLite file with the named backup.
    /// Caller is responsible for re-opening the project afterward.
    static func restore(projectID: UUID, from backup: BackupInfo) throws {
        let sqliteURL = ProjectStore.projectsDirectory
            .appendingPathComponent("\(projectID.uuidString).sqlite")
        guard FileManager.default.fileExists(atPath: backup.fileURL.path) else {
            throw BackupError.backupMissing
        }
        // copyItem does not overwrite, so clear the live file first if
        // present. We do not snapshot the live file before overwriting —
        // the user explicitly chose to discard it via the Restore button.
        if FileManager.default.fileExists(atPath: sqliteURL.path) {
            try FileManager.default.removeItem(at: sqliteURL)
        }
        try FileManager.default.copyItem(at: backup.fileURL, to: sqliteURL)
    }

    // MARK: - Corruption detection

    /// Quick smoke check that a SQLite file is openable and has the
    /// expected schema. Returns true on success. Used by AppState to
    /// detect corruption before the user sees a cryptic GRDB error.
    static func isReadable(sqlitePath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: sqlitePath) else { return false }
        do {
            let db = try ProjectDatabase(path: sqlitePath)
            // loadProjectMeta will throw if the file is not a valid
            // SQLite database, or if migrations fail. A nil return
            // (no project_meta row) still means the file is structurally
            // OK — the caller's openProject will fail with a clean
            // "project not found" message rather than corruption.
            _ = try db.loadProjectMeta()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Internals

    /// LRU trim: keep `maxBackupsPerProject`, drop the oldest.
    private static func trim(projectID: UUID) {
        let all = backups(for: projectID) // newest first
        guard all.count > maxBackupsPerProject else { return }
        let toRemove = all.suffix(from: maxBackupsPerProject)
        for backup in toRemove {
            try? FileManager.default.removeItem(at: backup.fileURL)
        }
    }

    /// `2026-05-09T14-30-00Z` — colons stripped to dashes for FS safety.
    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}

nonisolated enum BackupError: LocalizedError {
    case sourceMissing
    case backupMissing

    var errorDescription: String? {
        switch self {
        case .sourceMissing: return "The project's database file is missing."
        case .backupMissing: return "The selected backup file is missing."
        }
    }
}
