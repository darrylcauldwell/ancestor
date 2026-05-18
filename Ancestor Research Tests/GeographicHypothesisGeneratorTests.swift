import Testing
import Foundation
@testable import Ancestor_Research

/// Verifies `GeographicHypothesisGenerator` correctly infers likely
/// registration districts by walking the family graph.
///
/// Anchored to the real-world Jennifer Holmes case that exposed the gap:
/// her profile has only the year 1948 — no birth district — yet her own
/// marriage (Belper, 1969) and her son's birth (Wirksworth, 1976) both
/// point unambiguously at Belper RD.
struct GeographicHypothesisGeneratorTests {

    // MARK: - Helpers

    private func date(_ year: Int) -> GenealogicalDate {
        GenealogicalDate(
            original: "\(year)",
            earliest: year,
            latest: year,
            isApproximate: false,
            qualifier: .yearOnly
        )
    }

    private func profile(
        id: String,
        first: String,
        last: String,
        gender: Gender? = nil,
        birthYear: Int? = nil,
        birthLocation: String? = nil,
        birthLocationCode: String? = nil
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: first,
            middleName: nil,
            lastName: last,
            nickName: nil,
            mothersMaidenName: nil,
            gender: gender,
            attributes: nil,
            birthDate: birthYear.map { date($0) },
            birthLocation: birthLocation,
            birthLocationCode: birthLocationCode,
            deathDate: nil,
            deathLocation: nil,
            deathLocationCode: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    private func parentRel(parent: String, child: String, role: ParentRole) -> Relationship {
        Relationship(
            id: UUID(),
            from: parent,
            to: child,
            type: .parent,
            role: role,
            subtype: .biological,
            marriageDate: nil,
            marriageLocation: nil,
            divorceDate: nil
        )
    }

    private func spouseRel(
        a: String, b: String,
        location: String?, year: Int?
    ) -> Relationship {
        Relationship(
            id: UUID(),
            from: a,
            to: b,
            type: .spouse,
            role: nil,
            subtype: .unknown,
            marriageDate: year.map { date($0) },
            marriageLocation: location,
            divorceDate: nil
        )
    }

    // MARK: - Tests

    @Test func jenniferHolmesResolvesToBelperFromTreeContext() {
        // Jennifer has no birth district, only year 1948.
        // Two tree signals: she married in Belper (1969), and her son Darryl
        // was born in Wirksworth (which sits inside Belper RD post-1937).
        let jennifer = profile(
            id: "jennifer",
            first: "Jennifer", last: "Holmes",
            gender: .female,
            birthYear: 1948
        )
        let david = profile(
            id: "david",
            first: "David", last: "Cauldwell",
            gender: .male,
            birthYear: 1947
        )
        let darryl = profile(
            id: "darryl",
            first: "Darryl", last: "Cauldwell",
            gender: .male,
            birthYear: 1976,
            birthLocation: "Wirksworth, Derbyshire",
            birthLocationCode: "DBY:Wirksworth"
        )

        let snapshot = FamilyGraphSnapshot(
            profiles: [
                jennifer.id: jennifer,
                david.id: david,
                darryl.id: darryl,
            ],
            relationships: [
                spouseRel(a: david.id, b: jennifer.id, location: "BELPER", year: 1969),
                parentRel(parent: jennifer.id, child: darryl.id, role: .mother),
                parentRel(parent: david.id, child: darryl.id, role: .father),
            ]
        )

        let hypotheses = GeographicHypothesisGenerator.inferDistricts(
            for: jennifer.id,
            snapshot: snapshot,
            eventYear: 1948
        )

        #expect(!hypotheses.isEmpty, "should produce at least one hypothesis")
        let top = hypotheses[0]
        #expect(top.districtName.lowercased() == "belper",
                "top hypothesis should be Belper RD, got \(top.districtName)")
        #expect(top.chapmanCode == "DBY")
        #expect(top.signals.count >= 2,
                "should record both marriage and child-birth signals")
    }

    @Test func emptyTreeProducesNoHypotheses() {
        let lone = profile(id: "lone", first: "A", last: "B", birthYear: 1900)
        let snapshot = FamilyGraphSnapshot(
            profiles: [lone.id: lone],
            relationships: []
        )
        let hypotheses = GeographicHypothesisGenerator.inferDistricts(
            for: lone.id,
            snapshot: snapshot
        )
        #expect(hypotheses.isEmpty)
    }

    @Test func directBirthLocationOutranksInferredSignals() {
        // When the subject's own birth location is set, it should dominate.
        let subject = profile(
            id: "s",
            first: "S", last: "T",
            birthYear: 1900,
            birthLocation: "Ashbourne",
            birthLocationCode: nil
        )
        let snapshot = FamilyGraphSnapshot(
            profiles: [subject.id: subject],
            relationships: []
        )
        let hypotheses = GeographicHypothesisGenerator.inferDistricts(
            for: subject.id,
            snapshot: snapshot,
            eventYear: 1900
        )
        #expect(hypotheses.first?.districtName.lowercased() == "ashbourne")
    }

    @Test func unknownSubjectIDReturnsEmpty() {
        let snapshot = FamilyGraphSnapshot.empty
        let hypotheses = GeographicHypothesisGenerator.inferDistricts(
            for: "nonexistent",
            snapshot: snapshot
        )
        #expect(hypotheses.isEmpty)
    }
}
