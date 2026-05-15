import Foundation

/// Top-level container for a family tree research project.
/// Each project is a self-contained SQLite database.
nonisolated struct Project: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var source: DataSource
    var homePersonID: String?       // Anchor profile — the person whose tree this is
    var createdAt: Date
    var lastRefreshed: Date?
    var archivedAt: Date?           // nil = active; non-nil = archived at that moment

    var isArchived: Bool { archivedAt != nil }
}

nonisolated enum DataSource: Codable, Sendable {
    case gedcom(path: String)
    case wikitree(email: String)
    case manual                     // Started from scratch — no external source
}
