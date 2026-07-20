import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// TreeLayout must place a person's multiple spouses (remarriage / widowhood)
/// in SEPARATE columns, not stacked on one coordinate. Anchored to David Rose,
/// who married Margaret, then Jean after Margaret died — the two spouse cards
/// rendered on top of each other because every spouse got the same x.
@MainActor
struct TreeLayoutMultiSpouseTests {

    private func profile(_ id: String, _ given: String, _ surname: String, _ birthYear: Int) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: given, lastName: surname,
            gender: .unknown, attributes: nil,
            birthDate: GenealogicalDate(parsing: String(birthYear)),
            birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func spouseRel(_ a: String, _ b: String) -> Relationship {
        Relationship(id: UUID(), from: a, to: b, type: .spouse, role: nil,
                     subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    @Test func twoSpousesGetDistinctPositions() {
        let david = profile("david", "David", "Rose", 1950)
        let margaret = profile("margaret", "Margaret Helen", "Marshall", 1951)
        let jean = profile("jean", "Jean", "", 1935)
        let snapshot = FamilyGraphSnapshot(
            profiles: [david.id: david, margaret.id: margaret, jean.id: jean],
            relationships: [spouseRel("david", "margaret"), spouseRel("david", "jean")])

        let result = TreeLayout.pedigreeLayout(rootID: "david", snapshot: snapshot)
        let david0 = result.nodes.first { $0.id == "david" }
        let m = result.nodes.first { $0.id == "margaret" }
        let j = result.nodes.first { $0.id == "jean" }

        #expect(m != nil && j != nil, "both spouses must be laid out")
        // The bug: both got `node.x + width + spacing` → identical x → overlap.
        #expect(m!.x != j!.x, "two spouses must not share the same x (they overlapped)")
        // Both sit on the partner's row, to their right.
        #expect(m!.y == david0!.y && j!.y == david0!.y)
        #expect(m!.x > david0!.x && j!.x > david0!.x)
    }

    /// A single spouse still lands exactly where it always did (no regression).
    @Test func singleSpouseUnchanged() {
        let david = profile("david", "David", "Rose", 1950)
        let margaret = profile("margaret", "Margaret Helen", "Marshall", 1951)
        let snapshot = FamilyGraphSnapshot(
            profiles: [david.id: david, margaret.id: margaret],
            relationships: [spouseRel("david", "margaret")])

        let result = TreeLayout.pedigreeLayout(rootID: "david", snapshot: snapshot)
        let david0 = result.nodes.first { $0.id == "david" }!
        let m = result.nodes.first { $0.id == "margaret" }
        #expect(m != nil)
        #expect(m!.x > david0.x, "the one spouse still sits to the right")
    }
}
