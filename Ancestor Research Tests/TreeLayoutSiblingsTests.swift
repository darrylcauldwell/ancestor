import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the sibling-row addition in `TreeLayout.pedigreeLayout`.
/// Anchored to a user-observed bug — focusing on a profile in
/// pedigree mode hid the subject's siblings, contradicting the
/// natural "show me the family group" expectation.
@MainActor
struct TreeLayoutSiblingsTests {

    // MARK: - Helpers

    private func profile(
        id: String, given: String, surname: String, birthYear: Int? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: given, lastName: surname,
            gender: .male, attributes: nil,
            birthDate: birthYear.map { GenealogicalDate(parsing: String($0)) },
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func parentRel(_ from: String, _ to: String, _ role: ParentRole) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: role, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    /// Lilian + George + Hilda all children of Land + Brooks.
    private func threeSiblingsSnapshot() -> FamilyGraphSnapshot {
        let land = profile(id: "land", given: "", surname: "Land", birthYear: 1882)
        let brooks = profile(id: "brooks", given: "", surname: "Brooks", birthYear: 1882)
        let lilian = profile(id: "lilian", given: "Lilian Mary", surname: "Brooks", birthYear: 1914)
        let george = profile(id: "george", given: "George", surname: "Brooks", birthYear: 1916)
        let hilda = profile(id: "hilda", given: "Hilda", surname: "Brooks", birthYear: 1912)

        let rels: [Relationship] = [
            parentRel("land", "lilian", .father),
            parentRel("brooks", "lilian", .mother),
            parentRel("land", "george", .father),
            parentRel("brooks", "george", .mother),
            parentRel("land", "hilda", .father),
            parentRel("brooks", "hilda", .mother),
        ]

        return FamilyGraphSnapshot(
            profiles: Dictionary(uniqueKeysWithValues: [land, brooks, lilian, george, hilda].map { ($0.id, $0) }),
            relationships: rels
        )
    }

    // MARK: - Tests

    @Test func siblingsAppearAtSameGenerationAsSubject() {
        let snapshot = threeSiblingsSnapshot()
        let result = TreeLayout.pedigreeLayout(rootID: "lilian", snapshot: snapshot)

        let subject = result.nodes.first { $0.id == "lilian" }
        let george = result.nodes.first { $0.id == "george" }
        let hilda = result.nodes.first { $0.id == "hilda" }

        #expect(subject != nil, "Subject Lilian must be in the layout")
        #expect(george != nil, "Sibling George must appear in the layout — was hidden before this fix")
        #expect(hilda != nil, "Sibling Hilda must appear in the layout")

        #expect(george?.generation == 0, "Siblings render at generation 0 next to subject")
        #expect(hilda?.generation == 0)
        #expect(george?.y == subject?.y, "Siblings share the subject's y coordinate")
    }

    @Test func siblingsConnectToBothParentsByEdge() {
        let snapshot = threeSiblingsSnapshot()
        let result = TreeLayout.pedigreeLayout(rootID: "lilian", snapshot: snapshot)

        // Each sibling should have an edge from each of Lilian's parents.
        let edgeKeys = Set(result.edges.map { "\($0.fromID)->\($0.toID)" })
        #expect(edgeKeys.contains("land->george"))
        #expect(edgeKeys.contains("brooks->george"))
        #expect(edgeKeys.contains("land->hilda"))
        #expect(edgeKeys.contains("brooks->hilda"))
    }

    @Test func siblingsPlacedToRightOfSubject() {
        let snapshot = threeSiblingsSnapshot()
        let result = TreeLayout.pedigreeLayout(rootID: "lilian", snapshot: snapshot)

        let subject = result.nodes.first { $0.id == "lilian" }!
        let siblings = result.nodes.filter { ["george", "hilda"].contains($0.id) }
        for sib in siblings {
            #expect(sib.x > subject.x, "\(sib.id) should sit right of subject (x: \(sib.x) vs subject \(subject.x))")
        }
    }

    @Test func noSiblingsDoesNotPerturbLayout() {
        // Single-child subject — no siblings should be added.
        let land = profile(id: "land", given: "", surname: "Land")
        let brooks = profile(id: "brooks", given: "", surname: "Brooks")
        let lilian = profile(id: "lilian", given: "Lilian", surname: "Brooks", birthYear: 1914)
        let snapshot = FamilyGraphSnapshot(
            profiles: Dictionary(uniqueKeysWithValues: [land, brooks, lilian].map { ($0.id, $0) }),
            relationships: [
                parentRel("land", "lilian", .father),
                parentRel("brooks", "lilian", .mother),
            ]
        )
        let result = TreeLayout.pedigreeLayout(rootID: "lilian", snapshot: snapshot)
        let gen0 = result.nodes.filter { $0.generation == 0 }
        #expect(gen0.count == 1, "Only Lilian should be at generation 0 — no spurious sibling additions")
    }

    @Test func siblingsSortedByBirthYearAscending() {
        // Hilda (1912) → George (1916) → Lilian-as-subject sits at the
        // anchor; siblings should be placed in birth order (oldest first).
        let snapshot = threeSiblingsSnapshot()
        let result = TreeLayout.pedigreeLayout(rootID: "lilian", snapshot: snapshot)
        let siblings = result.nodes
            .filter { ["george", "hilda"].contains($0.id) }
            .sorted { $0.x < $1.x }
        #expect(siblings.map(\.id) == ["hilda", "george"],
                "Hilda (1912) should sort before George (1916)")
    }
}
