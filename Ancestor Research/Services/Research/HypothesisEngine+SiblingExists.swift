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
    /// identity is resolved AND both parents are linked.
    ///
    /// **T12-sibling Phase 1 status**: stub returns `[]`. The hypothesis
    /// production currently lives in `ResearchPipeline.siblingSearchOutcome`
    /// + `buildSiblingExistsHypothesis`, which run the legacy
    /// `findSiblings` dispatch and shape the result into a hypothesis.
    /// Phase 2 deletes those, moves the dispatch + inference here, and
    /// this generator becomes the single source of truth.
    static func generateSiblingExists(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> [ResearchHypothesis] {
        _ = state
        _ = snapshot
        return []
    }

    /// Grade an existing `.siblingExists` hypothesis.
    ///
    /// **T12-sibling Phase 1 status**: stub returns `.inconclusive`.
    /// Phase 2 replaces this with a real grader that inspects state for
    /// candidate sibling records (added to state by Phase 2's generator
    /// dispatch) and applies the `SiblingInferenceEngine` rule.
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

    /// Expansiveness ladder for `.siblingExists`. Sibling discovery has
    /// district already pinned (from the subject's resolved birth
    /// record), so the ladder primarily walks strictness:
    ///
    ///   level 1 → strict surname-only birth query in pinned district,
    ///             year window from the hypothesis payload. Matches the
    ///             legacy `findSiblings` dispatch.
    ///   ≥ 2    → nil (exhausted)
    ///
    /// T12-sibling Phase 1 implements level 1 only. Further levels
    /// (loose tier, adjacent districts) are deferred to T31's empirical
    /// ladder retune — without harness data they'd be guesses, and the
    /// existing storm guards (Part I §11.2) make loose-vs-strict a
    /// no-op for surname-only queries anyway.
    static func deficitQuerySiblingExists(
        for hypothesis: ResearchHypothesis,
        atLevel level: Int,
        state: ResearchState
    ) -> RecordQuery? {
        guard case .siblingExists(_, _, let yearWindow) = hypothesis.kind else {
            return nil
        }
        // The hypothesis carries the district name; map to FreeBMD code.
        guard case .siblingExists(let districtName, _, _) = hypothesis.kind,
              let district = FreeBMDDistrictCatalogue.shared.district(named: districtName) else {
            return nil
        }
        let subjectSurname = state.subject.surname ?? ""
        guard !subjectSurname.isEmpty else { return nil }

        switch level {
        case 1:
            return RecordQuery(
                surname: subjectSurname,
                givenName: nil,
                recordType: .birth,
                yearFrom: yearWindow.lowerBound,
                yearTo: yearWindow.upperBound,
                gender: nil,
                region: nil,
                sourceParams: .freeBMD(FreeBMDParams(
                    districtCode: district.code,
                    wildcardSurname: false,
                    motherSurname: nil,
                    spouseSurname: nil
                ))
            )
        default:
            return nil   // Exhausted — T31 will revisit the ladder ceiling
        }
    }
}
