import Foundation

/// Tree-wide census backfill: mine every CONFIRMED census in the tree for the
/// household members who are ALREADY LINKED to the census subject, and produce
/// a **member-scoped census record** for each — carrying that member's own
/// age/birthplace/occupation plus the shared district, year and citation. Run
/// through the normal absorption path, it lands their birth year, birthplace,
/// residence and occupation AND cites the census on their profile. The
/// evidence-side complement to `CensusFamilyLinker` (which links the people).
///
/// Safety is inherited from `CensusAgeEnrichment`, which does the matching:
///   • only relatives ALREADY linked to the census subject are touched — a
///     namesake's census can never leak onto the wrong person;
///   • non-family roster roles (boarder/lodger/servant…) are excluded;
///   • name matching is two-way unique (ambiguity is skipped).
///
/// Pure and deterministic — the DB layer gathers the `CensusSource` list; this
/// does the matching + record construction so it's fully unit-testable.
public nonisolated struct CensusBackfill {

    /// One confirmed census in the tree — the full household record it was a
    /// fact on, plus the profile it belongs to.
    public struct CensusSource: Sendable {
        public let subjectID: String
        public let record: CensusRecord
        public init(subjectID: String, record: CensusRecord) {
            self.subjectID = subjectID
            self.record = record
        }
    }

    /// A backfill available for one linked relative named in a household.
    public struct Proposal: Sendable, Identifiable {
        public var id: String { targetProfileID }
        public let targetProfileID: String
        public let targetName: String
        public let relationshipLabel: String
        public let estimatedBirthYear: Int?
        public let censusYear: Int
        /// The census scoped to this member — ready to absorb onto them.
        public let memberRecord: CensusRecord
        public init(targetProfileID: String, targetName: String, relationshipLabel: String,
                    estimatedBirthYear: Int?, censusYear: Int, memberRecord: CensusRecord) {
            self.targetProfileID = targetProfileID
            self.targetName = targetName
            self.relationshipLabel = relationshipLabel
            self.estimatedBirthYear = estimatedBirthYear
            self.censusYear = censusYear
            self.memberRecord = memberRecord
        }
    }

    /// Backfill proposals across all confirmed censuses. One proposal per target
    /// relative — the first census that yields a match wins, so a person
    /// enumerated in several censuses isn't proposed repeatedly.
    public static func proposals(
        censuses: [CensusSource],
        snapshot: FamilyGraphSnapshot
    ) -> [Proposal] {
        var out: [Proposal] = []
        var claimed: Set<String> = []
        for source in censuses {
            let household = source.record.household ?? []
            guard !household.isEmpty else { continue }
            let relatives = linkedRelatives(of: source.subjectID, in: snapshot)
            guard !relatives.isEmpty else { continue }
            let relations = relationMap(subjectID: source.subjectID, relatives: relatives, snapshot: snapshot)
            let matches = CensusAgeEnrichment.proposals(
                subjectID: source.subjectID,
                household: household,
                censusYear: source.record.censusYear,
                linkedRelatives: relatives,
                sourceID: source.record.common.sourceID,
                relations: relations)
            for m in matches where !claimed.contains(m.targetProfileID) {
                guard let member = matchMember(to: m, in: household) else { continue }
                claimed.insert(m.targetProfileID)
                out.append(Proposal(
                    targetProfileID: m.targetProfileID,
                    targetName: m.targetName,
                    relationshipLabel: m.relationshipLabel,
                    estimatedBirthYear: m.estimatedBirthYear,
                    censusYear: source.record.censusYear,
                    memberRecord: memberRecord(for: member, in: source.record)))
            }
        }
        return out
    }

    /// A census record scoped to one household member: their own age / birthplace
    /// / occupation, plus the shared district, year, address and citation from
    /// the household record. Absorbing this lands the member's social history and
    /// cites the census on their profile — the same shape the researched subject's
    /// own census record has.
    public static func memberRecord(for member: HouseholdMember, in household: CensusRecord) -> CensusRecord {
        let year = household.censusYear
        let birthYear = member.birthYear ?? member.age.map { year - $0 }
        let safeName = member.name.replacingOccurrences(of: " ", with: "_")
        let common = RecordCommon(
            id: "\(household.common.sourceID)_hh_\(safeName)_\(year)",
            sourceID: household.common.sourceID,
            name: member.name,
            surname: nil, givenName: nil,
            detailURL: household.common.detailURL,
            rawFields: household.common.rawFields,
            placeARK: household.common.placeARK,
            collectionCompleteness: household.common.collectionCompleteness,
            volatilityScore: household.common.volatilityScore)
        return CensusRecord(
            common: common,
            censusYear: year,
            age: member.age,
            birthYear: birthYear,
            birthPlace: member.birthPlace,
            birthCounty: member.birthCounty,
            relationship: member.relationship,
            occupation: member.occupation,
            address: household.address,
            parish: household.parish,
            district: household.district,
            household: household.household)
    }

    /// Recover the roster row `CensusAgeEnrichment` matched (it matches uniquely
    /// by name + role, so relationship + a loose name match re-identifies it).
    static func matchMember(to proposal: BirthYearProposal, in household: [HouseholdMember]) -> HouseholdMember? {
        household.first {
            $0.relationship.caseInsensitiveCompare(proposal.relationshipLabel) == .orderedSame
                && nameLooselyMatches($0.name, proposal.targetName)
        }
    }

    static func nameLooselyMatches(_ a: String, _ b: String) -> Bool {
        let na = a.lowercased().trimmingCharacters(in: .whitespaces)
        let nb = b.lowercased().trimmingCharacters(in: .whitespaces)
        return na == nb || na.contains(nb) || nb.contains(na)
    }

    static func linkedRelatives(of id: String, in snapshot: FamilyGraphSnapshot) -> [Profile] {
        var out: [Profile] = []
        out += snapshot.parentsOf(id)
        out += snapshot.spousesOf(id)
        out += snapshot.childrenOf(id)
        out += snapshot.siblingsOf(id)
        return out
    }

    static func relationMap(subjectID: String, relatives: [Profile], snapshot: FamilyGraphSnapshot) -> [String: CensusRelation] {
        let parents = Set(snapshot.parentsOf(subjectID).map(\.id))
        let spouses = Set(snapshot.spousesOf(subjectID).map(\.id))
        let children = Set(snapshot.childrenOf(subjectID).map(\.id))
        let siblings = Set(snapshot.siblingsOf(subjectID).map(\.id))
        var map: [String: CensusRelation] = [:]
        for r in relatives {
            if parents.contains(r.id)       { map[r.id] = .parent }
            else if spouses.contains(r.id)  { map[r.id] = .spouse }
            else if children.contains(r.id) { map[r.id] = .child }
            else if siblings.contains(r.id) { map[r.id] = .sibling }
        }
        return map
    }
}
