import Foundation

// MARK: - Record Type

/// What kind of record to search for.
nonisolated enum RecordType: String, Codable, Sendable {
    case birth, death, marriage, census, burial, military, probate
    case baptism, christening, parish, pedigree
}

// MARK: - Record Common

/// Fields shared by all record types.
nonisolated struct RecordCommon: Codable, Sendable {
    let id: String
    let sourceID: String
    let name: String?
    let surname: String?
    let givenName: String?
    let detailURL: String?
    let rawFields: [String: String]
}

// MARK: - Type-Specific Records

nonisolated struct BirthRecord: Codable, Sendable {
    let common: RecordCommon
    let birthYear: Int?
    let birthDate: String?
    let birthPlace: String?
    let quarter: String?
    let district: String?
    let volume: String?
    let page: String?
    let mothersMaidenName: String?
}

nonisolated struct DeathRecord: Codable, Sendable {
    let common: RecordCommon
    let deathYear: Int?
    let deathDate: String?
    let deathPlace: String?
    let age: Int?
    let quarter: String?
    let district: String?
    let volume: String?
    let page: String?
    let spouseSurname: String?
}

nonisolated struct MarriageRecord: Codable, Sendable {
    let common: RecordCommon
    let marriageYear: Int?
    let marriageDate: String?
    let marriagePlace: String?
    let quarter: String?
    let district: String?
    let volume: String?
    let page: String?
    let spouseName: String?
}

nonisolated struct CensusRecord: Codable, Sendable {
    let common: RecordCommon
    let censusYear: Int
    let age: Int?
    let birthYear: Int?
    let birthPlace: String?
    let birthCounty: String?
    let relationship: String?
    let occupation: String?
    let address: String?
    let parish: String?
    let district: String?
    let household: [HouseholdMember]?
}

nonisolated struct BurialRecord: Codable, Sendable {
    let common: RecordCommon
    let deathDate: String?
    let deathYear: Int?
    let birthDate: String?
    let birthYear: Int?
    let burialLocation: String?
    let cemetery: String?
    let memorialID: Int?
    let inscription: String?
    let bio: String?
    let isVeteran: Bool
}

nonisolated struct MilitaryRecord: Codable, Sendable {
    let common: RecordCommon
    let rank: String?
    let regiment: String?
    let unit: String?
    let serviceNumber: String?
    let dateOfDeath: String?
    let deathYear: Int?
    let age: Int?
    let cemetery: String?
    let graveRef: String?
    let additionalInfo: String?
}

nonisolated struct ProbateRecord: Codable, Sendable {
    let common: RecordCommon
    let deathDate: String?
    let deathYear: Int?
    let probateDate: String?
    let birthDate: String?
    let ageAtDeath: Int?
    let address: String?
    let grantType: String?
    let registry: String?
    let probateNumber: String?
    let regimentNumber: Int?
}

nonisolated struct ParishRecord: Codable, Sendable {
    let common: RecordCommon
    let eventType: String?
    let eventDate: String?
    let eventYear: Int?
    let parish: String?
    let county: String?
    let fatherName: String?
    let motherName: String?
}

nonisolated struct PedigreeRecord: Codable, Sendable {
    let common: RecordCommon
    let birthYear: Int?
    let deathYear: Int?
    let spouse: String?
    let marriageYear: Int?
    let occupation: String?
    let location: String?
    let generation: Int?
}

// MARK: - Household Member (shared by CensusRecord and ScoringRules)

nonisolated struct HouseholdMember: Codable, Sendable, Hashable {
    let name: String
    let relationship: String
    let age: Int?
    let birthYear: Int?
    let birthPlace: String?
    let occupation: String?
    let sex: String?
}

// MARK: - Source Record (enum with associated values)

/// A record returned from a source — typed by record kind.
/// Codable so it can be JSON-persisted in the evidence_records table without losing
/// any field (typed or raw). All associated values are already Codable.
nonisolated enum SourceRecord: Identifiable, Sendable, Codable {
    case birth(BirthRecord)
    case death(DeathRecord)
    case marriage(MarriageRecord)
    case census(CensusRecord)
    case burial(BurialRecord)
    case military(MilitaryRecord)
    case probate(ProbateRecord)
    case parish(ParishRecord)
    case pedigree(PedigreeRecord)

    var id: String { common.id }
    var sourceID: String { common.sourceID }
    var name: String? { common.name }
    var surname: String? { common.surname }
    var givenName: String? { common.givenName }
    var detailURL: String? { common.detailURL }
    var rawFields: [String: String] { common.rawFields }

    var common: RecordCommon {
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
    var recordType: RecordType {
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
nonisolated struct RecordQuery: Sendable {
    let surname: String?
    let givenName: String?
    let recordType: RecordType
    let yearFrom: Int?
    let yearTo: Int?
    let gender: Gender?
    let region: Region?
    let sourceParams: SourceQueryParams
    /// Name-match strictness. Defaults to `.strict`. Sources may ignore it
    /// — see RESEARCH_AXES_SPEC §7 for which sources honour which tiers.
    /// Change 4 ships the field with no source-side handling; Change 5
    /// wires the per-source query rewriting; Change 6 wires the dispatcher's
    /// empty-then-broaden flow.
    let strictness: SearchStrictness

    // MARK: Family-context axes (spec §23)
    // All optional. Source URL builders cherry-pick what they understand —
    // FS uses all of them, FreeBMD uses spouse+mother surname, FAG uses
    // birthPlace as `location`. nil means "axis not available for this
    // subject" (e.g. parents not on the tree).
    let birthPlace: String?
    let deathPlace: String?
    let spouseSurname: String?
    let spouseGivenName: String?
    let fatherSurname: String?
    let fatherGivenName: String?
    let motherSurname: String?
    let motherGivenName: String?

    /// Custom init so `strictness` can be defaulted without losing the
    /// memberwise calling convention (Swift drops defaulted `let` fields
    /// from the synthesised init).
    init(
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
    func with(strictness: SearchStrictness) -> RecordQuery {
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

    func with(surname: String?) -> RecordQuery {
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
nonisolated enum SourceQueryParams: Sendable {
    case freeBMD(FreeBMDParams)
    case freeCen(FreeCenParams)
    case findAGrave(FindAGraveParams)
    case cwgc(CWGCParams)
    case probate(ProbateParams)
    case wirksworth(WirksworthParams)
    case freeREG(FreeREGParams)
    case generic
}

nonisolated struct FreeBMDParams: Sendable {
    let districtCode: String?
    let wildcardSurname: Bool
    let motherSurname: String?
    let spouseSurname: String?
}

nonisolated struct FreeCenParams: Sendable {
    let chapmanCode: String?
    let censusYear: Int?
    let birthYearRange: ClosedRange<Int>?
}

nonisolated struct FindAGraveParams: Sendable {
    let yearRangeWidth: Int
    let location: String?
}

nonisolated struct CWGCParams: Sendable {
    let conflict: String?
}

nonisolated struct ProbateParams: Sendable {
    let courtType: String?       // "PROBATE", "ADMINISTRATION", etc.
}

nonisolated struct WirksworthParams: Sendable {
    let parishHint: String?      // Specific parish within Wirksworth area
}

nonisolated struct FreeREGParams: Sendable {
    let registerType: String?    // "ba" (baptism), "ma" (marriage), "bu" (burial)
    let parish: String?
    let chapmanCode: String?
}

// MARK: - Known Relative (used in FamilyContext)

nonisolated struct KnownRelative: Codable, Sendable {
    let name: String
    let birthYear: Int?
}

// MARK: - Source Query Result

/// What a source search returns — distinguishes "no results" from "source broken".
nonisolated enum SourceQueryResult: Sendable {
    case results([SourceRecord])
    case unavailable(reason: String)
    case throttled(retryAfter: Duration)
    case outsideCoverage(reason: String)
    /// Source needs credentials it doesn't have (or has expired ones).
    /// UI should prompt the user to authenticate; pipeline should treat
    /// the search as "didn't get to try" — see FAMILYSEARCH_SOURCE_SPEC §11.1.
    case requiresAuth(message: String)

    var records: [SourceRecord] {
        if case .results(let r) = self { return r } else { return [] }
    }
}

// MARK: - Source Readiness

nonisolated enum SourceReadiness: Sendable {
    case ready
    case needsAuth(message: String)
    case unavailable(reason: String)
}

// MARK: - Source Terms of Service Status

/// How this source's programmatic access relates to its terms of service.
nonisolated struct SourceToSStatus: Sendable {
    let level: ToSLevel
    let summary: String     // short description for Settings UI

    enum ToSLevel: Sendable {
        case open           // public API or explicitly permitted
        case community      // volunteer project, no prohibition, no explicit API
        case restricted     // ToS restricts automated access
    }
}
