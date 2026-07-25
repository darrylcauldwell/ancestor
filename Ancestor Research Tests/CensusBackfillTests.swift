import Testing
import Foundation
import AncestorKit

/// CensusBackfill: mine confirmed censuses to backfill the household members
/// already linked to the census subject — with a member-scoped census record
/// carrying their age, birthplace AND occupation, ready to absorb + cite.
/// Anchored to the real case: William's 1891 census (a fact on William) names
/// his father John as "Head, age 30, Coal Miner", so it proposes John's birth
/// year (~1861) and his occupation, without anyone re-researching John.
struct CensusBackfillTests {

    private func profile(id: String, first: String, birthYear: Int?) -> Profile {
        Profile(id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: "Cauldwell",
                gender: .unknown, birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
                isDeleted: false, sources: [:], disputes: [:])
    }

    private func member(_ name: String, _ relationship: String, age: Int?,
                        occupation: String? = nil, isTarget: Bool = false) -> HouseholdMember {
        HouseholdMember(name: name, relationship: relationship, age: age,
                        occupation: occupation, isTarget: isTarget)
    }

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

    private func census1891(subjectID: String = "william", year: Int = 1891, johnAge: Int = 30) -> CensusBackfill.CensusSource {
        let record = CensusRecord(
            common: RecordCommon(id: "c\(year)", sourceID: "freecen", name: "William Cauldwell", rawFields: [:]),
            censusYear: year, district: "Belper",
            household: [
                member("John Cauldwell", "Head", age: johnAge, occupation: "Coal Miner"),
                member("Elizabeth Cauldwell", "Wife", age: 30),
                member("William Cauldwell", "Son", age: year - 1882, isTarget: true),
                member("Thomas Brown", "Boarder", age: 25),
            ])
        return CensusBackfill.CensusSource(subjectID: subjectID, record: record)
    }

    // MARK: - Core

    @Test func proposesLinkedRelativesWithScopedRecord() {
        let proposals = CensusBackfill.proposals(censuses: [census1891()], snapshot: williamSnapshot())
        let john = proposals.first { $0.targetProfileID == "john" }
        #expect(john?.estimatedBirthYear == 1861, "age 30 in 1891 → born ~1861")
        // The member-scoped record carries John's OWN census facts — the whole point.
        #expect(john?.memberRecord.occupation == "Coal Miner")
        #expect(john?.memberRecord.age == 30)
        #expect(john?.memberRecord.birthYear == 1861)
        #expect(john?.memberRecord.common.name == "John Cauldwell")
        #expect(john?.memberRecord.district == "Belper", "shared household district travels onto the member")
        #expect(john?.memberRecord.common.sourceID == "freecen", "same source → same citation")
        #expect(proposals.contains { $0.targetProfileID == "eliz" })
        #expect(proposals.count == 2)
    }

    @Test func boarderNeverProposed() {
        let proposals = CensusBackfill.proposals(censuses: [census1891()], snapshot: williamSnapshot())
        #expect(proposals.allSatisfy { !$0.targetName.contains("Brown") })
        #expect(proposals.allSatisfy { $0.targetProfileID != "william" }, "the subject isn't re-proposed")
    }

    @Test func skipsRelativeWithExistingBirthYear() {
        let proposals = CensusBackfill.proposals(
            censuses: [census1891()], snapshot: williamSnapshot(johnBirthYear: 1860))
        #expect(proposals.map(\.targetProfileID) == ["eliz"])
    }

    @Test func dedupesAcrossCensuses() {
        let proposals = CensusBackfill.proposals(
            censuses: [census1891(), census1891(year: 1901, johnAge: 40)], snapshot: williamSnapshot())
        let johnProposals = proposals.filter { $0.targetProfileID == "john" }
        #expect(johnProposals.count == 1, "one proposal per relative, not per census")
        #expect(johnProposals.first?.estimatedBirthYear == 1861, "first census wins (1891, age 30)")
    }

    @Test func noLinkedRelativesYieldsNothing() {
        let lone = profile(id: "lone", first: "Solo", birthYear: 1870)
        let snap = FamilyGraphSnapshot(profiles: ["lone": lone], relationships: [])
        let record = CensusRecord(
            common: RecordCommon(id: "c", sourceID: "freecen", rawFields: [:]),
            censusYear: 1891,
            household: [member("Solo Cauldwell", "Head", age: 21, isTarget: true)])
        let source = CensusBackfill.CensusSource(subjectID: "lone", record: record)
        #expect(CensusBackfill.proposals(censuses: [source], snapshot: snap).isEmpty)
    }
}
