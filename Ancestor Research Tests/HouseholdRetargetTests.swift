import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// #33 — `isTarget` on a folded census roster must belong to the event's own
/// subject, not to whichever relative's record the roster was fetched
/// through. Driver (owner dogfood 2026-08-24): John Wheeldon jr's 1861
/// census event arrived with his MOTHER marked as the target — the household
/// was fetched via Ruth's record URL and her principal flag travelled with
/// it. The roster holds TWO John Wheeldons (father 37, son 12), so name
/// matching alone cannot decide; birth-year discrimination must.
struct HouseholdRetargetTests {

    private let burnLane: [HouseholdMember] = [
        HouseholdMember(name: "John WHEELDON", relationship: "Head",
                        age: 37, birthYear: 1824, birthPlace: "Cromford",
                        occupation: "Labourer", sex: "M", maritalStatus: "M",
                        birthCounty: "Derbyshire", isTarget: nil),
        HouseholdMember(name: "Ruth WHEELDON", relationship: "Wife",
                        age: 37, birthYear: 1824, birthPlace: "Middleton",
                        occupation: nil, sex: "F", maritalStatus: "M",
                        birthCounty: "Derbyshire", isTarget: true),  // fetched via Ruth
        HouseholdMember(name: "John WHEELDON", relationship: "Son",
                        age: 12, birthYear: 1849, birthPlace: "Cromford",
                        occupation: "Cotton Factory Worker", sex: "M", maritalStatus: "-",
                        birthCounty: "Derbyshire", isTarget: nil),
    ]

    private func profile(
        first: String, last: String, married: String? = nil, birth: String? = nil
    ) -> Profile {
        var p = Profile(id: "p1", externalIDs: [:], firstName: first, middleName: nil,
                        lastName: last, gender: .male, isDeleted: false,
                        sources: [:], disputes: [:])
        p.marriedSurname = married
        p.birthDate = birth.flatMap { GenealogicalDate(parsing: $0) }
        return p
    }

    @Test func sameNamedFatherAndSonAreSplitByBirthYear() {
        let out = HouseholdRetarget.retarget(
            burnLane, to: profile(first: "John", last: "Wheeldon", birth: "9 Sep 1848"))
        #expect(out[2].isTarget == true, "the son (b.1849, within slop of 1848) is the subject")
        #expect(out[0].isTarget == nil, "the father loses nothing but is not marked")
        #expect(out[1].isTarget == nil, "the fetched record's principal flag is discarded")
    }

    @Test func marriedWomanIsFoundUnderHerMarriedSurname() {
        let out = HouseholdRetarget.retarget(
            burnLane, to: profile(first: "Ruth", last: "Brailsford",
                                  married: "Wheeldon", birth: "1824"))
        #expect(out[1].isTarget == true)
        #expect(out[0].isTarget == nil)
    }

    @Test func ambiguousSameNamesWithNoProfileBirthMarkNobody() {
        let out = HouseholdRetarget.retarget(
            burnLane, to: profile(first: "John", last: "Wheeldon"))
        #expect(out.allSatisfy { $0.isTarget == nil },
                "two eligible Johns and no discriminator — an unmarked roster is honest")
    }

    @Test func nonMemberProfileClearsTheStaleFlag() {
        let out = HouseholdRetarget.retarget(
            burnLane, to: profile(first: "Samuel", last: "Wheeldon", birth: "14 Jul 1851"))
        #expect(out.allSatisfy { $0.isTarget == nil })
    }

    @Test func rosterDataSurvivesUntouched() {
        let out = HouseholdRetarget.retarget(
            burnLane, to: profile(first: "John", last: "Wheeldon", birth: "9 Sep 1848"))
        #expect(out.count == 3)
        #expect(out[0].occupation == "Labourer")
        #expect(out[1].birthPlace == "Middleton")
        #expect(out[2].age == 12)
    }
}
