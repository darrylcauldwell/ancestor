import Testing
import Foundation
@testable import FieldResearcherMCP

/// Unit tests for the expansion-bound decision helper used by
/// `promote_lead` (ENGINE_FOUNDATION_SPEC #Change7). Cover the pure
/// graph-distance logic only; the SQL fetch that gathers edges + seeds is
/// a thin wrapper exercised by the running server. Mirrors AncestorKit's
/// `ExpansionBoundsTests` so both sides of the (deliberately duplicated)
/// rule stay in lockstep.
struct PromoteLeadExpansionBoundTests {

    private func parent(_ p: String, _ c: String) -> MCPHandler.GraphEdge {
        MCPHandler.GraphEdge(from: p, to: c, type: "parent")
    }
    private func spouse(_ a: String, _ b: String) -> MCPHandler.GraphEdge {
        MCPHandler.GraphEdge(from: a, to: b, type: "spouse")
    }

    // MARK: - Policy parsing / override

    @Test func policyParse() {
        #expect(MCPHandler.ExpansionPolicy.parse("generational:4") == .generationalDistance(generations: 4))
        #expect(MCPHandler.ExpansionPolicy.parse("collateral:2") == .collateralDepth(hops: 2))
        #expect(MCPHandler.ExpansionPolicy.parse("  Collateral:1 ") == .collateralDepth(hops: 1))
        // nil / garbage → engine default.
        #expect(MCPHandler.ExpansionPolicy.parse(nil) == .generationalDistance(generations: 4))
        #expect(MCPHandler.ExpansionPolicy.parse("nonsense") == .generationalDistance(generations: 4))
    }

    // MARK: - Generational

    @Test func generationalHaltsAtGenFour() {
        let edges = [
            parent("S", "A"), parent("A", "B"), parent("B", "C"),
            parent("C", "D"), parent("D", "E"),
        ]
        // Generator C (dist 3) → promoted gen-4 → allowed.
        let onC = MCPHandler.decideExpansionBound(
            policy: .generationalDistance(generations: 4),
            edges: edges, seedIDs: ["S"], generatorID: "C"
        )
        #expect(onC.permitsPromotion)
        #expect(onC.code == "within_bounds")

        // Generator D (dist 4) → promoted gen-5 → refused.
        let onD = MCPHandler.decideExpansionBound(
            policy: .generationalDistance(generations: 4),
            edges: edges, seedIDs: ["S"], generatorID: "D"
        )
        #expect(!onD.permitsPromotion)
        #expect(onD.code == "outside_generational_bound")
        #expect(onD == .outsideGenerationalBound(limit: 4, measuredDistance: 5))
    }

    // MARK: - Collateral

    @Test func collateralHaltsAtDepthTwo() {
        let edges = [
            parent("GP", "P"), parent("GP", "Sib"),
            spouse("Sib", "SibSp"), parent("SibSpP", "SibSp"),
        ]
        // Sib (depth 1) → promoted depth 2 → allowed.
        let onSib = MCPHandler.decideExpansionBound(
            policy: .collateralDepth(hops: 2),
            edges: edges, seedIDs: ["P"], generatorID: "Sib"
        )
        #expect(onSib.permitsPromotion)

        // SibSp (depth 2) → promoted depth 3 → refused.
        let onSibSp = MCPHandler.decideExpansionBound(
            policy: .collateralDepth(hops: 2),
            edges: edges, seedIDs: ["P"], generatorID: "SibSp"
        )
        #expect(!onSibSp.permitsPromotion)
        #expect(onSibSp == .outsideCollateralBound(limit: 2, measuredDistance: 3))
    }

    // MARK: - Fail-open + unreachable

    @Test func noSeedFailsOpen() {
        let edges = [parent("A", "B")]
        let r = MCPHandler.decideExpansionBound(
            policy: .generationalDistance(generations: 1),
            edges: edges, seedIDs: [], generatorID: "B"
        )
        #expect(r.permitsPromotion)
        #expect(r.code == "no_seed_configured")
    }

    @Test func unreachableGeneratorRefused() {
        let edges = [parent("S", "A")]  // Z isolated
        let r = MCPHandler.decideExpansionBound(
            policy: .generationalDistance(generations: 4),
            edges: edges, seedIDs: ["S"], generatorID: "Z"
        )
        #expect(!r.permitsPromotion)
        #expect(r.code == "generator_unreachable")
    }

    @Test func emptyGeneratorFailsOpen() {
        let edges = [parent("S", "A")]
        let r = MCPHandler.decideExpansionBound(
            policy: .generationalDistance(generations: 4),
            edges: edges, seedIDs: ["S"], generatorID: ""
        )
        #expect(r.permitsPromotion)
        #expect(r.code == "no_seed_configured")
    }
}
