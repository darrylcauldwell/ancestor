import Foundation

/// A person in the family tree. Hashable on `id` only — sources and disputes
/// change frequently and must not affect identity.
///
/// Completeness is NOT on Profile — it requires graph context (parent edges).
/// See FamilyGraphSnapshot.completeness(for:).
///
/// History is NOT on Profile — it lives in the field_changes SQLite table,
/// keeping Profile lightweight for snapshots.
public nonisolated struct Profile: Codable, Identifiable, Sendable {
    public let id: String
    public var externalIDs: [String: String]

    public var firstName: String?
    /// Optional middle name(s). Separate from `firstName` so the user can
    /// disambiguate "John Robert Smith" → firstName=John, middleName=Robert.
    /// Legacy data carries the full given-name string in `firstName` with
    /// `middleName` nil — `displayName` handles either form gracefully so we
    /// don't have to back-fill on migration.
    public var middleName: String?
    public var lastName: String?
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
    public var marriedSurname: String?
    /// Familiar / known-as name. Common in historical records and search
    /// (e.g. "Bill" for William). Doesn't replace `firstName` — sits alongside
    /// it so a profile can be matched on either form. Not included in
    /// `displayName` to avoid noisy rendering; surfaces on profile detail.
    public var nickName: String?
    /// Mother's maiden name. Frequently the only thing a birth-index entry
    /// carries that disambiguates same-named children of different mothers
    /// (FreeBMD post-Sep-1911 mother's-maiden-name column). Keeping it on the
    /// child's profile mirrors how the registry indexed it, even though the
    /// fact is "about" the mother — research workflows look it up here.
    public var mothersMaidenName: String?
    public var gender: Gender?
    public var attributes: PersonAttributes?   // nil for existing profiles (treated as .default)

    public var birthDate: GenealogicalDate?
    public var birthLocation: String?
    /// Structured gazetteer ID (e.g. "DBY:Crich") chosen via LocationPicker.
    /// nil when the user typed freeform text that didn't match the gazetteer.
    /// Display strings remain in birthLocation; this powers hierarchical scope
    /// (parish/district/county) and cleanse-wizard ambiguity detection.
    public var birthLocationCode: String?
    public var deathDate: GenealogicalDate?
    public var deathLocation: String?
    public var deathLocationCode: String?
    public var bio: String?

    public var isDeleted: Bool                 // Soft delete — hidden from tree, preserved in DB

    public var sources: [ProfileField: [FieldSource]]
    public var disputes: [ProfileField: FieldDispute]

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: String, externalIDs: [String: String], firstName: String? = nil, middleName: String? = nil, lastName: String? = nil, marriedSurname: String? = nil, nickName: String? = nil, mothersMaidenName: String? = nil, gender: Gender? = nil, attributes: PersonAttributes? = nil, birthDate: GenealogicalDate? = nil, birthLocation: String? = nil, birthLocationCode: String? = nil, deathDate: GenealogicalDate? = nil, deathLocation: String? = nil, deathLocationCode: String? = nil, bio: String? = nil, isDeleted: Bool, sources: [ProfileField: [FieldSource]], disputes: [ProfileField: FieldDispute]) {
        self.id = id
        self.externalIDs = externalIDs
        self.firstName = firstName
        self.middleName = middleName
        self.lastName = lastName
        self.marriedSurname = marriedSurname
        self.nickName = nickName
        self.mothersMaidenName = mothersMaidenName
        self.gender = gender
        self.attributes = attributes
        self.birthDate = birthDate
        self.birthLocation = birthLocation
        self.birthLocationCode = birthLocationCode
        self.deathDate = deathDate
        self.deathLocation = deathLocation
        self.deathLocationCode = deathLocationCode
        self.bio = bio
        self.isDeleted = isDeleted
        self.sources = sources
        self.disputes = disputes
    }


    /// Resolved attributes — never nil at access time.
    public var resolvedAttributes: PersonAttributes {
        attributes ?? .default
    }

    /// Display name combining all given names with the surname.
    /// Legacy data with `firstName="John Robert"` and `middleName=nil` renders
    /// identically to new data with `firstName="John"` and `middleName="Robert"`
    /// — both produce "John Robert Smith".
    public var displayName: String {
        [firstName, middleName, lastName].compactMap { $0 }.joined(separator: " ")
    }

    /// WikiTree ID shortcut — reads from externalIDs.
    public var wikiTreeID: String? {
        externalIDs["wikitree"]
    }
}

nonisolated extension Profile: Hashable {
    public static func == (lhs: Profile, rhs: Profile) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
