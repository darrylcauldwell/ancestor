import Foundation

/// Where a `PlaceAuthority` sits in the UK jurisdictional hierarchy
/// (MODEL_EVOLUTION_SPEC §Change3 / ADR-004 E3). The chain the v14 migration
/// rationale already promised — "parish → district → county → national"
/// (`ProjectDatabase.swift`) — is finally a *typed* ladder rather than a flat
/// `COUNTY:Place` string namespace.
///
/// The registration **district** — *the* pivot of UK BMD research — gets its
/// own case here for the first time. Before E3 it existed only as free-text
/// `districtHint` strings inside hypothesis payloads, with no entity, no
/// hierarchy position, and no identity across runs.
///
/// Ordering is deliberate: cases ascend from most-specific (`.parish`) to
/// most-general (`.country`), so `rawValue` comparisons and `rollUp` walks read
/// naturally. `.place` is the catch-all for a town/village that we hold as a
/// gazetteer entry but haven't (yet) resolved to a specific parish — it keeps
/// the ~205 existing town entries representable without asserting a parish
/// identity the seed data doesn't carry.
public nonisolated enum PlaceKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// A civil/ecclesiastical parish — the finest jurisdiction we model. Its
    /// parent is a registration district (for BMD purposes).
    case parish
    /// A town or village held in the gazetteer without a resolved parish
    /// identity. Parents to a county today; a future GENUKI import may refine
    /// these to parishes.
    case place
    /// A GRO/BMD registration **district**. Its parent is a county; its
    /// children are parishes. This is the entity BMD research pivots on.
    case registrationDistrict
    /// A historical (Chapman-coded) county. Parent is a country.
    case county
    /// England / Wales / Scotland / … — the top of the UK hierarchy.
    case country
}

/// A place as a first-class entity: a node in the UK jurisdictional hierarchy
/// with temporal validity (MODEL_EVOLUTION_SPEC §Change3 / ADR-004 E3).
///
/// **A sidecar, not a rebuild** — the same additive-record philosophy as E1
/// (`ExternalIdentifier`) and E2 (`NameForm`). `Profile.birthLocation` (a
/// display string) and `Profile.birthLocationCode` (a flat `COUNTY:Place`
/// gazetteer ID) stay exactly as they are and keep their engine semantics; a
/// `COUNTY:Place` code still resolves to the same county and district it always
/// did (AC3). `PlaceAuthority` is the additive record that makes the *hierarchy*
/// and *temporal validity* — parish→district→county→country, and the fact that
/// registration districts and county boundaries moved over time (1837 creation,
/// 1852, 1946, 1974) — first-class and queryable, so that:
///
/// - the planned ~12k-parish GENUKI import lands into a hierarchy instead of a
///   flat namespace that would collide on parish names and then need
///   re-migrating (decision log #3), and
/// - the no-hardcoded-regions rule is *strengthened*: county/district
///   resolution is backed by data-derived authority records rather than
///   Derbyshire-specific code paths.
///
/// The records themselves are **derived from existing seed data** (the
/// gazetteer counties/towns, the FreeBMD district catalogue's
/// districts/parishes/validity years, and the RegionConfig parish lists) — see
/// the app-side `PlaceAuthorityRegistry`. Nothing here hardcodes a region.
///
/// Temporal validity is the pair `validFrom`/`validTo` (inclusive year bounds
/// on the jurisdictional *relationship*, i.e. this place being valid / sitting
/// under this parent in that window). `nil` means "unbounded on that side" —
/// the FreeBMD catalogue's own convention (`FreeBMDDistrict.startYear`/
/// `endYear`), preserved losslessly. A place that changed jurisdiction is
/// representable either as two entries with disjoint windows or as one entry
/// with dated parent links; the seed derivation uses distinct entries where the
/// catalogue already lists a successor district (e.g. Belper → Amber Valley),
/// which both the spec sketch and real GENUKI data allow.
public nonisolated struct PlaceAuthority: Codable, Hashable, Sendable, Identifiable {
    /// Stable structured ID. For gazetteer places this is the existing
    /// `COUNTY:Place` code unchanged ("DBY", "DBY:Crich") so legacy
    /// `birthLocationCode` values resolve directly. Registration districts use
    /// a `"{CHAPMAN}:{Name}-RD"` shape ("DBY:Belper-RD") to avoid colliding
    /// with a same-named town's `"{CHAPMAN}:{Name}"` id.
    public let id: String

    /// Human-readable place name ("Crich", "Belper", "Derbyshire", "England").
    public let name: String

    /// Position in the hierarchy — parish / place / registrationDistrict /
    /// county / country.
    public let kind: PlaceKind

    /// The `id` of this place's parent in the hierarchy, or `nil` for a
    /// top-level (`.country`) node. A parish's parent is a registration
    /// district; a district's parent is a county; a county's parent is a
    /// country. This is the single link the whole roll-up chain walks.
    public let parentID: String?

    /// Inclusive lower year bound on this place's jurisdictional validity, or
    /// `nil` for unbounded-below (the FreeBMD `startYear` convention). A parish
    /// that only sat under this district from 1974 carries `validFrom == 1974`.
    public let validFrom: Int?

    /// Inclusive upper year bound, or `nil` for unbounded-above (the FreeBMD
    /// `endYear` convention). A district that was reorganised away in 1994
    /// carries `validTo == 1994`.
    public let validTo: Int?

    /// The historical county name this place rolls up to ("Derbyshire").
    /// Carried directly (not only via `parentID`) so a single record answers
    /// "what county?" without a walk — matching `GazetteerEntry.county` so the
    /// two stay interchangeable during the compat window.
    public let county: String?

    /// The country this place rolls up to ("England" / "Wales" / …).
    public let country: String?

    /// Alternate spellings / transcription variants, mirroring
    /// `GazetteerEntry.aliases` and the district catalogue's name variants.
    public let aliases: [String]

    /// The FreeBMD district select's wire code for a `.registrationDistrict`
    /// (e.g. "722" for Belper), or `nil` for non-district kinds. Preserves the
    /// catalogue's `FreeBMDDistrict.code` so district resolution through the
    /// authority yields the identical wire value the flat path did.
    public let freeBMDCode: String?

    public init(
        id: String,
        name: String,
        kind: PlaceKind,
        parentID: String? = nil,
        validFrom: Int? = nil,
        validTo: Int? = nil,
        county: String? = nil,
        country: String? = nil,
        aliases: [String] = [],
        freeBMDCode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.validFrom = validFrom
        self.validTo = validTo
        self.county = county
        self.country = country
        self.aliases = aliases
        self.freeBMDCode = freeBMDCode
    }

    /// True when this place's jurisdictional relationship was valid at any point
    /// in `range` — the same year-bracket overlap the FreeBMD catalogue uses
    /// (`FreeBMDDistrict.overlaps(years:)`), so temporal filtering through the
    /// authority matches the flat path exactly. `nil` bounds are treated as
    /// open (`Int.min`/`Int.max`).
    public func overlaps(years range: ClosedRange<Int>) -> Bool {
        let lower = validFrom ?? Int.min
        let upper = validTo ?? Int.max
        return lower <= range.upperBound && upper >= range.lowerBound
    }

    /// True when this place was valid in a single `year`. Convenience over
    /// `overlaps(years:)` for point-in-time parish→district resolution.
    public func valid(in year: Int) -> Bool {
        overlaps(years: year...year)
    }
}
