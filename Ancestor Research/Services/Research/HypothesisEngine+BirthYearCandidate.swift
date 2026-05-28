import Foundation

/// `.birthYearCandidate(profileID, year)` kind — generator, grader, and
/// expansiveness ladder.
///
/// **Slice 1 of `project_multi_hypothesis_birth_year_plan`.** Lands only
/// the generator. Grader returns `.inconclusiveStub` and `deficitQuery`
/// returns `[]`; slices 2–4 fill those in (biographical-fit margin in
/// slice 2, census/marriage probes in slice 4). Without grading, the
/// pipeline still emits and persists the competing-candidate hypotheses,
/// which the UI / MCP can inspect — useful for verifying the generator's
/// shape on real data (George Herbert Brooks: Jun 1870 vs Dec 1883) before
/// the grader picks the disambiguator's evidence threshold.
nonisolated extension HypothesisEngine {

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

    /// Grade a `.birthYearCandidate`. Slice 1 stub — slice 2 will compare
    /// `BiographicalFitEvaluator` scores across the competing candidates
    /// and return `.supported` for the decisive winner / `.contradicted`
    /// for losers / `.inconclusive` when the margin is too narrow.
    static func gradeBirthYearCandidate(
        _ hypothesis: ResearchHypothesis,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> GradeResult {
        _ = state
        _ = snapshot
        guard case .birthYearCandidate = hypothesis.kind else {
            return .inconclusiveStub
        }
        return .inconclusiveStub
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
