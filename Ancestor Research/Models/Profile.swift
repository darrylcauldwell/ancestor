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

    var birthDate: GenealogicalDate?
    var birthLocation: String?
    var deathDate: GenealogicalDate?
    var deathLocation: String?
    var bio: String?

    var sources: [ProfileField: [FieldSource]]
    var disputes: [ProfileField: FieldDispute]

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
