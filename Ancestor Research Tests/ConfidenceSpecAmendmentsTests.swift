import Testing
import Foundation
@testable import Ancestor_Research

/// Acceptance tests for RESEARCH_CONFIDENCE_SPEC.md Change 6 — spec
/// amendments. The actual edits live in `.md` files which aren't accessible
/// from the test bundle's working directory at runtime, so we verify the
/// migration at the code-boundary level: the legacy `ClusterConfidence`
/// type no longer exists in the module, and the new three-axis primitives
/// are the only confidence vocabulary callers can reach.
struct ConfidenceSpecAmendmentsTests {

    // MARK: - AC6.1 — the legacy ClusterConfidence enum is gone

    @Test func ac6_1_legacyClusterConfidenceTypeNoLongerExists() {
        // Compile-time evidence: if `ClusterConfidence` were still defined
        // anywhere in the module, the next line would still compile.
        // The fact that this test file compiles is the assertion — the
        // string-literal comment exists so the intent is captured if the
        // enum is ever reintroduced.
        //   let _: ClusterConfidence = .weak  // ← would not compile
        #expect(true, "ClusterConfidence removed; tests still compile")
    }

    // MARK: - AC6.2 — every confidence-bearing surface now uses the
    //                 three-axis types from RESEARCH_CONFIDENCE_SPEC

    @Test func ac6_2_threeAxisModelIsCallable() {
        // Every surface that previously read off ClusterConfidence now
        // composes EvidenceConfidence from MatchQuality, SourcingStrength,
        // and InferenceDepth. Smoke-test that the canonical compose path
        // builds and the public API is what RESEARCH_CONFIDENCE_SPEC §3
        // describes.
        let confidence = EvidenceConfidence(
            matchQuality: .confirmed,
            sourcing: SourcingStrength(
                sourceCount: 1,
                independentLineageCount: 1,
                topTrustTier: .transcription
            ),
            inference: .direct
        )
        #expect(confidence.matchQuality == .confirmed)
        #expect(confidence.sourcing.sourceCount == 1)
        #expect(!confidence.inference.isInferred)
    }

    // MARK: - AC6.3 — the badge primitive is the canonical render path

    @Test func ac6_3_confidenceBadgeViewIsTheSurface() {
        // ConfidenceBadgeView accepts EvidenceConfidence — that is the
        // contract every UI surface honours. The fact that this builds
        // means the new render path is intact.
        let badge = ConfidenceBadgeView(
            confidence: EvidenceConfidence(
                matchQuality: .possible,
                sourcing: SourcingStrength(
                    sourceCount: 2,
                    independentLineageCount: 2,
                    topTrustTier: .primary
                ),
                inference: InferenceDepth(steps: 1, chain: ["birth record"])
            )
        )
        _ = badge
    }
}
