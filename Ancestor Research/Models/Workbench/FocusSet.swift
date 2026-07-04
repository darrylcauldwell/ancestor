import Foundation

/// A named working set of profiles the user is currently investigating.
/// Persists across sessions. Typically 3–10 profiles.
///
/// "Active" focus is implicit: the focus set with the most recent
/// `lastActiveAt` is treated as active. Switching focus sets bumps the
/// timestamp of the chosen one.
nonisolated struct FocusSet: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var title: String?              // "Maternal grandmother's siblings", optional
    var profileIDs: [String]        // Pinned manually
    var createdAt: Date
    var lastActiveAt: Date

    /// User-visible name — falls back to a generic label when title is nil.
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        return "Untitled focus"
    }
}
