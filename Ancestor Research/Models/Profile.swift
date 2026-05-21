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
    /// Optional middle name(s). Separate from `firstName` so the user can
    /// disambiguate "John Robert Smith" → firstName=John, middleName=Robert.
    /// Legacy data carries the full given-name string in `firstName` with
    /// `middleName` nil — `displayName` handles either form gracefully so we
    /// don't have to back-fill on migration.
    var middleName: String?
    var lastName: String?
    /// Surname after marriage, for women whose `lastName` carries the
    /// maiden surname (the genealogy convention this app inherited).
    /// Required to find death-shape records (UK probate calendar files
    /// deceased married women under married surname; FreeBMD post-1969
    /// death indexes same; FAG memorials erected by family also tend to
    /// inscribe married surname). Two ways this gets populated:
    ///   1. ResearchSubject derives it from spouse.lastName when a
    ///      spouse-relationship exists on the tree — covers ~80% of cases.
    ///   2. User enters it explicitly via the profile editor when they
    ///      only ever knew the relative by married surname and the
    ///      husband isn't a tree profile.
    /// `displayName` deliberately uses `lastName` (maiden) so the tree
    /// view stays consistent with the genealogy convention; UI surfaces
    /// the married surname where it matters (research scope, audit).
    var marriedSurname: String?
    /// Familiar / known-as name. Common in historical records and search
    /// (e.g. "Bill" for William). Doesn't replace `firstName` — sits alongside
    /// it so a profile can be matched on either form. Not included in
    /// `displayName` to avoid noisy rendering; surfaces on profile detail.
    var nickName: String?
    /// Mother's maiden name. Frequently the only thing a birth-index entry
    /// carries that disambiguates same-named children of different mothers
    /// (FreeBMD post-Sep-1911 mother's-maiden-name column). Keeping it on the
    /// child's profile mirrors how the registry indexed it, even though the
    /// fact is "about" the mother — research workflows look it up here.
    var mothersMaidenName: String?
    var gender: Gender?
    var attributes: PersonAttributes?   // nil for existing profiles (treated as .default)

    var birthDate: GenealogicalDate?
    var birthLocation: String?
    /// Structured gazetteer ID (e.g. "DBY:Crich") chosen via LocationPicker.
    /// nil when the user typed freeform text that didn't match the gazetteer.
    /// Display strings remain in birthLocation; this powers hierarchical scope
    /// (parish/district/county) and cleanse-wizard ambiguity detection.
    var birthLocationCode: String?
    var deathDate: GenealogicalDate?
    var deathLocation: String?
    var deathLocationCode: String?
    var bio: String?

    var isDeleted: Bool                 // Soft delete — hidden from tree, preserved in DB

    var sources: [ProfileField: [FieldSource]]
    var disputes: [ProfileField: FieldDispute]

    /// Resolved attributes — never nil at access time.
    var resolvedAttributes: PersonAttributes {
        attributes ?? .default
    }

    /// Display name combining all given names with the surname.
    /// Legacy data with `firstName="John Robert"` and `middleName=nil` renders
    /// identically to new data with `firstName="John"` and `middleName="Robert"`
    /// — both produce "John Robert Smith".
    var displayName: String {
        [firstName, middleName, lastName].compactMap { $0 }.joined(separator: " ")
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
