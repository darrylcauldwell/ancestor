import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// CensusAgeBirthYearRule — fills an EMPTY birth year on a relative whose age
/// appears in a linked family member's applied census. Modelled on the real
/// 1891 Cauldwell household: Ernest (b.1886) applied his census; his linked
/// parents John & Elizabeth have no birth year but appear as Head/Wife age 30.
struct CensusAgeBirthYearRuleTests {

    private func profile(_ id: String, first: String?, last: String?, birth: String? = nil) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, middleName: nil, lastName: last,
            gender: .unknown, attributes: nil,
            birthDate: birth.map { GenealogicalDate(parsing: $0) }, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func parentEdge(_ parent: String, _ child: String, _ uuid: String) -> Relationship {
        Relationship(id: UUID(uuidString: uuid)!, from: parent, to: child, type: .parent,
                     role: nil, subtype: .biological, marriageDate: nil,
                     marriageLocation: nil, divorceDate: nil)
    }

    private func member(_ name: String, _ rel: String, age: Int) -> HouseholdMember {
        HouseholdMember(name: name, relationship: rel, age: age)
    }

    /// Ernest's 1891 census (household of John/Elizabeth/Ernest), with John &
    /// Elizabeth linked as his parents but carrying no birth year.
    private func ernestSnapshot(johnBirth: String? = nil, lizBirth: String? = nil) -> FamilyGraphSnapshot {
        let ernest = profile("ernest", first: "Ernest", last: "Cauldwell", birth: "Jun 1886")
        let john = profile("john", first: "John", last: "Cauldwell", birth: johnBirth)
        let liz = profile("liz", first: "Elizabeth", last: "Cauldwell", birth: lizBirth)
        let census = LifeEvent(
            id: UUID(), profileID: "ernest", type: .census,
            date: GenealogicalDate(parsing: "1891"), location: "Turnditch",
            details: .census(CensusDetails(household: [
                member("John CAULDWELL", "Head", age: 30),
                member("Elizabeth CAULDWELL", "Wife", age: 30),
                member("Ernest CAULDWELL", "Son", age: 4),
            ])))
        return FamilyGraphSnapshot(
            profiles: ["ernest": ernest, "john": john, "liz": liz],
            relationships: [
                parentEdge("john", "ernest", "00000000-0000-0000-0000-000000000001"),
                parentEdge("liz", "ernest", "00000000-0000-0000-0000-000000000002"),
            ],
            lifeEvents: ["ernest": [census]])
    }

    @Test func firesForLinkedParentWithEmptyBirthYear() {
        let snap = ernestSnapshot()
        let rule = CensusAgeBirthYearRule()
        let john = snap.profiles["john"]!
        let results = rule.evaluate(profile: john, snapshot: snap)
        #expect(results.count == 1)
        #expect(results.first?.ruleID == "censusAgeBirthYear")
        #expect(results.first?.category == .issue)     // must not be routed out of Tasks
        #expect(results.first?.message.contains("~1861") == true)
    }

    @Test func suggestionReturnsCalculatedYearAndSource() {
        let snap = ernestSnapshot()
        let liz = snap.profiles["liz"]!
        let s = CensusAgeBirthYearRule.suggestion(for: liz, in: snap)
        #expect(s?.year == 1861)
        #expect(s?.censusYear == 1891)
        #expect(s?.viaName == "Ernest Cauldwell")
    }

    /// Never overwrites: a parent who already has a birth year is silent.
    @Test func silentWhenTargetAlreadyHasBirthYear() {
        let snap = ernestSnapshot(johnBirth: "1860")
        let john = snap.profiles["john"]!
        #expect(CensusAgeBirthYearRule().evaluate(profile: john, snapshot: snap).isEmpty)
    }

    /// The census owner (Ernest) already has a birth year, so he never fires;
    /// and an unrelated profile with no census linkage is silent.
    @Test func silentForCensusSubjectAndUnlinkedPeople() {
        let snap = ernestSnapshot()
        let ernest = snap.profiles["ernest"]!
        #expect(CensusAgeBirthYearRule().evaluate(profile: ernest, snapshot: snap).isEmpty)
        let stranger = profile("x", first: "Zeb", last: "Nobody")   // not in snapshot graph
        #expect(CensusAgeBirthYearRule().evaluate(profile: stranger, snapshot: snap).isEmpty)
    }

    /// The rule is registered so the audit engine actually runs it.
    @Test func ruleIsRegistered() {
        #expect(AuditRules.builtIn.contains { $0.id == "censusAgeBirthYear" })
    }

    /// End-to-end role-aware recovery: John Sr (Head, 30) and John Henry (Son,
    /// 10) both share the name "John" in Ernest's household. John Sr is linked
    /// as Ernest's parent, so the rule now recovers his 1861 (Head row) instead
    /// of skipping the two-John ambiguity.
    @Test func recoversFatherFromTwoJohnHousehold() {
        let ernest = profile("ernest", first: "Ernest", last: "Cauldwell", birth: "1886")
        let johnSr = profile("john", first: "John", last: "Cauldwell")
        let census = LifeEvent(
            id: UUID(), profileID: "ernest", type: .census,
            date: GenealogicalDate(parsing: "1891"), location: "Turnditch",
            details: .census(CensusDetails(household: [
                member("John CAULDWELL", "Head", age: 30),
                member("John Henry CAULDWELL", "Son", age: 10),
                member("Ernest CAULDWELL", "Son", age: 4),
            ])))
        let snap = FamilyGraphSnapshot(
            profiles: ["ernest": ernest, "john": johnSr],
            relationships: [parentEdge("john", "ernest", "00000000-0000-0000-0000-000000000010")],
            lifeEvents: ["ernest": [census]])
        let s = CensusAgeBirthYearRule.suggestion(for: johnSr, in: snap)
        #expect(s?.year == 1861)
        #expect(s?.viaName == "Ernest Cauldwell")
    }
}
