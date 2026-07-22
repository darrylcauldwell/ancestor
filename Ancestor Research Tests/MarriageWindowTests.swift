import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// UV-01 — a marriage precedes the first child, so when the children's birth
/// years are known the marriage search window tightens around the earliest
/// one instead of spanning the whole plausible adult life.
@MainActor
struct MarriageWindowTests {

    // MARK: - yearRange narrowing

    @Test func marriageWindowNarrowsToFirstChild() {
        let subject = subjectBorn(1850, childBirthYears: [1885, 1888])
        let range = subject.yearRange(for: .marriage)
        // low  = max(birth+16 = 1866, firstChild-12 = 1873) = 1873
        // high = min(wideHigh 1910, firstChild+2 = 1887) = 1887
        #expect(range.from == 1873)
        #expect(range.to == 1887)
    }

    @Test func marriageWindowStaysWideWithoutChildYears() {
        let subject = subjectBorn(1850, childBirthYears: [])
        let range = subject.yearRange(for: .marriage)
        #expect(range.from == 1866, "birth + 16")
        #expect(range.to == 1910, "birth + 60 when no death year")
    }

    @Test func narrowingNeverWidensBeyondTheBiologicalFloor() {
        // A child born when the subject was only ~18 → firstChild-12 falls
        // below the birth+16 floor, so the floor still wins (never widen).
        let subject = subjectBorn(1850, childBirthYears: [1868])
        let range = subject.yearRange(for: .marriage)
        #expect(range.from == 1866, "birth+16 floor beats firstChild-12 = 1856")
        #expect(range.to == 1870, "firstChild + 2")
    }

    // MARK: - fromProfile derivation

    @Test func fromProfilePopulatesChildBirthYears() {
        let parent = profile(id: "p", given: "John", birthYear: 1850)
        let childA = profile(id: "cA", given: "Ada", birthYear: 1885)
        let childB = profile(id: "cB", given: "Bert", birthYear: 1888)
        let snap = FamilyGraphSnapshot(
            profiles: [parent.id: parent, childA.id: childA, childB.id: childB],
            relationships: [parentOf(parent.id, childA.id), parentOf(parent.id, childB.id)])
        let subject = ResearchSubject.fromProfile(parent, snapshot: snap)
        #expect(Set(subject.familyContext?.childBirthYears ?? []) == [1885, 1888])
        // …and the marriage window is tightened as a result.
        #expect(subject.yearRange(for: .marriage).to == 1887)
    }

    // MARK: - Fixtures

    private func subjectBorn(_ year: Int, childBirthYears: [Int]) -> ResearchSubject {
        ResearchSubject(
            surname: "Smith", givenName: "John",
            birthYearFrom: year, birthYearTo: year,
            gender: .male, region: .englandAndWales, mode: .extend,
            familyContext: FamilyContext(
                spouseName: nil, spouseSurname: nil, spouseGivenName: nil,
                spouseFatherSurname: nil, childNames: [],
                fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                motherName: nil, motherSurname: nil, motherGivenName: nil,
                childBirthYears: childBirthYears))
    }

    private func profile(id: String, given: String, birthYear: Int) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: given, middleName: nil, lastName: "Smith",
            gender: .male, attributes: nil,
            birthDate: GenealogicalDate(parsing: String(birthYear)),
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func parentOf(_ parent: String, _ child: String) -> Relationship {
        Relationship(
            id: UUID(), from: parent, to: child,
            type: .parent, role: nil, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }
}
