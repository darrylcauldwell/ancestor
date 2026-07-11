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

    /// Typed external identifiers with a deprecation lifecycle
    /// (MODEL_EVOLUTION_SPEC §Change1 / ADR-004 E1). This is the source of
    /// truth; `externalIDs` is now a derived projection over it. A profile can
    /// carry, per system, a primary ID plus any number of deprecated IDs that
    /// forward to it — the untyped `[String: String]` dict this replaced could
    /// hold only one value per system with no lifecycle.
    public var externalIdentifiers: [ExternalIdentifier]

    /// Legacy `[String: String]` projection: current primary value per system.
    /// Retained as the compatibility face so the ~13 call-site files that read
    /// or assign `externalIDs` (and `wikiTreeID`, which reads through it) keep
    /// working while they migrate opportunistically to `externalIdentifiers`.
    ///
    /// - get: the primary (or persistent, or resolved-survivor) value per
    ///   system — see `primaryValuesBySystem`.
    /// - set: merges the map into `externalIdentifiers` losslessly, demoting a
    ///   superseded prior primary to `.persistent` rather than discarding it
    ///   (the old dict would have overwritten and lost it).
    public var externalIDs: [String: String] {
        get { externalIdentifiers.primaryValuesBySystem }
        set { externalIdentifiers = externalIdentifiers.mergingLegacyMap(newValue) }
    }

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

    /// Typed, repeatable name forms (MODEL_EVOLUTION_SPEC §Change2 / ADR-004 E2).
    /// An **additive sidecar** — the flat name fields above stay the canonical
    /// search keys with unchanged engine semantics, and `displayName` still
    /// derives from `firstName`/`middleName`/`lastName` only. `nameForms` is the
    /// lossless landing zone for name variants the flat model cannot express: a
    /// twice-married woman's second married surname, aliases (WikiTree
    /// `LastNameOther`, silently dropped before E2), deed-poll changes,
    /// prefixes/suffixes, non-Western structures. Nothing in the scorer,
    /// publisher, or viewers reads this — they read the flat fields and the
    /// materialised `displayName`, so E2's blast radius on those surfaces is
    /// zero (decision log #2). Default `[]`; pre-E2 profiles decode to `[]`.
    public var nameForms: [NameForm]
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
    ///
    /// Back-compat: existing call sites pass `externalIDs:` as a
    /// `[String: String]` (every entry becomes a `.primary` record). New call
    /// sites may pass `externalIdentifiers:` directly for typed records
    /// (primary + deprecated + persistent). When both are supplied, the record
    /// list is the base and the legacy map is merged in on top losslessly.
    public init(id: String, externalIDs: [String: String] = [:], externalIdentifiers: [ExternalIdentifier] = [], firstName: String? = nil, middleName: String? = nil, lastName: String? = nil, marriedSurname: String? = nil, nickName: String? = nil, mothersMaidenName: String? = nil, nameForms: [NameForm] = [], gender: Gender? = nil, attributes: PersonAttributes? = nil, birthDate: GenealogicalDate? = nil, birthLocation: String? = nil, birthLocationCode: String? = nil, deathDate: GenealogicalDate? = nil, deathLocation: String? = nil, deathLocationCode: String? = nil, bio: String? = nil, isDeleted: Bool, sources: [ProfileField: [FieldSource]], disputes: [ProfileField: FieldDispute]) {
        self.id = id
        self.externalIdentifiers = externalIdentifiers.mergingLegacyMap(externalIDs)
        self.firstName = firstName
        self.middleName = middleName
        self.lastName = lastName
        self.marriedSurname = marriedSurname
        self.nickName = nickName
        self.mothersMaidenName = mothersMaidenName
        self.nameForms = nameForms
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

    // MARK: - Codable (back-compatible)

    /// Custom Codable so a Profile blob serialised *before* E1 — which carries
    /// an `externalIDs` string-map and no `externalIdentifiers` key — still
    /// decodes losslessly (every legacy entry → a `.primary` record), while
    /// new blobs carry the typed `externalIdentifiers` list. When both keys are
    /// present (a mixed/hand-authored blob) the record list is the base and the
    /// legacy map is merged on top. Encoding always writes `externalIdentifiers`
    /// (the source of truth); the DB row path stores the `externalIDs`
    /// projection into its own column separately.
    private enum CodingKeys: String, CodingKey {
        case id, externalIdentifiers, externalIDs
        case firstName, middleName, lastName, marriedSurname, nickName, mothersMaidenName, nameForms
        case gender, attributes, birthDate, birthLocation, birthLocationCode
        case deathDate, deathLocation, deathLocationCode, bio, isDeleted, sources, disputes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        let records = try c.decodeIfPresent([ExternalIdentifier].self, forKey: .externalIdentifiers) ?? []
        let legacy = try c.decodeIfPresent([String: String].self, forKey: .externalIDs) ?? [:]
        self.externalIdentifiers = records.mergingLegacyMap(legacy)
        self.firstName = try c.decodeIfPresent(String.self, forKey: .firstName)
        self.middleName = try c.decodeIfPresent(String.self, forKey: .middleName)
        self.lastName = try c.decodeIfPresent(String.self, forKey: .lastName)
        self.marriedSurname = try c.decodeIfPresent(String.self, forKey: .marriedSurname)
        self.nickName = try c.decodeIfPresent(String.self, forKey: .nickName)
        self.mothersMaidenName = try c.decodeIfPresent(String.self, forKey: .mothersMaidenName)
        // E2: absent on pre-E2 blobs → []. The flat fields above are the source
        // of truth for those profiles; a form list is only present once E2
        // ingest/edit has populated it.
        self.nameForms = try c.decodeIfPresent([NameForm].self, forKey: .nameForms) ?? []
        self.gender = try c.decodeIfPresent(Gender.self, forKey: .gender)
        self.attributes = try c.decodeIfPresent(PersonAttributes.self, forKey: .attributes)
        self.birthDate = try c.decodeIfPresent(GenealogicalDate.self, forKey: .birthDate)
        self.birthLocation = try c.decodeIfPresent(String.self, forKey: .birthLocation)
        self.birthLocationCode = try c.decodeIfPresent(String.self, forKey: .birthLocationCode)
        self.deathDate = try c.decodeIfPresent(GenealogicalDate.self, forKey: .deathDate)
        self.deathLocation = try c.decodeIfPresent(String.self, forKey: .deathLocation)
        self.deathLocationCode = try c.decodeIfPresent(String.self, forKey: .deathLocationCode)
        self.bio = try c.decodeIfPresent(String.self, forKey: .bio)
        self.isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        self.sources = try c.decodeIfPresent([ProfileField: [FieldSource]].self, forKey: .sources) ?? [:]
        self.disputes = try c.decodeIfPresent([ProfileField: FieldDispute].self, forKey: .disputes) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(externalIdentifiers, forKey: .externalIdentifiers)
        try c.encodeIfPresent(firstName, forKey: .firstName)
        try c.encodeIfPresent(middleName, forKey: .middleName)
        try c.encodeIfPresent(lastName, forKey: .lastName)
        try c.encodeIfPresent(marriedSurname, forKey: .marriedSurname)
        try c.encodeIfPresent(nickName, forKey: .nickName)
        try c.encodeIfPresent(mothersMaidenName, forKey: .mothersMaidenName)
        // Always emit — empty `[]` for a profile with no variants — so a
        // round-trip is stable and the key is present for new consumers.
        try c.encode(nameForms, forKey: .nameForms)
        try c.encodeIfPresent(gender, forKey: .gender)
        try c.encodeIfPresent(attributes, forKey: .attributes)
        try c.encodeIfPresent(birthDate, forKey: .birthDate)
        try c.encodeIfPresent(birthLocation, forKey: .birthLocation)
        try c.encodeIfPresent(birthLocationCode, forKey: .birthLocationCode)
        try c.encodeIfPresent(deathDate, forKey: .deathDate)
        try c.encodeIfPresent(deathLocation, forKey: .deathLocation)
        try c.encodeIfPresent(deathLocationCode, forKey: .deathLocationCode)
        try c.encodeIfPresent(bio, forKey: .bio)
        try c.encode(isDeleted, forKey: .isDeleted)
        try c.encode(sources, forKey: .sources)
        try c.encode(disputes, forKey: .disputes)
    }
}

nonisolated extension Profile: Hashable {
    public static func == (lhs: Profile, rhs: Profile) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
