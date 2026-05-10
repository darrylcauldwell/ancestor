import Testing
import Foundation
@testable import Ancestor_Research

struct RelationshipCalculatorTests {

    private func makeProfile(
        id: String,
        firstName: String? = nil,
        gender: Gender? = .unknown
    ) -> Profile {
        Profile(
            id: id,
            externalIDs: [:],
            firstName: firstName,
            lastName: nil,
            gender: gender,
            attributes: nil,
            birthDate: nil,
            birthLocation: nil,
            deathDate: nil,
            deathLocation: nil,
            bio: nil,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )
    }

    private func parentEdge(parent: String, child: String) -> Relationship {
        Relationship(
            id: UUID(),
            from: parent,
            to: child,
            type: .parent,
            role: .unspecified,
            subtype: .biological,
            marriageDate: nil,
            marriageLocation: nil,
            divorceDate: nil
        )
    }

    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(
            id: UUID(),
            from: a,
            to: b,
            type: .spouse,
            role: nil,
            subtype: .unknown,
            marriageDate: nil,
            marriageLocation: nil,
            divorceDate: nil
        )
    }

    // MARK: - Self & Spouse

    @Test func selfRelationship() {
        let me = makeProfile(id: "me")
        let snap = FamilyGraphSnapshot(profiles: ["me": me], relationships: [])
        let desc = RelationshipCalculator.describe(from: "me", to: "me", snapshot: snap)
        #expect(desc?.label == "self")
        #expect(desc?.path.isEmpty == true)
    }

    @Test func spouseHusband() {
        let me = makeProfile(id: "me", gender: .female)
        let him = makeProfile(id: "him", gender: .male)
        let snap = FamilyGraphSnapshot(
            profiles: ["me": me, "him": him],
            relationships: [spouseEdge("me", "him")]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "him", snapshot: snap)
        #expect(desc?.label == "husband")
    }

    @Test func spouseWife() {
        let me = makeProfile(id: "me", gender: .male)
        let her = makeProfile(id: "her", gender: .female)
        let snap = FamilyGraphSnapshot(
            profiles: ["me": me, "her": her],
            relationships: [spouseEdge("me", "her")]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "her", snapshot: snap)
        #expect(desc?.label == "wife")
    }

    @Test func spouseUnknownGender() {
        let me = makeProfile(id: "me", gender: .unknown)
        let other = makeProfile(id: "other", gender: .unknown)
        let snap = FamilyGraphSnapshot(
            profiles: ["me": me, "other": other],
            relationships: [spouseEdge("me", "other")]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "other", snapshot: snap)
        #expect(desc?.label == "spouse")
    }

    // MARK: - Direct ancestry

    @Test func parentFather() {
        let dad = makeProfile(id: "dad", gender: .male)
        let me = makeProfile(id: "me")
        let snap = FamilyGraphSnapshot(
            profiles: ["dad": dad, "me": me],
            relationships: [parentEdge(parent: "dad", child: "me")]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "dad", snapshot: snap)
        #expect(desc?.label == "father")
        #expect(desc?.path == ["me", "dad"])
    }

    @Test func parentMother() {
        let mum = makeProfile(id: "mum", gender: .female)
        let me = makeProfile(id: "me")
        let snap = FamilyGraphSnapshot(
            profiles: ["mum": mum, "me": me],
            relationships: [parentEdge(parent: "mum", child: "me")]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "mum", snapshot: snap)
        #expect(desc?.label == "mother")
    }

    @Test func grandfather() {
        let gp = makeProfile(id: "gp", gender: .male)
        let p = makeProfile(id: "p")
        let me = makeProfile(id: "me")
        let snap = FamilyGraphSnapshot(
            profiles: ["gp": gp, "p": p, "me": me],
            relationships: [
                parentEdge(parent: "gp", child: "p"),
                parentEdge(parent: "p", child: "me")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "gp", snapshot: snap)
        #expect(desc?.label == "grandfather")
        #expect(desc?.path == ["me", "p", "gp"])
    }

    @Test func grandmother() {
        let gp = makeProfile(id: "gp", gender: .female)
        let p = makeProfile(id: "p")
        let me = makeProfile(id: "me")
        let snap = FamilyGraphSnapshot(
            profiles: ["gp": gp, "p": p, "me": me],
            relationships: [
                parentEdge(parent: "gp", child: "p"),
                parentEdge(parent: "p", child: "me")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "gp", snapshot: snap)
        #expect(desc?.label == "grandmother")
    }

    @Test func greatGrandfather() {
        let ggp = makeProfile(id: "ggp", gender: .male)
        let gp = makeProfile(id: "gp")
        let p = makeProfile(id: "p")
        let me = makeProfile(id: "me")
        let snap = FamilyGraphSnapshot(
            profiles: ["ggp": ggp, "gp": gp, "p": p, "me": me],
            relationships: [
                parentEdge(parent: "ggp", child: "gp"),
                parentEdge(parent: "gp", child: "p"),
                parentEdge(parent: "p", child: "me")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "ggp", snapshot: snap)
        #expect(desc?.label == "great-grandfather")
    }

    @Test func greatGreatGrandfather() {
        let gggp = makeProfile(id: "gggp", gender: .male)
        let ggp = makeProfile(id: "ggp")
        let gp = makeProfile(id: "gp")
        let p = makeProfile(id: "p")
        let me = makeProfile(id: "me")
        let snap = FamilyGraphSnapshot(
            profiles: ["gggp": gggp, "ggp": ggp, "gp": gp, "p": p, "me": me],
            relationships: [
                parentEdge(parent: "gggp", child: "ggp"),
                parentEdge(parent: "ggp", child: "gp"),
                parentEdge(parent: "gp", child: "p"),
                parentEdge(parent: "p", child: "me")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "gggp", snapshot: snap)
        #expect(desc?.label == "great-great-grandfather")
    }

    // MARK: - Direct descendancy

    @Test func childSon() {
        let me = makeProfile(id: "me")
        let kid = makeProfile(id: "kid", gender: .male)
        let snap = FamilyGraphSnapshot(
            profiles: ["me": me, "kid": kid],
            relationships: [parentEdge(parent: "me", child: "kid")]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "kid", snapshot: snap)
        #expect(desc?.label == "son")
    }

    @Test func childDaughter() {
        let me = makeProfile(id: "me")
        let kid = makeProfile(id: "kid", gender: .female)
        let snap = FamilyGraphSnapshot(
            profiles: ["me": me, "kid": kid],
            relationships: [parentEdge(parent: "me", child: "kid")]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "kid", snapshot: snap)
        #expect(desc?.label == "daughter")
    }

    @Test func grandson() {
        let me = makeProfile(id: "me")
        let kid = makeProfile(id: "kid")
        let gk = makeProfile(id: "gk", gender: .male)
        let snap = FamilyGraphSnapshot(
            profiles: ["me": me, "kid": kid, "gk": gk],
            relationships: [
                parentEdge(parent: "me", child: "kid"),
                parentEdge(parent: "kid", child: "gk")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "gk", snapshot: snap)
        #expect(desc?.label == "grandson")
    }

    @Test func granddaughter() {
        let me = makeProfile(id: "me")
        let kid = makeProfile(id: "kid")
        let gk = makeProfile(id: "gk", gender: .female)
        let snap = FamilyGraphSnapshot(
            profiles: ["me": me, "kid": kid, "gk": gk],
            relationships: [
                parentEdge(parent: "me", child: "kid"),
                parentEdge(parent: "kid", child: "gk")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "gk", snapshot: snap)
        #expect(desc?.label == "granddaughter")
    }

    @Test func greatGrandchildIsGenderNeutral() {
        let me = makeProfile(id: "me")
        let kid = makeProfile(id: "kid")
        let gk = makeProfile(id: "gk")
        let ggk = makeProfile(id: "ggk", gender: .male) // even with gender, label stays neutral
        let snap = FamilyGraphSnapshot(
            profiles: ["me": me, "kid": kid, "gk": gk, "ggk": ggk],
            relationships: [
                parentEdge(parent: "me", child: "kid"),
                parentEdge(parent: "kid", child: "gk"),
                parentEdge(parent: "gk", child: "ggk")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "ggk", snapshot: snap)
        #expect(desc?.label == "great-grandchild")
    }

    // MARK: - Siblings

    @Test func brotherFullSiblings() {
        let p = makeProfile(id: "p")
        let me = makeProfile(id: "me")
        let bro = makeProfile(id: "bro", gender: .male)
        let snap = FamilyGraphSnapshot(
            profiles: ["p": p, "me": me, "bro": bro],
            relationships: [
                parentEdge(parent: "p", child: "me"),
                parentEdge(parent: "p", child: "bro")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "bro", snapshot: snap)
        #expect(desc?.label == "brother")
    }

    @Test func sisterHalfSiblings() {
        // Half sister — only one shared parent
        let dad = makeProfile(id: "dad")
        let mum1 = makeProfile(id: "mum1")
        let mum2 = makeProfile(id: "mum2")
        let me = makeProfile(id: "me")
        let sis = makeProfile(id: "sis", gender: .female)
        let snap = FamilyGraphSnapshot(
            profiles: ["dad": dad, "mum1": mum1, "mum2": mum2, "me": me, "sis": sis],
            relationships: [
                parentEdge(parent: "dad", child: "me"),
                parentEdge(parent: "mum1", child: "me"),
                parentEdge(parent: "dad", child: "sis"),
                parentEdge(parent: "mum2", child: "sis")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "sis", snapshot: snap)
        #expect(desc?.label == "sister")
    }

    @Test func siblingUnknownGender() {
        let p = makeProfile(id: "p")
        let me = makeProfile(id: "me")
        let sib = makeProfile(id: "sib", gender: .unknown)
        let snap = FamilyGraphSnapshot(
            profiles: ["p": p, "me": me, "sib": sib],
            relationships: [
                parentEdge(parent: "p", child: "me"),
                parentEdge(parent: "p", child: "sib")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "sib", snapshot: snap)
        #expect(desc?.label == "sibling")
    }

    // MARK: - Aunts / Uncles / Nephews / Nieces

    @Test func uncle() {
        // gp → dad → me; gp → uncle
        let gp = makeProfile(id: "gp")
        let dad = makeProfile(id: "dad")
        let me = makeProfile(id: "me")
        let uncle = makeProfile(id: "uncle", gender: .male)
        let snap = FamilyGraphSnapshot(
            profiles: ["gp": gp, "dad": dad, "me": me, "uncle": uncle],
            relationships: [
                parentEdge(parent: "gp", child: "dad"),
                parentEdge(parent: "gp", child: "uncle"),
                parentEdge(parent: "dad", child: "me")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "uncle", snapshot: snap)
        #expect(desc?.label == "uncle")
    }

    @Test func aunt() {
        let gp = makeProfile(id: "gp")
        let dad = makeProfile(id: "dad")
        let me = makeProfile(id: "me")
        let aunt = makeProfile(id: "aunt", gender: .female)
        let snap = FamilyGraphSnapshot(
            profiles: ["gp": gp, "dad": dad, "me": me, "aunt": aunt],
            relationships: [
                parentEdge(parent: "gp", child: "dad"),
                parentEdge(parent: "gp", child: "aunt"),
                parentEdge(parent: "dad", child: "me")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "aunt", snapshot: snap)
        #expect(desc?.label == "aunt")
    }

    @Test func nephew() {
        // Reverse of uncle test: from uncle to me → nephew
        let gp = makeProfile(id: "gp")
        let dad = makeProfile(id: "dad")
        let me = makeProfile(id: "me", gender: .male)
        let uncle = makeProfile(id: "uncle", gender: .male)
        let snap = FamilyGraphSnapshot(
            profiles: ["gp": gp, "dad": dad, "me": me, "uncle": uncle],
            relationships: [
                parentEdge(parent: "gp", child: "dad"),
                parentEdge(parent: "gp", child: "uncle"),
                parentEdge(parent: "dad", child: "me")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "uncle", to: "me", snapshot: snap)
        #expect(desc?.label == "nephew")
    }

    @Test func greatAunt() {
        // ggp → gp → dad → me; ggp → greatAunt
        let ggp = makeProfile(id: "ggp")
        let gp = makeProfile(id: "gp")
        let dad = makeProfile(id: "dad")
        let me = makeProfile(id: "me")
        let greatAunt = makeProfile(id: "ga", gender: .female)
        let snap = FamilyGraphSnapshot(
            profiles: ["ggp": ggp, "gp": gp, "dad": dad, "me": me, "ga": greatAunt],
            relationships: [
                parentEdge(parent: "ggp", child: "gp"),
                parentEdge(parent: "ggp", child: "ga"),
                parentEdge(parent: "gp", child: "dad"),
                parentEdge(parent: "dad", child: "me")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "ga", snapshot: snap)
        #expect(desc?.label == "great-aunt")
    }

    // MARK: - Cousins

    @Test func firstCousin() {
        // gp → dad → me; gp → uncle → cousin
        let gp = makeProfile(id: "gp")
        let dad = makeProfile(id: "dad")
        let uncle = makeProfile(id: "uncle")
        let me = makeProfile(id: "me")
        let cousin = makeProfile(id: "cousin")
        let snap = FamilyGraphSnapshot(
            profiles: ["gp": gp, "dad": dad, "uncle": uncle, "me": me, "cousin": cousin],
            relationships: [
                parentEdge(parent: "gp", child: "dad"),
                parentEdge(parent: "gp", child: "uncle"),
                parentEdge(parent: "dad", child: "me"),
                parentEdge(parent: "uncle", child: "cousin")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "cousin", snapshot: snap)
        #expect(desc?.label == "first cousin")
        // Path: me → dad → gp → uncle → cousin
        #expect(desc?.path == ["me", "dad", "gp", "uncle", "cousin"])
    }

    @Test func firstCousinOnceRemoved() {
        // me at depth 2 from gp; cousin's child at depth 3 from gp
        let gp = makeProfile(id: "gp")
        let dad = makeProfile(id: "dad")
        let uncle = makeProfile(id: "uncle")
        let me = makeProfile(id: "me")
        let cousin = makeProfile(id: "cousin")
        let cousinKid = makeProfile(id: "ck")
        let snap = FamilyGraphSnapshot(
            profiles: ["gp": gp, "dad": dad, "uncle": uncle, "me": me, "cousin": cousin, "ck": cousinKid],
            relationships: [
                parentEdge(parent: "gp", child: "dad"),
                parentEdge(parent: "gp", child: "uncle"),
                parentEdge(parent: "dad", child: "me"),
                parentEdge(parent: "uncle", child: "cousin"),
                parentEdge(parent: "cousin", child: "ck")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "ck", snapshot: snap)
        #expect(desc?.label == "first cousin once removed")
    }

    @Test func secondCousin() {
        // Common ancestor at depth 3 (great-grandparent) for both
        let ggp = makeProfile(id: "ggp")
        // My side
        let gp1 = makeProfile(id: "gp1")
        let dad = makeProfile(id: "dad")
        let me = makeProfile(id: "me")
        // Cousin's side
        let gp2 = makeProfile(id: "gp2")
        let other = makeProfile(id: "other")
        let cousin2 = makeProfile(id: "c2")

        let snap = FamilyGraphSnapshot(
            profiles: [
                "ggp": ggp, "gp1": gp1, "dad": dad, "me": me,
                "gp2": gp2, "other": other, "c2": cousin2
            ],
            relationships: [
                parentEdge(parent: "ggp", child: "gp1"),
                parentEdge(parent: "ggp", child: "gp2"),
                parentEdge(parent: "gp1", child: "dad"),
                parentEdge(parent: "dad", child: "me"),
                parentEdge(parent: "gp2", child: "other"),
                parentEdge(parent: "other", child: "c2")
            ]
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "c2", snapshot: snap)
        #expect(desc?.label == "second cousin")
    }

    // MARK: - Edge cases

    @Test func unrelatedReturnsNoKnownRelationship() {
        let me = makeProfile(id: "me")
        let stranger = makeProfile(id: "stranger")
        let snap = FamilyGraphSnapshot(
            profiles: ["me": me, "stranger": stranger],
            relationships: []
        )
        let desc = RelationshipCalculator.describe(from: "me", to: "stranger", snapshot: snap)
        #expect(desc?.label == "no known relationship")
    }

    @Test func missingFromIDReturnsNil() {
        let target = makeProfile(id: "target")
        let snap = FamilyGraphSnapshot(profiles: ["target": target], relationships: [])
        let desc = RelationshipCalculator.describe(from: "missing", to: "target", snapshot: snap)
        #expect(desc == nil)
    }

    @Test func missingToIDReturnsNil() {
        let me = makeProfile(id: "me")
        let snap = FamilyGraphSnapshot(profiles: ["me": me], relationships: [])
        let desc = RelationshipCalculator.describe(from: "me", to: "missing", snapshot: snap)
        #expect(desc == nil)
    }
}
