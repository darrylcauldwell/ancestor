import Foundation

/// `.siblingExists` kind — generator, grader, and expansiveness ladder.
///
/// **T11 scaffold.** The three functions return empty / inconclusive /
/// nil so the engine compiles and the central switches in
/// `HypothesisEngine.swift` have somewhere to dispatch. T12-sibling
/// fills in the real implementations, folding `SiblingInferenceEngine`
/// in as the grader and `ParentInferenceEngine` + identity resolution
/// as the generator preconditions.
///
/// Per V2 spec §5.2's phased migration, the legacy `findSiblings()`
/// path in `ResearchPipeline.swift` continues to run in T11 and
/// T12-sibling Phase 1; this extension only becomes load-bearing at
/// T12-sibling Phase 2 (when `proposedSiblings` is flipped to derive
/// from `hypotheses`).
nonisolated extension HypothesisEngine {

    /// Emit one hypothesis per `(district, mmn, yearWindow)` when subject
    /// identity is resolved AND both parents are linked. T11 stub
    /// returns empty.
    static func generateSiblingExists(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> [ResearchHypothesis] {
        _ = state
        _ = snapshot
        return []
    }

    /// Grade an existing `.siblingExists` hypothesis. T11 stub returns
    /// `.inconclusive`.
    static func gradeSiblingExists(
        _ hypothesis: ResearchHypothesis,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> GradeResult {
        _ = hypothesis
        _ = state
        _ = snapshot
        return .inconclusiveStub
    }

    /// Expansiveness ladder for `.siblingExists`. Per V2 spec §5.10's
    /// per-kind override discussion, sibling discovery has district
    /// already pinned (from the subject's resolved birth record), so
    /// it walks strictness first:
    ///
    ///   level 1 → strict surname match in pinned district, ±20yr
    ///   level 2 → loose surname match in pinned district, ±20yr
    ///   level 3 → loose surname match in adjacent districts
    ///   level 4 → variant-tier surname match in pinned district
    ///   ≥ 5    → nil (exhausted)
    ///
    /// T11 stub returns nil at every level (the engine isn't dispatching
    /// queries yet; T7 wires that up).
    static func deficitQuerySiblingExists(
        for hypothesis: ResearchHypothesis,
        atLevel level: Int,
        state: ResearchState
    ) -> RecordQuery? {
        _ = hypothesis
        _ = level
        _ = state
        return nil
    }
}
