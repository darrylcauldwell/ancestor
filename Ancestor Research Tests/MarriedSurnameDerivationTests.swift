import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the spouse-derived married-surname derivation in
/// `ResearchSubject.fromProfile`. Mirrors the deterministic pivot in
/// `agent/pipeline.py:_expand_post_marriage_searches` — without it,
/// women's death + probate searches probe only the maiden surname
/// and miss records filed under the married surname.
///
/// Anchored to the Lilian Mary Brooks → Holmes case: WikiTree's
/// LastNameCurrent kept "Brooks" after marriage, so the explicit
/// `profile.marriedSurname` is nil. The fix derives "Holmes" from
/// her linked spouse so the dispatcher fans out death/burial/probate
/// queries to both surnames.
@MainActor
struct MarriedSurnameDerivationTests {

    private func profile(
        id: String, given: String, surname: String,
        gender: Gender = .female, birthYear: Int? = nil,
        marriedSurname: String? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: given, middleName: nil, lastName: surname,
            marriedSurname: marriedSurname,
            nickName: nil, mothersMaidenName: nil,
            gender: gender, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
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

    @Test func femaleWithDifferentSurnameSpouseDerivesMarriedSurname() {
        let lilian = profile(id: "lilian", given: "Lilian Mary", surname: "Brooks", birthYear: 1914)
        let reginald = profile(id: "reg", given: "Reginald", surname: "Holmes", gender: .male, birthYear: 1916)
        let snapshot = FamilyGraphSnapshot(
            profiles: [lilian.id: lilian, reginald.id: reginald],
            relationships: [spouseRel(lilian.id, reginald.id)]
        )
        let subject = ResearchSubject.fromProfile(lilian, snapshot: snapshot)
        #expect(subject.marriedSurname == "Holmes",
                "Should derive Holmes from spouse — was \(subject.marriedSurname ?? "nil")")
    }

    @Test func explicitProfileMarriedSurnameTakesPrecedence() {
        // Even with a spouse linked, an explicitly-set marriedSurname
        // wins (the import / user may know the canonical form better
        // than the spouse-derivation chain).
        let lilian = profile(id: "lilian", given: "Lilian", surname: "Brooks", marriedSurname: "Holmes-Brooks")
        let reginald = profile(id: "reg", given: "R", surname: "Holmes", gender: .male)
        let snapshot = FamilyGraphSnapshot(
            profiles: [lilian.id: lilian, reginald.id: reginald],
            relationships: [spouseRel(lilian.id, reginald.id)]
        )
        let subject = ResearchSubject.fromProfile(lilian, snapshot: snapshot)
        #expect(subject.marriedSurname == "Holmes-Brooks")
    }

    @Test func maleSubjectDoesNotDeriveMarriedSurname() {
        // Symmetric guard — men don't take spouse surname in this era.
        // The Python expansion explicitly gates on gender == F.
        let ernest = profile(id: "e", given: "Ernest", surname: "Cauldwell", gender: .male)
        let kathleen = profile(id: "k", given: "Kathleen", surname: "Wheeldon", gender: .female)
        let snapshot = FamilyGraphSnapshot(
            profiles: [ernest.id: ernest, kathleen.id: kathleen],
            relationships: [spouseRel(ernest.id, kathleen.id)]
        )
        let subject = ResearchSubject.fromProfile(ernest, snapshot: snapshot)
        #expect(subject.marriedSurname == nil,
                "Male subjects should not pick up spouse surname")
    }

    @Test func femaleWithSameSurnameSpouseYieldsNil() {
        // No useful pivot when spouse shares the surname (re-marriage
        // to a cousin, or same-name coincidence). Avoids a useless
        // duplicate-surname fan-out.
        let lilian = profile(id: "l", given: "Lilian", surname: "Brooks")
        let other = profile(id: "o", given: "John", surname: "Brooks", gender: .male)
        let snapshot = FamilyGraphSnapshot(
            profiles: [lilian.id: lilian, other.id: other],
            relationships: [spouseRel(lilian.id, other.id)]
        )
        let subject = ResearchSubject.fromProfile(lilian, snapshot: snapshot)
        #expect(subject.marriedSurname == nil)
    }

    @Test func femaleWithNoSpouseYieldsNil() {
        // Unmarried female subject — nothing to derive from.
        let lilian = profile(id: "l", given: "Lilian", surname: "Brooks")
        let snapshot = FamilyGraphSnapshot(
            profiles: [lilian.id: lilian],
            relationships: []
        )
        let subject = ResearchSubject.fromProfile(lilian, snapshot: snapshot)
        #expect(subject.marriedSurname == nil)
    }
}
