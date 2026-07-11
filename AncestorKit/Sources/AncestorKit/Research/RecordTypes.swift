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

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: String, sourceID: String, name: String? = nil, surname: String? = nil, givenName: String? = nil, detailURL: String? = nil, rawFields: [String: String]) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.surname = surname
        self.givenName = givenName
        self.detailURL = detailURL
        self.rawFields = rawFields
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
    public let grantType: String?
    public let registry: String?
    public let probateNumber: String?
    public let regimentNumber: Int?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(common: RecordCommon, deathDate: String? = nil, deathYear: Int? = nil, probateDate: String? = nil, birthDate: String? = nil, ageAtDeath: Int? = nil, address: String? = nil, grantType: String? = nil, registry: String? = nil, probateNumber: String? = nil, regimentNumber: Int? = nil) {
        self.common = common
        self.deathDate = deathDate
        self.deathYear = deathYear
        self.probateDate = probateDate
        self.birthDate = birthDate
        self.ageAtDeath = ageAtDeath
        self.address = address
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
        self.spouseSurname = spouseSurname
        self.spouseGivenName = spouseGivenName
        self.fatherSurname = fatherSurname
        self.fatherGivenName = fatherGivenName
        self.motherSurname = motherSurname
        self.motherGivenName = motherGivenName
    }

    /// Builder helpers for the dispatcher's strictness ladder (Change 5).
    /// All other fields preserved. See RESEARCH_AXES_SPEC §7.
    public func with(strictness: SearchStrictness) -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: givenName, recordType: recordType,
            yearFrom: yearFrom, yearTo: yearTo, gender: gender, region: region,
            sourceParams: sourceParams, strictness: strictness,
            birthPlace: birthPlace, deathPlace: deathPlace,
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
    case wirksworth(WirksworthParams)
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
    /// DO NOT flip to true without that probe. Default false = the
    /// safe pre-FT-01 per-district loop. The `.national` single-query
    /// path (FT-02) is NOT behind this gate — `districtid=""` is
    /// proven wire behaviour (Python sources/freebmd.py:152-153).
    public static let countyQueryEnabled = false

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

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(districtCode: String? = nil, countyCode: String? = nil, wildcardSurname: Bool, motherSurname: String? = nil, spouseSurname: String? = nil) {
        self.districtCode = districtCode
        self.countyCode = countyCode
        self.wildcardSurname = wildcardSurname
        self.motherSurname = motherSurname
        self.spouseSurname = spouseSurname
    }

}

public nonisolated struct FreeCenParams: Sendable {
    public let chapmanCode: String?
    public let censusYear: Int?
    public let birthYearRange: ClosedRange<Int>?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(chapmanCode: String? = nil, censusYear: Int? = nil, birthYearRange: ClosedRange<Int>? = nil) {
        self.chapmanCode = chapmanCode
        self.censusYear = censusYear
        self.birthYearRange = birthYearRange
    }

}

public nonisolated struct FindAGraveParams: Sendable {
    public let yearRangeWidth: Int
    public let location: String?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(yearRangeWidth: Int, location: String? = nil) {
        self.yearRangeWidth = yearRangeWidth
        self.location = location
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
    public let courtType: String?       // "PROBATE", "ADMINISTRATION", etc.

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(courtType: String? = nil) {
        self.courtType = courtType
    }

}

public nonisolated struct WirksworthParams: Sendable {
    public let parishHint: String?      // Specific parish within Wirksworth area

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(parishHint: String? = nil) {
        self.parishHint = parishHint
    }

}

public nonisolated struct FreeREGParams: Sendable {
    public let registerType: String?    // "ba" (baptism), "ma" (marriage), "bu" (burial)
    public let parish: String?
    public let chapmanCode: String?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(registerType: String? = nil, parish: String? = nil, chapmanCode: String? = nil) {
        self.registerType = registerType
        self.parish = parish
        self.chapmanCode = chapmanCode
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
    /// The source is rate-limiting us. Emptiness is meaningless.
    case throttled
    /// Anti-bot / block page detected (e.g. Find a Grave's Cloudflare
    /// challenge). Emptiness is meaningless.
    case blocked(reason: String)
    /// The source needs credentials it doesn't have. Emptiness is meaningless.
    case requiresAuth
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

    public init(
        resultCount: Int,
        totalAvailable: Int? = nil,
        truncated: Bool = false,
        availability: SearchAvailability = .ok
    ) {
        self.resultCount = resultCount
        self.totalAvailable = totalAvailable
        self.truncated = truncated
        self.availability = availability
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
    public var isCleanNegative: Bool {
        isConclusive && resultCount == 0
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
