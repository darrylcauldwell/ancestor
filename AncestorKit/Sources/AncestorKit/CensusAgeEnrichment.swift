import Foundation

/// How a target relative sits relative to the census SUBJECT (the person whose
/// household roster we're reading). Used to break name ambiguity by roster
/// role — a "John" who is the subject's parent must be the Head/Wife, never a
/// Son. Absent (name-only matching) the engine stays conservative and skips
/// ambiguous rows.
public nonisolated enum CensusRelation: Sendable {
    case parent, sibling, spouse, child
}

/// A proposal to fill an EMPTY birth year on a profile that is already
/// structurally linked to the census subject, using an age (or stated birth
/// year) from that subject's census household roster.
///
/// This is the "linked → enrich" half of census-roster absorption (the
/// "unlinked → surface as a discovery/lead" half is handled by
/// `DiscoveryExtractor`'s `.unknownSibling` / `.unknownChild` /
/// `.householdMember` paths). It makes NO new identity claim — it only
/// touches people the user has already vouched for as relatives of the
/// subject — and it only ever fills a gap, never overwrites a known date.
public nonisolated struct BirthYearProposal: Sendable, Hashable, Identifiable {
    public let targetProfileID: String
    public let targetName: String
    public let estimatedBirthYear: Int
    public let censusYear: Int
    /// The roster relationship string the estimate came from ("Head", "Wife",
    /// "Son"…) — informational; the target is already a known relative.
    public let relationshipLabel: String
    public let sourceID: String?

    public var id: String { "\(targetProfileID)-\(censusYear)" }

    public init(targetProfileID: String, targetName: String, estimatedBirthYear: Int,
                censusYear: Int, relationshipLabel: String, sourceID: String?) {
        self.targetProfileID = targetProfileID
        self.targetName = targetName
        self.estimatedBirthYear = estimatedBirthYear
        self.censusYear = censusYear
        self.relationshipLabel = relationshipLabel
        self.sourceID = sourceID
    }
}

/// Derives circa birth years for already-linked household members from a
/// census age. A census age → birth year is arithmetic (`censusYear − age`),
/// precise to ±1 (the person's birthday may not have passed on census night),
/// so the result is best represented with the `.calculated` GenealogicalDate
/// qualifier ("CAL 1861") — the caller owns that conversion.
public nonisolated struct CensusAgeEnrichment {

    /// Roster relationship strings that are NOT blood/marriage family. A
    /// boarder or servant who happens to share a linked relative's name must
    /// never seed that relative's birth year.
    private static let nonFamilyRoles = [
        "servant", "boarder", "lodger", "visitor", "nurse", "employee",
        "apprentice", "governess", "housekeeper", "assistant", "worker", "inmate",
    ]

    /// Propose gap-filling birth years for members of `household` that map,
    /// unambiguously and by name, onto a `linkedRelatives` profile whose birth
    /// year is currently empty.
    ///
    /// Safety rules, in order:
    ///  1. Only relatives with NO usable birth year are candidates (gap-fill).
    ///  2. Non-family roster roles are ignored outright.
    ///  3. A member must have a usable age or stated birth year.
    ///  4. Matching is TWO-WAY unique: a proposal is emitted only when exactly
    ///     one candidate relative matches the member AND exactly one member
    ///     matches that relative. Any ambiguity (two "John"s) is skipped, not
    ///     guessed — consistent with "when in doubt, split".
    public static func proposals(
        subjectID: String,
        household: [HouseholdMember],
        censusYear: Int,
        linkedRelatives: [Profile],
        sourceID: String?,
        relations: [String: CensusRelation] = [:]
    ) -> [BirthYearProposal] {
        let gapRelatives = linkedRelatives.filter {
            $0.id != subjectID && $0.birthDate?.bestYear == nil
        }
        guard !gapRelatives.isEmpty else { return [] }

        // Family members with a usable year, paired with their estimate.
        let candidates: [(member: HouseholdMember, year: Int)] = household.compactMap { m in
            let role = m.relationship.lowercased()
            if Self.nonFamilyRoles.contains(where: { role.contains($0) }) { return nil }
            guard let year = Self.estimatedYear(m, censusYear: censusYear) else { return nil }
            return (m, year)
        }

        var proposals: [BirthYearProposal] = []
        for target in gapRelatives {
            var matches = candidates.filter { Self.nameMatches($0.member.name, target) }
            // Role-aware tiebreak: if several roster rows share the name but we
            // know how the target relates to the subject, keep only the rows
            // whose census role is compatible (a parent → Head/Wife, not Son).
            if matches.count > 1, let relation = relations[target.id] {
                let refined = matches.filter { Self.roleIsCompatible($0.member.relationship, with: relation) }
                if refined.count == 1 { matches = refined }
            }
            guard matches.count == 1 else { continue }        // 0 or still-ambiguous
            let hit = matches[0]
            // Member-side uniqueness: this member must not also plausibly be a
            // different gap relative.
            let relativesForMember = gapRelatives.filter { Self.nameMatches(hit.member.name, $0) }
            guard relativesForMember.count == 1 else { continue }

            proposals.append(BirthYearProposal(
                targetProfileID: target.id,
                targetName: target.displayName,
                estimatedBirthYear: hit.year,
                censusYear: censusYear,
                relationshipLabel: hit.member.relationship,
                sourceID: sourceID
            ))
        }
        return proposals
    }

    /// Prefer a stated birth year; otherwise back it out of the age. Guards
    /// against nonsense ages so a corrupt "age 0"/"age 999" row can't seed a
    /// wild year.
    static func estimatedYear(_ m: HouseholdMember, censusYear: Int) -> Int? {
        if let by = m.birthYear, by > 1000, by <= censusYear { return by }
        if let a = m.age, a > 0, a < 120 { return censusYear - a }
        return nil
    }

    /// Whether a census roster role is consistent with the target's
    /// relationship to the subject. Used only to break a name tie — a subject's
    /// parent is a senior-generation row (Head/Wife/Father/Mother), never a
    /// Son/Daughter, so "John, Head" wins over "John Henry, Son". Kept
    /// deliberately loose: it narrows an ambiguous set, it doesn't gate.
    static func roleIsCompatible(_ rosterRole: String, with relation: CensusRelation) -> Bool {
        let r = rosterRole.lowercased()
        let junior = ["son", "daughter", "grandson", "granddaughter", "stepson", "stepdaughter"]
        let senior = ["head", "wife", "husband", "father", "mother"]
        let isJunior = junior.contains { r.contains($0) }
        let isSenior = senior.contains { r.contains($0) }
        switch relation {
        case .parent:  return isSenior && !isJunior          // Head/Wife/Father/Mother, not a child row
        case .child:   return isJunior
        case .spouse:  return r.contains("wife") || r.contains("husband") || r.contains("head")
        case .sibling: return isJunior || r.contains("brother") || r.contains("sister")
        }
    }

    /// Given-name-and-surname match tolerant of missing surnames (a thin
    /// linked stub is often given-name only). Requires the given name to line
    /// up; the surname must match only when both sides carry one.
    static func nameMatches(_ memberName: String, _ profile: Profile) -> Bool {
        let memberTokens = memberName.uppercased()
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let memberGiven = memberTokens.first else { return false }
        let memberSurname = memberTokens.count > 1 ? memberTokens.last : nil

        let profileGiven = (profile.firstName ?? "").uppercased()
        let profileSurname = (profile.lastName ?? "").uppercased()
        guard !profileGiven.isEmpty else { return false }

        let givenMatch = memberGiven == profileGiven || memberTokens.contains(profileGiven)
        guard givenMatch else { return false }

        let surnameMatch = memberSurname == nil || profileSurname.isEmpty
            || memberSurname == profileSurname
        return surnameMatch
    }
}
