import Foundation

// MARK: - Record Type

/// What kind of record to search for.
public nonisolated enum RecordType: String, Codable, Sendable {
    case birth, death, marriage, census, burial, military, probate
    case baptism, christening, parish, pedigree
}

// MARK: - Record Common

/// Fields shared by all record types.
public nonisolated struct RecordCommon: Codable, Sendable {
    public let id: String
    public let sourceID: String
    public let name: String?
    public let surname: String?
    public let givenName: String?
    public let detailURL: String?
    public let rawFields: [String: String]

    // MARK: Secondary-metadata columns (FAMILYSEARCH_READ_LEG_PLAN #Change7,
    // FAMILYSEARCH_SOURCE_SPEC §12.4). Data-model commits landing NOW so
    // second-cut endpoint work needs no schema migration; each stays nil
    // until the endpoint that fills it is wired. Optional + synthesized
    // Codable = old JSON without these keys decodes to nil (additive-safe).

    /// Bare place-authority ARK path segment for the record's event place
    /// (§6.7, §17.1 — never the full URL). Populated when a normalized
    /// place ARK is present; place-authority integration is later (E3).
    public let placeARK: String?
    /// Collection coverage completeness 0…1 (§7.4), when the source reports
    /// it. Promoted to first-class from rawFields on FS records; the
    /// scorer's negative-evidence weighting consumes it later.
    public let collectionCompleteness: Double?
    /// Contested-attribution signal from a record's change history (§7.3),
    /// e.g. many edits by many contributors. Column now; the change-history
    /// endpoint that populates it is second-cut.
    public let volatilityScore: Double?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this. The
    /// #Change7 columns default to nil so existing construction sites are
    /// untouched.
    public init(id: String, sourceID: String, name: String? = nil, surname: String? = nil, givenName: String? = nil, detailURL: String? = nil, rawFields: [String: String], placeARK: String? = nil, collectionCompleteness: Double? = nil, volatilityScore: Double? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.surname = surname
        self.givenName = givenName
        self.detailURL = detailURL
        self.rawFields = rawFields
        self.placeARK = placeARK
        self.collectionCompleteness = collectionCompleteness
        self.volatilityScore = volatilityScore
    }

}

// MARK: - Type-Specific Records

public nonisolated struct BirthRecord: Codable, Sendable {
    public let common: RecordCommon
    public let birthYear: Int?
    public let birthDate: String?
    public let birthPlace: String?
    public let quarter: String?
    public let district: String?
    public let volume: String?
    public let page: String?
    public let mothersMaidenName: String?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(common: RecordCommon, birthYear: Int? = nil, birthDate: String? = nil, birthPlace: String? = nil, quarter: String? = nil, district: String? = nil, volume: String? = nil, page: String? = nil, mothersMaidenName: String? = nil) {
        self.common = common
        self.birthYear = birthYear
        self.birthDate = birthDate
        self.birthPlace = birthPlace
        self.quarter = quarter
        self.district = district
        self.volume = volume
        self.page = page
        self.mothersMaidenName = mothersMaidenName
    }

}

public nonisolated struct DeathRecord: Codable, Sendable {
    public let common: RecordCommon
    public let deathYear: Int?
    public let deathDate: String?
    public let deathPlace: String?
    public let age: Int?
    public let quarter: String?
    public let district: String?
    public let volume: String?
    public let page: String?
    public let spouseSurname: String?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(common: RecordCommon, deathYear: Int? = nil, deathDate: String? = nil, deathPlace: String? = nil, age: Int? = nil, quarter: String? = nil, district: String? = nil, volume: String? = nil, page: String? = nil, spouseSurname: String? = nil) {
        self.common = common
        self.deathYear = deathYear
        self.deathDate = deathDate
        self.deathPlace = deathPlace
        self.age = age
        self.quarter = quarter
        self.district = district
        self.volume = volume
        self.page = page
        self.spouseSurname = spouseSurname
    }

}

public nonisolated struct MarriageRecord: Codable, Sendable {
    public let common: RecordCommon
    public let marriageYear: Int?
    public let marriageDate: String?
    public let marriagePlace: String?
    public let quarter: String?
    public let district: String?
    public let volume: String?
    public let page: String?
    public let spouseName: String?
    /// Partner's surname recovered by pairing this record with a same-page
    /// entry indexed under the spouse's surname. Pre-Sep-1912 FreeBMD
    /// marriage entries lack the spouse-surname column entirely (`spouseName`
    /// is nil); the two sides of one marriage are registered on the same
    /// (volume, page), so a separately-fetched spouse-side query lets us
    /// recover the partner deterministically. The pipeline's same-page
    /// pairing pass is the only writer; sources default to nil.
    public let partnerSurnameFromSamePage: String?

    /// Custom init so `partnerSurnameFromSamePage` can default to nil
    /// without forcing every existing source/test constructor to pass it.
    /// Same pattern as `RecordQuery.init`.
    public init(
        common: RecordCommon,
        marriageYear: Int?,
        marriageDate: String?,
        marriagePlace: String?,
        quarter: String?,
        district: String?,
        volume: String?,
        page: String?,
        spouseName: String?,
        partnerSurnameFromSamePage: String? = nil
    ) {
        self.common = common
        self.marriageYear = marriageYear
        self.marriageDate = marriageDate
        self.marriagePlace = marriagePlace
        self.quarter = quarter
        self.district = district
        self.volume = volume
        self.page = page
        self.spouseName = spouseName
        self.partnerSurnameFromSamePage = partnerSurnameFromSamePage
    }
}

public nonisolated struct CensusRecord: Codable, Sendable {
    public let common: RecordCommon
    public let censusYear: Int
    public let age: Int?
    public let birthYear: Int?
    public let birthPlace: String?
    public let birthCounty: String?
    public let relationship: String?
    public let occupation: String?
    public let address: String?
    public let parish: String?
    public let district: String?
    public let household: [HouseholdMember]?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(common: RecordCommon, censusYear: Int, age: Int? = nil, birthYear: Int? = nil, birthPlace: String? = nil, birthCounty: String? = nil, relationship: String? = nil, occupation: String? = nil, address: String? = nil, parish: String? = nil, district: String? = nil, household: [HouseholdMember]? = nil) {
        self.common = common
        self.censusYear = censusYear
        self.age = age
        self.birthYear = birthYear
        self.birthPlace = birthPlace
        self.birthCounty = birthCounty
        self.relationship = relationship
        self.occupation = occupation
        self.address = address
        self.parish = parish
        self.district = district
        self.household = household
    }

}

public nonisolated struct BurialRecord: Codable, Sendable {
    public let common: RecordCommon
    public let deathDate: String?
    public let deathYear: Int?
    public let birthDate: String?
    public let birthYear: Int?
    /// Birth town/place from the memorial's schema.org `birthPlace`
    /// itemprop (FindAGrave detail page). Distinct from
    /// `burialLocation`, which is where the cemetery is — a person can
    /// be born in Belper and buried in London. Optional because not
    /// every memorial carries this metadata.
    public let birthPlace: String?
    /// Death town/place from the memorial's schema.org `deathPlace`
    /// itemprop. Same shape as birthPlace and same reason for being
    /// distinct from burialLocation.
    public let deathPlace: String?
    public let burialLocation: String?
    public let cemetery: String?
    public let memorialID: Int?
    public let inscription: String?
    public let bio: String?
    public let isVeteran: Bool

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(common: RecordCommon, deathDate: String? = nil, deathYear: Int? = nil, birthDate: String? = nil, birthYear: Int? = nil, birthPlace: String? = nil, deathPlace: String? = nil, burialLocation: String? = nil, cemetery: String? = nil, memorialID: Int? = nil, inscription: String? = nil, bio: String? = nil, isVeteran: Bool) {
        self.common = common
        self.deathDate = deathDate
        self.deathYear = deathYear
        self.birthDate = birthDate
        self.birthYear = birthYear
        self.birthPlace = birthPlace
        self.deathPlace = deathPlace
        self.burialLocation = burialLocation
        self.cemetery = cemetery
        self.memorialID = memorialID
        self.inscription = inscription
        self.bio = bio
        self.isVeteran = isVeteran
    }

}

public nonisolated struct MilitaryRecord: Codable, Sendable {
    public let common: RecordCommon
    public let rank: String?
    public let regiment: String?
    public let unit: String?
    public let serviceNumber: String?
    public let dateOfDeath: String?
    public let deathYear: Int?
    public let age: Int?
    public let cemetery: String?
    public let graveRef: String?
    public let additionalInfo: String?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(common: RecordCommon, rank: String? = nil, regiment: String? = nil, unit: String? = nil, serviceNumber: String? = nil, dateOfDeath: String? = nil, deathYear: Int? = nil, age: Int? = nil, cemetery: String? = nil, graveRef: String? = nil, additionalInfo: String? = nil) {
        self.common = common
        self.rank = rank
        self.regiment = regiment
        self.unit = unit
        self.serviceNumber = serviceNumber
        self.dateOfDeath = dateOfDeath
        self.deathYear = deathYear
        self.age = age
        self.cemetery = cemetery
        self.graveRef = graveRef
        self.additionalInfo = additionalInfo
    }

}

public nonisolated struct ProbateRecord: Codable, Sendable {
    public let common: RecordCommon
    public let deathDate: String?
    public let deathYear: Int?
    public let probateDate: String?
    public let birthDate: String?
    public let ageAtDeath: Int?
    public let address: String?
    /// T1-28 — estate postcode (Nuxeo `hmctsgrant:estatepostcode`). The
    /// strongest geographic disambiguator the source offers: unlike the
    /// joined address lines, a postcode pins a locality precisely. Python
    /// has always parsed it (sources/probate.py:103); the Swift port had
    /// dropped it. Nil when the grant carries no postcode (soldier wills,
    /// older grants).
    public let postcode: String?
    /// T1-28 — honorific/title (Nuxeo `hmctsgrant:estatetitle`, e.g.
    /// "MRS" / "MISS" / "DR"). Carries marital-status and gender signal
    /// for the married-woman matching pathway. Python parses it
    /// (sources/probate.py:104). Nil when absent.
    public let title: String?
    public let grantType: String?
    public let registry: String?
    public let probateNumber: String?
    public let regimentNumber: Int?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    /// `postcode`/`title` default nil so pre-T1-28 construction sites are
    /// unchanged.
    public init(common: RecordCommon, deathDate: String? = nil, deathYear: Int? = nil, probateDate: String? = nil, birthDate: String? = nil, ageAtDeath: Int? = nil, address: String? = nil, postcode: String? = nil, title: String? = nil, grantType: String? = nil, registry: String? = nil, probateNumber: String? = nil, regimentNumber: Int? = nil) {
        self.common = common
        self.deathDate = deathDate
        self.deathYear = deathYear
        self.probateDate = probateDate
        self.birthDate = birthDate
        self.ageAtDeath = ageAtDeath
        self.address = address
        self.postcode = postcode
        self.title = title
        self.grantType = grantType
        self.registry = registry
        self.probateNumber = probateNumber
        self.regimentNumber = regimentNumber
    }

}

public nonisolated struct ParishRecord: Codable, Sendable {
    public let common: RecordCommon
    public let eventType: String?
    public let eventDate: String?
    public let eventYear: Int?
    public let parish: String?
    public let county: String?
    public let fatherName: String?
    public let motherName: String?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(common: RecordCommon, eventType: String? = nil, eventDate: String? = nil, eventYear: Int? = nil, parish: String? = nil, county: String? = nil, fatherName: String? = nil, motherName: String? = nil) {
        self.common = common
        self.eventType = eventType
        self.eventDate = eventDate
        self.eventYear = eventYear
        self.parish = parish
        self.county = county
        self.fatherName = fatherName
        self.motherName = motherName
    }

}

public nonisolated struct PedigreeRecord: Codable, Sendable {
    public let common: RecordCommon
    public let birthYear: Int?
    public let deathYear: Int?
    public let spouse: String?
    public let marriageYear: Int?
    public let occupation: String?
    public let location: String?
    public let generation: Int?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(common: RecordCommon, birthYear: Int? = nil, deathYear: Int? = nil, spouse: String? = nil, marriageYear: Int? = nil, occupation: String? = nil, location: String? = nil, generation: Int? = nil) {
        self.common = common
        self.birthYear = birthYear
        self.deathYear = deathYear
        self.spouse = spouse
        self.marriageYear = marriageYear
        self.occupation = occupation
        self.location = location
        self.generation = generation
    }

}

// MARK: - Household Member (shared by CensusRecord and ScoringRules)

public nonisolated struct HouseholdMember: Codable, Sendable, Hashable {
    public let name: String
    public let relationship: String
    public let age: Int?
    public let birthYear: Int?
    public let birthPlace: String?
    public let occupation: String?
    public let sex: String?
    /// Marital-status column (M/S/W/U…) — distinguishes wife vs widow vs
    /// unmarried sister on identical relationship strings (connector-audit
    /// FT-15).
    public let maritalStatus: String?
    /// Birth-county column — disambiguates common birth-place strings
    /// (connector-audit FT-15).
    public let birthCounty: String?
    /// Disability column (connector-audit FT-15). A flat typed field, not a
    /// rawFields bag: this struct has no bag and its design is flat optionals.
    public let disability: String?
    /// Notes column (connector-audit FT-15). Flat typed field, as above.
    public let notes: String?
    /// True when the source marked this member's row as "the person found in
    /// your search" — Python's `is_target` (sources/freecen.py:318), ported
    /// for connector-audit FT-10. Optional so legacy persisted JSON in
    /// `evidence_records` (which predates the field) decodes as nil
    /// ("unknown") rather than failing.
    public let isTarget: Bool?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(name: String, relationship: String, age: Int? = nil, birthYear: Int? = nil, birthPlace: String? = nil, occupation: String? = nil, sex: String? = nil, maritalStatus: String? = nil, birthCounty: String? = nil, disability: String? = nil, notes: String? = nil, isTarget: Bool? = nil) {
        self.name = name
        self.relationship = relationship
        self.age = age
        self.birthYear = birthYear
        self.birthPlace = birthPlace
        self.occupation = occupation
        self.sex = sex
        self.maritalStatus = maritalStatus
        self.birthCounty = birthCounty
        self.disability = disability
        self.notes = notes
        self.isTarget = isTarget
    }

}

// MARK: - Source Record (enum with associated values)

/// A record returned from a source — typed by record kind.
/// Codable so it can be JSON-persisted in the evidence_records table without losing
/// any field (typed or raw). All associated values are already Codable.
public nonisolated enum SourceRecord: Identifiable, Sendable, Codable {
    case birth(BirthRecord)
    case death(DeathRecord)
    case marriage(MarriageRecord)
    case census(CensusRecord)
    case burial(BurialRecord)
    case military(MilitaryRecord)
    case probate(ProbateRecord)
    case parish(ParishRecord)
    case pedigree(PedigreeRecord)

    public var id: String { common.id }
    public var sourceID: String { common.sourceID }
    public var name: String? { common.name }
    public var surname: String? { common.surname }
    public var givenName: String? { common.givenName }
    public var detailURL: String? { common.detailURL }
    public var rawFields: [String: String] { common.rawFields }

    public var common: RecordCommon {
        switch self {
        case .birth(let r): r.common
        case .death(let r): r.common
        case .marriage(let r): r.common
        case .census(let r): r.common
        case .burial(let r): r.common
        case .military(let r): r.common
        case .probate(let r): r.common
        case .parish(let r): r.common
        case .pedigree(let r): r.common
        }
    }

    /// Map the enum case to a RecordType. Nonisolated so the DB layer can use it
    /// outside MainActor.
    public var recordType: RecordType {
        switch self {
        case .birth: .birth
        case .death: .death
        case .marriage: .marriage
        case .census: .census
        case .burial: .burial
        case .military: .death  // military records are death records for scoring
        case .probate: .probate
        case .parish: .parish
        case .pedigree: .pedigree
        }
    }
}

// MARK: - Record Query

/// Search parameters — source adapters extract what they need.
///
/// Common axes (surname, given, year range, gender, region) sit at the
/// top level so any source can read them. Source-specific configuration
/// (FreeBMD district code, FAG year-range width, etc.) lives in
/// `sourceParams`. The trailing block of optional family-context axes
/// (birthPlace, deathPlace, spouse/parent surnames + given names) lets
/// the dispatcher plumb tree-side context into source queries — FS
/// reads `q.spouseSurname` / `q.fatherSurname`/etc., FreeBMD reads
/// `motherSurname`/`spouseSurname` via its own params struct (populated
/// from the same source). Spec §23.
public nonisolated struct RecordQuery: Sendable {
    public let surname: String?
    public let givenName: String?
    public let recordType: RecordType
    public let yearFrom: Int?
    public let yearTo: Int?
    public let gender: Gender?
    public let region: Region?
    public let sourceParams: SourceQueryParams
    /// Name-match strictness. Defaults to `.strict`. Sources may ignore it
    /// — see RESEARCH_AXES_SPEC §7 for which sources honour which tiers.
    /// Change 4 ships the field with no source-side handling; Change 5
    /// wires the per-source query rewriting; Change 6 wires the dispatcher's
    /// empty-then-broaden flow.
    public let strictness: SearchStrictness

    // MARK: Family-context axes (spec §23)
    // All optional. Source URL builders cherry-pick what they understand —
    // FS uses all of them, FreeBMD uses spouse+mother surname, FAG uses
    // birthPlace as `location`. nil means "axis not available for this
    // subject" (e.g. parents not on the tree).
    public let birthPlace: String?
    public let deathPlace: String?
    /// Residence place (census scoping) and marriage place — FS's
    /// `q.residenceLikePlace` / `q.marriageLikePlace`
    /// (FAMILYSEARCH_READ_LEG_PLAN #Change6). Optional like the other
    /// family-context axes; nil skips the parameter.
    public let residencePlace: String?
    public let marriagePlace: String?
    /// Soft country/region scoping — FS's `q.anyPlace`. A tree-derived home
    /// country (e.g. "England") that biases ranking toward the subject's
    /// nation to thin the long tail of same-surname records from other
    /// countries. Re-rank-only (fuzzy q.* axis), so it can never drop the
    /// true local record. nil skips the parameter.
    public let anyPlace: String?
    public let spouseSurname: String?
    public let spouseGivenName: String?
    public let fatherSurname: String?
    public let fatherGivenName: String?
    public let motherSurname: String?
    public let motherGivenName: String?

    /// Custom init so `strictness` can be defaulted without losing the
    /// memberwise calling convention (Swift drops defaulted `let` fields
    /// from the synthesised init).
    public init(
        surname: String?,
        givenName: String?,
        recordType: RecordType,
        yearFrom: Int?,
        yearTo: Int?,
        gender: Gender?,
        region: Region?,
        sourceParams: SourceQueryParams,
        strictness: SearchStrictness = .strict,
        birthPlace: String? = nil,
        deathPlace: String? = nil,
        residencePlace: String? = nil,
        marriagePlace: String? = nil,
        anyPlace: String? = nil,
        spouseSurname: String? = nil,
        spouseGivenName: String? = nil,
        fatherSurname: String? = nil,
        fatherGivenName: String? = nil,
        motherSurname: String? = nil,
        motherGivenName: String? = nil
    ) {
        self.surname = surname
        self.givenName = givenName
        self.recordType = recordType
        self.yearFrom = yearFrom
        self.yearTo = yearTo
        self.gender = gender
        self.region = region
        self.sourceParams = sourceParams
        self.strictness = strictness
        self.birthPlace = birthPlace
        self.deathPlace = deathPlace
        self.residencePlace = residencePlace
        self.marriagePlace = marriagePlace
        self.anyPlace = anyPlace
        self.spouseSurname = spouseSurname
        self.spouseGivenName = spouseGivenName
        self.fatherSurname = fatherSurname
        self.fatherGivenName = fatherGivenName
        self.motherSurname = motherSurname
        self.motherGivenName = motherGivenName
    }

    /// Builder helpers for the dispatcher's strictness ladder (Change 5).
    /// All other fields preserved. See RESEARCH_AXES_SPEC §7.
    /// NOTE: every axis must be threaded through BOTH copiers, or the
    /// strictness ladder silently drops it before the wire (blast-radius
    /// audit Q3 trap).
    public func with(strictness: SearchStrictness) -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: givenName, recordType: recordType,
            yearFrom: yearFrom, yearTo: yearTo, gender: gender, region: region,
            sourceParams: sourceParams, strictness: strictness,
            birthPlace: birthPlace, deathPlace: deathPlace,
            residencePlace: residencePlace, marriagePlace: marriagePlace,
            anyPlace: anyPlace,
            spouseSurname: spouseSurname, spouseGivenName: spouseGivenName,
            fatherSurname: fatherSurname, fatherGivenName: fatherGivenName,
            motherSurname: motherSurname, motherGivenName: motherGivenName
        )
    }

    public func with(surname: String?) -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: givenName, recordType: recordType,
            yearFrom: yearFrom, yearTo: yearTo, gender: gender, region: region,
            sourceParams: sourceParams, strictness: strictness,
            birthPlace: birthPlace, deathPlace: deathPlace,
            residencePlace: residencePlace, marriagePlace: marriagePlace,
            anyPlace: anyPlace,
            spouseSurname: spouseSurname, spouseGivenName: spouseGivenName,
            fatherSurname: fatherSurname, fatherGivenName: fatherGivenName,
            motherSurname: motherSurname, motherGivenName: motherGivenName
        )
    }

    public func with(givenName: String?) -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: givenName, recordType: recordType,
            yearFrom: yearFrom, yearTo: yearTo, gender: gender, region: region,
            sourceParams: sourceParams, strictness: strictness,
            birthPlace: birthPlace, deathPlace: deathPlace,
            residencePlace: residencePlace, marriagePlace: marriagePlace,
            anyPlace: anyPlace,
            spouseSurname: spouseSurname, spouseGivenName: spouseGivenName,
            fatherSurname: fatherSurname, fatherGivenName: fatherGivenName,
            motherSurname: motherSurname, motherGivenName: motherGivenName
        )
    }
}

/// Source-specific typed parameters. The dispatcher knows which source
/// gets which params; the source doesn't need to parse strings.
public nonisolated enum SourceQueryParams: Sendable {
    case freeBMD(FreeBMDParams)
    case freeCen(FreeCenParams)
    case findAGrave(FindAGraveParams)
    case cwgc(CWGCParams)
    case probate(ProbateParams)
    // `.wirksworth(WirksworthParams)` removed — SOURCE_WEIGHTING Change 0
    // retired the Wirksworth structured-source plugin (persisted evidence
    // with sourceID "wirksworth" remains valid; read-time classifiers keep
    // handling the ID).
    case freeREG(FreeREGParams)
    case generic
}

public nonisolated struct FreeBMDParams: Sendable {
    /// FT-01 feature gate — county-level `countyid` queries.
    ///
    /// When true, the dispatcher's `.county`/`.adjacent` scopes emit ONE
    /// query per county (via `countyCode`) instead of one query per
    /// registration district (12 for DBY). The emission path, params
    /// plumbing, and cache keying are fully wired and tested; the gate
    /// exists because the exact `countyid` wire value is UNVERIFIED
    /// against today's live form (CONNECTOR_AUDIT_2026-07 §1 — the
    /// ground-truth form payload never arrived). The audit's live-form
    /// note says the county dropdown's option values are compound
    /// strings (Chapman code + that county's district IDs, e.g.
    /// "BDF,66,133,…"); we reconstruct that value statically, but
    /// whether search.pl accepts a reconstructed ID list — or ignores
    /// `countyid` entirely, silently widening the query to national —
    /// needs the one FT-27 live probe session (audit §5.6).
    ///
    /// PROBED LIVE 2026-07-11: captured-table countyid value returned 49 rows across 13 Derbyshire-area districts (incl. cross-border ones — geography gate scores per-row districts, so that is correct behaviour). Gate ON. Default false = the
    /// safe pre-FT-01 per-district loop. The `.national` single-query
    /// path (FT-02) is NOT behind this gate — `districtid=""` is
    /// proven wire behaviour (Python sources/freebmd.py:152-153).
    public static let countyQueryEnabled = true

    public let districtCode: String?
    /// FT-01 — the finished FreeBMD `countyid` wire value for a
    /// county-level query (compound "DBY,406,418,…" — Chapman code
    /// followed by district IDs; built by
    /// `RegionConfig.freeBMDCountyID(forChapmanCode:)`). nil = no
    /// county axis; the query is district-level (`districtCode`) or
    /// national (both nil). When set, `FreeBMDSource` emits it as the
    /// `countyid` form field; when nil the field is omitted entirely
    /// (checkbox-presence semantics — see FT-06).
    public let countyCode: String?
    public let wildcardSurname: Bool
    public let motherSurname: String?
    public let spouseSurname: String?
    /// FT-03 — GRO reference volume for a same-page page-lookup query.
    /// FreeBMD's search form accepts a `vol` + `pgno` pair that fetches
    /// the 2–4 index entries registered on ONE GRO page in a single
    /// request. A marriage is registered on the same (volume, page)
    /// under BOTH parties' surnames, so a page-lookup on a subject-side
    /// marriage's own (vol, page) returns the spouse-side entry
    /// deterministically — even when NO spouse is on the tree (unlike
    /// the surname-sweep path, which needs the spouse surname up front).
    /// nil = no page filter; the two page fields are emitted only when
    /// BOTH are non-empty (a lone vol or page is not a valid page key).
    public let volume: String?
    /// FT-03 — GRO reference page for a same-page page-lookup query. See
    /// `volume`. Paired with it: both must be set for the source to emit
    /// the `vol`/`pgno` form fields.
    public let page: String?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    /// `volume`/`page` default nil so pre-FT-03 construction sites are
    /// unchanged.
    public init(districtCode: String? = nil, countyCode: String? = nil, wildcardSurname: Bool, motherSurname: String? = nil, spouseSurname: String? = nil, volume: String? = nil, page: String? = nil) {
        self.districtCode = districtCode
        self.countyCode = countyCode
        self.wildcardSurname = wildcardSurname
        self.motherSurname = motherSurname
        self.spouseSurname = spouseSurname
        self.volume = volume
        self.page = page
    }

}

public nonisolated struct FreeCenParams: Sendable {
    /// FT-25 / FT-28 batching gate — repeated-key multi-code requests.
    ///
    /// When true, the dispatcher batches a broad-scope RESIDENCE fan-out
    /// (the `.national`/`.adjacent` fallback when no home chapman is
    /// derivable) into groups of `Self.batchGroupSize` codes carried in
    /// ONE request via the repeated `search_query[chapman_codes][]`
    /// idiom (the `multiFields` transport primitive). When false — the
    /// safe default — the dispatcher emits the pre-FT-25 one-code-per-
    /// query fan-out, which is proven wire behaviour (Python builds the
    /// POST as a tuple list precisely for the repeated key, but whether
    /// FreeCen's live form honours it is UNVERIFIED — CONNECTOR_AUDIT
    /// FT-27; needs the one live probe session before enabling blind,
    /// exactly as `FreeBMDParams.countyQueryEnabled` was gated).
    ///
    /// Default false = flag for a probe rather than enable blind.
    public static let multiCodeBatchEnabled = false

    /// FT-28 group size — how many chapman codes ride ONE batched
    /// request. Conservative (not all-at-once): a whole-scope single
    /// request maximises first-page truncation, which FT-22/FT-23 flag
    /// as already more likely under wider queries. 10 cuts a ~90-code
    /// national residence sweep to ~9 requests (a ~10× reduction) while
    /// keeping each query's result set an order of magnitude smaller than
    /// batching everything, so the 500-result / 10-page pagination budget
    /// recovers most truncation. Automatic re-split on truncation (the
    /// audit's "mirroring FreeBMD's adaptive split") is the runtime
    /// follow-up; the static group size keeps the wire conservative until
    /// then.
    public static let batchGroupSize = 10

    /// RESIDENCE county filter — where the subject lived at census time
    /// (FreeCen's `search_query[chapman_codes][]`). nil/empty = no
    /// residence filter on the wire.
    public let chapmanCode: String?
    /// FT-25 — a BATCH of residence chapman codes carried in one request
    /// via repeated `search_query[chapman_codes][]` keys. Set by the
    /// dispatcher for broad-scope residence fan-out when
    /// `multiCodeBatchEnabled`; supersedes the single `chapmanCode` when
    /// present and non-empty. nil/empty = no batch (use `chapmanCode`).
    /// Order is preserved so the wire shape (and cache key) is stable.
    public let chapmanCodes: [String]?
    public let censusYear: Int?
    public let birthYearRange: ClosedRange<Int>?
    /// BIRTH county filter (connector-audit FT-11) — FreeCen's
    /// `search_query[birth_chapman_codes][]`, distinct from the
    /// residence filter above. The tree-known stable fact is where the
    /// subject was BORN, not where they lived at census time: a
    /// DBY-born subject in a Lancashire mill town is invisible to a
    /// residence-scoped query but reachable in ONE request with
    /// `birth_chapman_codes=[DBY]` and no residence filter — on
    /// exactly the field the scorer trusts most (the parsed
    /// birth_county column) and matching the engine's chapman-anchor
    /// philosophy. The dispatcher uses this as the primary axis for
    /// `.adjacent`/`.national` census sweeps, keeping residence codes
    /// for `.county`. nil/empty = no birth-county filter.
    ///
    /// Wire-affecting: MUST join `QueryCache.cacheKey`'s freeCen arm
    /// (FT-24 contract) — tracked as a coordinator follow-up.
    public let birthChapmanCode: String?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    /// `birthChapmanCode` defaults nil so pre-FT-11 construction sites
    /// (FocusedQuery, SourceExplorerView) are unchanged. `chapmanCodes`
    /// defaults nil so pre-FT-25 construction sites are unchanged.
    public init(chapmanCode: String? = nil, chapmanCodes: [String]? = nil, censusYear: Int? = nil, birthYearRange: ClosedRange<Int>? = nil, birthChapmanCode: String? = nil) {
        self.chapmanCode = chapmanCode
        self.chapmanCodes = chapmanCodes
        self.censusYear = censusYear
        self.birthYearRange = birthYearRange
        self.birthChapmanCode = birthChapmanCode
    }

}

public nonisolated struct FindAGraveParams: Sendable {
    /// Requested tolerance FLOOR for the year-axis filters — the value
    /// behind FAG's `birthyearfilter`/`deathyearfilter` wire params
    /// (T1-16). The connector rounds it UP through FAG's discrete
    /// tolerance ladder (1/2/3/5/10/25; 0 = exact) and widens it
    /// further when a subject-side window needs more slack — the
    /// emitted filter may be wider than requested, never narrower.
    public let yearRangeWidth: Int
    public let location: String?
    /// Subject-side birth-year window (T1-16). Populated from the
    /// SUBJECT's `birthYearFrom...birthYearTo` — never from
    /// `RecordQuery.yearFrom`/`yearTo`, which are the bounds of ONE
    /// record-type search window (for `.burial` both bounds are
    /// death-year ± slack). Mapping that window onto birth+death
    /// simultaneously is the historical birthyear=2015/deathyear=2019
    /// child-query bug the year params were removed for. nil = no
    /// birth-year filter on the wire.
    public let birthYearRange: ClosedRange<Int>?
    /// Subject-side death-year window (T1-16) — the axis a burial
    /// search keys on. Only a REAL death window belongs here; the
    /// dispatcher never maps the birth+15..birth+95 fallback guess in
    /// (FAG's widest tolerance is ±25, so an ~80-year guess would be
    /// silently narrowed into a false-negative filter). nil = no
    /// death-year filter on the wire.
    public let deathYearRange: ClosedRange<Int>?
    /// Page size (FAG's `limit` wire param). Default keeps the
    /// historical 20; dispatcher-settable so a truncated first page
    /// (envelope `truncated`/`totalAvailable`, T1-01/T1-16) can be
    /// re-requested larger — FAG accepts up to ~100
    /// (sources/findagrave.py:135). Distinct limits are distinct
    /// QueryCache keys, so a raise is a genuine re-fetch, never served
    /// the cached partial page. No `skip` pagination — batching stays
    /// out by design.
    public let limit: Int
    /// T1-23 (request-param half) — emit FAG's `includeMaidenName`
    /// flag so `lastname` also matches the memorial's maiden-name
    /// field. Populated for female subjects: married women are
    /// frequently memorialised under one surname with the other
    /// recorded as maiden name, and without the flag the maiden-filed
    /// memorial is server-side unfindable. Not in the Python
    /// reference's param enumeration (the audit's §7 note); ground
    /// truth is the live search form's "Include maiden name" checkbox —
    /// same provenance as T1-18's `includeNickName`. Broadening-only:
    /// extra hits are scored downstream, so a server-side no-op costs
    /// nothing and can never manufacture a false negative.
    public let includeMaidenName: Bool

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    /// New params default to today's wire behaviour (no year filters,
    /// limit 20, no maiden flag) so pre-T1-16 construction sites
    /// (FocusedQuery, SourceExplorerView) are unchanged.
    public init(
        yearRangeWidth: Int,
        location: String? = nil,
        birthYearRange: ClosedRange<Int>? = nil,
        deathYearRange: ClosedRange<Int>? = nil,
        limit: Int = 20,
        includeMaidenName: Bool = false
    ) {
        self.yearRangeWidth = yearRangeWidth
        self.location = location
        self.birthYearRange = birthYearRange
        self.deathYearRange = deathYearRange
        self.limit = limit
        self.includeMaidenName = includeMaidenName
    }

}

public nonisolated struct CWGCParams: Sendable {
    public let conflict: String?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(conflict: String? = nil) {
        self.conflict = conflict
    }

}

public nonisolated struct ProbateParams: Sendable {
    /// Grant-type scope for the Nuxeo `hmcts_grant_schema_grantdocTypeOf`
    /// filter, e.g. "PROBATE" / "ADMINISTRATION" — and, for soldier-wills
    /// or intestacy scoping, the document type the calendar exposes.
    ///
    /// T1-28 — this used to be dead plumbing: every construction site
    /// passed nil and `ProbateSource` never read `query.sourceParams`, so
    /// `grantdocTypeOf` always went out empty. `ProbateSource.search` now
    /// READS this param and puts it on the wire when non-empty, so a caller
    /// that wants intestacy/soldier-will scoping can finally reach it. The
    /// existing dispatcher/FocusedQuery construction sites still pass nil
    /// (an empty filter = "all grant types", unchanged wire behaviour), so
    /// this is opt-in, not a behaviour change.
    public let courtType: String?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(courtType: String? = nil) {
        self.courtType = courtType
    }

}

public nonisolated struct FreeREGParams: Sendable {
    /// FT-25 / FT-28 batching gate — repeated-key multi-code requests.
    /// FreeREG's `.adjacent` (~7 codes) and `.national` (~70 codes)
    /// scopes always fan out per chapman code; when true the dispatcher
    /// batches them into groups of `Self.batchGroupSize` codes per
    /// request via the repeated `search_query[chapman_codes][]` idiom.
    /// Default false — the pre-FT-25 one-code-per-query fan-out is proven
    /// wire behaviour; whether FreeREG's live form honours the repeated
    /// key is UNVERIFIED (CONNECTOR_AUDIT FT-27, same as FreeCen), so
    /// this flags for a probe rather than enabling blind — the
    /// `FreeBMDParams.countyQueryEnabled` pattern.
    public static let multiCodeBatchEnabled = false

    /// FT-28 group size — codes per batched request. Conservative for
    /// the same truncation reason as FreeCen (see
    /// `FreeCenParams.batchGroupSize`): 10 cuts a ~70-code national sweep
    /// to ~7 requests while keeping each result set well within the
    /// 500-result / 10-page pagination budget.
    public static let batchGroupSize = 10

    // `registerType` and `parish` were removed by SOURCE_WEIGHTING
    // Change 3 (SCOPE_AUDIT finding 4): neither ever reached the wire —
    // register type is derived from `query.recordType` source-side, and
    // the search form has no parish axis wired. Dead params invite the
    // strategist to "narrow" into a silent no-op.
    public let chapmanCode: String?
    /// FT-25 — a BATCH of chapman codes carried in one request via
    /// repeated `search_query[chapman_codes][]` keys. Supersedes the
    /// single `chapmanCode` when present and non-empty. nil/empty = no
    /// batch (use `chapmanCode`). Order is preserved so the wire shape
    /// (and cache key) is stable.
    public let chapmanCodes: [String]?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    /// `chapmanCodes` defaults nil so pre-FT-25 construction sites are
    /// unchanged.
    public init(chapmanCode: String? = nil, chapmanCodes: [String]? = nil) {
        self.chapmanCode = chapmanCode
        self.chapmanCodes = chapmanCodes
    }

}

// MARK: - Known Relative (used in FamilyContext)

public nonisolated struct KnownRelative: Codable, Sendable {
    public let name: String
    public let birthYear: Int?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(name: String, birthYear: Int? = nil) {
        self.name = name
        self.birthYear = birthYear
    }

}

// MARK: - Source Query Result

/// What a source search returns — distinguishes "no results" from "source broken".
public nonisolated enum SourceQueryResult: Sendable {
    case results([SourceRecord])
    case unavailable(reason: String)
    case throttled(retryAfter: Duration)
    case outsideCoverage(reason: String)
    /// Source needs credentials it doesn't have (or has expired ones).
    /// UI should prompt the user to authenticate; pipeline should treat
    /// the search as "didn't get to try" — see FAMILYSEARCH_SOURCE_SPEC §11.1.
    case requiresAuth(message: String)

    public var records: [SourceRecord] {
        if case .results(let r) = self { return r } else { return [] }
    }
}

// MARK: - Search Outcome (honesty envelope — connector audit T1-01 / FT-22 / FT-23)

/// How the source answered one (source, query) attempt.
///
/// Distinct from `SourceQueryResult`, which carries the records themselves:
/// availability classifies whether an empty answer can be *trusted* as
/// evidence of absence. Blocks, API errors, throttles, and auth walls must
/// never be recorded as "searched, found nothing" — that poisons
/// negative-evidence reasoning and the GPS "reasonably exhaustive search"
/// criterion (CONNECTOR_AUDIT_2026-07 §5.1, §6.1 T1-01).
public nonisolated enum SearchAvailability: Sendable, Equatable {
    /// The source answered normally. Emptiness is meaningful (subject to
    /// `truncated`).
    case ok
    /// The source failed to answer (HTTP error, malformed payload, page
    /// outside coverage, validation error). Emptiness is meaningless.
    case error(reason: String)
    /// The source is rate-limiting us TRANSIENTLY (an HTTP 429 that the
    /// circuit breaker will clear in seconds-to-minutes). Distinct from
    /// `budgetExhausted`: a throttle is worth waiting out with a short
    /// cool-down ladder; a budget exhaustion is not (ENGINE_FOUNDATION
    /// #Change5). Emptiness is meaningless.
    case throttled
    /// The source's DAILY quota is spent — it will not answer usefully
    /// again until `resumeAt` (the source's documented reset, else UTC
    /// midnight). Unlike `.throttled`, this must NOT trigger the
    /// 60s/300s/900s circuit-breaker ladder: no amount of short-cool-down
    /// retrying recovers a spent daily budget, so the engine parks the
    /// source until `resumeAt` and continues with the others
    /// (ENGINE_FOUNDATION #Change5). Emptiness is meaningless.
    case budgetExhausted(resumeAt: Date)
    /// Anti-bot / block page detected (e.g. Find a Grave's Cloudflare
    /// challenge). Emptiness is meaningless.
    case blocked(reason: String)
    /// The source needs credentials it doesn't have. Emptiness is meaningless.
    case requiresAuth
    /// The DISPATCHER decided not to search this (source, scope) at all —
    /// e.g. an anchor-less subject at a geographically bounded scope, or a
    /// source with no endpoint at this granularity (SOURCE_WEIGHTING
    /// Change 2). Nothing failed and nothing was searched: not conclusive,
    /// never a negative. The reason is the honesty copy for the
    /// searched-surface.
    case skipped(reason: String)
}

/// Per-(source, query) search outcome — the honesty envelope.
///
/// `truncated` covers the page-1 problem (FT-22): connectors that fetch a
/// single page of a paginated result set, or hit a too-many-results
/// interstitial, must flag that the answer is partial. `totalAvailable`
/// carries the site's own claimed hit count when one was parsed (FT-23),
/// so `resultCount < totalAvailable` is checkable downstream.
///
/// Only a clean outcome — `availability == .ok`, `truncated == false`,
/// `resultCount == 0` — may be recorded as a genuine negative search.
public nonisolated struct SearchOutcome: Sendable, Equatable {
    /// Records actually parsed and returned for this query.
    public let resultCount: Int
    /// The site's own claimed total hit count, when the connector parsed
    /// one (FreeCen "We found N Results", Probate `resultsCount`, FAG
    /// `total`, FreeBMD's overflow entry count). Nil when unknown.
    public let totalAvailable: Int?
    /// True when the returned records are known or suspected to be a
    /// partial answer: parsed rows < claimed total, pagination nav
    /// present, or an unsplittable too-many-results overflow.
    public let truncated: Bool
    public let availability: SearchAvailability
    /// True when this empty answer was NOT obtained by hitting the wire
    /// this run — the query was skipped because a PRIOR run recorded it
    /// as a clean negative and the record is still fresh (connector-audit
    /// T1-04 / §5.2 persistent negative-search cache). The result is a
    /// genuine `.ok` zero (broadening the strictness ladder on it is
    /// correct — known-empty is as empty as freshly-verified-empty), but
    /// it must NOT be re-persisted as a new negative: it would double-
    /// count the same absence and refresh a stale `searched_at` without
    /// re-verifying. `suppressionReason` carries the human-facing
    /// "skipped — searched \<date\>, empty" string for the activity feed.
    /// Never set on a live wire answer.
    public let suppressed: Bool
    /// Non-nil only when `suppressed` — a short reason string for the
    /// activity feed / audit trail (e.g. "prior clean negative
    /// 2026-06-30").
    public let suppressionReason: String?

    public init(
        resultCount: Int,
        totalAvailable: Int? = nil,
        truncated: Bool = false,
        availability: SearchAvailability = .ok,
        suppressed: Bool = false,
        suppressionReason: String? = nil
    ) {
        self.resultCount = resultCount
        self.totalAvailable = totalAvailable
        self.truncated = truncated
        self.availability = availability
        self.suppressed = suppressed
        self.suppressionReason = suppressionReason
    }

    /// A synthetic outcome for a query skipped because a prior run
    /// recorded it as a clean negative (T1-04). Clean `.ok` zero so the
    /// ladder broadens exactly as it would on a freshly-verified empty,
    /// flagged `suppressed` so persistence never re-counts it.
    public static func suppressedNegative(reason: String) -> SearchOutcome {
        SearchOutcome(
            resultCount: 0,
            availability: .ok,
            suppressed: true,
            suppressionReason: reason
        )
    }

    /// A synthetic outcome for a (source, scope) pairing the dispatcher
    /// skipped BEFORE building any queries (SOURCE_WEIGHTING Change 2).
    /// Availability `.skipped` keeps it out of GPS criterion 1
    /// (`isConclusive == false`), out of negative persistence
    /// (`isCleanNegative == false`), and out of ladder broadening.
    public static func scopeSkip(reason: String) -> SearchOutcome {
        SearchOutcome(resultCount: 0, availability: .skipped(reason: reason))
    }

    /// True when this outcome's record set can be trusted as the source's
    /// complete answer — the source responded normally and did not
    /// truncate. Only conclusive outcomes count toward GPS criterion 1,
    /// and only conclusive emptiness may stop-or-broaden the strictness
    /// ladder on merit.
    public var isConclusive: Bool {
        availability == .ok && !truncated
    }

    /// True when this outcome is a genuine "searched, found nothing" —
    /// the only shape that may be persisted as negative evidence.
    ///
    /// A `suppressed` outcome is deliberately EXCLUDED: it was never
    /// searched on the wire this run (it IS the replay of an earlier
    /// negative), so re-persisting it would double-count the absence and
    /// silently refresh the freshness window without re-verifying the
    /// source. `NegativeSearchAggregator` relies on this to avoid the
    /// double-count guard (T1-04 correctness guard (a)).
    public var isCleanNegative: Bool {
        isConclusive && resultCount == 0 && !suppressed
    }
}

extension SourceQueryResult {
    /// Map the plain result into the honesty envelope. This is the
    /// *default* mapping — connectors that can detect truncation, hit
    /// counts, or block pages return a richer `SearchOutcome` through
    /// `searchWithOutcome` instead. Note `.outsideCoverage` maps to
    /// `.error`: nothing was searched, so the emptiness must not read
    /// as a genuine negative.
    public var outcome: SearchOutcome {
        switch self {
        case .results(let r):
            return SearchOutcome(resultCount: r.count)
        case .unavailable(let reason):
            return SearchOutcome(resultCount: 0, availability: .error(reason: reason))
        case .throttled:
            return SearchOutcome(resultCount: 0, availability: .throttled)
        case .outsideCoverage(let reason):
            return SearchOutcome(resultCount: 0, availability: .error(reason: "outside coverage: \(reason)"))
        case .requiresAuth:
            return SearchOutcome(resultCount: 0, availability: .requiresAuth)
        }
    }
}

// MARK: - Source Readiness

public nonisolated enum SourceReadiness: Sendable {
    case ready
    case needsAuth(message: String)
    case unavailable(reason: String)
}

// MARK: - Source Terms of Service Status

/// How this source's programmatic access relates to its terms of service.
public nonisolated struct SourceToSStatus: Sendable {
    public let level: ToSLevel
    public let summary: String     // short description for Settings UI

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(level: ToSLevel, summary: String) {
        self.level = level
        self.summary = summary
    }


    public enum ToSLevel: Sendable {
        case open           // public API or explicitly permitted
        case community      // volunteer project, no prohibition, no explicit API
        case restricted     // ToS restricts automated access
    }
}
