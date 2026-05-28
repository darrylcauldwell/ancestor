import Foundation

/// `.birthYearCandidate(profileID, year)` kind — generator, grader, and
/// expansiveness ladder.
///
/// **Slices 1 + 2 of `project_multi_hypothesis_birth_year_plan`.**
/// Slice 1 shipped the generator. Slice 2 now wires
/// `BiographicalFitEvaluator` into the grader: each `.birthYearCandidate`
/// is scored against the subject's known life-timeline (children's birth
/// years drive Rule 3 — age 14–65 at first child; death-shape records
/// in state drive Rules 1 + 2). The grader compares the candidate's
/// plausibility against the best competitor and returns:
///   • `.supported`   — this year is the winner AND beats the second-best
///                       candidate by ≥ `decisiveMargin` (0.4)
///   • `.contradicted` — another year is the winner AND beats this one by
///                       ≥ `decisiveMargin`
///   • `.inconclusive` — winner unclear (ties at top, or all candidates
///                       score 1.0 because rule 3 alone passes)
///
/// The canonical case (George Brooks: 1870 vs 1883, first child 1912)
/// scores both candidates 1.0 on rule 3 alone — both ages (42, 29) fall
/// inside 14–65. Slice 2 returns `.inconclusive` for both. Slice 4's
/// deficit queries will dispatch census + marriage probes that bring in
/// records whose age-at-record fields tilt the evaluator decisively.
///
/// `deficitQuery` still returns `[]` (slice 4's job).
nonisolated extension HypothesisEngine {

    /// Plausibility-gap threshold for declaring a winner. 0.4 chosen to
    /// match the evaluator's only multiplier in rule 2 (×0.4 for
    /// age-at-death mismatch). A 1.0 vs 0.4 gap (≥ 0.6) is decisive;
    /// 1.0 vs 0.6 (gap 0.4) is exactly at threshold and counts as
    /// supported. Tied at 1.0 (gap 0.0) is correctly inconclusive.
    /// Calibration TODO after first real-data run with corroborating
    /// records from slice 4.
    fileprivate static let birthYearCandidateDecisiveMargin: Double = 0.4

    /// Emit one `.birthYearCandidate` per distinct precise (span-0)
    /// birth-year value currently attested in `Profile.sources[.birthDate]`,
    /// but **only when ≥ 2 distinct years compete**. A single precise
    /// candidate is the subject-self-narrowing slice-B path's job (it
    /// writes a pending fact); a wide-range value alone needs neither
    /// path. This is the multi-hypothesis disambiguator's entry condition.
    ///
    /// Precision rule: a candidate is "precise" iff
    /// `GenealogicalDate(parsing:)` returns `earliest != nil &&
    /// latest != nil && earliest == latest`. That captures `.exact`,
    /// `.yearOnly`, and any other qualifier that happens to land both
    /// bounds on the same year. Wide-range entries (`BET 1869 AND 1896`,
    /// `ABT 1880`, `BEF 1900`) are ignored — they can't compete with a
    /// precise value, only support or contradict one.
    ///
    /// Output order: candidates sorted ascending by year, so re-runs
    /// produce stable IDs in stable list positions (matters for
    /// upsert-driven persistence and for log-diffing across runs).
    static func generateBirthYearCandidate(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> [ResearchHypothesis] {
        guard let subjectProfileID = state.subject.profileID,
              let profile = snapshot.profiles[subjectProfileID]
        else { return [] }
        let sources = profile.sources[.birthDate] ?? []

        var years: Set<Int> = []
        for source in sources {
            let parsed = GenealogicalDate(parsing: source.raw)
            guard let earliest = parsed.earliest,
                  let latest = parsed.latest,
                  earliest == latest
            else { continue }
            years.insert(earliest)
        }
        guard years.count >= 2 else { return [] }

        let now = Date()
        return years.sorted().map { year in
            let kind = HypothesisKind.birthYearCandidate(
                profileID: subjectProfileID, year: year
            )
            return ResearchHypothesis(
                id: kind.identityKey(subjectProfileID: subjectProfileID),
                subjectProfileID: subjectProfileID,
                kind: kind,
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "Pending grading.",
                createdAt: now,
                lastTestedAt: now,
                attempts: 0,
                history: []
            )
        }
    }

    /// Grade a `.birthYearCandidate` by scoring its year against every
    /// competing candidate's year via `BiographicalFitEvaluator`, then
    /// comparing plausibilities. Deterministic — no MLX involvement,
    /// `isModelAssisted = false`.
    ///
    /// **Why re-derive the candidate set?** A grader sees one hypothesis
    /// at a time. The cross-candidate compare needs visibility into the
    /// OTHER candidate years to decide whether THIS year wins. The
    /// generator's input — `Profile.sources[.birthDate]` — is also
    /// available at grading time (snapshot is the same), so the grader
    /// re-derives the year set with the same logic. This keeps the
    /// hypothesis self-grading: no dependency on whether the other
    /// candidate hypotheses happen to be in scope at grading.
    static func gradeBirthYearCandidate(
        _ hypothesis: ResearchHypothesis,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> GradeResult {
        guard case .birthYearCandidate(let profileID, let year) = hypothesis.kind,
              let profile = snapshot.profiles[profileID]
        else { return .inconclusiveStub }

        // Re-derive the candidate year set (generator's logic).
        var years: Set<Int> = []
        for source in profile.sources[.birthDate] ?? [] {
            let parsed = GenealogicalDate(parsing: source.raw)
            guard let earliest = parsed.earliest,
                  let latest = parsed.latest,
                  earliest == latest
            else { continue }
            years.insert(earliest)
        }
        // Preconditions evaporated since generation (sources were edited
        // mid-run, etc.). Grader's contract is to grade what's there.
        guard years.count >= 2 else {
            return GradeResult(
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "Preconditions no longer hold at grading time: \(years.count) precise birth-year candidate(s) currently attested (generator emits only for ≥ 2)."
            )
        }
        guard years.contains(year) else {
            return GradeResult(
                verdict: .contradicted,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "Candidate year \(year) is no longer attested in Profile.sources[.birthDate]."
            )
        }

        // Synthesise a minimal BirthRecord per year so the evaluator has
        // surname+given hooks for `sameIdentity` checks against death
        // records in state. Subject's surname/given come from
        // `state.subject` (the ResearchSubject derived from this profile).
        let surname = state.subject.surname ?? profile.lastName ?? ""
        let given = state.subject.givenName ?? profile.firstName ?? ""
        let candidates: [ScoredRecord] = years.sorted().map { y in
            let common = RecordCommon(
                id: "birthYearCandidate:synth:\(profileID):\(y)",
                sourceID: "synth",
                name: nil,
                surname: surname,
                givenName: given,
                detailURL: nil,
                rawFields: [:]
            )
            let birth = BirthRecord(
                common: common,
                birthYear: y,
                birthDate: nil,
                birthPlace: nil,
                quarter: nil,
                district: nil,
                volume: nil,
                page: nil,
                mothersMaidenName: nil
            )
            return ScoredRecord(
                id: common.id, record: .birth(birth),
                verdict: .lead, gates: [], summary: ""
            )
        }

        let deathShapeRecords = state.scoredRecords.filter { scored in
            switch scored.record {
            case .death, .burial, .probate, .military: return true
            default: return false
            }
        }

        let results = BiographicalFitEvaluator.evaluate(
            candidates: candidates,
            subject: state.subject,
            deathRecords: deathShapeRecords,
            snapshot: snapshot
        )
        guard let thisResult = results.first(where: { $0.candidateBirthYear == year }) else {
            // evaluate() skips candidates without a birthYear — shouldn't
            // happen since we just synthesised them with explicit years,
            // but guard for completeness.
            return GradeResult(
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "BiographicalFitEvaluator returned no result for year \(year)."
            )
        }

        // Sorted descending by plausibility already (evaluate() sorts).
        let topPlausibility = results[0].plausibility
        let secondPlausibility = results.count >= 2 ? results[1].plausibility : 0.0
        let thisPlausibility = thisResult.plausibility

        let winnerIsThis = thisPlausibility == topPlausibility
        let topMinusSecond = topPlausibility - secondPlausibility
        let topMinusThis = topPlausibility - thisPlausibility

        let allYears = results.map(\.candidateBirthYear)
        let competing = allYears.filter { $0 != year }
        let competingSummary = competing.map(String.init).joined(separator: ", ")

        if winnerIsThis,
           topMinusSecond >= birthYearCandidateDecisiveMargin {
            return GradeResult(
                verdict: .supported,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "Year \(year) wins biographical fit (plausibility \(formatScore(thisPlausibility)) vs next \(formatScore(secondPlausibility)), margin ≥ \(formatScore(birthYearCandidateDecisiveMargin))). Competing years: [\(competingSummary)]. \(thisResult.reasoning)"
            )
        }
        if !winnerIsThis,
           topMinusThis >= birthYearCandidateDecisiveMargin {
            return GradeResult(
                verdict: .contradicted,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "Year \(year) loses biographical fit (plausibility \(formatScore(thisPlausibility)) vs winner \(formatScore(topPlausibility)), gap ≥ \(formatScore(birthYearCandidateDecisiveMargin))). Competing years: [\(competingSummary)]. \(thisResult.reasoning)"
            )
        }
        return GradeResult(
            verdict: .inconclusive,
            isModelAssisted: false,
            supportingEvidence: [],
            contradictingEvidence: [],
            reasoning: "Year \(year) plausibility \(formatScore(thisPlausibility)); top \(formatScore(topPlausibility)); margin below \(formatScore(birthYearCandidateDecisiveMargin)). Competing years: [\(competingSummary)]. Awaiting slice-4 corroborating evidence. \(thisResult.reasoning)"
        )
    }

    /// Format a 0.00-1.00 plausibility for the reasoning string.
    private static func formatScore(_ x: Double) -> String {
        String(format: "%.2f", x)
    }

    /// Expansiveness ladder for `.birthYearCandidate`. Slice 1 stub —
    /// slice 4 will return the level-0 census probe for the implied age
    /// at the nearest census year and the level-1 marriage probe for the
    /// plausible spouse-age at known marriage.
    static func deficitQueryBirthYearCandidate(
        for hypothesis: ResearchHypothesis,
        atLevel level: Int,
        state: ResearchState
    ) -> [RecordQuery] {
        _ = hypothesis
        _ = level
        _ = state
        return []
    }
}
