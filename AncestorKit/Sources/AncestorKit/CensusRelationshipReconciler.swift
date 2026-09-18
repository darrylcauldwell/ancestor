import Foundation

/// Reconciles the family relationships a CENSUS HOUSEHOLD implies for a subject
/// against the relationships actually recorded in the tree.
///
/// A census records relationship-to-Head, not a family. `CensusFamilyLinker`
/// already turns a roster into each member's typed relation TO THE SUBJECT
/// (parent / child / spouse / sibling), filtering out lodgers, servants,
/// in-laws, grand-, step-, foster and adopted rows. This engine takes those
/// census-implied relatives and diffs them against the subject's EXISTING tree
/// relatives, matched by name + birth year:
///  - `.missing`       — the census names a relative the tree has no edge for.
///  - `.contradiction` — the tree links the same person in a DIFFERENT role
///    (the classic "recorded as a parent when the census shows them as
///    siblings").
///
/// Household members are not linked to profiles, so member→profile matching is
/// heuristic (surname + first given-name token; birth years within tolerance
/// when both are known). Matching is scoped to the subject's own handful of
/// tree relatives, which keeps namesake risk low. Nothing is written here —
/// this produces findings for review / one-click follow-up, honouring the
/// "AI/heuristic proposes, human decides" boundary.
public nonisolated struct CensusRelationshipReconciler {

    /// Which parent-in-law a roster row names — the mother or father of the
    /// household head's spouse. Their surname is that spouse's maiden name.
    public enum CensusParentInLaw: Sendable, Equatable { case mother, father }

    public struct Finding: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case missing, contradiction }
        public let kind: Kind
        public let subjectID: String
        /// The member's relation TO THE SUBJECT, as implied by the census.
        public let censusRelation: CensusRelation
        public let member: HouseholdMember
        public let censusYear: Int?
        /// Contradiction only: the tree profile matched to `member`, and the
        /// role the tree currently records for it (which differs from
        /// `censusRelation`).
        public let treeRelativeID: String?
        public let treeRelation: CensusRelation?

        public init(kind: Kind, subjectID: String, censusRelation: CensusRelation,
                    member: HouseholdMember, censusYear: Int?,
                    treeRelativeID: String? = nil, treeRelation: CensusRelation? = nil) {
            self.kind = kind
            self.subjectID = subjectID
            self.censusRelation = censusRelation
            self.member = member
            self.censusYear = censusYear
            self.treeRelativeID = treeRelativeID
            self.treeRelation = treeRelation
        }
    }

    /// Census ages are approximate; allow this much slack when both a roster
    /// birth year and a profile birth year are known.
    public static let yearTolerance = 3

    /// A full, per-census classification of a subject's household roster against
    /// the tree — the review-facing report the audit UI renders (the roster, who
    /// is already in the tree, who conflicts, who is missing, and who is not a
    /// reconcilable family relation). `findings` is derived from this so the two
    /// can never diverge.
    public struct CensusReconciliation: Sendable, Equatable {
        public struct RosterEntry: Sendable, Equatable {
            public enum Status: Sendable, Equatable {
                /// The target row — the subject themselves.
                case subject
                /// Already an edge in the tree, in the role the census implies.
                case inTree(profileID: String)
                /// In the tree, but linked in a DIFFERENT role than the census.
                case contradiction(treeRelativeID: String, treeRelation: CensusRelation)
                /// A census family relative with no edge in the tree AND no
                /// matching profile anywhere — a genuinely new person to create.
                case missing
                /// A census family relative who already EXISTS elsewhere in the
                /// tree (matched by name + year) but is not linked to the subject
                /// in this role — offer to LINK the existing profile rather than
                /// ADD a duplicate. Carries that existing profile.
                case unlinkedInTree(profileID: String)
                /// The forename did NOT clear the name-similarity floor, but the
                /// structural evidence agrees: same census-implied relation, that
                /// relation is a singleton among the subject's tree relatives, the
                /// surname matches, and both birth years agree within tolerance.
                /// Proposed for human confirmation — never auto-linked.
                /// Owner dogfood 2026-08-22: Samuel Holmes's 1891 roster reported
                /// "Harriett HOLMES (spouse)" and "Wilfred D S HOLMES (child)" as
                /// NOT IN THE TREE, though both were already linked to him — the
                /// census spells Harriett with two t's and calls William by his
                /// second name. Acting on that finding would have minted two
                /// duplicates of people the tree already held.
                case nearMatch(profileID: String, reason: String)
                /// A parent-in-law of the household head (subject): the mother or
                /// father of the head's spouse. Not a blood relative of the
                /// subject, but pins the spouse's parent — and hence the spouse's
                /// maiden name. Carries the spouse to attach the parent to.
                case inLawOfSpouse(spouseID: String, kind: CensusParentInLaw)
                /// Not a reconcilable family relation (lodger, servant, other
                /// in-law, grand-, step-, foster, adopted) — nothing to act on.
                case outOfScope
            }
            public let member: HouseholdMember
            /// The member's relation TO THE SUBJECT, when they are a family
            /// relation (`nil` for the subject row and out-of-scope co-residents).
            public let censusRelation: CensusRelation?
            public let status: Status

            public init(member: HouseholdMember, censusRelation: CensusRelation?, status: Status) {
                self.member = member
                self.censusRelation = censusRelation
                self.status = status
            }
        }
        public let censusYear: Int?
        public let entries: [RosterEntry]

        public init(censusYear: Int?, entries: [RosterEntry]) {
            self.censusYear = censusYear
            self.entries = entries
        }
    }

    /// Per-census roster classification for `subject`, across every census
    /// life-event on the subject's profile. Only censuses whose target row is
    /// actually this subject are reconciled (see the anchor guard below).
    public static func reconciliations(for subject: Profile, in snapshot: FamilyGraphSnapshot) -> [CensusReconciliation] {
        // The subject's existing tree relatives, each tagged with its tree role.
        var treeRelatives: [(profile: Profile, relation: CensusRelation)] = []
        for p in snapshot.parentsOf(subject.id)  { treeRelatives.append((p, .parent)) }
        for p in snapshot.childrenOf(subject.id) { treeRelatives.append((p, .child)) }
        for p in snapshot.spousesOf(subject.id)  { treeRelatives.append((p, .spouse)) }
        for p in snapshot.siblingsOf(subject.id) { treeRelatives.append((p, .sibling)) }

        var result: [CensusReconciliation] = []
        let censusEvents = (snapshot.lifeEvents[subject.id] ?? []).filter { $0.type == .census }
        for event in censusEvents {
            guard case .census(let details) = event.details else { continue }
            let year = event.date?.bestYear
            // Only reconcile when the roster's target row is actually THIS
            // subject. A household can be attached to several profiles (or carry
            // a stale `isTarget`); if the flagged row is someone else,
            // `familyLinks` anchors on them and every relation lands in the
            // wrong reference frame — phantom contradictions (e.g. a Head's own
            // census read as if he were one of his sons). Verified by name+age.
            guard let target = details.household.first(where: { $0.isTarget == true }),
                  Self.anchorMatches(member: target, profile: subject, censusYear: year)
            else { continue }

            // The in-scope family relations, keyed by the roster MEMBER (not by
            // name): a household can list two people with the same name — a father
            // "John" (Head) and his son "John" (Son) — and keying by name collides,
            // stamping both with one relation (the son's `.child`), so the father
            // read as a missing child. HouseholdMember is Hashable and the two rows
            // differ (age/role), so keying by the member keeps them distinct.
            var relationByMember: [HouseholdMember: CensusRelation] = [:]
            for link in CensusFamilyLinker.familyLinks(household: details.household) {
                relationByMember[link.member] = link.relation
            }

            // A parent-in-law is meaningful only when the subject is the HEAD
            // (the roster's "-in-law" is relative to the head): the head's
            // mother/father-in-law is the head's SPOUSE's parent. Requires a lone
            // spouse in the tree to attach that parent to.
            let subjectIsHead = target.relationship.lowercased().contains("head")
            let spouses = snapshot.spousesOf(subject.id)
            let loneSpouse: Profile? = spouses.count == 1 ? spouses.first : nil

            var entries: [CensusReconciliation.RosterEntry] = []
            for member in details.household {
                // The subject's own row first, so it is never read as a relative.
                if member.isTarget == true,
                   Self.anchorMatches(member: member, profile: subject, censusYear: year) {
                    entries.append(.init(member: member, censusRelation: nil, status: .subject))
                    continue
                }
                guard let relation = relationByMember[member] else {
                    // Not a nuclear relation of the subject. A parent-in-law of
                    // the head, though, identifies the head's spouse's parent —
                    // surface it as an actionable lead rather than a dead row.
                    if subjectIsHead, let spouse = loneSpouse,
                       let kind = Self.parentInLawKind(member.relationship) {
                        // Already captured? If the spouse already has a
                        // name-matching parent, the in-law is in the tree — show
                        // that, don't re-offer the add (which would duplicate).
                        if let existing = snapshot.parentsOf(spouse.id).first(where: {
                            Self.namesMatch(member: member, profile: $0)
                        }) {
                            entries.append(.init(member: member, censusRelation: nil,
                                                 status: .inTree(profileID: existing.id)))
                        } else {
                            entries.append(.init(member: member, censusRelation: nil,
                                                 status: .inLawOfSpouse(spouseID: spouse.id, kind: kind)))
                        }
                    } else {
                        entries.append(.init(member: member, censusRelation: nil, status: .outOfScope))
                    }
                    continue
                }
                if let match = treeRelatives.first(where: {
                    Self.matches(member: member, profile: $0.profile, censusYear: year)
                }) {
                    let status: CensusReconciliation.RosterEntry.Status =
                        match.relation == relation
                        ? .inTree(profileID: match.profile.id)
                        : .contradiction(treeRelativeID: match.profile.id, treeRelation: match.relation)
                    entries.append(.init(member: member, censusRelation: relation, status: status))
                } else if let sameRole = treeRelatives.first(where: {
                    $0.relation == relation
                        && Self.sameRoleFallbackMatch(member: member, profile: $0.profile,
                                                      relation: relation, censusYear: year)
                }) {
                    // Name-matching relative in the SAME household role where
                    // EITHER side is undateable — the same person seen from
                    // another viewpoint (a household lists each member once, so
                    // same census + same role + same name = same person):
                    //   • undateable ROSTER row (no age, no stated year — an
                    //     infant "7m"), or
                    //   • undateable TREE PROFILE (a ghost parent with no birth
                    //     date — owner report 2026-08-06: Abraham Twyford's
                    //     linked-but-dateless father George read as "not in the
                    //     tree" and grew an Add-father offer that would have
                    //     duplicated him).
                    // Classify as in-tree so we neither re-offer the add nor
                    // spawn a duplicate. Namesake safety is unaffected: when
                    // both sides carry a year, only the year-corroborated
                    // branch above can match — a datable namesake with the
                    // wrong year stays a distinct, missing person.
                    entries.append(.init(member: member, censusRelation: relation,
                                         status: .inTree(profileID: sameRole.profile.id)))
                } else if let linked = Self.linkedSingletonRoleMatch(
                    member: member, relation: relation, treeRelatives: treeRelatives) {
                    // An already-linked spouse or parent whose name matches but
                    // whose YEAR disagrees — the tree edge outranks a census
                    // age. See `linkedSingletonRoleMatch`.
                    entries.append(.init(member: member, censusRelation: relation,
                                         status: .inTree(profileID: linked.id)))
                } else if let existing = snapshot.profiles.values.first(where: {
                    !$0.isDeleted && $0.id != subject.id
                        && Self.matches(member: member, profile: $0, censusYear: year)
                }) {
                    // Not linked to the subject, but this person already EXISTS
                    // elsewhere in the tree (name + year) — offer to link them
                    // rather than spawn a duplicate. Year corroboration required
                    // (a tree-wide name-only search would over-match namesakes).
                    entries.append(.init(member: member, censusRelation: relation,
                                         status: .unlinkedInTree(profileID: existing.id)))
                } else if let near = Self.nearMatchCandidate(
                    member: member, relation: relation,
                    treeRelatives: treeRelatives,
                    rosterPeers: relationByMember.map { ($0.key, $0.value) },
                    censusYear: year
                ) {
                    // Structural agreement without name agreement — surface for
                    // confirmation instead of proposing a duplicate.
                    entries.append(.init(member: member, censusRelation: relation,
                                         status: .nearMatch(profileID: near.profile.id,
                                                            reason: near.reason)))
                } else {
                    entries.append(.init(member: member, censusRelation: relation, status: .missing))
                }
            }
            result.append(.init(censusYear: year, entries: entries))
        }
        return result
    }

    /// All census-vs-tree relationship findings for `subject` — the `.missing`
    /// and `.contradiction` rows distilled from `reconciliations`, deduped for a
    /// member seen across multiple censuses.
    public static func findings(for subject: Profile, in snapshot: FamilyGraphSnapshot) -> [Finding] {
        var findings: [Finding] = []
        var seen = Set<String>()
        for recon in reconciliations(for: subject, in: snapshot) {
            for entry in recon.entries {
                guard let relation = entry.censusRelation else { continue }   // skip subject / out-of-scope
                let key = "\(entry.member.name.lowercased())|\(relation)"
                if !seen.insert(key).inserted { continue }
                switch entry.status {
                case .missing:
                    findings.append(Finding(
                        kind: .missing, subjectID: subject.id,
                        censusRelation: relation, member: entry.member, censusYear: recon.censusYear))
                case .contradiction(let treeRelativeID, let treeRelation):
                    findings.append(Finding(
                        kind: .contradiction, subjectID: subject.id,
                        censusRelation: relation, member: entry.member, censusYear: recon.censusYear,
                        treeRelativeID: treeRelativeID, treeRelation: treeRelation))
                case .subject, .inTree, .inLawOfSpouse, .unlinkedInTree, .nearMatch, .outOfScope:
                    // `.nearMatch` is deliberately NOT a `.missing` finding: the
                    // person is on the tree and linked, only the forename differs.
                    // Emitting it would keep telling the owner to add someone they
                    // already have.
                    break
                }
            }
        }
        return findings
    }

    /// Conservative name + birth-year match between a census roster member and a
    /// tree profile. Requires the surname (birth or married) and the first
    /// given-name token to match case-insensitively, AND birth-year
    /// corroboration: both a roster year (stated, or census year − age) and a
    /// profile year must be known and within `yearTolerance`. Year corroboration
    /// is mandatory, not a fallback — a name-only match too readily pairs
    /// namesakes (a census-sibling "George" b.1889 with a tree-child "George"
    /// b.1915), which would surface as a phantom contradiction. When a year is
    /// unknown on either side the pair is left unmatched (treated as "missing"
    /// rather than a wrongly-confident contradiction).
    /// Public so write paths (e.g. `AppState.addCensusFamily`) can dedup a
    /// roster member against relatives already in the tree before creating a
    /// profile — otherwise applying a second sibling's census re-creates the
    /// brothers/sisters the first one already added.
    public static func matches(member: HouseholdMember, profile: Profile, censusYear: Int?) -> Bool {
        guard namesMatch(member: member, profile: profile) else { return false }
        guard let memberYear = memberBirthYear(member, censusYear: censusYear),
              let profileYear = profile.birthDate?.bestYear else { return false }
        return abs(memberYear - profileYear) <= yearTolerance
    }

    /// Tree-wide-safe existence match for the census net-new guard: the member is
    /// "already on the tree" when the name matches AND either the birth YEAR
    /// corroborates (the strict path, identical to `matches`) OR — for a roster
    /// row the census cannot date (an infant like "3w" / "7m", a torn age cell) —
    /// the town-level BIRTHPLACE corroborates. Birthplace disambiguates namesakes
    /// where a bare name (undateable) would over-pair, so this stays safe across
    /// the WHOLE tree — unlike `matchesRoleScoped`'s name-only fallback, which is
    /// safe only within the subject's own relatives. Used by
    /// `AppState.censusFamilyNetNewLinks` so a person already on the tree (linked
    /// to a DIFFERENT profile) isn't offered net-new and duplicated on absorb
    /// (owner dogfood 2026-08-13: Elizabeth Barker, "age 3w · born Weston
    /// Underwood", already on the tree under her father Samson, was offered
    /// net-new on a namesake Joseph Barker's 1861 household).
    public static func matchesTreeWide(member: HouseholdMember, profile: Profile, censusYear: Int?) -> Bool {
        guard namesMatch(member: member, profile: profile) else { return false }
        if let memberYear = memberBirthYear(member, censusYear: censusYear),
           let profileYear = profile.birthDate?.bestYear {
            return abs(memberYear - profileYear) <= yearTolerance
        }
        // Undateable roster row → require a town-level birthplace match, so a
        // namesake born elsewhere is not falsely paired.
        guard let memberTown = town(of: member.birthPlace) else { return false }
        return memberTown == town(of: profile.birthLocation)
    }

    /// First comma-component, lowercased/trimmed — the town, so a census
    /// "Weston Underwood" matches a profile "Weston Underwood, Derbyshire".
    /// nil when the string is empty.
    static func town(of place: String?) -> String? {
        guard let t = place?.split(separator: ",").first?
            .trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        return t
    }

    /// Like `matches`, but when EITHER side is UNDATEABLE — the census row has
    /// no age and no stated birth year (an infant recorded as "7m", a torn or
    /// blank age cell), or the tree profile carries no birth date (a ghost
    /// parent) — it falls back to a name-only match. Safe ONLY when the
    /// candidate set is already ROLE-SCOPED (the subject's own children /
    /// spouses / parents), where a name match within that handful is
    /// unambiguous; a tree-wide name-only match would over-pair namesakes.
    ///
    /// The census DEDUP paths (`AppState.censusFamilyNetNewLinks` /
    /// `addCensusFamily`) use this so an age-less roster row isn't treated as a
    /// NEW person merely because the census can't date it — the defect behind
    /// the "Add N family members" over-offer, the duplicate-on-apply, and the
    /// false "census unabsorbed" audit (owner report 2026-08-06: George
    /// Cauldwell, "7m" in the 1891 roster, offered as net-new and flagged
    /// unabsorbed though already a linked child). The dateless-PROFILE arm is
    /// the mirror case (same-day owner report: Abraham Twyford's linked-but-
    /// dateless father George read as "not in the tree", with an Add-father
    /// offer that would have duplicated him). When BOTH sides carry a year the
    /// year-corroborated path alone decides — a datable member against a dated
    /// profile with the wrong year still refuses, so namesake safety is
    /// unchanged.
    public static func matchesRoleScoped(member: HouseholdMember, profile: Profile, censusYear: Int?) -> Bool {
        if matches(member: member, profile: profile, censusYear: censusYear) { return true }
        guard memberBirthYear(member, censusYear: censusYear) == nil
                || profile.birthDate?.bestYear == nil else { return false }
        return namesMatch(member: member, profile: profile)
    }

    /// The same-role classification fallback for a subject's own LINKED
    /// relatives (used only after the year-corroborated pass found no match).
    ///
    /// For the SINGLETON roles — parent, spouse — a name match alone suffices
    /// even when both sides are dated but disagree: census ages drift, and a
    /// subject has one father, so "George TWYFORD (Head)" against the linked
    /// father George Twyford is the same man whatever the age column says
    /// (owner report 2026-08-06: father b.1857 vs Head age 30 → b.1861, four
    /// years against a ±3 tolerance, read the linked father as "missing" and
    /// offered a duplicating Add-father).
    ///
    /// For children and siblings the either-side-undateable guard stays:
    /// families reused a dead child's name, so a DATED same-name sibling with
    /// a different year is a genuinely distinct person the census may be
    /// discovering — never silently welded onto the survivor.
    static func sameRoleFallbackMatch(
        member: HouseholdMember, profile: Profile,
        relation: CensusRelation, censusYear: Int?
    ) -> Bool {
        guard namesMatch(member: member, profile: profile) else { return false }
        switch relation {
        case .parent, .spouse:
            return true
        default:
            return memberBirthYear(member, censusYear: censusYear) == nil
                || profile.birthDate?.bestYear == nil
        }
    }

    /// Public wrapper over the near-match rung, so the census ABSORPTION dedup
    /// (`AppState.censusFamilyNetNewLinks`) asks exactly the question the
    /// reconciliation view answers, instead of computing its own.
    ///
    /// Returns the id of the tree relative this roster row almost certainly IS,
    /// or nil. Two rules over one household must never disagree: on 2026-08-22
    /// Harriet Holmes's profile showed "Add 4 family members" beside "Add all 3"
    /// for the same 1891 census, because the reconciler had been taught to
    /// recognise "Wilfred D S HOLMES" as the tree's William and the absorption
    /// dedup had not. The bigger number was the wrong one and it was the more
    /// prominent button.
    public static func nearMatchedRelativeID(
        member: HouseholdMember,
        relation: CensusRelation,
        treeRelatives: [(profile: Profile, relation: CensusRelation)],
        rosterPeers: [(member: HouseholdMember, relation: CensusRelation)],
        censusYear: Int?
    ) -> String? {
        nearMatchCandidate(
            member: member, relation: relation,
            treeRelatives: treeRelatives, rosterPeers: rosterPeers,
            censusYear: censusYear
        )?.profile.id
    }

    /// Does the roster's `isTarget` row identify THIS subject? Governs whether a
    /// census is reconciled at all, so a false negative silently discards the
    /// entire household.
    ///
    /// `matches` is tried first. When it fails, the forename is allowed to differ
    /// provided surname, birth year and sex all agree — because a subject's own
    /// row is the one place where a spelling variant costs everything. Harriet
    /// Holmes's 1891 roster flags "Harriett HOLMES" (Wife, 34, born Longcliffe
    /// Wharf) as the target; the tree holds "Harriet". One edit, 0.7, under the
    /// 0.85 floor — so the guard rejected her own row, `reconciliations` skipped
    /// the census entirely, and her three daughters Bertha, Minnie and Edith were
    /// never offered. The same spelling that hid her census hid her children.
    ///
    /// The guard's real job is unaffected. It exists because a household can be
    /// attached to several profiles, or carry a stale `isTarget`, and anchoring on
    /// the wrong row puts every relation in the wrong reference frame. Requiring
    /// surname + year + non-contradicting sex still refuses that: reconciling this
    /// same roster for Samuel (M, 1847) against a target row of Harriett (F, 1857)
    /// fails on both sex and year.
    static func anchorMatches(member: HouseholdMember, profile: Profile, censusYear: Int?) -> Bool {
        if matches(member: member, profile: profile, censusYear: censusYear) { return true }
        guard !sexContradicts(member: member, profile: profile) else { return false }
        guard surnamesMatch(member: member, profile: profile) else { return false }
        guard let memberYear = memberBirthYear(member, censusYear: censusYear),
              let profileYear = profile.birthDate?.bestYear else { return false }
        return abs(memberYear - profileYear) <= yearTolerance
    }

    /// Surname agreement alone — the roster row's LAST name token against every
    /// surname the profile is known by, case-insensitively. The half of
    /// `namesMatch` that carries structural weight: a forename is what a census
    /// enumerator mishears or abbreviates, a surname is what the household is
    /// known by.
    ///
    /// EV23 (2026-08-26): the surname union used to be assembled inline here,
    /// again in `namesMatch`, and a THIRD time — from a different set of fields
    /// — in `CensusAgeEnrichment`, which is how two engines reading the same
    /// household came to disagree about who was on it. It now comes from
    /// `RosterIdentity`, the one primitive both roster matchers share. Strict
    /// arm: only `.agrees` counts, so a surname-less roster row or a
    /// surname-less profile still refuses to assert identity here, exactly as
    /// before. The one widening is that the `nameForms` sidecar (a WikiTree
    /// `LastNameOther`, a twice-married woman's second married surname) now
    /// counts as a surname the profile is known by — which it already did
    /// everywhere else in the app.
    static func surnamesMatch(member: HouseholdMember, profile: Profile) -> Bool {
        RosterIdentity.surnameAgreement(memberName: member.name, profile: profile) == .agrees
    }

    /// A relative ALREADY LINKED to the subject in a SINGLETON role — spouse or
    /// parent — whose name matches but whose birth year does not.
    ///
    /// An existing tree edge is direct evidence of identity. Age arithmetic
    /// cannot overturn it, and a transcribed census age is the weakest number in
    /// genealogy. Owner dogfood 2026-08-22: Jacob Holmes's baptism proved he was
    /// born 1817, not the 1823 his census age implied, so his birth year was
    /// corrected — and his WIFE's card immediately offered to "Add 1 family
    /// member: Jacob HOLMES — head", the husband she was already married to.
    /// Six years apart, `yearTolerance` is 3, so the match failed. Making the
    /// tree more accurate made the app offer a duplicate.
    ///
    /// Deliberately restricted to spouse and parent, because the rule this
    /// sits beside — "a name-agreeing relative whose year is wrong is a
    /// genuinely distinct person" — is TRUE for children and siblings, where
    /// families reused a dead child's name. It cannot be true for a spouse or a
    /// parent: nobody has two fathers, and the head of a wife's household is her
    /// husband. Sex must not contradict, and exactly one linked relative may
    /// qualify, so a two-parent row still resolves to the right one.
    /// Public so the write path (`AppState.censusFamilyNetNewLinks`) shares this
    /// rung — the count and the roster label must never diverge.
    public static func linkedSingletonRoleMatch(
        member: HouseholdMember, relation: CensusRelation,
        treeRelatives: [(profile: Profile, relation: CensusRelation)]
    ) -> Profile? {
        guard relation == .spouse || relation == .parent else { return nil }
        let candidates = treeRelatives.filter {
            $0.relation == relation
                && namesMatch(member: member, profile: $0.profile)
                && !sexContradicts(member: member, profile: $0.profile)
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0].profile
    }

    /// The tree relative a roster row is ALREADY resolved to by a rung STRONGER
    /// than the near-match one — the name+year match (`.inTree` or, in a
    /// different role, `.contradiction`), the same-role fallback, or an existing
    /// singleton edge — or nil when the row is still unspoken for.
    ///
    /// Mirrors the branch ORDER in `reconciliations` exactly (`matches` →
    /// `sameRoleFallbackMatch` → `linkedSingletonRoleMatch`), minus the
    /// tree-wide `.unlinkedInTree` rung, which needs a snapshot. Leaving that
    /// one out is safe in both directions: it can only ever leave a row counted
    /// as an open rival, which is the REFUSING direction, and it can never hide
    /// a claim on the candidate — a peer that `matches` a tree relative is
    /// caught by the first branch, so `.unlinkedInTree` never names one.
    static func resolvedTreeRelativeID(
        member: HouseholdMember,
        relation: CensusRelation,
        treeRelatives: [(profile: Profile, relation: CensusRelation)],
        censusYear: Int?
    ) -> String? {
        if let m = treeRelatives.first(where: {
            matches(member: member, profile: $0.profile, censusYear: censusYear)
        }) { return m.profile.id }
        if let m = treeRelatives.first(where: {
            $0.relation == relation
                && sameRoleFallbackMatch(member: member, profile: $0.profile,
                                         relation: relation, censusYear: censusYear)
        }) { return m.profile.id }
        return linkedSingletonRoleMatch(member: member, relation: relation,
                                        treeRelatives: treeRelatives)?.id
    }

    /// A roster row whose FORENAME fails the similarity floor but whose
    /// STRUCTURE agrees: same census-implied relation, that relation a singleton
    /// among the subject's tree relatives, matching surname, and both birth years
    /// known and within `yearTolerance`.
    ///
    /// Every other rung in this file opens with `guard namesMatch` — so a
    /// forename spelling defeats role, uniqueness and year evidence combined.
    /// That is what reported Samuel Holmes's own wife and son as "not in the
    /// tree" (census "Harriett" vs tree "Harriet", one edit; census "Wilfred D S"
    /// vs tree "William", a second forename in daily use). The 0.85 floor stays —
    /// it stops Dale/Gale-style near-names welding together — and this rung does
    /// not link anything. It PROPOSES, for the human to confirm.
    ///
    /// Safety, deliberately narrow. Uniqueness must hold on BOTH sides, after
    /// filtering by year and sex — counting only what is LINKED is not the same
    /// as counting what exists, and an incomplete tree will happily look
    /// unambiguous. (First cut of this rung counted tree relatives alone and
    /// near-matched Samuel Wheeldon's mother onto his father: one parent linked,
    /// both born 1824, both surnamed Wheeldon. The existing suite caught it.)
    ///  - `namesMatch` must have FAILED. A name-agreeing relative whose year is
    ///    wrong is a genuinely distinct person (families reused a dead child's
    ///    name) and must stay `.missing` — never routed through here.
    ///  - exactly ONE tree relative in that relation may agree on year and sex.
    ///  - and no OTHER roster row in that relation may equally fit that
    ///    candidate. Four children on the page and one on the tree is ambiguous
    ///    unless year and sex single one out. A peer already resolved to its OWN
    ///    tree profile is not a rival; a peer resolved to THIS candidate refuses
    ///    outright.
    ///  - both sides must be dated. An undateable row already has
    ///    `sameRoleFallbackMatch`; it does not get a forename bypass as well.
    static func nearMatchCandidate(
        member: HouseholdMember,
        relation: CensusRelation,
        treeRelatives: [(profile: Profile, relation: CensusRelation)],
        rosterPeers: [(member: HouseholdMember, relation: CensusRelation)],
        censusYear: Int?
    ) -> (profile: Profile, reason: String)? {
        guard let memberYear = memberBirthYear(member, censusYear: censusYear) else { return nil }

        // Tree side: same role, year agrees, sex not contradicted — and unique.
        let treeCandidates = treeRelatives.filter { rel in
            rel.relation == relation
                && !sexContradicts(member: member, profile: rel.profile)
                && (rel.profile.birthDate?.bestYear)
                    .map { abs($0 - memberYear) <= yearTolerance } ?? false
        }
        guard treeCandidates.count == 1, let candidate = treeCandidates.first?.profile,
              let profileYear = candidate.birthDate?.bestYear else { return nil }
        guard !namesMatch(member: member, profile: candidate) else { return nil }
        guard surnamesMatch(member: member, profile: candidate) else { return nil }

        // The candidate is already CLAIMED by another row on this schedule, by a
        // stronger rung than this one. Two rows cannot both be one person, and
        // the stronger claim wins — checked before the rival filter and across
        // EVERY role, because `sameRoleFallbackMatch` can pair a parent/spouse
        // whose year is nowhere near this member's. Load-bearing: without it,
        // Ruth Wheeldon (Wife, b.1824) would near-match onto her own HUSBAND
        // John (Head, b.1824) the moment his row is excluded as spoken-for —
        // same surname, same census-implied role (both are Samuel's parents),
        // same year, and no sex column to separate them.
        if rosterPeers.contains(where: { peer in
            peer.member != member
                && resolvedTreeRelativeID(member: peer.member, relation: peer.relation,
                                          treeRelatives: treeRelatives,
                                          censusYear: censusYear) == candidate.id
        }) { return nil }

        // Roster side: no other UNRESOLVED row in the same role could equally be
        // this person. A peer that already has its own identity on the tree is
        // not competing for this one — EV18, 2026-08-26. William Gladwin's 1871
        // Whittington schedule refused "John H Gladwin" (b.1861, Unstone)
        // against the tree's "Thomas H Gladwin" (b.1861, Unstone) because his
        // brother James, b.1864, sat exactly on the ±3 boundary — and James's
        // own row resolves to the tree's James by name and year. An already
        // matched sibling was vetoing a question about a different boy.
        let rivals = rosterPeers.filter { peer in
            peer.relation == relation
                && peer.member != member
                && !sexContradicts(member: peer.member, profile: candidate)
                && memberBirthYear(peer.member, censusYear: censusYear)
                    .map { abs($0 - profileYear) <= yearTolerance } ?? false
                && resolvedTreeRelativeID(member: peer.member, relation: peer.relation,
                                          treeRelatives: treeRelatives,
                                          censusYear: censusYear) == nil
        }
        guard rivals.isEmpty else { return nil }

        let roleWord: String
        switch relation {
        case .parent:  roleWord = "parent"
        case .child:   roleWord = "child"
        case .spouse:  roleWord = "spouse"
        case .sibling: roleWord = "sibling"
        }
        let reason = "same surname and household role (\(roleWord)), the only \(roleWord) "
            + "the years and sex allow on either side, birth years agree "
            + "(\(memberYear) vs \(profileYear)) — only the forename differs"
        return (candidate, reason)
    }

    /// True when the roster row and the profile state OPPOSITE sexes. Absent or
    /// non-binary values never contradict — this only ever rules a pairing out,
    /// it never rules one in.
    static func sexContradicts(member: HouseholdMember, profile: Profile) -> Bool {
        guard let s = member.sex?.uppercased().first, let g = profile.gender else { return false }
        switch g {
        case .male:   return s == "F"
        case .female: return s == "M"
        case .other, .unknown: return false
        }
    }

    /// Name-only agreement: first given-name token + any surname the profile is
    /// known by (`RosterIdentity`), case-insensitive. The weaker half of
    /// `matches`. Two callers use it alone, both role-scoped:
    /// `matchesRoleScoped`, only once either side is undatable, and
    /// `linkedSingletonRoleMatch`, where exactly one linked relative holds the
    /// row's role. It is never enough on its own to assert a cross-role
    /// contradiction — that still requires year corroboration.
    static func namesMatch(member: HouseholdMember, profile: Profile) -> Bool {
        // Surname first, through the shared primitive (EV23, 2026-08-26). The
        // guard is unchanged in strength — a bare given-name roster row and a
        // surname-less profile both still refuse here, because this rung
        // ASSERTS identity; `sameRoleFallbackMatch` and `matchesRoleScoped` are
        // the rungs that relax it under role scoping.
        guard surnamesMatch(member: member, profile: profile) else { return false }

        let memberTokens = RosterIdentity.tokens(of: member.name)
        guard let memberGiven = memberTokens.first else { return false }

        let profileGiven = (profile.firstName ?? "").uppercased()
            .split(separator: " ").first.map(String.init) ?? ""
        guard !profileGiven.isEmpty else { return false }
        // Given names compare through the name-similarity ladder at the
        // nickname threshold, not by string equality — a census "Samuel" must
        // recognise the tree's "Sam", "Joseph" its "Joe" (owner dogfood
        // 2026-08-14: Ernest's 1891 household offered "Add 4 family members"
        // for a roster where five of six relatives were already on the tree,
        // three hidden behind pet-form names — pressing it would have minted
        // three duplicates). 0.85 admits exact matches, AU/OU spelling
        // normalisation and the nickname table; it EXCLUDES the looser
        // containment (0.8) and single-edit (0.7) rungs, so Dale/Gale-style
        // near-names still refuse — dedup must never be laxer than that.
        return memberGiven == profileGiven
            || nameSimilarity(memberGiven, profileGiven) >= 0.85
    }

    /// The member's birth year — stated, or derived from census-year − age.
    /// `nil` when the roster gives neither (an undateable row).
    static func memberBirthYear(_ member: HouseholdMember, censusYear: Int?) -> Int? {
        member.birthYear ?? censusYear.flatMap { y in member.age.map { y - $0 } }
    }

    /// Classify a "relationship to head" string as a PARENT-in-law (mother/father
    /// of the head's spouse), or nil. Handles both spelled-out ("Mother-in-Law",
    /// "Mother in law") and the abbreviated census forms ("Ma-Law", "Fa-Law",
    /// "Pa-Law"). Deliberately excludes son-/daughter-/brother-/sister-in-law —
    /// those are not a spouse's parent.
    public static func parentInLawKind(_ relationship: String) -> CensusParentInLaw? {
        let letters = relationship.lowercased().filter { $0.isLetter }
        guard letters.hasSuffix("law") else { return nil }              // must be an in-law form
        if letters.hasPrefix("son") || letters.hasPrefix("dau")
            || letters.hasPrefix("bro") || letters.hasPrefix("sis") { return nil }
        if letters.hasPrefix("mother") || letters.hasPrefix("ma") { return .mother }
        if letters.hasPrefix("father") || letters.hasPrefix("fa") || letters.hasPrefix("pa") { return .father }
        return nil
    }

    /// A surfaced parent-in-law lead: a roster row that pins the subject's
    /// spouse's parent (and thereby the spouse's maiden name).
    public struct InLawLead: Sendable, Equatable {
        public let member: HouseholdMember
        public let spouseID: String
        public let kind: CensusParentInLaw
        public let censusYear: Int?
        public init(member: HouseholdMember, spouseID: String, kind: CensusParentInLaw, censusYear: Int?) {
            self.member = member
            self.spouseID = spouseID
            self.kind = kind
            self.censusYear = censusYear
        }
    }

    /// A census family member who already exists in the tree but isn't linked to
    /// the subject — a link, not an add.
    public struct UnlinkedRelative: Sendable, Equatable {
        public let member: HouseholdMember
        public let existingID: String
        public let relation: CensusRelation
        public let censusYear: Int?
        public init(member: HouseholdMember, existingID: String, relation: CensusRelation, censusYear: Int?) {
            self.member = member
            self.existingID = existingID
            self.relation = relation
            self.censusYear = censusYear
        }
    }

    /// A roster row the engine can only PROPOSE an identity for — the near-match
    /// rung's output, surfaced so a household whose ONLY outstanding row is an
    /// unconfirmed name match still reaches a review surface. Silence would be
    /// the app asserting the identity on the owner's behalf (EV18, 2026-08-26).
    public struct NearMatchProposal: Sendable, Equatable {
        public let member: HouseholdMember
        public let candidateID: String
        public let relation: CensusRelation
        public let reason: String
        public let censusYear: Int?
        public init(member: HouseholdMember, candidateID: String, relation: CensusRelation,
                    reason: String, censusYear: Int?) {
            self.member = member
            self.candidateID = candidateID
            self.relation = relation
            self.reason = reason
            self.censusYear = censusYear
        }
    }

    /// Every unconfirmed name match for `subject`, deduped by candidate +
    /// relation. Distilled from `reconciliations` so rule and panel agree.
    public static func nearMatchProposals(for subject: Profile, in snapshot: FamilyGraphSnapshot) -> [NearMatchProposal] {
        var out: [NearMatchProposal] = []
        var seen = Set<String>()
        for recon in reconciliations(for: subject, in: snapshot) {
            for entry in recon.entries {
                guard case .nearMatch(let candidateID, let reason) = entry.status,
                      let relation = entry.censusRelation else { continue }
                if seen.insert("\(candidateID)|\(relation)").inserted {
                    out.append(.init(member: entry.member, candidateID: candidateID,
                                     relation: relation, reason: reason,
                                     censusYear: recon.censusYear))
                }
            }
        }
        return out
    }

    /// Every unlinked-but-in-tree relative for `subject`, deduped by existing
    /// profile + relation. Distilled from `reconciliations` so rule and panel agree.
    public static func unlinkedRelatives(for subject: Profile, in snapshot: FamilyGraphSnapshot) -> [UnlinkedRelative] {
        var out: [UnlinkedRelative] = []
        var seen = Set<String>()
        for recon in reconciliations(for: subject, in: snapshot) {
            for entry in recon.entries {
                guard case .unlinkedInTree(let existingID) = entry.status,
                      let relation = entry.censusRelation else { continue }
                if seen.insert("\(existingID)|\(relation)").inserted {
                    out.append(.init(member: entry.member, existingID: existingID,
                                     relation: relation, censusYear: recon.censusYear))
                }
            }
        }
        return out
    }

    /// Every parent-in-law lead for `subject`, deduped by member name across
    /// censuses. Distilled from `reconciliations` so the rule and the panel agree.
    public static func inLawLeads(for subject: Profile, in snapshot: FamilyGraphSnapshot) -> [InLawLead] {
        var leads: [InLawLead] = []
        var seen = Set<String>()
        for recon in reconciliations(for: subject, in: snapshot) {
            for entry in recon.entries {
                guard case .inLawOfSpouse(let spouseID, let kind) = entry.status else { continue }
                if seen.insert(entry.member.name.lowercased()).inserted {
                    leads.append(.init(member: entry.member, spouseID: spouseID,
                                       kind: kind, censusYear: recon.censusYear))
                }
            }
        }
        return leads
    }
}
