import Foundation

/// Structured detail payload for `LifeEvent` types where freeform
/// `description` previously lost important fields the sources already
/// parse. Persisted JSON-encoded in `life_events.details_json` (migration
/// v19); presence of a non-nil `details` is what distinguishes a structured
/// event row from a legacy freeform one.
///
/// The four cases cover the audit's four lossy event types:
///
/// - **military**: CWGC casualties and Find a Grave veterans carry rank,
///   regiment, unit, service number, country of service and a grave
///   reference — all of which used to be flattened into description.
/// - **probate**: HMCTS probate grants carry grant type (Will / Letters of
///   Admin), the registry that issued the grant, a probate number, the
///   deceased's address at probate, and their age at death — the last of
///   which is often the only birth-year signal we get.
/// - **burial**: cemetery / plot / grave reference / inscription / veteran
///   marker, the bulk of which appears on a Find a Grave or CWGC memorial.
/// - **census**: the census enumerator captures an entire household; the
///   primary subject is one row, but the rest of the household is part of
///   the same record. We keep the full `HouseholdMember` array plus the
///   subject's own occupation and the residence address.
///
/// `other` lifecycle types (residence, occupation, education, religion,
/// immigration, emigration, baptism, the generic "other") continue to use
/// `description` only — there's no structured payload to capture from the
/// sources we support today.
public nonisolated enum LifeEventDetails: Codable, Sendable, Hashable {
    case military(MilitaryDetails)
    case probate(ProbateDetails)
    case burial(BurialDetails)
    case census(CensusDetails)
}

public nonisolated struct MilitaryDetails: Codable, Sendable, Hashable {
    public var rank: String?
    public var regiment: String?
    public var unit: String?
    public var serviceNumber: String?
    public var countryOfService: String?
    public var cemetery: String?
    public var graveRef: String?
    /// Honours and decorations (e.g. "DCM", "MM"). Carried as a single
    /// pre-formatted string rather than an array — CWGC emits it that way.
    public var honours: String?

    public init(
        rank: String? = nil, regiment: String? = nil, unit: String? = nil,
        serviceNumber: String? = nil, countryOfService: String? = nil,
        cemetery: String? = nil, graveRef: String? = nil, honours: String? = nil
    ) {
        self.rank = rank
        self.regiment = regiment
        self.unit = unit
        self.serviceNumber = serviceNumber
        self.countryOfService = countryOfService
        self.cemetery = cemetery
        self.graveRef = graveRef
        self.honours = honours
    }
}

public nonisolated struct ProbateDetails: Codable, Sendable, Hashable {
    public var grantType: String?      // "Will" / "Administration" / etc.
    public var registry: String?       // e.g. "Birmingham District Probate Registry"
    public var probateNumber: String?
    public var address: String?        // Deceased's address at probate
    public var ageAtDeath: Int?

    public init(
        grantType: String? = nil, registry: String? = nil,
        probateNumber: String? = nil, address: String? = nil,
        ageAtDeath: Int? = nil
    ) {
        self.grantType = grantType
        self.registry = registry
        self.probateNumber = probateNumber
        self.address = address
        self.ageAtDeath = ageAtDeath
    }
}

public nonisolated struct BurialDetails: Codable, Sendable, Hashable {
    public var cemetery: String?
    public var plot: String?
    public var graveRef: String?
    public var inscription: String?
    public var isVeteran: Bool

    public init(
        cemetery: String? = nil, plot: String? = nil,
        graveRef: String? = nil, inscription: String? = nil,
        isVeteran: Bool = false
    ) {
        self.cemetery = cemetery
        self.plot = plot
        self.graveRef = graveRef
        self.inscription = inscription
        self.isVeteran = isVeteran
    }
}

public nonisolated struct CensusDetails: Codable, Sendable, Hashable {
    /// Subject's own occupation as recorded on the census schedule.
    public var occupation: String?
    /// Street / house address of the dwelling.
    public var address: String?
    /// Registration district reported on the schedule (separate from a
    /// gazetteer match — this is what the enumerator wrote).
    public var district: String?
    /// Parish from the census schedule.
    public var parish: String?
    /// Full household roster from the schedule (Task #51). Persisted with
    /// the event so the user keeps the household context even if no
    /// individual member ever becomes its own profile.
    public var household: [HouseholdMember]

    public init(
        occupation: String? = nil, address: String? = nil,
        district: String? = nil, parish: String? = nil,
        household: [HouseholdMember] = []
    ) {
        self.occupation = occupation
        self.address = address
        self.district = district
        self.parish = parish
        self.household = household
    }
}
