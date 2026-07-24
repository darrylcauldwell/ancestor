import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Sibling-cohort birth inference: a dateless subject inherits a search window
/// from the span of their dated siblings (± ~15 years). Anchored to the real
/// "Eve Land" case — dateless, with sibling "Ida Louisa Land" (b.1885) — where
/// the window rules out the 1862 and 1923/1924 namesake births. Search-only,
/// never written back; own DOB and a spouse estimate both take precedence.
@MainActor
struct SiblingBirthWindowTests {

    @Test func datelessSubjectInheritsSiblingCohortWindow() {
        let eve = profile(id: "eve", given: "Eve", birthYear: nil)
        let ida = profile(id: "ida", given: "Ida", birthYear: 1885)
        let subject = ResearchSubject.fromProfile(eve, snapshot: siblings(eve, ida))
        #expect(subject.birthYearFrom == 1870, "sibling 1885 − 15")
        #expect(subject.birthYearTo == 1900, "sibling 1885 + 15")
    }

    @Test func siblingWindowSpansTheWholeCohort() {
        let eve = profile(id: "eve", given: "Eve", birthYear: nil)
        let ida = profile(id: "ida", given: "Ida", birthYear: 1885)
        let sam = profile(id: "sam", given: "Sam", birthYear: 1897)
        let subject = ResearchSubject.fromProfile(eve, snapshot: siblings(eve, ida, sam))
        #expect(subject.birthYearFrom == 1870, "min sibling 1885 − 15")
        #expect(subject.birthYearTo == 1912, "max sibling 1897 + 15")
    }

    @Test func ownDobWinsOverSiblings() {
        let eve = profile(id: "eve", given: "Eve", birthYear: 1894)
        let ida = profile(id: "ida", given: "Ida", birthYear: 1885)
        let subject = ResearchSubject.fromProfile(eve, snapshot: siblings(eve, ida))
        #expect(subject.birthYearFrom == 1894 && subject.birthYearTo == 1894,
                "the subject's own DOB must win over the sibling estimate")
    }

    @Test func noDatedSiblingsFallsThrough() {
        let eve = profile(id: "eve", given: "Eve", birthYear: nil)
        let ida = profile(id: "ida", given: "Ida", birthYear: nil)
        let subject = ResearchSubject.fromProfile(eve, snapshot: siblings(eve, ida))
        #expect(subject.birthYearFrom == nil && subject.birthYearTo == nil)
    }

    // MARK: - Fixtures

    private func profile(id: String, given: String, birthYear: Int?) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: given, middleName: nil, lastName: "Land",
            gender: .female, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    /// A snapshot where `subject` and every `sibs` share one mother — so
    /// `snapshot.siblingsOf(subject)` returns the siblings.
    private func siblings(_ subject: Profile, _ sibs: Profile...) -> FamilyGraphSnapshot {
        let mother = profile(id: "mother", given: "Mother", birthYear: nil)
        var profiles: [String: Profile] = [mother.id: mother, subject.id: subject]
        var rels: [Relationship] = []
        for kid in [subject] + sibs {
            profiles[kid.id] = kid
            rels.append(Relationship(
                id: UUID(), from: mother.id, to: kid.id, type: .parent,
                role: .mother, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        }
        return FamilyGraphSnapshot(profiles: profiles, relationships: rels)
    }
}
