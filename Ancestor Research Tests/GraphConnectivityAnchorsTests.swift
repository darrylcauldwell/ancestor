import Testing
import Foundation
@testable import Ancestor_Research

/// M16.12 — tests for `GraphConnectivity.suggestConnectionAnchors`, the
/// helper behind the DisconnectedBanner's "Connect them?" button.
struct GraphConnectivityAnchorsTests {

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

    @Test func suggestConnectionAnchorsLeadsWithTheOrphan() {
        // Owner design 2026-07-15: the connect flow anchors on the ORPHAN
        // (smallest component — the person just added and lost), with a
        // main-tree member as the reference. Three components: {p1,p2,p3}
        // (size 3), {p4,p5} (size 2), {p6} (the orphan).
        let profiles = ["p1", "p2", "p3", "p4", "p5", "p6"].map(makeProfile)
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let rels = [
            parentEdge("p1", "p2"),
            parentEdge("p2", "p3"),
            parentEdge("p4", "p5"),
        ]
        let snapshot = FamilyGraphSnapshot(profiles: dict, relationships: rels)

        let anchors = GraphConnectivity.suggestConnectionAnchors(snapshot: snapshot)
        #expect(anchors != nil)
        guard let (orphan, mainMember) = anchors else { return }

        #expect(orphan == "p6", "anchor must be the smallest component's member; got \(orphan)")
        #expect(["p1", "p2", "p3"].contains(mainMember),
                "reference must come from the largest component; got \(mainMember)")
    }

    @Test func suggestConnectionAnchorsReturnsNilWhenSingleComponent() {
        let profiles = ["p1", "p2", "p3"].map(makeProfile)
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let rels = [
            parentEdge("p1", "p2"),
            parentEdge("p2", "p3"),
        ]
        let snapshot = FamilyGraphSnapshot(profiles: dict, relationships: rels)

        let anchors = GraphConnectivity.suggestConnectionAnchors(snapshot: snapshot)
        #expect(anchors == nil)
    }

    @Test func suggestConnectionAnchorsReturnsNilForEmptyTree() {
        let snapshot = FamilyGraphSnapshot(profiles: [:], relationships: [])
        #expect(GraphConnectivity.suggestConnectionAnchors(snapshot: snapshot) == nil)
    }

    @Test func suggestConnectionAnchorsHandlesTwoSingletons() {
        // Two completely isolated profiles — each forms its own component
        // of size 1. Should still return a pair so the user can connect them.
        let profiles = ["p1", "p2"].map(makeProfile)
        let dict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let snapshot = FamilyGraphSnapshot(profiles: dict, relationships: [])

        let anchors = GraphConnectivity.suggestConnectionAnchors(snapshot: snapshot)
        #expect(anchors != nil)
        guard let (a, b) = anchors else { return }
        #expect(a != b)
        #expect(["p1", "p2"].contains(a))
        #expect(["p1", "p2"].contains(b))
    }
}
