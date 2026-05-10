import Foundation

/// Manages project listing, creation, and deletion.
/// Projects live in Application Support as individual SQLite files.
nonisolated struct ProjectStore {
    static let projectsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AncestorResearch/projects")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// List all available projects by reading SQLite files.
    static func listProjects() -> [Project] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "sqlite" }
            .compactMap { url in
                guard let db = try? ProjectDatabase(path: url.path),
                      let project = try? db.loadProjectMeta() else { return nil }
                return project
            }
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
