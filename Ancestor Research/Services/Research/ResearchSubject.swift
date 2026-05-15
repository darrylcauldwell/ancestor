import Foundation

/// The four research modes — each tunes pipeline thoroughness rather than
/// running different algorithms. Same dispatcher, same sources, same scoring;
/// modes differ in iteration count, fact caps, and early-stop conditions.
nonisolated enum ResearchMode: String, Sendable {
    /// Confirm what's already in the tree. Stops early if all facts corroborated.
    case verify
    /// Fill missing facts (death date, marriage). Standard iterations.
    case extend
    /// Find this person from scratch (ghost node). Broadest search.
    case discover
    /// Most thorough preset — runs everything Discover does, plus extra
    /// iterations and a higher fact cap. Use when you want the kitchen sink.
    case all
}

/// Profile-contextual trigger for a research run. Used by the profile-detail
/// "Research" sheet to fire a research run with mode/scope picked at the moment
/// of triggering, rather than relying on whatever's currently set on the
/// Research view's controls.
nonisolated struct ResearchRequest: Sendable {
    let profileID: String
    let mode: ResearchMode
    let scope: ResearchScope
}

/// How widely to fan out scope-aware sources (FreeBMD, FreeCen, FreeREG).
/// Mode is orthogonal — depth (verify/extend/discover/all) is on `ResearchMode`.
///
/// Ordered widening:
///   parish < district < county < adjacent < national
///
/// - `parish`: subject's home parish only. Parish-unsupported sources
///   (FreeBMD, CWGC, Probate, FindAGrave) return zero queries.
/// - `district`: subject's home registration district. Sources without a
///   district axis (FreeREG, FreeCen) widen to `.county` for that source only.
/// - `county`: all districts in the subject's home county. The old `.local`.
/// - `adjacent`: home county + counties bordering it (single hop, via
///   `RegionConfig.adjacentCounties`). FreeBMD falls back to `.county` until
///   per-county district data exists for non-Derbyshire counties.
/// - `national`: entire UK catalogue. The old `.national`.
///
/// Transitional: until `Profile.birthLocationCode` ships (prior spec's Change 2),
/// `.parish` and `.district` silently widen to `.county` for any subject lacking
/// a structured location code. See RESEARCH_AXES_SPEC §3.2.
nonisolated enum ResearchScope: String, Comparable, Sendable, CaseIterable {
    case parish
    case district
    case county
    case adjacent
    case national

    private var order: Int {
        switch self {
        case .parish: return 0
        case .district: return 1
        case .county: return 2
        case .adjacent: return 3
        case .national: return 4
        }
    }

    static func < (lhs: ResearchScope, rhs: ResearchScope) -> Bool {
        lhs.order < rhs.order
    }
}

/// The person being researched.
nonisolated struct ResearchSubject: Sendable {
    /// Profile ID this subject was built from, if any.
    /// nil for manual-input subjects and leads (no profile yet exists).
    /// Required for parent-inference to create real parent-of edges.
    var profileID: String?
    var surname: String?
    var givenName: String?
    var birthYearFrom: Int?
    var birthYearTo: Int?
    var deathYearFrom: Int?
    var deathYearTo: Int?
    var gender: Gender?
    var region: Region?
    var mode: ResearchMode
    var familyContext: FamilyContext?
    /// Chapman code of the subject's home county — drives per-subject scoring
    /// and dispatch lookups. Defaults to "DBY" (Derbyshire) for legacy data
    /// where the project's home_chapman_code wasn't set at creation. See
    /// RESEARCH_AXES_SPEC.md Change 1.
    var homeChapmanCode: String = "DBY"
}

/// Known family members for the family context gate.
nonisolated struct FamilyContext: Sendable {
    let spouseName: String?
    let spouseSurname: String?
    let childNames: [String]
    let fatherName: String?
    let motherName: String?
}

nonisolated extension ResearchSubject {
    var displayName: String {
        [givenName, surname].compactMap { $0 }.joined(separator: " ")
    }

    /// Year range for a given record type.
    func yearRange(for recordType: RecordType) -> (from: Int?, to: Int?) {
        switch recordType {
        case .birth, .christening, .baptism:
            return (birthYearFrom.map { $0 - 2 }, birthYearTo.map { $0 + 2 })
        case .death, .burial, .probate:
            if let df = deathYearFrom { return (df - 2, (deathYearTo ?? df) + 2) }
            // Fallback: birth + 15 to birth + 95
            if let bf = birthYearFrom { return (bf + 15, (birthYearTo ?? bf) + 95) }
            return (nil, nil)
        case .marriage:
            if let bf = birthYearFrom { return (bf + 16, (deathYearTo ?? (birthYearTo ?? bf) + 60)) }
            return (nil, nil)
        case .census:
            let earliest = birthYearFrom ?? 1841
            let latest = deathYearTo ?? (birthYearTo.map { $0 + 80 } ?? 1911)
            return (earliest, latest)
        default:
            return (birthYearFrom, deathYearTo ?? birthYearTo)
        }
    }

    /// Refine the subject from confirmed facts (learned date propagation).
    func refined(withBirthYear: Int? = nil, withDeathYear: Int? = nil) -> ResearchSubject {
        var s = self
        if let by = withBirthYear {
            s.birthYearFrom = by
            s.birthYearTo = by
        }
        if let dy = withDeathYear {
            s.deathYearFrom = dy
            s.deathYearTo = dy
        }
        return s
    }

    /// Build from an existing profile.
    static func fromProfile(
        _ profile: Profile,
        snapshot: FamilyGraphSnapshot,
        mode: ResearchMode = .extend,
        homeChapmanCode: String = "DBY"
    ) -> ResearchSubject {
        // Build family context from the tree
        let spouses = snapshot.spousesOf(profile.id)
        let children = snapshot.childrenOf(profile.id)
        let parents = snapshot.parentsOf(profile.id)

        let context = FamilyContext(
            spouseName: spouses.first?.displayName,
            spouseSurname: spouses.first?.lastName,
            childNames: children.map(\.displayName),
            fatherName: parents.first(where: { $0.gender == .male })?.displayName,
            motherName: parents.first(where: { $0.gender == .female })?.displayName
        )

        return ResearchSubject(
            profileID: profile.id,
            surname: profile.lastName,
            givenName: profile.firstName,
            birthYearFrom: profile.birthDate?.earliest,
            birthYearTo: profile.birthDate?.latest,
            deathYearFrom: profile.deathDate?.earliest,
            deathYearTo: profile.deathDate?.latest,
            gender: profile.gender,
            region: profile.birthLocation.map { .county($0) },
            mode: mode,
            familyContext: context,
            homeChapmanCode: homeChapmanCode
        )
    }

    /// Build from manual user input.
    static func fromUserInput(
        surname: String?, givenName: String?,
        birthYear: Int?, deathYear: Int?,
        gender: Gender?, location: String?,
        mode: ResearchMode = .extend,
        homeChapmanCode: String = "DBY"
    ) -> ResearchSubject {
        ResearchSubject(
            surname: surname, givenName: givenName,
            birthYearFrom: birthYear, birthYearTo: birthYear,
            deathYearFrom: deathYear, deathYearTo: deathYear,
            gender: gender,
            region: location.map { .county($0) },
            mode: mode,
            familyContext: nil,
            homeChapmanCode: homeChapmanCode
        )
    }
}
