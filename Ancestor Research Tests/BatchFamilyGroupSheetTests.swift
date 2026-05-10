import Testing
import Foundation
@testable import Ancestor_Research

/// Batch Family Group Sheet export — DESIGN.md §7.9.3.
///
/// Covers `FamilyGroupSheetReport.enumerateFamilies(snapshot:)` and the
/// multi-page `renderAllFamiliesPDF(...)` integration:
///   - couple-with-children → one family
///   - two unconnected couples → two families
///   - couple plus orphan profile → two families (orphan as singleton)
///   - duplicated spouse edges (A→B and B→A) collapse to one family
///   - integration: full snapshot renders to non-nil multi-page PDF
///   - empty snapshot returns nil
@MainActor
struct BatchFamilyGroupSheetTests {

    // MARK: - Helpers

    private func makeProfile(
        id: String,
        firstName: String? = nil,
        lastName: String? = nil,
        gender: Gender? = .unknown,
        birthYear: Int? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName,
            gender: gender, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: "\($0)") },
            birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    private func parentRel(from: String, to: String) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: nil, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private func spouseRel(_ a: String, _ b: String) -> Relationship {
        Relationship(
            id: UUID(), from: a, to: b,
            type: .spouse, role: nil, subtype: .unknown,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    // MARK: - Enumeration

    @Test func oneCoupleWithTwoChildren_yieldsOneFamily() {
        let h = makeProfile(id: "h", firstName: "John", lastName: "Smith", gender: .male)
        let w = makeProfile(id: "w", firstName: "Mary", lastName: "Jones", gender: .female)
        let c1 = makeProfile(id: "c1", firstName: "Alice", gender: .female, birthYear: 1860)
        let c2 = makeProfile(id: "c2", firstName: "Bob", gender: .male, birthYear: 1858)

        let snap = FamilyGraphSnapshot(
            profiles: ["h": h, "w": w, "c1": c1, "c2": c2],
            relationships: [
                spouseRel("h", "w"),
                parentRel(from: "h", to: "c1"),
                parentRel(from: "w", to: "c1"),
                parentRel(from: "h", to: "c2"),
                parentRel(from: "w", to: "c2")
            ]
        )

        let units = FamilyGroupSheetReport.enumerateFamilies(snapshot: snap)
        #expect(units.count == 1)
        #expect(units.first?.father?.id == "h")
        #expect(units.first?.mother?.id == "w")
        #expect(Set((units.first?.children ?? []).map(\.id)) == ["c1", "c2"])
    }

    @Test func twoUnconnectedCouples_yieldsTwoFamilies() {
        let h1 = makeProfile(id: "h1", firstName: "John", lastName: "Smith", gender: .male)
        let w1 = makeProfile(id: "w1", firstName: "Mary", lastName: "Jones", gender: .female)
        let h2 = makeProfile(id: "h2", firstName: "Tom", lastName: "Brown", gender: .male)
        let w2 = makeProfile(id: "w2", firstName: "Jane", lastName: "Green", gender: .female)

        let snap = FamilyGraphSnapshot(
            profiles: ["h1": h1, "w1": w1, "h2": h2, "w2": w2],
            relationships: [
                spouseRel("h1", "w1"),
                spouseRel("h2", "w2")
            ]
        )

        let units = FamilyGroupSheetReport.enumerateFamilies(snapshot: snap)
        #expect(units.count == 2)
        let fatherIDs = Set(units.compactMap(\.father?.id))
        #expect(fatherIDs == ["h1", "h2"])
    }

    @Test func coupleAndOrphanProfile_yieldsTwoFamilies() {
        let h = makeProfile(id: "h", firstName: "John", lastName: "Smith", gender: .male)
        let w = makeProfile(id: "w", firstName: "Mary", lastName: "Jones", gender: .female)
        let lone = makeProfile(id: "lone", firstName: "Solo", lastName: "Person", gender: .male)

        let snap = FamilyGraphSnapshot(
            profiles: ["h": h, "w": w, "lone": lone],
            relationships: [spouseRel("h", "w")]
        )

        let units = FamilyGroupSheetReport.enumerateFamilies(snapshot: snap)
        #expect(units.count == 2)
        // The couple and the singleton — both surface with this father id set.
        let fatherIDs = Set(units.compactMap(\.father?.id))
        #expect(fatherIDs == ["h", "lone"])
        // Singleton has no marriage and no children.
        let singleton = units.first { $0.father?.id == "lone" }
        #expect(singleton?.mother == nil)
        #expect(singleton?.children.isEmpty == true)
        #expect(singleton?.marriage == nil)
    }

    @Test func duplicatedSpouseEdges_collapseToOneFamily() {
        // Same couple listed twice with reversed direction. Defensive against
        // historical tree imports where both directions are stored.
        let h = makeProfile(id: "h", firstName: "John", lastName: "Smith", gender: .male)
        let w = makeProfile(id: "w", firstName: "Mary", lastName: "Jones", gender: .female)

        let snap = FamilyGraphSnapshot(
            profiles: ["h": h, "w": w],
            relationships: [
                spouseRel("h", "w"),
                spouseRel("w", "h")  // reversed duplicate
            ]
        )

        let units = FamilyGroupSheetReport.enumerateFamilies(snapshot: snap)
        #expect(units.count == 1)
        #expect(units.first?.father?.id == "h")
        #expect(units.first?.mother?.id == "w")
    }

    @Test func singleParentWithChildren_yieldsOneSingleParentFamily() {
        // Parent with a child but no spouse — should produce one family
        // (the single-parent unit) regardless of the child not being a
        // separate family on its own.
        let mom = makeProfile(id: "m", firstName: "Sarah", gender: .female)
        let kid = makeProfile(id: "k", firstName: "Tom", gender: .male, birthYear: 1840)

        let snap = FamilyGraphSnapshot(
            profiles: ["m": mom, "k": kid],
            relationships: [parentRel(from: "m", to: "k")]
        )

        let units = FamilyGroupSheetReport.enumerateFamilies(snapshot: snap)
        #expect(units.count == 1)
        #expect(units.first?.mother?.id == "m")
        #expect(units.first?.father == nil)
        #expect(units.first?.children.map(\.id) == ["k"])
    }

    // MARK: - Render integration

    @Test func renderAllFamiliesPDF_returnsNonNilDataForRealisticSnapshot() {
        let h = makeProfile(id: "h", firstName: "John", lastName: "Smith", gender: .male, birthYear: 1830)
        let w = makeProfile(id: "w", firstName: "Mary", lastName: "Jones", gender: .female, birthYear: 1832)
        let c = makeProfile(id: "c", firstName: "Alice", gender: .female, birthYear: 1860)
        let lone = makeProfile(id: "lone", firstName: "Solo", lastName: "Person", gender: .male)

        let snap = FamilyGraphSnapshot(
            profiles: ["h": h, "w": w, "c": c, "lone": lone],
            relationships: [
                spouseRel("h", "w"),
                parentRel(from: "h", to: "c"),
                parentRel(from: "w", to: "c")
            ]
        )

        let data = FamilyGroupSheetReport.renderAllFamiliesPDF(
            paperSize: .a4,
            snapshot: snap,
            notes: []
        )
        #expect(data != nil)
        #expect((data?.count ?? 0) > 0)
    }

    /// Empty snapshot has no families to enumerate; renderer returns nil
    /// (documented contract — caller surfaces this as "No families to export").
    @Test func renderAllFamiliesPDF_emptySnapshotReturnsNil() {
        let snap = FamilyGraphSnapshot.empty
        let data = FamilyGroupSheetReport.renderAllFamiliesPDF(
            paperSize: .a4,
            snapshot: snap,
            notes: []
        )
        #expect(data == nil)
    }

    @Test func enumerateFamilies_emptySnapshotReturnsEmpty() {
        let units = FamilyGroupSheetReport.enumerateFamilies(snapshot: .empty)
        #expect(units.isEmpty)
    }
}
