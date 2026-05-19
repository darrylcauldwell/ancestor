import Foundation

/// `.parentInferred(gender, surname)` kind — generator, grader, and
/// expansiveness ladder. Mirrors today's `ParentInferenceEngine.infer`
/// pattern: every BMD-index birth record carrying the subject's name
/// implies two parent surnames — mother via the `mothersMaidenName`
/// column (post-Sep-1911), father via `subject.surname` (the BMD index
/// doesn't carry the father's surname directly; the child's surname is
/// the inference).
///
/// **T12-parent Phase 1.** Lands alongside the legacy
/// `ParentInferenceEngine.infer` + `enrichParentsWithMarriage` paths.
/// Both surfaces produce the same parent surnames; tests pin the
/// projection-equality invariant. Phase 2 flips the source of truth so
/// `result.proposedRelatives` becomes a projection of these hypotheses
/// (with marriage given names cross-referenced from `.parentMarriage`
/// via `HypothesisEngine.reconcileParentMarriages`).
nonisolated extension HypothesisEngine {

    /// Emit one `.parentInferred` per (subject birth record carrying
    /// MMN, parent gender) pair. Mother surname = MMN; father surname
    /// = subject's surname. Skips records with `.impossible` verdict —
    /// `ParentInferenceEngine.infer` accepts both `.fact` and `.lead`
    /// because the BMD-index MMN is a transcribed property that doesn't
    /// depend on geography / family-context gates.
    static func generateParentInferred(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> [ResearchHypothesis] {
        guard let subjectProfileID = state.subject.profileID else { return [] }
        let subjectSurname = state.subject.surname?
            .trimmingCharacters(in: .whitespaces) ?? ""

        var seen: Set<String> = []
        var results: [ResearchHypothesis] = []
        let now = Date()

        for scored in state.scoredRecords {
            guard scored.verdict != .impossible else { continue }
            guard case .birth(let birth) = scored.record else { continue }
            guard let mmn = birth.mothersMaidenName?
                .trimmingCharacters(in: .whitespaces), !mmn.isEmpty
            else { continue }

            // Mother
            let motherKind = HypothesisKind.parentInferred(gender: .female, surname: mmn)
            let motherID = motherKind.identityKey(subjectProfileID: subjectProfileID)
            if seen.insert(motherID).inserted {
                results.append(ResearchHypothesis(
                    id: motherID,
                    subjectProfileID: subjectProfileID,
                    kind: motherKind,
                    verdict: .inconclusive,
                    isModelAssisted: false,
                    supportingEvidence: [],
                    contradictingEvidence: [],
                    reasoning: "Pending grading.",
                    createdAt: now,
                    lastTestedAt: now,
                    attempts: 0,
                    history: []
                ))
            }

            // Father — subject's surname carries the inference
            guard !subjectSurname.isEmpty else { continue }
            let fatherKind = HypothesisKind.parentInferred(gender: .male, surname: subjectSurname)
            let fatherID = fatherKind.identityKey(subjectProfileID: subjectProfileID)
            if seen.insert(fatherID).inserted {
                results.append(ResearchHypothesis(
                    id: fatherID,
                    subjectProfileID: subjectProfileID,
                    kind: fatherKind,
                    verdict: .inconclusive,
                    isModelAssisted: false,
                    supportingEvidence: [],
                    contradictingEvidence: [],
                    reasoning: "Pending grading.",
                    createdAt: now,
                    lastTestedAt: now,
                    attempts: 0,
                    history: []
                ))
            }
        }
        _ = snapshot   // generator doesn't consult the graph for this kind
        return results
    }

    /// Grade a `.parentInferred` hypothesis: `.supported` when at least
    /// one fact-or-lead BMD birth record for the subject attests the
    /// surname (mother via MMN equality, father via subject's surname
    /// equality on the record). `.inconclusive` otherwise.
    ///
    /// `.contradicted` is intentionally not produced in V2 scope —
    /// "explicit no-parents" cases (foundling, abandoned-at-birth) are
    /// out of scope; if there's no evidence, the right outcome is
    /// `.inconclusive` so T7's deficit-query / user "investigate"
    /// gestures have something to work with.
    static func gradeParentInferred(
        _ hypothesis: ResearchHypothesis,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> GradeResult {
        guard case .parentInferred(let gender, let surname) = hypothesis.kind else {
            return .inconclusiveStub
        }
        let upperSurname = surname.uppercased()
        var supporting: [String] = []
        for scored in state.scoredRecords {
            guard scored.verdict != .impossible else { continue }
            guard case .birth(let birth) = scored.record else { continue }
            switch gender {
            case .female:
                let mmn = (birth.mothersMaidenName ?? "")
                    .trimmingCharacters(in: .whitespaces)
                    .uppercased()
                if mmn == upperSurname { supporting.append(scored.id) }
            case .male:
                let recordSurname = (birth.common.surname ?? "")
                    .trimmingCharacters(in: .whitespaces)
                    .uppercased()
                if recordSurname == upperSurname { supporting.append(scored.id) }
            case .other, .unknown:
                // The generator only ever emits .male / .female for
                // parent hypotheses (BMD index is binary on parental
                // gender). A stored hypothesis carrying .other / .unknown
                // would be malformed — skip it rather than match
                // arbitrary records.
                continue
            }
        }
        _ = snapshot   // grader doesn't need the graph; supportingEvidence already in state

        if supporting.isEmpty {
            return GradeResult(
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "No BMD birth record attests \(surname) as \(gender == .female ? "mother (via MMN)" : "father (via subject surname)")."
            )
        }
        let label = gender == .female ? "mother (via MMN)" : "father (via subject surname)"
        return GradeResult(
            verdict: .supported,
            isModelAssisted: false,
            supportingEvidence: supporting,
            contradictingEvidence: [],
            reasoning: "Inferred \(surname) as \(label) from \(supporting.count) BMD birth record\(supporting.count == 1 ? "" : "s")."
        )
    }

    /// Expansiveness ladder for `.parentInferred`. No per-kind ladder —
    /// "look harder for a fact-grade birth record" is what the main
    /// pipeline's whole-profile widening already does. Returning `nil`
    /// at every level means T7's deficit-query path never re-dispatches
    /// against this kind; the kind contributes to the framework's
    /// hypothesis set but its inconclusive cases fall through to T8's
    /// MLX next-search fallback (§5.4) instead.
    static func deficitQueryParentInferred(
        for hypothesis: ResearchHypothesis,
        atLevel level: Int,
        state: ResearchState
    ) -> RecordQuery? {
        _ = (hypothesis, level, state)
        return nil
    }
}
