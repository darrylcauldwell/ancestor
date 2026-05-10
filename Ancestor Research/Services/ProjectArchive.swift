import Foundation

/// `.ancestor` project archive — a zip containing the project's SQLite file
/// plus its `media/` and `thumbnails/` directories. Per DESIGN.md §5.15
/// this is the lossless export format: it preserves every attachment,
/// thumbnail, and DB row in a single user-portable file.
///
/// Implementation note: we shell out to `/usr/bin/zip` and `/usr/bin/unzip`.
/// Those binaries are present on every macOS install and `Process` can
/// invoke them even from a sandboxed app provided the file paths it operates
/// on are inside the sandbox container — which they are here, since
/// staging happens in `NSTemporaryDirectory()` and the destination URL
/// is reached via the user-granted `.fileExporter` / `.fileImporter` flow.
nonisolated enum ProjectArchive {

    /// Bundle a project (sqlite + media + thumbnails) into a `.ancestor`
    /// zip archive at `destinationURL`. Overwrites any existing file at
    /// that location.
    static func export(projectID: UUID, to destinationURL: URL) throws {
        let fm = FileManager.default
        let sqliteURL = ProjectStore.projectsDirectory
            .appendingPathComponent("\(projectID.uuidString).sqlite")
        guard fm.fileExists(atPath: sqliteURL.path) else {
            throw ProjectArchiveError.missingDatabaseInArchive
        }

        // Stage everything in a temp directory so the archive's internal
        // paths are relative — `project.sqlite`, `media/...`,
        // `thumbnails/...` — rather than absolute Application Support paths.
        let staging = NSTemporaryDirectory().appending("ancestor-export-\(UUID().uuidString)")
        let stagingURL = URL(fileURLWithPath: staging, isDirectory: true)
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingURL) }

        // Copy the database under a stable name. The importer recognises
        // `project.sqlite` regardless of the original UUID-based filename.
        try fm.copyItem(at: sqliteURL, to: stagingURL.appendingPathComponent("project.sqlite"))

        // Copy media and thumbnails when present. The directories are
        // lazily created by ProjectStore — copy only if they actually
        // contain something so an empty project produces a smaller archive.
        let mediaSrc = ProjectStore.mediaDirectory(for: projectID)
        if let entries = try? fm.contentsOfDirectory(atPath: mediaSrc.path), !entries.isEmpty {
            try fm.copyItem(at: mediaSrc, to: stagingURL.appendingPathComponent("media"))
        }
        let thumbsSrc = ProjectStore.thumbnailsDirectory(for: projectID)
        if let entries = try? fm.contentsOfDirectory(atPath: thumbsSrc.path), !entries.isEmpty {
            try fm.copyItem(at: thumbsSrc, to: stagingURL.appendingPathComponent("thumbnails"))
        }

        // Make sure the target slot is empty — `zip` would otherwise update
        // an existing archive in place rather than replace it.
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }

        // Run `/usr/bin/zip -r <dest> .` from the staging dir.
        try runZip(stagingURL: stagingURL, destinationURL: destinationURL)
    }

    /// Unzip a `.ancestor` archive into a fresh project. Generates a new
    /// project ID, places the SQLite file at
    /// `projectsDirectory/{newID}.sqlite`, and moves the bundled media +
    /// thumbnails into the new per-project subdirectories. Returns the
    /// newly-created project ID — the caller is expected to refresh the
    /// project list and (if desired) open the project.
    @discardableResult
    static func importArchive(from sourceURL: URL) throws -> UUID {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw ProjectArchiveError.archiveCommandFailed("Source archive does not exist")
        }

        let staging = NSTemporaryDirectory().appending("ancestor-import-\(UUID().uuidString)")
        let stagingURL = URL(fileURLWithPath: staging, isDirectory: true)
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingURL) }

        try runUnzip(archiveURL: sourceURL, destinationURL: stagingURL)

        // Validate the layout. Some archives may unpack with their content
        // nested one level deep (e.g. when the archive was created as
        // `zip -r foo.ancestor projectFolder/`). Detect that and recurse.
        let dbCandidate = stagingURL.appendingPathComponent("project.sqlite")
        let resolvedRoot: URL
        if fm.fileExists(atPath: dbCandidate.path) {
            resolvedRoot = stagingURL
        } else if let nested = try? findNestedRoot(in: stagingURL) {
            resolvedRoot = nested
        } else {
            throw ProjectArchiveError.missingDatabaseInArchive
        }

        let newID = UUID()
        let destSqlite = ProjectStore.projectsDirectory
            .appendingPathComponent("\(newID.uuidString).sqlite")
        // Ensure destination directory exists. `projectsDirectory` lazily
        // creates itself, but be defensive.
        try fm.createDirectory(
            at: ProjectStore.projectsDirectory,
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destSqlite.path) {
            try fm.removeItem(at: destSqlite)
        }
        try fm.copyItem(at: resolvedRoot.appendingPathComponent("project.sqlite"), to: destSqlite)

        // Open + rewrite the project meta with the new ID so the file's
        // record matches its filename. Without this, listProjects would
        // surface the original UUID and openProject(newID) would fail.
        let db = try ProjectDatabase(path: destSqlite.path)
        if let existing = try db.loadProjectMeta() {
            let renamed = Project(
                id: newID,
                name: existing.name,
                source: existing.source,
                homePersonID: existing.homePersonID,
                createdAt: existing.createdAt,
                lastRefreshed: existing.lastRefreshed
            )
            try db.saveProjectMeta(renamed)
        } else {
            // Brand-new project record so listProjects can find it.
            let placeholder = Project(
                id: newID,
                name: "Imported Archive",
                source: .manual,
                homePersonID: nil,
                createdAt: Date(),
                lastRefreshed: nil
            )
            try db.saveProjectMeta(placeholder)
        }

        // Move media + thumbnails into the per-project sub-dirs.
        let mediaSrc = resolvedRoot.appendingPathComponent("media")
        if fm.fileExists(atPath: mediaSrc.path) {
            let mediaDest = ProjectStore.mediaDirectory(for: newID)
            try mergeDirectory(from: mediaSrc, into: mediaDest, fm: fm)
        }
        let thumbsSrc = resolvedRoot.appendingPathComponent("thumbnails")
        if fm.fileExists(atPath: thumbsSrc.path) {
            let thumbsDest = ProjectStore.thumbnailsDirectory(for: newID)
            try mergeDirectory(from: thumbsSrc, into: thumbsDest, fm: fm)
        }

        return newID
    }

    // MARK: - Internals

    /// Walk one level down in case the archive nests its content inside
    /// a single sub-directory (a common zip convention).
    private static func findNestedRoot(in stagingURL: URL) throws -> URL? {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: [.isDirectoryKey])
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if fm.fileExists(atPath: entry.appendingPathComponent("project.sqlite").path) {
                return entry
            }
        }
        return nil
    }

    /// Move every file from `source` into `destination`, creating the
    /// destination directory if needed. Preserves the relative tree under
    /// `source`, overwriting same-named entries in `destination`.
    private static func mergeDirectory(from source: URL, into destination: URL, fm: FileManager) throws {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: entry, to: target)
        }
    }

    private static func runZip(stagingURL: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -r recurse, -q quiet. Working directory is the staging dir so
        // entries go in with relative paths.
        process.arguments = ["-r", "-q", destinationURL.path, "."]
        process.currentDirectoryURL = stagingURL
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()  // discard
        do {
            try process.run()
        } catch {
            throw ProjectArchiveError.archiveCommandFailed("Failed to launch zip: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw ProjectArchiveError.archiveCommandFailed("zip exited \(process.terminationStatus): \(message)")
        }

        // A "successful" zip with no entries (empty staging) leaves no file —
        // surface that as a clear error rather than letting the caller
        // discover an absent archive later.
        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            throw ProjectArchiveError.emptyArchive
        }
    }

    private static func runUnzip(archiveURL: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archiveURL.path, "-d", destinationURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw ProjectArchiveError.archiveCommandFailed("Failed to launch unzip: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw ProjectArchiveError.archiveCommandFailed("unzip exited \(process.terminationStatus): \(message)")
        }
    }
}

nonisolated enum ProjectArchiveError: LocalizedError {
    case emptyArchive
    case archiveCommandFailed(String)
    case missingDatabaseInArchive

    var errorDescription: String? {
        switch self {
        case .emptyArchive:
            return "Archive could not be created — no project data was staged."
        case .archiveCommandFailed(let detail):
            return "Archive command failed: \(detail)"
        case .missingDatabaseInArchive:
            return "Archive does not contain a project.sqlite at its root."
        }
    }
}
