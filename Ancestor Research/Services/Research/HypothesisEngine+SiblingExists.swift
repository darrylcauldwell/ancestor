import Foundation

/// `.siblingExists` kind — generator, grader, and expansiveness ladder.
///
/// **T12-sibling Phase 2.** The framework path is now the only path:
/// `ResearchPipeline.research(...)` calls `generate` → `deficitQuery` →
/// dispatch → `grade`. The legacy `findSiblings()` /
/// `siblingSearchOutcome` / `buildSiblingExistsHypothesis` triple were
/// deleted in this phase; this extension is load-bearing.
nonisolated extension HypothesisEngine {

    /// Emit one `.siblingExists` hypothesis when the subject's identity
    /// is resolved AND both parents are linked AND the resolved birth
    /// record carries district + year + mother's maiden name. The draft
    /// is unverified (`.inconclusive`, attempts: 0); the orchestrator
    /// dispatches the level-1 deficit query and then `gradeSiblingExists`
    /// settles the verdict.
    ///
    /// Returns `[]` when any precondition fails — distinct from
    /// "tried, found nothing" which is a `.contradicted` verdict on a
    /// generated hypothesis.
    static func generateSiblingExists(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> [ResearchHypothesis] {
        guard let context = resolveSiblingContext(state: state, snapshot: snapshot) else {
            return []
        }
        let kind = HypothesisKind.siblingExists(
            district: context.districtName,
            mmn: context.mmn,
            yearWindow: context.yearWindow
        )
        let now = Date()
        return [ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: context.subjectProfileID),
            subjectProfileID: context.subjectProfileID,
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
        )]
    }

    /// Grade a `.siblingExists` hypothesis. Reads candidate birth records
    /// from `state.scoredRecords` (the orchestrator appends the level-1
    /// deficit query's results before calling the grader) and runs
    /// `SiblingInferenceEngine.inferSiblings` against them.
    ///
    /// `.supported` with `supportingEvidence = candidateRecordIDs` when
    /// ≥1 candidate passes the surname+MMN+district+age-gap filter;
    /// `.contradicted` with empty evidence when zero candidates match;
    /// `.inconclusive` when preconditions stop holding between
    /// generation and grading (rare — included for correctness, not as
    /// a failure mode the pipeline exercises).
    static func gradeSiblingExists(
        _ hypothesis: ResearchHypothesis,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> GradeResult {
        guard case .siblingExists(let district, _, let yearWindow) = hypothesis.kind else {
            return .inconclusiveStub
        }
        guard let context = resolveSiblingContext(state: state, snapshot: snapshot) else {
            return GradeResult(
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "Preconditions no longer hold at grading time (identity or parents)."
            )
        }
        // Filter candidates by the hypothesis's payload, not the freshly
        // resolved context — payload is the contract grader works under
        // (matters for stale hypotheses loaded from disk).
        let upperDistrict = district.uppercased()
        let candidates = state.scoredRecords.filter { scored in
            guard case .birth(let birth) = scored.record else { return false }
            let recordDistrict = (birth.district ?? "")
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            guard recordDistrict == upperDistrict else { return false }
            guard let year = birth.birthYear else { return false }
            return yearWindow.contains(year)
        }
        let proposals = SiblingInferenceEngine.inferSiblings(
            subjectBirthRecord: context.subjectBirth,
            candidateRecords: candidates,
            knownFatherID: context.fatherID,
            knownMotherID: context.motherID,
            snapshot: snapshot
        )
        if proposals.isEmpty {
            return GradeResult(
                verdict: .contradicted,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "Searched \(district) \(yearWindow.lowerBound)–\(yearWindow.upperBound) for MMN; 0 matching candidates."
            )
        }
        return GradeResult(
            verdict: .supported,
            isModelAssisted: false,
            supportingEvidence: proposals.map(\.candidateRecordID),
            contradictingEvidence: [],
            reasoning: "Found \(proposals.count) candidate sibling\(proposals.count == 1 ? "" : "s") in \(district) \(yearWindow.lowerBound)–\(yearWindow.upperBound) sharing MMN."
        )
    }

    /// Expansiveness ladder for `.siblingExists`. Sibling discovery has
    /// district already pinned (from the subject's resolved birth
    /// record), so the ladder primarily walks strictness:
    ///
    ///   level 1 → strict surname-only birth query in pinned district,
    ///             year window from the hypothesis payload.
    ///   ≥ 2    → nil (exhausted)
    ///
    /// Further levels (loose tier, adjacent districts) are deferred to
    /// T31's empirical ladder retune — without harness data they'd be
    /// guesses, and the existing storm guards (Part I §11.2) make
    /// loose-vs-strict a no-op for surname-only queries anyway.
    static func deficitQuerySiblingExists(
        for hypothesis: ResearchHypothesis,
        atLevel level: Int,
        state: ResearchState
    ) -> [RecordQuery] {
        guard case .siblingExists(let districtName, _, let yearWindow) = hypothesis.kind else {
            return []
        }
        let subjectSurname = state.subject.surname ?? ""
        guard !subjectSurname.isEmpty else { return [] }

        // Audit finding (pass 13 + Helen Clare Cauldwell case): a sibling
        // search restricted to the subject's birth district silently misses
        // ~50% of real siblings. In UK practice, the second child is
        // commonly born at a different hospital (mother visiting her own
        // mother, regional maternity unit, etc.) — landing in a different
        // GRO registration district from the subject. For Darryl b. 1976
        // Belper, his actual sister Helen Clare Cauldwell is registered in
        // Derby 3A/177S — same county (DBY), different district.
        //
        // Fix: at level 1, expand to all districts in the subject's home
        // Chapman code. QueryCache dedupes any overlap (the birth district
        // is in the set). Cost: ~12 queries per sibling-search on a DBY
        // tree vs 1; acceptable because sibling search runs once per
        // profile per pipeline run.
        switch level {
        case 1:
            let countyDistricts = RegionConfig.districts(forChapmanCode: state.subject.homeChapmanCode)
            // Keep birth district first for log readability — it's where
            // most siblings actually appear.
            var orderedCodes: [String] = []
            if let birthDistrict = FreeBMDDistrictCatalogue.shared.district(named: districtName) {
                orderedCodes.append(birthDistrict.code)
            }
            for code in countyDistricts.values where !orderedCodes.contains(code) {
                orderedCodes.append(code)
            }
            return orderedCodes.map { code in
                RecordQuery(
                    surname: subjectSurname,
                    givenName: nil,
                    recordType: .birth,
                    yearFrom: yearWindow.lowerBound,
                    yearTo: yearWindow.upperBound,
                    gender: nil,
                    region: nil,
                    sourceParams: .freeBMD(FreeBMDParams(
                        districtCode: code,
                        wildcardSurname: false,
                        motherSurname: nil,
                        spouseSurname: nil
                    ))
                )
            }
        default:
            return []   // Exhausted — T31 will revisit the ladder ceiling
        }
    }

    // MARK: - Shared preconditions

    /// Resolved context for both generator and grader: the subject's
    /// birth fact, the linked parents, and the (district, MMN, year window)
    /// that the hypothesis payload encodes. `nil` when any precondition
    /// fails. Defined here (not on `HypothesisEngine`) so both methods
    /// can't drift in what they consider "ready to attempt".
    private struct SiblingContext {
        let subjectProfileID: String
        let subjectBirth: ScoredRecord
        let districtName: String
        let mmn: String
        let yearWindow: ClosedRange<Int>
        let fatherID: String
        let motherID: String
    }

    private static func resolveSiblingContext(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> SiblingContext? {
        // Inlined `state.confirmedFacts` filter — that computed property
        // is MainActor-isolated on `ResearchState`, and this extension
        // runs nonisolated. Reading the stored `scoredRecords` array
        // directly is the standard escape.
        let birthFacts = state.scoredRecords.filter { scored in
            guard scored.verdict == .fact else { return false }
            if case .birth = scored.record { return true }
            return false
        }
        let geoHypotheses: [GeographicHypothesis] = state.subject.profileID.map { id in
            GeographicHypothesisGenerator.inferDistricts(
                for: id, snapshot: snapshot, eventYear: state.subject.birthYearFrom
            )
        } ?? []
        let identity = SubjectIdentityResolver.resolve(
            candidateBirthFacts: birthFacts, hypotheses: geoHypotheses
        )
        guard case .resolved(let resolvedID, _) = identity,
              let subjectBirth = birthFacts.first(where: { $0.id == resolvedID })
        else { return nil }

        guard let subjectProfileID = state.subject.profileID else { return nil }
        let parents = snapshot.parentsOf(subjectProfileID)
        guard let father = parents.first(where: { $0.gender == .male }),
              let mother = parents.first(where: { $0.gender == .female })
        else { return nil }

        guard case .birth(let birth) = subjectBirth.record,
              let districtName = birth.district, !districtName.isEmpty,
              let subjectYear = birth.birthYear,
              let surname = birth.common.surname, !surname.isEmpty
        else { return nil }
        _ = surname  // generator uses state.subject.surname for query; resolved record's surname is the integrity check
        guard let mmnRaw = birth.mothersMaidenName?
            .trimmingCharacters(in: .whitespaces),
              !mmnRaw.isEmpty else { return nil }

        let yearFrom = subjectYear - SiblingInferenceEngine.maxSiblingAgeGap
        let yearTo = subjectYear + SiblingInferenceEngine.maxSiblingAgeGap
        return SiblingContext(
            subjectProfileID: subjectProfileID,
            subjectBirth: subjectBirth,
            districtName: districtName,
            mmn: mmnRaw,
            yearWindow: yearFrom...yearTo,
            fatherID: father.id,
            motherID: mother.id
        )
    }
}
