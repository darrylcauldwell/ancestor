import Testing
import Foundation
@testable import Ancestor_Research

struct FamilyGraphSnapshotTests {

    private func makeProfile(
        id: String, firstName: String? = nil, lastName: String? = nil,
        birthDate: String? = nil, deathDate: String? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName, gender: .male,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: nil,
            deathDate: deathDate.map { GenealogicalDate(parsing: $0) },
            deathLocation: nil, bio: nil, sources: [:], disputes: [:]
        )
    }

    @Test func emptySnapshot() {
        let snap = FamilyGraphSnapshot.empty
        #expect(snap.profiles.isEmpty)
        #expect(snap.relationships.isEmpty)
    }

    @Test func parentsOf() {
        let parent = makeProfile(id: "p", firstName: "John")
        let child = makeProfile(id: "c", firstName: "James")
        let rel = Relationship(id: UUID(), from: "p", to: "c", type: .parent, role: .father, subtype: .biological, marriageDate: nil, divorceDate: nil)
        let snap = FamilyGraphSnapshot(profiles: ["p": parent, "c": child], relationships: [rel])
        #expect(snap.parentsOf("c").count == 1)
        #expect(snap.parentsOf("c").first?.id == "p")
        #expect(snap.childrenOf("p").count == 1)
    }

    @Test func siblingsDerivation() {
        let parent = makeProfile(id: "p")
        let child1 = makeProfile(id: "c1", firstName: "Alice")
        let child2 = makeProfile(id: "c2", firstName: "Bob")
        let r1 = Relationship(id: UUID(), from: "p", to: "c1", type: .parent, role: .father, subtype: .biological, marriageDate: nil, divorceDate: nil)
        let r2 = Relationship(id: UUID(), from: "p", to: "c2", type: .parent, role: .father, subtype: .biological, marriageDate: nil, divorceDate: nil)
        let snap = FamilyGraphSnapshot(profiles: ["p": parent, "c1": child1, "c2": child2], relationships: [r1, r2])
        let siblings = snap.siblingsOf("c1")
        #expect(siblings.count == 1)
        #expect(siblings.first?.id == "c2")
    }

    @Test func completenessLivingPerson() {
        // Born 1990, no death → potentially living → max 6
        let profile = makeProfile(id: "living", firstName: "Test", birthDate: "1990")
        let snap = FamilyGraphSnapshot(profiles: ["living": profile], relationships: [])
        let comp = snap.completeness(for: "living")
        #expect(comp.potentiallyLiving == true)
        #expect(comp.maximum == 6)
    }

    @Test func completenessDeadPerson() {
        // Born 1800, died 1870 → not living → max 7
        let profile = makeProfile(id: "dead", firstName: "Test", birthDate: "1800", deathDate: "1870")
        let snap = FamilyGraphSnapshot(profiles: ["dead": profile], relationships: [])
        let comp = snap.completeness(for: "dead")
        #expect(comp.potentiallyLiving == false)
        #expect(comp.maximum == 7)
    }

    @Test func completenessWithParents() {
        let parent = makeProfile(id: "p")
        let child = makeProfile(id: "c", firstName: "Test", birthDate: "1990")
        let rel = Relationship(id: UUID(), from: "p", to: "c", type: .parent, role: .father, subtype: .biological, marriageDate: nil, divorceDate: nil)
        let snap = FamilyGraphSnapshot(profiles: ["p": parent, "c": child], relationships: [rel])
        let comp = snap.completeness(for: "c")
        // Has firstName + birthDate + parents = 3. Missing: birthLocation, deathLocation, bio = 3 missing. Score = 3/6
        #expect(!comp.missing.contains(where: { if case .hasParents = $0 { return true }; return false }))
    }

    @Test func spousesOf() {
        let p1 = makeProfile(id: "h", firstName: "John")
        let p2 = makeProfile(id: "w", firstName: "Mary")
        let rel = Relationship(id: UUID(), from: "h", to: "w", type: .spouse, role: nil, subtype: .unknown, marriageDate: nil, divorceDate: nil)
        let snap = FamilyGraphSnapshot(profiles: ["h": p1, "w": p2], relationships: [rel])
        #expect(snap.spousesOf("h").count == 1)
        #expect(snap.spousesOf("w").count == 1)
    }

    @Test func ancestorsOf() {
        let gp = makeProfile(id: "gp")
        let p = makeProfile(id: "p")
        let c = makeProfile(id: "c")
        let r1 = Relationship(id: UUID(), from: "gp", to: "p", type: .parent, role: .father, subtype: .biological, marriageDate: nil, divorceDate: nil)
        let r2 = Relationship(id: UUID(), from: "p", to: "c", type: .parent, role: .father, subtype: .biological, marriageDate: nil, divorceDate: nil)
        let snap = FamilyGraphSnapshot(profiles: ["gp": gp, "p": p, "c": c], relationships: [r1, r2])
        let ancestors = snap.ancestorsOf("c", depth: 5)
        #expect(ancestors.count == 2)
    }
}
