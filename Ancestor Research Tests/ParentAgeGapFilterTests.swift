import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the pipeline-time parent age-gap filter in
/// `ResearchSubject.fromProfile`. Mirrors `agent/pipeline.py:96-109`.
/// Without it, a mis-typed "parent" only a few years older than the
/// subject (FamilySearch / GEDCOM role drift) contaminates the
/// FamilyContext.fatherName / .motherName the scorer reads.
@MainActor
struct ParentAgeGapFilterTests {

    private func profile(
        id: String, given: String, surname: String,
        gender: Gender, birthYear: Int? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: given, middleName: nil, lastName: surname,
            marriedSurname: nil, nickName: nil, mothersMaidenName: nil,
            gender: gender, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func parentRel(_ from: String, _ to: String,
                           role: ParentRole, subtype: RelationshipSubtype = .biological) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: role, subtype: subtype,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    @Test func plausibleParentReachesFamilyContext() {
        let subject = profile(id: "s", given: "Lilian", surname: "Brooks", gender: .female, birthYear: 1914)
        let father = profile(id: "f", given: "George", surname: "Brooks", gender: .male, birthYear: 1882)  // 32 yrs older
        let snapshot = FamilyGraphSnapshot(
            profiles: [subject.id: subject, father.id: father],
            relationships: [parentRel("f", "s", role: .father)]
        )
        let sub = ResearchSubject.fromProfile(subject, snapshot: snapshot)
        #expect(sub.familyContext?.fatherSurname == "Brooks")
    }

    @Test func implausibleBiologicalParentFilteredOut() {
        // 5-year gap — almost certainly a mis-typed sibling. Should
        // not pollute FamilyContext.
        let subject = profile(id: "s", given: "John", surname: "Smith", gender: .male, birthYear: 1900)
        let fakeFather = profile(id: "f", given: "Bill", surname: "Smith", gender: .male, birthYear: 1895)
        let snapshot = FamilyGraphSnapshot(
            profiles: [subject.id: subject, fakeFather.id: fakeFather],
            relationships: [parentRel("f", "s", role: .father)]
        )
        let sub = ResearchSubject.fromProfile(subject, snapshot: snapshot)
        #expect(sub.familyContext?.fatherName == nil,
                "5-year-gap 'father' should be filtered from FamilyContext, got \(String(describing: sub.familyContext?.fatherName))")
    }

    @Test func exactlyFourteenYearGapIsKept() {
        // Threshold is 14 inclusive. The Python check is `gap < 14`
        // → skip, so `gap >= 14` keeps. Pin the boundary.
        let subject = profile(id: "s", given: "X", surname: "Y", gender: .male, birthYear: 1900)
        let father = profile(id: "f", given: "A", surname: "B", gender: .male, birthYear: 1886)  // 14 yrs older
        let snapshot = FamilyGraphSnapshot(
            profiles: [subject.id: subject, father.id: father],
            relationships: [parentRel("f", "s", role: .father)]
        )
        let sub = ResearchSubject.fromProfile(subject, snapshot: snapshot)
        #expect(sub.familyContext?.fatherSurname == "B")
    }

    @Test func adoptiveParentExemptFromAgeGap() {
        // Guardian / adoptive parent with small age gap is legit —
        // the filter applies to biological subtype only.
        let subject = profile(id: "s", given: "Child", surname: "Doe", gender: .male, birthYear: 1900)
        let guardian = profile(id: "g", given: "Sis", surname: "Doe", gender: .female, birthYear: 1895)
        let snapshot = FamilyGraphSnapshot(
            profiles: [subject.id: subject, guardian.id: guardian],
            relationships: [parentRel("g", "s", role: .mother, subtype: .adoptive)]
        )
        let sub = ResearchSubject.fromProfile(subject, snapshot: snapshot)
        #expect(sub.familyContext?.motherSurname == "Doe",
                "Adoptive parent with small gap should NOT be filtered")
    }

    @Test func missingBirthYearKeepsTheParent() {
        // Can't validate gap → don't filter. Conservative — better
        // to keep a parent than silently drop one with thin data.
        let subject = profile(id: "s", given: "X", surname: "Y", gender: .male, birthYear: 1900)
        let father = profile(id: "f", given: "A", surname: "B", gender: .male, birthYear: nil)
        let snapshot = FamilyGraphSnapshot(
            profiles: [subject.id: subject, father.id: father],
            relationships: [parentRel("f", "s", role: .father)]
        )
        let sub = ResearchSubject.fromProfile(subject, snapshot: snapshot)
        #expect(sub.familyContext?.fatherSurname == "B")
    }
}
