import Foundation

/// A person in the family tree. Hashable on `id` only — sources and disputes
/// change frequently and must not affect identity.
///
/// Completeness is NOT on Profile — it requires graph context (parent edges).
/// See FamilyGraphSnapshot.completeness(for:).
///
/// History is NOT on Profile — it lives in the field_changes SQLite table,
/// keeping Profile lightweight for snapshots.
nonisolated struct Profile: Codable, Identifiable, Sendable {
    let id: String
    var externalIDs: [String: String]

    var firstName: String?
    var lastName: String?
    var gender: Gender?
    var attributes: PersonAttributes?   // nil for existing profiles (treated as .default)

    var birthDate: GenealogicalDate?
    var birthLocation: String?
    var deathDate: GenealogicalDate?
    var deathLocation: String?
    var bio: String?

    var isDeleted: Bool                 // Soft delete — hidden from tree, preserved in DB

    var sources: [ProfileField: [FieldSource]]
    var disputes: [ProfileField: FieldDispute]

    /// Resolved attributes — never nil at access time.
    var resolvedAttributes: PersonAttributes {
        attributes ?? .default
    }

    /// Display name combining first and last.
    var displayName: String {
        [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }

    /// WikiTree ID shortcut — reads from externalIDs.
    var wikiTreeID: String? {
        externalIDs["wikitree"]
    }
}

nonisolated extension Profile: Hashable {
    static func == (lhs: Profile, rhs: Profile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
