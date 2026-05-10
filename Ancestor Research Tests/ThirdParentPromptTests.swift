import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the M17.7 third-parent disambiguation helper.
/// `FamilyGraphSnapshot.parentCount(for:)` drives the conditional visibility
/// of the "What's the relationship?" prompt in `AddRelationshipView`.
struct ThirdParentPromptTests {

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

    private func parentEdge(_ from: String, _ to: String, subtype: RelationshipSubtype = .biological) -> Relationship {
        Relationship(
            id: UUID(), from: from, to: to,
            type: .parent, role: .unspecified, subtype: subtype,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    @Test func parentCountReturnsZeroForNewProfile() {
        // A fresh profile with no edges should report zero parents — the
        // prompt must stay hidden in this state.
        let snap = FamilyGraphSnapshot(
            profiles: ["x": makeProfile("x")],
            relationships: []
        )
        #expect(snap.parentCount(for: "x") == 0)
    }

    @Test func parentCountReturnsTwoWhenTwoParentEdgesExist() {
        // Standard biological parents. parentCount == 2 — adding any further
        // parent triggers the prompt.
        let snap = FamilyGraphSnapshot(
            profiles: [
                "child": makeProfile("child"),
                "father": makeProfile("father"),
                "mother": makeProfile("mother")
            ],
            relationships: [
                parentEdge("father", "child"),
                parentEdge("mother", "child")
            ]
        )
        #expect(snap.parentCount(for: "child") == 2)
    }

    @Test func parentCountReturnsThreeAfterStepparentAdded() {
        // Father, mother, plus a step edge — exactly the post-stepparent
        // scenario from M17.1. parentCount == 3 means the prompt should
        // already have been shown for the third edge addition; confirms
        // the count is the correct discriminator (>= 2 surfaces the prompt).
        let snap = FamilyGraphSnapshot(
            profiles: [
                "child": makeProfile("child"),
                "father": makeProfile("father"),
                "mother": makeProfile("mother"),
                "step": makeProfile("step")
            ],
            relationships: [
                parentEdge("father", "child"),
                parentEdge("mother", "child"),
                parentEdge("step", "child", subtype: .step)
            ]
        )
        #expect(snap.parentCount(for: "child") == 3)
    }
}
