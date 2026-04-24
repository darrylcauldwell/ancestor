import Foundation

/// Top-level container for a family tree research project.
/// Each project is a self-contained SQLite database.
struct Project: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var source: DataSource
    var createdAt: Date
    var lastRefreshed: Date?
}

enum DataSource: Codable, Sendable {
    case gedcom(path: String)
    case wikitree(email: String)
}
