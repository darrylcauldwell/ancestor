import Testing
import Foundation
@testable import Ancestor_Research

struct DiffEngineTests {

    private func makeProfile(
        id: String, firstName: String? = nil, lastName: String? = nil,
        birthDate: String? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName, gender: .male,
            attributes: nil,
            birthDate: birthDate.map { GenealogicalDate(parsing: $0) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    @Test func noDifferences() {
        let p = makeProfile(id: "a", firstName: "John")
        let snap = FamilyGraphSnapshot(profiles: ["a": p], relationships: [])
        let diff = DiffEngine.diff(old: snap, new: snap)
        #expect(diff.isEmpty)
    }

    @Test func detectsAddedProfile() {
        let old = FamilyGraphSnapshot(profiles: [:], relationships: [])
        let p = makeProfile(id: "a", firstName: "John")
        let new = FamilyGraphSnapshot(profiles: ["a": p], relationships: [])
        let diff = DiffEngine.diff(old: old, new: new)
        #expect(diff.added.count == 1)
        #expect(diff.added.first?.id == "a")
    }

    @Test func detectsRemovedProfile() {
        let p = makeProfile(id: "a", firstName: "John")
        let old = FamilyGraphSnapshot(profiles: ["a": p], relationships: [])
        let new = FamilyGraphSnapshot(profiles: [:], relationships: [])
        let diff = DiffEngine.diff(old: old, new: new)
        #expect(diff.removed.count == 1)
    }

    @Test func detectsModifiedField() {
        let old = makeProfile(id: "a", firstName: "John", birthDate: "1880")
        let new = makeProfile(id: "a", firstName: "John", birthDate: "1882")
        let oldSnap = FamilyGraphSnapshot(profiles: ["a": old], relationships: [])
        let newSnap = FamilyGraphSnapshot(profiles: ["a": new], relationships: [])
        let diff = DiffEngine.diff(old: oldSnap, new: newSnap)
        #expect(diff.modified.count == 1)
        #expect(diff.modified.first?.fieldChanges.first?.field == .birthDate)
    }

    @Test func detectsAddedRelationship() {
        let p1 = makeProfile(id: "p")
        let p2 = makeProfile(id: "c")
        let old = FamilyGraphSnapshot(profiles: ["p": p1, "c": p2], relationships: [])
        let rel = Relationship(id: UUID(), from: "p", to: "c", type: .parent, role: .father, subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
        let new = FamilyGraphSnapshot(profiles: ["p": p1, "c": p2], relationships: [rel])
        let diff = DiffEngine.diff(old: old, new: new)
        #expect(diff.relationshipsAdded.count == 1)
    }

    @Test func refreshIdempotence() {
        // Same data twice → no changes
        let p = makeProfile(id: "a", firstName: "John", birthDate: "1880")
        let snap = FamilyGraphSnapshot(profiles: ["a": p], relationships: [])
        let diff = DiffEngine.diff(old: snap, new: snap)
        #expect(diff.isEmpty)
        #expect(diff.changeCount == 0)
    }
}
