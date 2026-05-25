import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for `UnlinkedSpouseForFemaleSubjectRule` — surfaces the
/// gap that today's married-surname derivation can't close on its
/// own. When the user knows the married surname but didn't link
/// the spouse, the construction-time derivation has nothing to
/// pivot from. The audit flags it; user resolves by linking the
/// spouse (or accepting the gap).
@MainActor
struct UnlinkedSpouseAuditTests {

    private func profile(
        id: String, given: String, surname: String,
        gender: Gender = .female, marriedSurname: String? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: given, middleName: nil, lastName: surname,
            marriedSurname: marriedSurname,
            nickName: nil, mothersMaidenName: nil,
            gender: gender, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func spouseRel(_ from: String, _ to: String) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .spouse, role: nil, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    @Test func firesForFemaleWithMarriedSurnameAndNoSpouse() {
        let cath = profile(id: "c", given: "Catherine", surname: "Bown", marriedSurname: "WARD")
        let snapshot = FamilyGraphSnapshot(
            profiles: [cath.id: cath],
            relationships: []
        )
        let rule = UnlinkedSpouseForFemaleSubjectRule()
        let results = rule.evaluate(profile: cath, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.severity == .warning)
        #expect(results.first?.message.contains("WARD") == true)
    }

    @Test func suppressedWhenSpouseLinked() {
        // Linked-spouse case is covered by the construction-time
        // derivation — no need to nag the user.
        let lilian = profile(id: "l", given: "Lilian", surname: "Brooks", marriedSurname: "Holmes")
        let reg = profile(id: "r", given: "Reginald", surname: "Holmes", gender: .male)
        let snapshot = FamilyGraphSnapshot(
            profiles: [lilian.id: lilian, reg.id: reg],
            relationships: [spouseRel(lilian.id, reg.id)]
        )
        let rule = UnlinkedSpouseForFemaleSubjectRule()
        #expect(rule.evaluate(profile: lilian, snapshot: snapshot).isEmpty)
    }

    @Test func suppressedWhenNoMarriedSurnameRecorded() {
        // No married-surname signal at all — can't say anything
        // useful, the engine has no information to pivot on either
        // way. Silent.
        let unmarried = profile(id: "u", given: "Mary", surname: "Brooks")
        let snapshot = FamilyGraphSnapshot(
            profiles: [unmarried.id: unmarried],
            relationships: []
        )
        let rule = UnlinkedSpouseForFemaleSubjectRule()
        #expect(rule.evaluate(profile: unmarried, snapshot: snapshot).isEmpty)
    }

    @Test func suppressedForMaleSubjects() {
        // Symmetric guard — men's death records aren't filed under
        // wife's surname in the era this app targets.
        let john = profile(id: "j", given: "John", surname: "Smith",
                           gender: .male, marriedSurname: "Jones")
        let snapshot = FamilyGraphSnapshot(
            profiles: [john.id: john],
            relationships: []
        )
        let rule = UnlinkedSpouseForFemaleSubjectRule()
        #expect(rule.evaluate(profile: john, snapshot: snapshot).isEmpty)
    }

    @Test func guidanceMessageNamesTheMarriedSurname() {
        // The guidance message tells the user EXACTLY which surname
        // they're missing research coverage for — names the value,
        // not just "your tree has a gap".
        let cath = profile(id: "c", given: "Catherine", surname: "Bown", marriedSurname: "WARD")
        let rule = UnlinkedSpouseForFemaleSubjectRule()
        let guidance = rule.guidanceMessage(profile: cath) ?? ""
        #expect(guidance.contains("WARD"))
        #expect(guidance.contains("Catherine"))
    }
}
