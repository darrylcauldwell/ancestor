import Testing
import Foundation
@testable import Ancestor_Research

/// Acceptance tests for RESEARCH_CONFIDENCE_SPEC.md Change 1 — confidence
/// model types. Purely additive; no behaviour change to existing code.
struct EvidenceConfidenceTests {

    // MARK: - AC1.1 — types compile + Sendable + Codable + doc comments

    @Test func ac1_1_typesAreSendableAndCodable() throws {
        // Compile-time evidence: these initialisers wouldn't type-check if
        // the conformances were missing. Runtime evidence: round-trip a value
        // through JSONEncoder / Decoder to confirm Codable wiring.
        let value = EvidenceConfidence(
            matchQuality: .confirmed,
            sourcing: SourcingStrength(sourceCount: 3,
                                       independentLineageCount: 2,
                                       topTrustTier: .primary),
            inference: InferenceDepth(steps: 1, chain: ["FreeBMD birth record"])
        )
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(EvidenceConfidence.self, from: data)
        #expect(decoded == value)
    }

    @Test func ac1_1_matchQualityHasThreeCases() {
        #expect(MatchQuality.allCases.count == 3)
        #expect(Set(MatchQuality.allCases) == [.confirmed, .possible, .wrong])
    }

    // MARK: - AC1.2 — RecordVerdict → MatchQuality mapping

    @Test func ac1_2_recordVerdictMapsToMatchQuality() {
        #expect(RecordVerdict.fact.matchQuality == .confirmed)
        #expect(RecordVerdict.lead.matchQuality == .possible)
        #expect(RecordVerdict.impossible.matchQuality == .wrong)
    }

    @Test func ac1_2_matchQualityBestAggregation() {
        #expect(MatchQuality.best(of: [.confirmed, .possible, .wrong]) == .confirmed)
        #expect(MatchQuality.best(of: [.possible, .wrong]) == .possible)
        #expect(MatchQuality.best(of: [.wrong, .wrong]) == .wrong)
        #expect(MatchQuality.best(of: []) == nil)
    }

    // MARK: - AC1.3 — SourcingStrength default + Codable round-trip

    @Test func ac1_3_sourcingStrengthNoneIsZero() {
        let none = SourcingStrength.none
        #expect(none.sourceCount == 0)
        #expect(none.independentLineageCount == 0)
        #expect(none.topTrustTier == .transcription)
        #expect(!none.isCrossReferenced)
    }

    @Test func ac1_3_sourcingStrengthCodableRoundTrip() throws {
        let original = SourcingStrength(
            sourceCount: 5,
            independentLineageCount: 3,
            topTrustTier: .primary
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SourcingStrength.self, from: data)
        #expect(decoded == original)
    }

    @Test func ac1_3_isCrossReferencedThreshold() {
        let single = SourcingStrength(sourceCount: 3,
                                      independentLineageCount: 1,
                                      topTrustTier: .transcription)
        let multi = SourcingStrength(sourceCount: 3,
                                     independentLineageCount: 2,
                                     topTrustTier: .transcription)
        #expect(!single.isCrossReferenced)
        #expect(multi.isCrossReferenced)
    }

    // MARK: - AC1.4 — InferenceDepth.direct returns (0, [])

    @Test func ac1_4_inferenceDepthDirectIsZeroAndEmpty() {
        let direct = InferenceDepth.direct
        #expect(direct.steps == 0)
        #expect(direct.chain.isEmpty)
        #expect(!direct.isInferred)
    }

    @Test func ac1_4_inferenceDepthIsInferredFlag() {
        let inferred = InferenceDepth(steps: 1, chain: ["From: child birth record"])
        #expect(inferred.isInferred)
        #expect(inferred.steps == 1)

        let nested = InferenceDepth(steps: 2, chain: ["grandparent ←", "parent inference ←", "child birth"])
        #expect(nested.isInferred)
        #expect(nested.steps == 2)
    }
}
