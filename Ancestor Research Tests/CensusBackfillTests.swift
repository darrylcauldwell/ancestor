import Testing
import Foundation
import AncestorKit

/// CensusBackfill: mine confirmed censuses to gap-fill birth years for the
/// household members who are ALREADY linked to the census subject. Anchored to
/// the real case — William's 1891 census (a fact on William) names his father
/// John as "Head, age 30", so it should propose John's birth year (~1861)
/// without anyone re-researching John. Only linked relatives are touched;
/// boarders and relatives who already have a birth year are left alone.
struct CensusBackfillTests {

    private func profile(id: String, first: String, birthYear: Int?) -> Profile {
        Profile(id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: "Cauldwell",
                gender: .unknown, birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
                isDeleted: false, sources: [:], disputes: [:])
    }

    private func member(_ name: String, _ relationship: String, age: Int?, isTarget: Bool = false) -> HouseholdMember {
        HouseholdMember(name: name, relationship: relationship, age: age, isTarget: isTarget)
    }

    /// William (subject) with parents John + Elizabeth linked; the 1891 census
    /// on William names them as Head/Wife age 30.
    private func williamSnapshot(johnBirthYear: Int? = nil) -> FamilyGraphSnapshot {
        let william = profile(id: "william", first: "William", birthYear: 1882)
        let john = profile(id: "john", first: "John", birthYear: johnBirthYear)
        let eliz = profile(id: "eliz", first: "Elizabeth", birthYear: nil)
        let rels = [
            Relationship(id: UUID(), from: "john", to: "william", type: .parent, role: .father,
                         subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil),
            Relationship(id: UUID(), from: "eliz", to: "william", type: .parent, role: .mother,
                         subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil),
        ]
        return FamilyGraphSnapshot(
            profiles: ["william": william, "john": john, "eliz": eliz], relationships: rels)
    }

    private func census1891(subjectID: String = "william") -> CensusBackfill.CensusSource {
        CensusBackfill.CensusSource(
            subjectID: subjectID,
            household: [
                member("John Cauldwell", "Head", age: 30),
                member("Elizabeth Cauldwell", "Wife", age: 30),
                member("William Cauldwell", "Son", age: 9, isTarget: true),
                member("Thomas Brown", "Boarder", age: 25),
            ],
            censusYear: 1891, sourceID: "freecen")
    }

    // MARK: - Core

    @Test func proposesLinkedRelativesFromHousehold() {
        let proposals = CensusBackfill.proposals(censuses: [census1891()], snapshot: williamSnapshot())
        let john = proposals.first { $0.targetProfileID == "john" }
        let eliz = proposals.first { $0.targetProfileID == "eliz" }
        #expect(john?.estimatedBirthYear == 1861, "age 30 in 1891 → born ~1861")
        #expect(eliz?.estimatedBirthYear == 1861)
        #expect(proposals.allSatisfy { $0.targetProfileID != "william" }, "the subject isn't re-proposed")
        #expect(proposals.count == 2)
    }

    @Test func boarderNeverProposed() {
        // A boarder in the roster is not a relative and must never be enriched.
        let proposals = CensusBackfill.proposals(censuses: [census1891()], snapshot: williamSnapshot())
        #expect(proposals.allSatisfy { !$0.targetName.contains("Brown") })
    }

    @Test func skipsRelativeWithExistingBirthYear() {
        // John already has a birth year → gap-fill only, so only Elizabeth proposed.
        let proposals = CensusBackfill.proposals(
            censuses: [census1891()], snapshot: williamSnapshot(johnBirthYear: 1860))
        #expect(proposals.map(\.targetProfileID) == ["eliz"])
    }

    @Test func dedupesAcrossCensuses() {
        // John appears in two censuses; propose him once (first year wins).
        let c1901 = CensusBackfill.CensusSource(
            subjectID: "william",
            household: [
                member("John Cauldwell", "Head", age: 40),
                member("William Cauldwell", "Son", age: 19, isTarget: true),
            ],
            censusYear: 1901, sourceID: "freecen")
        let proposals = CensusBackfill.proposals(
            censuses: [census1891(), c1901], snapshot: williamSnapshot())
        let johnProposals = proposals.filter { $0.targetProfileID == "john" }
        #expect(johnProposals.count == 1, "one proposal per relative, not per census")
        #expect(johnProposals.first?.estimatedBirthYear == 1861, "first census wins (1891, age 30)")
    }

    @Test func noLinkedRelativesYieldsNothing() {
        // A census subject with no linked family produces no backfill.
        let lone = profile(id: "lone", first: "Solo", birthYear: 1870)
        let snap = FamilyGraphSnapshot(profiles: ["lone": lone], relationships: [])
        let census = CensusBackfill.CensusSource(
            subjectID: "lone",
            household: [member("Solo Cauldwell", "Head", age: 21, isTarget: true)],
            censusYear: 1891, sourceID: "freecen")
        #expect(CensusBackfill.proposals(censuses: [census], snapshot: snap).isEmpty)
    }
}
