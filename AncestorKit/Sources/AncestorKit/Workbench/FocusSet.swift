import Foundation

/// A named working set of profiles the user is currently investigating.
/// Persists across sessions. Typically 3–10 profiles.
///
/// "Active" focus is implicit: the focus set with the most recent
/// `lastActiveAt` is treated as active. Switching focus sets bumps the
/// timestamp of the chosen one.
public nonisolated struct FocusSet: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var title: String?              // "Maternal grandmother's siblings", optional
    public var profileIDs: [String]        // Pinned manually
    public var createdAt: Date
    public var lastActiveAt: Date

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: UUID, title: String? = nil, profileIDs: [String], createdAt: Date, lastActiveAt: Date) {
        self.id = id
        self.title = title
        self.profileIDs = profileIDs
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }


    /// User-visible name — falls back to a generic label when title is nil.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        return "Untitled focus"
    }
}
