import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// ENGINE_FOUNDATION_SPEC §Change7 — "stop digging here" expansion bound.
/// Verifies the deterministic gate on WHICH leads promote: generational
/// distance and collateral depth, the queryable reason, and per-project
/// override. Pure graph tests — no DB, no scorer.
struct ExpansionBoundsTests {

    // MARK: - Helpers

    private func profile(_ id: String) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: id, lastName: "X", gender: .male, attributes: nil,
            birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    /// parent → child edge (from = parent, to = child), matching app convention.
    private func parentEdge(_ parent: String, _ child: String) -> Relationship {
        Relationship(
            id: UUID(), from: parent, to: child, type: .parent, role: .father,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private func spouseEdge(_ a: String, _ b: String) -> Relationship {
        Relationship(
            id: UUID(), from: a, to: b, type: .spouse, role: nil,
            subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private func snapshot(ids: [String], rels: [Relationship]) -> FamilyGraphSnapshot {
        var profiles: [String: Profile] = [:]
        for id in ids { profiles[id] = profile(id) }
        return FamilyGraphSnapshot(profiles: profiles, relationships: rels)
    }

    // MARK: - Generational distance

    /// Direct 5-generation line from the seed. Generator distances from
    /// seed S: A=1, B=2, C=3, D=4, E=5. With generational:4 the promoted
    /// node = generator+1, so expansion halts at gen-4: a generator at D
    /// (which would create a gen-5 node) is refused; a generator at C
    /// (creating the gen-4 node) is allowed.
    @Test func generationalHaltsAtGenFour() {
        let ids = ["S", "A", "B", "C", "D", "E"]
        let rels = [
            parentEdge("S", "A"), parentEdge("A", "B"), parentEdge("B", "C"),
            parentEdge("C", "D"), parentEdge("D", "E"),
        ]
        let snap = snapshot(ids: ids, rels: rels)
        let bounds = ExpansionBounds(
            policy: .generationalDistance(generations: 4), snapshot: snap, seedIDs: ["S"]
        )

        // Generator C is at generational distance 3 → promoted node gen-4 → allowed.
        let onC = bounds.evaluate(generatorID: "C")
        #expect(onC.permitsPromotion)
        #expect(onC.code == "within_bounds")

        // Generator D is at distance 4 → promoted node gen-5 → refused.
        let onD = bounds.evaluate(generatorID: "D")
        #expect(!onD.permitsPromotion)
        #expect(onD.code == "outside_generational_bound")
        if case .outsideGenerationalBound(let limit, let measured) = onD {
            #expect(limit == 4)
            #expect(measured == 5)  // the would-be gen-5 node
        } else {
            Issue.record("expected outsideGenerationalBound, got \(onD)")
        }
    }

    /// Spouse edges are generation-preserving (cost 0): a spouse married
    /// into the tree shares their partner's generational distance.
    @Test func spouseSharesGeneration() {
        let ids = ["S", "A", "ASpouse"]
        let rels = [parentEdge("S", "A"), spouseEdge("A", "ASpouse")]
        let snap = snapshot(ids: ids, rels: rels)
        // A and A's spouse are both generational distance 1 from the seed,
        // so the promoted node off either is at distance 2. Probed through
        // the public evaluate() API: with generations:2 both are within
        // bounds; with generations:1 both fall outside at measured 2.
        let loose = ExpansionBounds(
            policy: .generationalDistance(generations: 2), snapshot: snap, seedIDs: ["S"]
        )
        #expect(loose.evaluate(generatorID: "A").permitsPromotion)
        #expect(loose.evaluate(generatorID: "ASpouse").permitsPromotion)

        let tight = ExpansionBounds(
            policy: .generationalDistance(generations: 1), snapshot: snap, seedIDs: ["S"]
        )
        if case .outsideGenerationalBound(_, let mA) = tight.evaluate(generatorID: "A") {
            #expect(mA == 2)
        } else { Issue.record("expected A out of bounds at measured 2") }
        if case .outsideGenerationalBound(_, let mSp) = tight.evaluate(generatorID: "ASpouse") {
            #expect(mSp == 2)  // spouse shares A's generation
        } else { Issue.record("expected ASpouse out of bounds at measured 2") }
    }

    // MARK: - Collateral depth

    /// Collateral policy: direct ancestors/descendants of the proband are
    /// depth 0; siblings (up then down = one turn) are depth 1; extending
    /// the branch further accrues depth. With collateral:2 (promoted =
    /// generator+1), a generator at collateral depth 2 is refused (halts
    /// at depth 2); a generator at depth 1 is allowed.
    @Test func collateralHaltsAtDepthTwo() {
        // P = proband. GP = P's parent. Sib = P's sibling (shares GP).
        // Sib's spouse SibSp — reaching SibSp is a spouse hop from Sib
        // (collateral depth of Sib + 1). SibSp's parent SibSpP — going up
        // after arriving .down via spouse is another turn.
        //   depth(GP)=0 (direct ancestor), depth(P)=0,
        //   depth(Sib)=1 (up to GP, down to Sib),
        //   depth(SibSp)=2 (spouse hop from Sib),
        //   depth(SibSpP)=3 (up-turn from SibSp).
        let ids = ["P", "GP", "Sib", "SibSp", "SibSpP"]
        let rels = [
            parentEdge("GP", "P"),
            parentEdge("GP", "Sib"),
            spouseEdge("Sib", "SibSp"),
            parentEdge("SibSpP", "SibSp"),
        ]
        let snap = snapshot(ids: ids, rels: rels)
        let bounds = ExpansionBounds(
            policy: .collateralDepth(hops: 2), snapshot: snap, seedIDs: ["P"]
        )

        // Generator GP is a direct ancestor (collateral depth 0) → promoted
        // node depth 1 → allowed.
        #expect(bounds.evaluate(generatorID: "GP").permitsPromotion)

        // Generator Sib (depth 1) → promoted node depth 2 → allowed.
        let onSib = bounds.evaluate(generatorID: "Sib")
        #expect(onSib.permitsPromotion)
        if case .withinBounds(_, let m) = onSib { #expect(m == 2) }

        // Generator SibSp (depth 2) → promoted node depth 3 → refused,
        // and the queryable reason names the collateral bound + measured
        // distance (this is the "why didn't this promote?" answer).
        let onSibSp = bounds.evaluate(generatorID: "SibSp")
        #expect(!onSibSp.permitsPromotion)
        #expect(onSibSp.code == "outside_collateral_bound")
        if case .outsideCollateralBound(let limit, let measured) = onSibSp {
            #expect(limit == 2)
            #expect(measured == 3)
        } else {
            Issue.record("expected outsideCollateralBound, got \(onSibSp)")
        }

        // SibSpP (depth 3) → promoted depth 4 → also refused.
        #expect(!bounds.evaluate(generatorID: "SibSpP").permitsPromotion)
    }

    /// Direct descendants of the proband stay at collateral depth 0 no
    /// matter how deep, so a deep-but-direct line is never collateral-bound
    /// (the generational policy is what bounds direct depth).
    @Test func directDescendantsAreDepthZero() {
        let ids = ["P", "C1", "C2", "C3"]
        let rels = [parentEdge("P", "C1"), parentEdge("C1", "C2"), parentEdge("C2", "C3")]
        let snap = snapshot(ids: ids, rels: rels)
        let bounds = ExpansionBounds(
            policy: .collateralDepth(hops: 2), snapshot: snap, seedIDs: ["P"]
        )
        #expect(bounds.nearestCollateralDepth(to: "C3") == 0)
        #expect(bounds.evaluate(generatorID: "C3").permitsPromotion)
    }

    // MARK: - Queryable reason + fail-open

    /// No seed configured → bound not applied (fail-open); promotion allowed.
    @Test func noSeedFailsOpen() {
        let snap = snapshot(ids: ["A", "B"], rels: [parentEdge("A", "B")])
        let bounds = ExpansionBounds(
            policy: .generationalDistance(generations: 1), snapshot: snap, seedIDs: []
        )
        let r = bounds.evaluate(generatorID: "B")
        #expect(r.permitsPromotion)
        #expect(r.code == "no_seed_configured")
    }

    /// A generator in a disconnected component is treated as out of bounds.
    @Test func unreachableGeneratorRefused() {
        // S---A is one component; Z is isolated.
        let ids = ["S", "A", "Z"]
        let rels = [parentEdge("S", "A")]
        let snap = snapshot(ids: ids, rels: rels)
        let bounds = ExpansionBounds(
            policy: .generationalDistance(generations: 4), snapshot: snap, seedIDs: ["S"]
        )
        let r = bounds.evaluate(generatorID: "Z")
        #expect(!r.permitsPromotion)
        #expect(r.code == "generator_unreachable")
    }

    // MARK: - Policy override / wire value

    @Test func policyWireRoundTrip() {
        #expect(ExpansionPolicy.generationalDistance(generations: 4).wireValue == "generational:4")
        #expect(ExpansionPolicy.collateralDepth(hops: 2).wireValue == "collateral:2")
        #expect(ExpansionPolicy(wireValue: "generational:6") == .generationalDistance(generations: 6))
        #expect(ExpansionPolicy(wireValue: "collateral:3") == .collateralDepth(hops: 3))
        #expect(ExpansionPolicy(wireValue: "  Collateral:1 ") == .collateralDepth(hops: 1))
        #expect(ExpansionPolicy(wireValue: "nonsense") == nil)
        #expect(ExpansionPolicy(wireValue: "") == nil)
    }

    /// A project override changes where the walk halts. With collateral:1
    /// even a first sibling's branch (generator depth 1 → promoted depth 2)
    /// is refused; the default generational:4 would have allowed it.
    @Test func overrideChangesBound() {
        let ids = ["P", "GP", "Sib"]
        let rels = [parentEdge("GP", "P"), parentEdge("GP", "Sib")]
        let snap = snapshot(ids: ids, rels: rels)

        let tight = ExpansionBounds(policy: .collateralDepth(hops: 1), snapshot: snap, seedIDs: ["P"])
        #expect(!tight.evaluate(generatorID: "Sib").permitsPromotion)

        let loose = ExpansionBounds(policy: .generationalDistance(generations: 4), snapshot: snap, seedIDs: ["P"])
        #expect(loose.evaluate(generatorID: "Sib").permitsPromotion)
    }

    @Test func effectivePolicyUsesDefaultWhenUnset() {
        var project = Project(
            id: UUID(), name: "T", source: .manual, createdAt: Date()
        )
        #expect(project.effectiveExpansionPolicy == ExpansionPolicy.default)
        #expect(project.effectiveExpansionPolicy == .generationalDistance(generations: 4))

        project.expansionPolicy = .collateralDepth(hops: 2)
        #expect(project.effectiveExpansionPolicy == .collateralDepth(hops: 2))
    }
}
