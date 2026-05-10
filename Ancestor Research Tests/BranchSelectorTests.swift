import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for `BranchSelector` — pure ancestor/descendant traversal helper
/// powering the M17.6 "Remove person and ancestors/descendants" affordance.
struct BranchSelectorTests {

    private func makeProfile(_ id: String) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: id, lastName: nil, gender: nil,
            attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false,
            sources: [:], disputes: [:]
        )
    }

    private func parentEdge(_ from: String, _ to: String) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: .unspecified, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    @Test func ancestorsWalkOnlyParentEdges() {
        // gp -> p -> c, with sibling s also a child of p.
        // ancestors(c) must NOT include s (sibling) or any descendant.
        let snap = FamilyGraphSnapshot(
            profiles: [
                "gp": makeProfile("gp"),
                "p": makeProfile("p"),
                "c": makeProfile("c"),
                "s": makeProfile("s")
            ],
            relationships: [
                parentEdge("gp", "p"),
                parentEdge("p", "c"),
                parentEdge("p", "s")
            ]
        )

        let ancestors = BranchSelector.ancestorsOf("c", in: snap)
        #expect(ancestors.contains("c"))
        #expect(ancestors.contains("p"))
        #expect(ancestors.contains("gp"))
        #expect(!ancestors.contains("s"))
        #expect(ancestors.count == 3)
    }

    @Test func descendantsWalkOnlyChildEdges() {
        // gp -> p -> c. descendants(p) must include p, c — but never gp.
        let snap = FamilyGraphSnapshot(
            profiles: [
                "gp": makeProfile("gp"),
                "p": makeProfile("p"),
                "c": makeProfile("c")
            ],
            relationships: [
                parentEdge("gp", "p"),
                parentEdge("p", "c")
            ]
        )

        let descendants = BranchSelector.descendantsOf("p", in: snap)
        #expect(descendants.contains("p"))
        #expect(descendants.contains("c"))
        #expect(!descendants.contains("gp"))
        #expect(descendants.count == 2)
    }

    @Test func branchIncludesRootProfile() {
        // Lone profile, no edges. Both directions should yield {root}.
        let snap = FamilyGraphSnapshot(
            profiles: ["only": makeProfile("only")],
            relationships: []
        )

        #expect(BranchSelector.ancestorsOf("only", in: snap) == ["only"])
        #expect(BranchSelector.descendantsOf("only", in: snap) == ["only"])
    }

    @Test func siblingOfTargetIsExcluded() {
        // p -> c1, p -> c2. Removing c1's branch (descendants) must not
        // sweep c2 into the set — siblings live in their own subtrees.
        let snap = FamilyGraphSnapshot(
            profiles: [
                "p": makeProfile("p"),
                "c1": makeProfile("c1"),
                "c2": makeProfile("c2")
            ],
            relationships: [
                parentEdge("p", "c1"),
                parentEdge("p", "c2")
            ]
        )

        let descendantsOfC1 = BranchSelector.descendantsOf("c1", in: snap)
        #expect(descendantsOfC1 == ["c1"])
        #expect(!descendantsOfC1.contains("c2"))
    }

    @Test func cyclicTreeDoesNotInfiniteLoop() {
        // Genealogically impossible, but defend against bad data: a -> b -> a.
        // The walk must terminate and visit each node at most once.
        let snap = FamilyGraphSnapshot(
            profiles: [
                "a": makeProfile("a"),
                "b": makeProfile("b")
            ],
            relationships: [
                parentEdge("a", "b"),
                parentEdge("b", "a")
            ]
        )

        let ancestors = BranchSelector.ancestorsOf("a", in: snap)
        #expect(ancestors == ["a", "b"])

        let descendants = BranchSelector.descendantsOf("a", in: snap)
        #expect(descendants == ["a", "b"])
    }
}
