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
                /// A census family relative with no edge in the tree.
                case missing
                /// Not a reconcilable family relation (lodger, servant, in-law,
                /// grand-, step-, foster, adopted) — `CensusFamilyLinker` drops it.
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
                  Self.matches(member: target, profile: subject, censusYear: year)
            else { continue }

            // The in-scope family relations, keyed by roster member name.
            var relationByName: [String: CensusRelation] = [:]
            for link in CensusFamilyLinker.familyLinks(household: details.household) {
                relationByName[link.member.name] = link.relation
            }

            var entries: [CensusReconciliation.RosterEntry] = []
            for member in details.household {
                // The subject's own row first, so it is never read as a relative.
                if member.isTarget == true, Self.matches(member: member, profile: subject, censusYear: year) {
                    entries.append(.init(member: member, censusRelation: nil, status: .subject))
                    continue
                }
                guard let relation = relationByName[member.name] else {
                    entries.append(.init(member: member, censusRelation: nil, status: .outOfScope))
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
                case .subject, .inTree, .outOfScope:
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
    static func matches(member: HouseholdMember, profile: Profile, censusYear: Int?) -> Bool {
        let memberTokens = member.name.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let memberGiven = memberTokens.first,
              let memberSurname = memberTokens.last,
              memberTokens.count >= 2 else { return false }

        let profileGiven = (profile.firstName ?? "").lowercased()
            .split(separator: " ").first.map(String.init) ?? ""
        let profileSurnames = [profile.lastName, profile.marriedSurname]
            .compactMap { $0?.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !profileGiven.isEmpty, !profileSurnames.isEmpty else { return false }

        guard memberGiven == profileGiven, profileSurnames.contains(memberSurname) else { return false }

        guard let memberYear = member.birthYear ?? censusYear.flatMap({ y in member.age.map { y - $0 } }),
              let profileYear = profile.birthDate?.bestYear else { return false }
        return abs(memberYear - profileYear) <= yearTolerance
    }
}
