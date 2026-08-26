import Foundation

/// How a target relative sits relative to the census SUBJECT (the person whose
/// household roster we're reading). Used to break name ambiguity by roster
/// role — a "John" who is the subject's parent must be the Head/Wife, never a
/// Son. Absent (name-only matching) the engine stays conservative and skips
/// ambiguous rows.
public nonisolated enum CensusRelation: Sendable, Equatable, Hashable {
    case parent, sibling, spouse, child
}

/// How a census roster row's surname sits against the surnames a tree profile
/// is known by.
///
/// FOUR outcomes, not two, deliberately: the callers of this primitive have
/// different — and each correct — tolerances for a MISSING surname. Census
/// enrichment matches a bare given-name roster row against a thin linked stub
/// on purpose (`CensusAgeEnrichment.nameMatches`); the reconciler refuses to
/// assert identity without a surname on both sides
/// (`CensusRelationshipReconciler.surnamesMatch`). Collapsing the absences
/// into the mismatch case, or into the match case, would silently rewrite one
/// of them. Only `.conflicts` means "these are different families".
public nonisolated enum RosterSurnameAgreement: Sendable, Equatable {
    /// The roster row's surname is one the profile is known by.
    case agrees
    /// Both sides carry a surname and they disagree.
    case conflicts
    /// The roster row is a single token — a bare given name. Nothing to compare.
    case rosterSurnameAbsent
    /// The profile carries no surname at all (a thin stub). Nothing to compare.
    case profileSurnamesAbsent
}

/// The single answer to "does this census roster row's NAME refer to this
/// person?".
///
/// EV23 (owner dogfood 2026-08-26): three implementations of that one question
/// had drifted apart. `CensusRelationshipReconciler` consulted `lastName` AND
/// `marriedSurname`; `CensusAgeEnrichment.nameMatches` consulted `lastName`
/// alone; `ConflictSweep.knownSurnames(of:)` (app target, used by
/// `ApplyEngine`'s marriage path) consulted `lastName`, `marriedSurname` AND
/// the `nameForms` sidecar. The tree stores a married woman under her MAIDEN
/// surname and every census indexes her under her MARRIED one, so the
/// `lastName`-only variant could not see ANY married woman on ANY roster —
/// Hannah HEWKIN (`marriedSurname` "Gladwin") is "Hannah Gladwin" on every
/// household she ever appears in, so no census-citation offer could form for
/// her anywhere in the app. Two engines reading the same household disagreed
/// about who was on it.
///
/// This is the canonical home. Both AncestorKit roster matchers read it;
/// `ConflictSweep.knownSurnames(of:)` is the third caller and should be
/// migrated to it (it lives in the app target, which already depends on
/// AncestorKit, so the move is one-way and safe).
public nonisolated enum RosterIdentity {

    /// Every surname the profile is known by, trimmed and upper-cased, empties
    /// dropped.
    ///
    /// The union is deliberately identical to `ConflictSweep.knownSurnames`:
    /// the two flat search keys — `lastName` (maiden, by tree convention) and
    /// `marriedSurname` — plus the `NameForm` sidecar, which is where a
    /// WikiTree `LastNameOther` and a twice-married woman's second married
    /// surname land.
    ///
    /// A form carrying only `fullText` and no structured `surname` contributes
    /// nothing: `fullText` on a `.nickname` form is a GIVEN name, so admitting
    /// it blind would inject forenames into the surname set. Every producer in
    /// the app (`WikiTreeClient`, `ProjectDatabase.nameForms`) populates
    /// `surname` on the forms it builds, so this costs nothing today; a future
    /// bare-surname producer would need this taught the `.birth`/`.married`/
    /// `.alsoKnownAs` single-token case explicitly, never `fullText` wholesale.
    public static func knownSurnames(of profile: Profile) -> Set<String> {
        var out: Set<String> = []
        let candidates = [profile.lastName, profile.marriedSurname]
            + profile.nameForms.map(\.surname)
        for candidate in candidates {
            let value = (candidate ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            if !value.isEmpty { out.insert(value) }
        }
        return out
    }

    /// A roster name split into upper-cased tokens on spaces and commas — the
    /// tokenizer both matchers already used, preserved verbatim.
    ///
    /// KNOWN LIMITATION, pre-existing and deliberately not changed by EV23
    /// (2026-08-26): `rosterSurname` takes the LAST token, so an INVERTED row
    /// ("GLADWIN, Hannah") is mis-read with "HANNAH" as the surname and
    /// refuses. Both matchers had that flaw independently; consolidating them
    /// makes it fail identically on both sides instead of differently, which is
    /// the prerequisite for fixing it in one place later. Fixing it here would
    /// have meant changing name PARSING while fixing name MATCHING.
    public static func tokens(of memberName: String) -> [String] {
        memberName.uppercased()
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// The roster row's surname — its LAST name token, upper-cased. `nil` when
    /// the row carries a single token, which is an absence to be tolerated or
    /// refused by the caller, never a mismatch.
    public static func rosterSurname(of memberName: String) -> String? {
        let parts = tokens(of: memberName)
        guard parts.count >= 2 else { return nil }
        return parts.last
    }

    /// Compare a roster row's surname against every surname the profile is
    /// known by. The caller decides what the two absences mean for it — see
    /// `RosterSurnameAgreement`.
    public static func surnameAgreement(memberName: String, profile: Profile) -> RosterSurnameAgreement {
        let known = knownSurnames(of: profile)
        guard !known.isEmpty else { return .profileSurnamesAbsent }
        guard let surname = rosterSurname(of: memberName) else { return .rosterSurnameAbsent }
        return known.contains(surname) ? .agrees : .conflicts
    }
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

    /// Whether a roster "Relationship to Head" string denotes a co-resident who
    /// is NOT blood/marriage family (servant, boarder, lodger, visitor, …).
    /// Exposed so the roster→link path (`CensusFamilyLinker`) applies the exact
    /// same exclusion this enrichment path uses.
    public static func isNonFamilyRole(_ role: String) -> Bool {
        let r = role.lowercased()
        return nonFamilyRoles.contains { r.contains($0) }
    }

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
        matchProposals(
            subjectID: subjectID, household: household, censusYear: censusYear,
            linkedRelatives: linkedRelatives, sourceID: sourceID, relations: relations,
            targetFilter: { $0.birthDate?.bestYear == nil },
            yearConsistency: nil)
    }

    /// Corroborate-in-place (owner dogfood 2026-07-31): the gap-fill rule
    /// above skips any relative who already HAS a birth year — so a child
    /// with an UNSOURCED import year stays uncited even when the applied
    /// household roster agrees with it (George Keyworth jr: gedcom 1877,
    /// roster age 4 in 1881). This mode targets relatives whose recorded
    /// year lacks any research-source backing AND matches the roster
    /// estimate (±1 — a census age straddles the birthday). Absorbing the
    /// member record changes NO value: the same-value apply path records
    /// the census as an alternative fact + citation, upgrading the year to
    /// evidence-backed. Same two-way-unique matching, same role exclusions.
    public static func corroborations(
        subjectID: String,
        household: [HouseholdMember],
        censusYear: Int,
        linkedRelatives: [Profile],
        sourceID: String?,
        relations: [String: CensusRelation] = [:]
    ) -> [BirthYearProposal] {
        matchProposals(
            subjectID: subjectID, household: household, censusYear: censusYear,
            linkedRelatives: linkedRelatives, sourceID: sourceID, relations: relations,
            targetFilter: { profile in
                guard profile.birthDate?.bestYear != nil else { return false }
                let backed = (profile.sources[.birthDate] ?? [])
                    .contains { $0.origin.tier == .researchSource }
                return !backed
            },
            yearConsistency: { estimate, target in
                guard let recorded = target.birthDate?.bestYear else { return false }
                return abs(estimate - recorded) <= 1
            })
    }

    /// Cite-the-census mode (census-gap sweep 2026-08-24): the corroborate
    /// rule above deliberately skips any relative whose recorded year is
    /// already research-backed — but a child ABSORBED from this very
    /// household is exactly that (their birth year carries the census as a
    /// field source) while the census itself never landed on their profile
    /// as an event. 120 of the tree's 161 census-gapped profiles were in
    /// this class (William Goodlad: his mother's applied 1861 names him
    /// "son, 15", his own birth fact cites it, his profile shows zero
    /// censuses). This mode targets relatives whose recorded year AGREES
    /// with the roster (±1 — the same namesake guard as corroboration)
    /// and whom the caller says do NOT yet carry this census on their
    /// profile: field sourcing is irrelevant, the EVENT is what's missing.
    /// Same two-way-unique matching, same role gates.
    public static func citations(
        subjectID: String,
        household: [HouseholdMember],
        censusYear: Int,
        linkedRelatives: [Profile],
        sourceID: String?,
        relations: [String: CensusRelation] = [:],
        alreadyCited: (Profile) -> Bool
    ) -> [BirthYearProposal] {
        matchProposals(
            subjectID: subjectID, household: household, censusYear: censusYear,
            linkedRelatives: linkedRelatives, sourceID: sourceID, relations: relations,
            targetFilter: { profile in
                // A year-less relative is gap-fill's territory (`proposals`);
                // keeping the modes disjoint keeps every offer explainable.
                profile.birthDate?.bestYear != nil && !alreadyCited(profile)
            },
            yearConsistency: { estimate, target in
                guard let recorded = target.birthDate?.bestYear else { return false }
                return abs(estimate - recorded) <= 1
            })
    }

    private static func matchProposals(
        subjectID: String,
        household: [HouseholdMember],
        censusYear: Int,
        linkedRelatives: [Profile],
        sourceID: String?,
        relations: [String: CensusRelation],
        targetFilter: (Profile) -> Bool,
        yearConsistency: ((Int, Profile) -> Bool)?
    ) -> [BirthYearProposal] {
        let targets = linkedRelatives.filter {
            $0.id != subjectID && targetFilter($0)
        }
        guard !targets.isEmpty else { return [] }

        // Family members with a usable year, paired with their estimate.
        let candidates: [(member: HouseholdMember, year: Int)] = household.compactMap { m in
            let role = m.relationship.lowercased()
            if Self.nonFamilyRoles.contains(where: { role.contains($0) }) { return nil }
            guard let year = Self.estimatedYear(m, censusYear: censusYear) else { return nil }
            return (m, year)
        }

        var proposals: [BirthYearProposal] = []
        for target in targets {
            var matches = candidates.filter { Self.nameMatches($0.member.name, target) }
            // Role GATE (owner dogfood 2026-08-06): when we KNOW how the target
            // relates to the subject, a roster row in an incompatible
            // generation is never a match — role compatibility used to be only
            // a tiebreak for 2+ same-name rows, so a UNIQUE-but-wrong-
            // generation name match sailed straight through: a dateless
            // DAUGHTER namesake matched her mother's/grandmother's "Wife" row
            // and was offered that row's birth (b.1844 / b.1861) as backfill
            // (Elizabeth Keyworth, Elizabeth Cauldwell). Unknown relation
            // keeps the old name-only behaviour.
            if let relation = relations[target.id] {
                matches = matches.filter { Self.roleIsCompatible($0.member.relationship, with: relation) }
            }
            guard matches.count == 1 else { continue }        // 0 or ambiguous
            let hit = matches[0]
            // Member-side uniqueness: this member must not also plausibly be a
            // different candidate relative. The role GATE applies HERE too —
            // without it the check counts rivals the gate above has already
            // ruled out, and the guard bails on an unambiguous match: a
            // grandfather (Thomas, b.1801, relation .parent) and his grandson
            // (Thomas H, b.1861, relation .child) both name-match the one
            // "Thomas" roster row, so neither ever got a proposal.
            let relativesForMember = targets.filter { target in
                guard Self.nameMatches(hit.member.name, target) else { return false }
                guard let relation = relations[target.id] else { return true }
                return Self.roleIsCompatible(hit.member.relationship, with: relation)
            }
            guard relativesForMember.count == 1 else { continue }
            // Mode-specific consistency (corroboration: the roster estimate
            // must agree with the recorded year — a mismatch is namesake
            // territory, never silently cited).
            if let consistent = yearConsistency, !consistent(hit.year, target) { continue }

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
    /// relationship to the subject — a subject's parent is a senior-generation
    /// row (Head/Wife/Father/Mother), never a Son/Daughter, so "John, Head"
    /// wins over "John Henry, Son". Since 2026-08-06 this GATES matching
    /// whenever the target's relation is known (it used to only break name
    /// ties, which let a unique wrong-generation namesake through — see the
    /// gate comment in `matchProposals`). Still deliberately loose in what it
    /// accepts within a generation; name-only matching remains for targets
    /// whose relation is unknown.
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
    ///
    /// EV23 (owner dogfood 2026-08-26): the surname half read `profile.lastName`
    /// ALONE. The tree stores a married woman under her MAIDEN surname and every
    /// census indexes her under her MARRIED one, so this matcher could not see a
    /// married woman on her own household roster — Hannah HEWKIN
    /// (`marriedSurname` "Gladwin") appears as "Hannah Gladwin", the surname
    /// compared against "HEWKIN", and every proposal, corroboration and
    /// census-citation offer for her was silently dropped. Not a one-person
    /// defect: by tree convention it is EVERY married woman.
    ///
    /// The surname question now goes through `RosterIdentity` — the same
    /// primitive `CensusRelationshipReconciler` reads over the SAME household —
    /// so the two engines can no longer disagree about who a roster row is.
    ///
    /// The widening is on exactly ONE axis — which surnames count as this
    /// person's — and nowhere else. A surname the profile is not known by is
    /// still a refusal: a maiden-only profile with no `marriedSurname` still
    /// does NOT match a married-surname roster row, so nothing here can merge
    /// two women who merely share a forename and a village. The tolerance the
    /// matcher was written for is preserved (a bare given-name roster row, and
    /// a surname-less stub, both still match — only `.conflicts` refuses).
    /// One case tightens, deliberately: a profile with a BLANK `lastName` but a
    /// recorded married surname used to match every roster row regardless of
    /// surname, because the old guard tested `lastName` emptiness rather than
    /// "no surname known". It now has to agree — "when in doubt, split".
    static func nameMatches(_ memberName: String, _ profile: Profile) -> Bool {
        let memberTokens = RosterIdentity.tokens(of: memberName)
        guard let memberGiven = memberTokens.first else { return false }

        let profileGiven = (profile.firstName ?? "").uppercased()
        guard !profileGiven.isEmpty else { return false }

        let givenMatch = memberGiven == profileGiven || memberTokens.contains(profileGiven)
        guard givenMatch else { return false }

        return RosterIdentity.surnameAgreement(
            memberName: memberName, profile: profile) != .conflicts
    }
}
