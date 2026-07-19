import Testing
import Foundation
import AncestorKit

/// The "married surname missing" audit — the mirror of
/// `UnlinkedSpouseForFemaleSubjectRule`. Reproduces the live Jennifer Holmes →
/// David Cauldwell case (probate silently searched under the maiden name).
struct MarriedSurnameFromSpouseRuleTests {

    private func profile(_ id: String, first: String, last: String?,
                         gender: Gender = .female, married: String? = nil) -> Profile {
        Profile(id: id, firstName: first, lastName: last, marriedSurname: married,
                gender: gender, isDeleted: false, sources: [:], disputes: [:])
    }
    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil,
                     subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }
    private func snapshot(_ profiles: [Profile], _ rels: [Relationship]) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(
            profiles: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) }),
            relationships: rels)
    }

    private let rule = MarriedSurnameFromSpouseRule()

    @Test func firesForFemaleWithLinkedSpouseAndNoMarriedName() {
        let her = profile("her", first: "Jennifer", last: "Holmes")
        let him = profile("him", first: "David", last: "Cauldwell", gender: .male)
        let snap = snapshot([her, him], [spouseEdge("her", "him")])

        let results = rule.evaluate(profile: her, snapshot: snap)
        #expect(results.count == 1)
        #expect(results[0].message.contains("Cauldwell"))
        #expect(results[0].relatedProfileIDs == ["him"])
        // The shared suggestion (used by the one-click fix) agrees on the name.
        #expect(MarriedSurnameFromSpouseRule.suggestion(for: her, in: snap)?.marriedSurname == "Cauldwell")
    }

    @Test func silentWhenMarriedSurnameAlreadySet() {
        let her = profile("her", first: "Jennifer", last: "Holmes", married: "Cauldwell")
        let him = profile("him", first: "David", last: "Cauldwell", gender: .male)
        let snap = snapshot([her, him], [spouseEdge("her", "him")])
        #expect(rule.evaluate(profile: her, snapshot: snap).isEmpty)
    }

    @Test func silentForMale() {
        let him = profile("him", first: "David", last: "Cauldwell", gender: .male)
        let her = profile("her", first: "Jennifer", last: "Holmes")
        let snap = snapshot([him, her], [spouseEdge("him", "her")])
        #expect(rule.evaluate(profile: him, snapshot: snap).isEmpty)
    }

    @Test func silentWhenSpouseSharesSurname() {
        // Already recorded under the married surname as her lastName — nothing to add.
        let her = profile("her", first: "Jennifer", last: "Cauldwell")
        let him = profile("him", first: "David", last: "Cauldwell", gender: .male)
        let snap = snapshot([her, him], [spouseEdge("her", "him")])
        #expect(rule.evaluate(profile: her, snapshot: snap).isEmpty)
    }

    @Test func silentWhenNoSpouse() {
        let her = profile("her", first: "Jennifer", last: "Holmes")
        #expect(rule.evaluate(profile: her, snapshot: snapshot([her], [])).isEmpty)
    }
}
