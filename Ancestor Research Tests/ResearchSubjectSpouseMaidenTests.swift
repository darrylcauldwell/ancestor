import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the spouse-maiden derivation on `ResearchSubject.fromProfile` —
/// the wife's maiden surname is recovered from her own father's `lastName`
/// on the tree, so groom-side FreeBMD marriage probes can fan out across
/// both the wife's recorded (married) surname and her maiden surname.
///
/// Symmetric to today's `ResearchSubject.surnamesToProbe` maiden widening
/// (commit `0b75b5f`), but operating across the profile boundary: spouse
/// profile → spouse's parent profile → father's `lastName`.
///
/// Anchored to the Ernest Cauldwell case (parity report cluster #2): wife
/// Sarah Cauldwell carries `lastName = "Cauldwell"` (her married name)
/// while her real maiden surname "Ward" lives on her father Joseph Ward.
struct ResearchSubjectSpouseMaidenTests {

    // MARK: - fromProfile plumbing

    @Test func fromProfilePopulatesSpouseFatherSurnameFromTree() {
        // Husband (Ernest), wife (Sarah, recorded under married surname),
        // wife's father (Joseph Ward) — all on the tree. After
        // `fromProfile`, the subject's familyContext.spouseFatherSurname
        // must equal the wife's father's lastName.
        let husband = profile(id: "H", first: "Ernest", last: "Cauldwell", gender: .male)
        let wife = profile(id: "W", first: "Sarah", last: "Cauldwell", gender: .female)
        let wifeFather = profile(id: "WF", first: "Joseph", last: "Ward", gender: .male)
        let spouseEdge = Relationship(
            id: UUID(), from: "H", to: "W", type: .spouse, role: nil,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let wifeParentEdge = Relationship(
            id: UUID(), from: "WF", to: "W", type: .parent, role: .father,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snap = FamilyGraphSnapshot(
            profiles: ["H": husband, "W": wife, "WF": wifeFather],
            relationships: [spouseEdge, wifeParentEdge]
        )

        let subject = ResearchSubject.fromProfile(husband, snapshot: snap)
        #expect(subject.familyContext?.spouseSurname == "Cauldwell")
        #expect(subject.familyContext?.spouseFatherSurname == "Ward")
    }

    @Test func fromProfileNilSpouseFatherSurnameWhenWifeHasNoTrackedFather() {
        // Wife is on the tree but her parents aren't — common when the
        // groom's side has more depth than the bride's. spouseFatherSurname
        // is nil, dispatcher falls back to single-axis probing.
        let husband = profile(id: "H", first: "Ernest", last: "Cauldwell", gender: .male)
        let wife = profile(id: "W", first: "Sarah", last: "Cauldwell", gender: .female)
        let spouseEdge = Relationship(
            id: UUID(), from: "H", to: "W", type: .spouse, role: nil,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snap = FamilyGraphSnapshot(
            profiles: ["H": husband, "W": wife],
            relationships: [spouseEdge]
        )

        let subject = ResearchSubject.fromProfile(husband, snapshot: snap)
        #expect(subject.familyContext?.spouseSurname == "Cauldwell")
        #expect(subject.familyContext?.spouseFatherSurname == nil)
    }

    @Test func fromProfileNilSpouseFatherSurnameWhenNoSpouse() {
        // Unmarried subject — no spouse edge in the tree. Family context
        // builds with both spouseSurname and spouseFatherSurname nil.
        let subject = profile(id: "S", first: "Ernest", last: "Cauldwell", gender: .male)
        let snap = FamilyGraphSnapshot(profiles: ["S": subject], relationships: [])

        let researchSubject = ResearchSubject.fromProfile(subject, snapshot: snap)
        #expect(researchSubject.familyContext?.spouseSurname == nil)
        #expect(researchSubject.familyContext?.spouseFatherSurname == nil)
    }

    @Test func fromProfileSpouseFatherSurnameOnlyReadsMaleParent() {
        // Wife has both parents on the tree but only the FATHER's
        // surname is what FreeBMD's marriage index keys on for the
        // bride (women historically indexed under father's surname).
        // Test that the mother's surname doesn't shadow the father's
        // when present.
        let husband = profile(id: "H", first: "Ernest", last: "Cauldwell", gender: .male)
        let wife = profile(id: "W", first: "Sarah", last: "Cauldwell", gender: .female)
        let wifeFather = profile(id: "WF", first: "Joseph", last: "Ward", gender: .male)
        let wifeMother = profile(id: "WM", first: "Mary", last: "Smith", gender: .female)
        let spouseEdge = Relationship(
            id: UUID(), from: "H", to: "W", type: .spouse, role: nil,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let fatherEdge = Relationship(
            id: UUID(), from: "WF", to: "W", type: .parent, role: .father,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let motherEdge = Relationship(
            id: UUID(), from: "WM", to: "W", type: .parent, role: .mother,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snap = FamilyGraphSnapshot(
            profiles: ["H": husband, "W": wife, "WF": wifeFather, "WM": wifeMother],
            relationships: [spouseEdge, fatherEdge, motherEdge]
        )

        let subject = ResearchSubject.fromProfile(husband, snapshot: snap)
        #expect(subject.familyContext?.spouseFatherSurname == "Ward",
                "Must read wife's father's surname, not mother's")
    }

    @Test func fromProfileSpouseFatherSurnameForFemaleSubjectAlsoPlumbed() {
        // Symmetric case: a female subject (Sarah) with a male spouse
        // (Ernest) whose own father is on the tree. The plumbing is
        // gender-neutral on the subject side — the field always carries
        // the spouse's father's surname. (Marriage probes don't act on
        // it for female subjects in this fix, but the field stays
        // populated for future use and doesn't depend on subject gender.)
        let wife = profile(id: "W", first: "Sarah", last: "Cauldwell", gender: .female)
        let husband = profile(id: "H", first: "Ernest", last: "Cauldwell", gender: .male)
        let husbandFather = profile(id: "HF", first: "John", last: "Cauldwell", gender: .male)
        let spouseEdge = Relationship(
            id: UUID(), from: "W", to: "H", type: .spouse, role: nil,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let husbandParentEdge = Relationship(
            id: UUID(), from: "HF", to: "H", type: .parent, role: .father,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
        let snap = FamilyGraphSnapshot(
            profiles: ["W": wife, "H": husband, "HF": husbandFather],
            relationships: [spouseEdge, husbandParentEdge]
        )

        let subject = ResearchSubject.fromProfile(wife, snapshot: snap)
        #expect(subject.familyContext?.spouseFatherSurname == "Cauldwell")
    }

    // MARK: - Fixtures

    private func profile(
        id: String,
        first: String?,
        last: String?,
        gender: Gender
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: first, lastName: last,
            gender: gender,
            attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }
}
