import Foundation

/// `.birthYearCandidate(profileID, year)` kind — generator, grader, and
/// expansiveness ladder.
///
/// **Slices 1 + 2 + 4 of `project_multi_hypothesis_birth_year_plan`.**
/// Slice 1 shipped the generator. Slice 2 wired `BiographicalFitEvaluator`
/// into the grader. Slice 4 wires the expansiveness ladder: level 1
/// emits one FreeCen census probe per applicable UK census year (the
/// nearest census after birth and any subsequent census during the
/// candidate's plausible adulthood), with the subject's home Chapman
/// code + a tight birthYearRange around the candidate. Census records
/// returning carry an `age` field; the grader passes them through to
/// `BiographicalFitEvaluator` via the new `censusRecords:` parameter so
/// Rule 4 can `(censusYear - age)` back-calculate and corroborate.
///
/// The grader returns:
///   • `.supported`   — this year is the plausibility winner AND beats
///                       the second-best candidate by ≥ `decisiveMargin`
///                       (0.4), OR plausibilities are tied at the top
///                       but this year has ≥ 2 more corroborating
///                       matches than any competitor.
///   • `.contradicted` — another year is the winner via either rule
///   • `.inconclusive` — neither rule resolves
///
/// The canonical case (George Brooks: 1870 vs 1883, first child 1912)
/// scores both candidates 1.0 on rule 3 alone. With slice 4 census
/// probes, the 1891 Belper census ("George Brooks aged 8") corroborates
/// 1883 with implied-birth 1883 (gap 0; within tolerance) and is
/// irrelevant to 1870 (gap 13; outside the relevance window). The
/// corroboration tie-break then picks 1883 as `.supported`.
nonisolated extension HypothesisEngine {

    /// Plausibility-gap threshold for declaring a winner. 0.4 chosen to
    /// match the evaluator's only multiplier in rule 2 (×0.4 for
    /// age-at-death mismatch). A 1.0 vs 0.4 gap (≥ 0.6) is decisive;
    /// 1.0 vs 0.6 (gap 0.4) is exactly at threshold and counts as
    /// supported. Tied at 1.0 (gap 0.0) is correctly inconclusive.
    /// Calibration TODO after first real-data run with corroborating
    /// records from slice 4.
    fileprivate static let birthYearCandidateDecisiveMargin: Double = 0.4

    /// Corroboration-count margin for the tie-break rule. When two
    /// candidates can't be separated by plausibility (typically both
    /// 1.0 — rule 3 alone passes), the candidate with ≥ this many more
    /// corroborating matches wins. Two independent census ages
    /// agreeing on a specific year is the minimum bar — a single
    /// census record could be transcription error; two from different
    /// years can't be the same error. Mirrors the "≥ 2 independent
    /// signals" pattern in V2 spec §5.8.
    fileprivate static let birthYearCandidateCorroborationMargin: Int = 2

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
        // Slice 4: pass census records to the evaluator so Rule 4
        // (census-age back-calculation) can corroborate the right
        // candidate when level-1 deficit-query probes have populated
        // state with census evidence.
        let censusShapeRecords = state.scoredRecords.filter { scored in
            if case .census = scored.record { return true }
            return false
        }

        let results = BiographicalFitEvaluator.evaluate(
            candidates: candidates,
            subject: state.subject,
            deathRecords: deathShapeRecords,
            snapshot: snapshot,
            censusRecords: censusShapeRecords
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

        // Decision rule 1: plausibility-margin winner.
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

        // Decision rule 2: corroboration tie-break (slice 4).
        // When plausibilities can't separate the candidates (typically
        // all 1.0 — rule 3 alone passes), corroboration counts from
        // Rule 4 census-age back-calculation surface the discriminator.
        // Decisive iff exactly one candidate has ≥ 2 more corroborating
        // matches than every other candidate at the same plausibility tier.
        let topTierResults = results.filter { $0.plausibility == topPlausibility }
        if topTierResults.count >= 2 {
            let sortedByCorroboration = topTierResults.sorted {
                $0.corroboratingMatches > $1.corroboratingMatches
            }
            let topC = sortedByCorroboration[0].corroboratingMatches
            let secondC = sortedByCorroboration[1].corroboratingMatches
            if topC - secondC >= birthYearCandidateCorroborationMargin {
                let winnerYear = sortedByCorroboration[0].candidateBirthYear
                if year == winnerYear {
                    return GradeResult(
                        verdict: .supported,
                        isModelAssisted: false,
                        supportingEvidence: [],
                        contradictingEvidence: [],
                        reasoning: "Year \(year) wins corroboration tie-break (\(topC) census/death matches vs next \(secondC), margin ≥ \(birthYearCandidateCorroborationMargin)). Competing years: [\(competingSummary)]. \(thisResult.reasoning)"
                    )
                }
                // Different year won the corroboration race — this one
                // is .contradicted iff its own corroboration count
                // trails the winner by ≥ the margin. (At plausibility
                // tier-mates, lacking corroboration is the deciding
                // signal; matching corroboration to a different year
                // doesn't auto-contradict if THIS year tied for top
                // corroboration but lost only via ties broken on year
                // — handled by the >= 2 margin requirement.)
                if topC - thisResult.corroboratingMatches >= birthYearCandidateCorroborationMargin {
                    return GradeResult(
                        verdict: .contradicted,
                        isModelAssisted: false,
                        supportingEvidence: [],
                        contradictingEvidence: [],
                        reasoning: "Year \(year) loses corroboration tie-break (\(thisResult.corroboratingMatches) census/death matches vs winner \(winnerYear) at \(topC), gap ≥ \(birthYearCandidateCorroborationMargin)). Competing years: [\(competingSummary)]. \(thisResult.reasoning)"
                    )
                }
            }
        }
        return GradeResult(
            verdict: .inconclusive,
            isModelAssisted: false,
            supportingEvidence: [],
            contradictingEvidence: [],
            reasoning: "Year \(year) plausibility \(formatScore(thisPlausibility)); top \(formatScore(topPlausibility)); margin below \(formatScore(birthYearCandidateDecisiveMargin)); corroboration \(thisResult.corroboratingMatches). Competing years: [\(competingSummary)]. \(thisResult.reasoning)"
        )
    }

    /// Format a 0.00-1.00 plausibility for the reasoning string.
    private static func formatScore(_ x: Double) -> String {
        String(format: "%.2f", x)
    }

    /// Expansiveness ladder for `.birthYearCandidate`.
    ///
    /// `level 1` (slice 4) → one FreeCen census probe per applicable
    /// UK census year between `candidateYear + 1` and `candidateYear + 80`.
    /// Each probe is chapman-coded to the subject's home county and
    /// carries a tight `birthYearRange` of `±censusAgeTolerance` (2)
    /// around the candidate's year. The FreeCen source rates census
    /// records via the standard scorer; matching records flow into
    /// `state.scoredRecords` (tagged as enrichment) and the grader's
    /// next call passes them to `BiographicalFitEvaluator`'s Rule 4.
    ///
    /// `level ≥ 2` → empty. Marriage probes were considered (per the
    /// original plan) but BMD marriage indexes don't carry ages, so a
    /// marriage probe at level 2 wouldn't discriminate birth years. T8
    /// (MLX strategist, paper-only) is the intended next step beyond
    /// level 1.
    ///
    /// Required preconditions: subject has `surname` and `homeChapmanCode`
    /// (set on `ResearchSubject` by `ResearchSubjectBuilder`). When
    /// either is missing the probe set is empty and T7 skips this
    /// hypothesis on its second pass.
    static func deficitQueryBirthYearCandidate(
        for hypothesis: ResearchHypothesis,
        atLevel level: Int,
        state: ResearchState
    ) -> [RecordQuery] {
        guard case .birthYearCandidate(_, let candidateYear) = hypothesis.kind else {
            return []
        }
        switch level {
        case 1:
            return censusProbes(candidateYear: candidateYear, state: state)
        default:
            return []
        }
    }

    /// One FreeCen probe per UK census year inside the candidate's
    /// plausible adulthood. Returns `[]` when surname is missing —
    /// without surname the FreeCen query is too broad to be useful.
    private static func censusProbes(
        candidateYear: Int, state: ResearchState
    ) -> [RecordQuery] {
        let surname = (state.subject.surname ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !surname.isEmpty else { return [] }
        let chapmanCode = state.subject.homeChapmanCode
        let tolerance = ScoringRules.censusAgeTolerance
        let birthYearRange = (candidateYear - tolerance)...(candidateYear + tolerance)
        // Candidate must have been alive AND named in the census — the
        // upper bound (80y) caps at human lifespan; the lower bound
        // (≥ candidate + 1) skips the census in their birth year itself
        // (FreeCen would only catch newborns at the April enumeration
        // date, a noisy edge case for our discriminator purpose).
        let applicableCensusYears = ScoringRules.censusYears.filter { y in
            y > candidateYear && y <= candidateYear + 80
        }
        return applicableCensusYears.map { year in
            RecordQuery(
                surname: surname,
                givenName: state.subject.givenName,
                recordType: .census,
                yearFrom: year,
                yearTo: year,
                gender: state.subject.gender,
                region: state.subject.region,
                sourceParams: .freeCen(FreeCenParams(
                    chapmanCode: chapmanCode,
                    censusYear: year,
                    birthYearRange: birthYearRange
                ))
            )
        }
    }
}
