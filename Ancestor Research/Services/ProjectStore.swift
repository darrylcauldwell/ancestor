import Foundation
import os

/// Manages project listing, creation, and deletion.
/// Projects live in Application Support as individual SQLite files.
nonisolated struct ProjectStore {
    private static let logger = Logger(
        subsystem: "dev.dreamfold.Ancestor-Research",
        category: "ProjectStore"
    )
    static let projectsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AncestorResearch/projects")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// List projects by reading SQLite files. Active-only by default;
    /// callers that need to surface archived projects (the picker) pass
    /// `includingArchived: true` and filter presentationally.
    static func listProjects(includingArchived: Bool = false) -> [Project] {
        logger.info("listProjects scanning dir: \(projectsDirectory.path, privacy: .public)")
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: projectsDirectory, includingPropertiesForKeys: nil
            )
        } catch {
            logger.error("listProjects directory scan failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let sqliteFiles = files.filter { $0.pathExtension == "sqlite" }
        logger.info("listProjects found \(sqliteFiles.count, privacy: .public) sqlite files in dir")

        var loaded: [Project] = []
        var dbInitFailures = 0
        var metaFailures = 0
        for url in sqliteFiles {
            do {
                let db = try ProjectDatabase(path: url.path)
                do {
                    if let project = try db.loadProjectMeta() {
                        if includingArchived || !project.isArchived {
                            loaded.append(project)
                        }
                    } else {
                        metaFailures += 1
                        logger.warning("loadProjectMeta returned nil for \(url.lastPathComponent, privacy: .public)")
                    }
                } catch {
                    metaFailures += 1
                    logger.warning("loadProjectMeta threw for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            } catch {
                dbInitFailures += 1
                logger.warning("ProjectDatabase init failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        logger.info("listProjects done: loaded=\(loaded.count, privacy: .public) initFail=\(dbInitFailures, privacy: .public) metaFail=\(metaFailures, privacy: .public)")
        return loaded
    }

    /// Mark a project archived. The SQLite file is left in place — archive is
    /// a metadata flag, not a file move, so backups/media paths stay stable.
    static func archiveProject(_ id: UUID) throws {
        let path = projectsDirectory.appendingPathComponent("\(id.uuidString).sqlite").path
        let db = try ProjectDatabase(path: path)
        try db.setArchivedAt(Date())
    }

    /// Clear the archived flag.
    static func unarchiveProject(_ id: UUID) throws {
        let path = projectsDirectory.appendingPathComponent("\(id.uuidString).sqlite").path
        let db = try ProjectDatabase(path: path)
        try db.setArchivedAt(nil)
    }

    /// Create a new project with the given name and data source.
    static func createProject(name: String, source: DataSource) throws -> (Project, ProjectDatabase) {
        let project = Project(
            id: UUID(),
            name: name,
            source: source,
            homePersonID: nil,
            createdAt: Date(),
            lastRefreshed: nil
        )
        let path = projectsDirectory.appendingPathComponent("\(project.id.uuidString).sqlite").path
        let db = try ProjectDatabase(path: path)
        try db.saveProjectMeta(project)
        return (project, db)
    }

    /// Open an existing project by ID.
    static func openProject(_ id: UUID) throws -> (Project, ProjectDatabase) {
        let path = projectsDirectory.appendingPathComponent("\(id.uuidString).sqlite").path
        let db = try ProjectDatabase(path: path)
        guard let project = try db.loadProjectMeta() else {
            throw ProjectStoreError.projectNotFound
        }
        return (project, db)
    }

    /// Delete a project's SQLite file. Also removes the media + thumbnails
    /// + backups directories if they exist.
    static func deleteProject(_ id: UUID) throws {
        let path = projectsDirectory.appendingPathComponent("\(id.uuidString).sqlite")
        try FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: mediaDirectory(for: id))
        try? FileManager.default.removeItem(at: thumbnailsDirectory(for: id))
        try? FileManager.default.removeItem(at: backupsDirectory(for: id))
    }

    // MARK: - Media directory helpers (M13)

    /// Per-project media directory. Lazily created.
    static func mediaDirectory(for projectID: UUID) -> URL {
        let dir = projectsDirectory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Per-project thumbnail directory. Lazily created.
    static func thumbnailsDirectory(for projectID: UUID) -> URL {
        let dir = projectsDirectory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Per-project backups directory (M14). Lazily created.
    static func backupsDirectory(for projectID: UUID) -> URL {
        let dir = projectsDirectory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolve an attachment's relative path to an absolute URL on disk.
    static func absoluteURL(for attachment: Attachment, in projectID: UUID) -> URL {
        mediaDirectory(for: projectID).appendingPathComponent(attachment.relativePath)
    }
}

nonisolated enum ProjectStoreError: Error {
    case projectNotFound
}
