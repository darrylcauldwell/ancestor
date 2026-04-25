import Foundation

/// The three research modes — each affects pipeline behaviour.
nonisolated enum ResearchMode: String, Sendable {
    /// Confirm what's already in the tree. Stops early if all facts corroborated.
    case verify
    /// Fill missing facts (death date, marriage). Standard iterations.
    case extend
    /// Find this person from scratch (ghost node). Broadest search.
    case discover
}

/// The person being researched.
nonisolated struct ResearchSubject: Sendable {
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
    static func fromProfile(_ profile: Profile, snapshot: FamilyGraphSnapshot, mode: ResearchMode = .extend) -> ResearchSubject {
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
            surname: profile.lastName,
            givenName: profile.firstName,
            birthYearFrom: profile.birthDate?.earliest,
            birthYearTo: profile.birthDate?.latest,
            deathYearFrom: profile.deathDate?.earliest,
            deathYearTo: profile.deathDate?.latest,
            gender: profile.gender,
            region: profile.birthLocation.map { .county($0) },
            mode: mode,
            familyContext: context
        )
    }

    /// Build from manual user input.
    static func fromUserInput(
        surname: String?, givenName: String?,
        birthYear: Int?, deathYear: Int?,
        gender: Gender?, location: String?,
        mode: ResearchMode = .extend
    ) -> ResearchSubject {
        ResearchSubject(
            surname: surname, givenName: givenName,
            birthYearFrom: birthYear, birthYearTo: birthYear,
            deathYearFrom: deathYear, deathYearTo: deathYear,
            gender: gender,
            region: location.map { .county($0) },
            mode: mode,
            familyContext: nil
        )
    }
}
