import Foundation

/// Tree-wide census backfill: mine every CONFIRMED census in the tree for the
/// household members who are ALREADY LINKED to the census subject, and propose
/// gap-filling their birth years from their census ages. The evidence-side
/// complement to `CensusFamilyLinker` (which links the household *people*) —
/// here the census *evidence* enriches the family the researcher never opened.
///
/// Safety is inherited from `CensusAgeEnrichment`:
///   • only relatives ALREADY linked to the census subject are touched — a
///     namesake's census can never leak a birth year onto the wrong person;
///   • non-family roster roles (boarder/lodger/servant…) are excluded;
///   • only relatives with an EMPTY birth year are proposals (gap-fill, never
///     overwrite); and name matching is two-way unique (ambiguity is skipped).
///
/// Pure and deterministic — the DB layer gathers the `CensusSource` list; this
/// does the matching so it's fully unit-testable.
public nonisolated struct CensusBackfill {

    /// One confirmed census in the tree, ready to be mined for its household.
    public struct CensusSource: Sendable, Equatable {
        /// The profile the census is a confirmed fact on.
        public let subjectID: String
        public let household: [HouseholdMember]
        public let censusYear: Int
        public let sourceID: String?
        public init(subjectID: String, household: [HouseholdMember], censusYear: Int, sourceID: String?) {
            self.subjectID = subjectID
            self.household = household
            self.censusYear = censusYear
            self.sourceID = sourceID
        }
    }

    /// Birth-year backfill proposals across all confirmed censuses. One proposal
    /// per target relative — the first census that yields a year wins, so a
    /// person enumerated in several censuses isn't proposed repeatedly.
    public static func proposals(
        censuses: [CensusSource],
        snapshot: FamilyGraphSnapshot
    ) -> [BirthYearProposal] {
        var out: [BirthYearProposal] = []
        var claimed: Set<String> = []
        for census in censuses {
            let relatives = linkedRelatives(of: census.subjectID, in: snapshot)
            guard !relatives.isEmpty else { continue }
            let relations = relationMap(subjectID: census.subjectID, relatives: relatives, snapshot: snapshot)
            let proposals = CensusAgeEnrichment.proposals(
                subjectID: census.subjectID,
                household: census.household,
                censusYear: census.censusYear,
                linkedRelatives: relatives,
                sourceID: census.sourceID,
                relations: relations)
            for p in proposals where !claimed.contains(p.targetProfileID) {
                claimed.insert(p.targetProfileID)
                out.append(p)
            }
        }
        return out
    }

    /// The census subject's immediate linked family — the only people a census
    /// may enrich.
    static func linkedRelatives(of id: String, in snapshot: FamilyGraphSnapshot) -> [Profile] {
        var out: [Profile] = []
        out += snapshot.parentsOf(id)
        out += snapshot.spousesOf(id)
        out += snapshot.childrenOf(id)
        out += snapshot.siblingsOf(id)
        return out
    }

    /// Each relative's relationship TO THE SUBJECT — feeds `CensusAgeEnrichment`'s
    /// role-aware tiebreak (a parent must be a Head/Wife row, not a Son).
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
