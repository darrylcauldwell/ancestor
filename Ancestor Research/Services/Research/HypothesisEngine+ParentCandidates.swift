import Foundation

/// `.parentCandidates(fatherGiven, fatherSurname, motherGiven,
/// motherMaidenSurname, marriageWindow)` kind — grader and expansiveness
/// ladder for user-seeded parent hunches (RESEARCH_PIPELINE_SPEC §5.15,
/// Slice 2).
///
/// **No generator by design (§5.15.1, Decision E1).** The engine never
/// invents a hunch: rows of this kind carry `origin == .user` and are
/// materialised from the v32 `user_hypothesis_seeds` staging table by
/// `HypothesisSeedService`. The engine's regeneration cycle never
/// creates, deletes, or reshapes `.user` rows — only re-grades them
/// (the "regeneration exemption"). The central `generate` switch arm
/// therefore returns `[]` permanently, not as a stub.
///
/// **Doctrine — a hunch is a search directive, never data.** Nothing in
/// this file writes anywhere. The deficit ladder emits focused queries;
/// records those probes surface face the normal machinery (scorer →
/// clustering → review → standard accept path); grading updates the
/// hypothesis verdict only.
///
/// **Grading is Decision E5 — supported requires the linkage chain.**
/// A unique Bob × Sue marriage proves the *couple* existed, not that
/// they are the subject's parents. `.supported` needs marriage match
/// AND subject linkage (birth-index MMN or census household). Couple
/// attestation alone stays `.inconclusive` — no self-confirmation.
nonisolated extension HypothesisEngine {

    // MARK: - Nickname equivalence (§5.15.2 / §5.15.3 / AC 8)

    /// Agreement threshold on `ScoringRules.nameSimilarity`. 0.7 is the
    /// codebase-wide match bar (RecordScorer household checks,
    /// ClusteringEngine member overlap) — nickname-table hits score
    /// 0.85, learned `name_equivalences` pairs 0.9, both clear it.
    static let parentCandidatesNameAgreementThreshold: Double = 0.7

    /// §5.15.3 promises "Bob" matches "Robert" via the nickname
    /// machinery, and AC 8 pins it. The shipped
    /// `ScoringRules.nicknameEquivalents` table is a faithful port of
    /// `agent/rules.py` and carries NEITHER BOB↔ROBERT nor SUE↔SUSAN —
    /// the spec's canonical hunch. Mutating the ported table would
    /// silently change 4-gate scorer behaviour project-wide, so the
    /// hunch grader carries this local supplement instead. User-learned
    /// `name_equivalences` pairs still apply through
    /// `ScoringRules.nameSimilarity` as everywhere.
    private static let parentCandidatesSupplementalDiminutives: [String: Set<String>] = [
        "BOB": ["ROBERT"], "BOBBY": ["ROBERT"], "ROB": ["ROBERT"],
        "SUE": ["SUSAN", "SUSANNAH"], "SUSIE": ["SUSAN", "SUSANNAH"],
    ]

    /// "Given names agreeing via nickname equivalence" (§5.15.4).
    /// Compares full strings and first tokens (BMD index given names
    /// are often "Robert James") through `ScoringRules.nameSimilarity`
    /// (exact / learned equivalence / spelling normalisation / built-in
    /// nickname table / single-char drift) plus the local diminutive
    /// supplement above.
    static func parentCandidatesGivenNamesAgree(_ a: String, _ b: String) -> Bool {
        let aTrim = a.trimmingCharacters(in: .whitespaces)
        let bTrim = b.trimmingCharacters(in: .whitespaces)
        guard !aTrim.isEmpty, !bTrim.isEmpty else { return false }
        let aFirst = String(aTrim.split(separator: " ").first ?? "")
        let bFirst = String(bTrim.split(separator: " ").first ?? "")
        for (x, y) in [(aTrim, bTrim), (aFirst, bFirst)] {
            if ScoringRules.nameSimilarity(x, y) >= parentCandidatesNameAgreementThreshold {
                return true
            }
            let xU = x.uppercased(), yU = y.uppercased()
            if parentCandidatesSupplementalDiminutives[xU]?.contains(yU) == true
                || parentCandidatesSupplementalDiminutives[yU]?.contains(xU) == true {
                return true
            }
        }
        return false
    }

    /// Surname conflict test for the MMN rule. Surnames don't have
    /// nicknames — "conflicting" means uppercased inequality that also
    /// fails the similarity bar (so transcriber drift like
    /// CAULDWELL/CALDWELL doesn't fire a false `.contradicted`).
    private static func parentCandidatesSurnamesConflict(_ a: String, _ b: String) -> Bool {
        let aU = a.uppercased().trimmingCharacters(in: .whitespaces)
        let bU = b.uppercased().trimmingCharacters(in: .whitespaces)
        guard !aU.isEmpty, !bU.isEmpty else { return false }
        if aU == bU { return false }
        return ScoringRules.nameSimilarity(aU, bU) < parentCandidatesNameAgreementThreshold
    }

    // MARK: - Grader (§5.15.4, Decision E5)

    /// Grade a `.parentCandidates` hunch against current evidence. Pure
    /// function — state + snapshot in, verdict out; deterministic, no
    /// MLX involvement, `isModelAssisted: false` always.
    ///
    /// Verdict table (§5.15.4):
    ///
    /// | Evidence state | Verdict |
    /// |---|---|
    /// | Marriage `.unique` for the hinted pair AND subject linkage (birth MMN = matched bride's maiden, OR census household with subject as child of the hinted couple) | `.supported` |
    /// | Marriage `.unique`, no linkage yet | `.inconclusive` — couple attested; parental link unproven |
    /// | Identity-resolved birth MMN conflicts with a non-nil `motherMaidenSurname` hint | `.contradicted` |
    /// | Confirmed (field_sources-backed) tree parent given name conflicts with a hint beyond nickname equivalence | `.contradicted` |
    /// | No marriage / no linkage found in window | `.inconclusive` — NEVER `.contradicted` (asymmetric verdict space, §4.1) |
    static func gradeParentCandidates(
        _ hypothesis: ResearchHypothesis,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> GradeResult {
        guard case .parentCandidates(
            let fatherGiven, let fatherSurname,
            let motherGiven, let motherMaidenSurname,
            let window
        ) = hypothesis.kind else {
            return .inconclusiveStub
        }

        // Rule 1 — confirmed-parent conflict (table row 4). A
        // field_sources-backed parent already on the tree whose given
        // name disagrees with the hint beyond nickname equivalence
        // refutes the hunch outright; `contradictingEvidence` cites
        // the edge.
        let subjectProfileID = hypothesis.subjectProfileID ?? state.subject.profileID
        if let subjectProfileID,
           let conflict = confirmedParentGivenNameConflict(
                fatherGiven: fatherGiven, motherGiven: motherGiven,
                subjectProfileID: subjectProfileID, snapshot: snapshot
           ) {
            return GradeResult(
                verdict: .contradicted,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: ["edge:parent:\(conflict.parentID)"],
                reasoning: "Hunch says \(conflict.role) given name \"\(conflict.hint)\"; the tree holds a confirmed \(conflict.role) \"\(conflict.confirmed)\" (profile \(conflict.parentID)) — conflict beyond nickname equivalence."
            )
        }

        // Rule 2 — MMN conflict (table row 3). The subject's
        // identity-resolved birth record carries a mother's maiden name
        // that disagrees with a non-nil hint.
        if let mmsHint = normalisedHint(motherMaidenSurname),
           let resolved = identityResolvedBirthRecord(state: state, snapshot: snapshot),
           case .birth(let birth) = resolved.record,
           let recordMMN = birth.mothersMaidenName?
                .trimmingCharacters(in: .whitespaces),
           !recordMMN.isEmpty,
           parentCandidatesSurnamesConflict(mmsHint, recordMMN) {
            return GradeResult(
                verdict: .contradicted,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [resolved.id],
                reasoning: "Hunch says mother maiden surname \"\(mmsHint)\"; the subject's identity-resolved birth record (\(resolved.id)) carries MMN \"\(recordMMN)\"."
            )
        }

        // Rule 3 — marriage match + linkage chain (table rows 1/2/5).
        let effectiveGroomSurname = parentCandidatesGroomSurname(
            fatherSurname: fatherSurname, state: state
        )
        guard let groomSurname = effectiveGroomSurname else {
            return GradeResult(
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "No groom-side surname derivable (no fatherSurname hint and subject has no surname) — the marriage probe cannot run."
            )
        }
        let resolutionNote = fatherSurname == nil
            ? " Groom surname resolved from subject surname \"\(groomSurname)\" (paternal-naming convention)."
            : ""

        let match = parentCandidatesMarriageEvidence(
            fatherGiven: fatherGiven,
            groomSurname: groomSurname,
            motherGiven: motherGiven,
            motherMaidenSurname: normalisedHint(motherMaidenSurname),
            window: window,
            state: state
        )
        switch match.outcome {
        case .unique(let fGiven, let mGiven, let fEvidence, let mEvidence):
            var marriageIDs: [String] = []
            if let f = fEvidence { marriageIDs.append(f.id) }
            if let m = mEvidence, m.id != fEvidence?.id { marriageIDs.append(m.id) }

            // Linkage leg (a): subject's birth record carries MMN = the
            // matched bride's maiden surname.
            let brideMaiden = normalisedHint(motherMaidenSurname) ?? match.recoveredBrideMaiden
            var linkageIDs: [String] = []
            if let brideMaiden {
                linkageIDs.append(contentsOf: subjectBirthMMNLinkage(
                    brideMaiden: brideMaiden, state: state
                ))
            }
            // Linkage leg (b): census household containing the subject
            // as child of the hinted couple. Missing hints fall back to
            // the given names the unique marriage match recovered from
            // the index — deterministic, and stronger than skipping the
            // check.
            let effectiveFatherGiven = normalisedHint(fatherGiven) ?? fGiven
            let effectiveMotherGiven = normalisedHint(motherGiven) ?? mGiven
            let censusIDs = censusHouseholdLinkage(
                fatherGiven: effectiveFatherGiven,
                motherGiven: effectiveMotherGiven,
                state: state
            )
            for id in censusIDs where !linkageIDs.contains(id) {
                linkageIDs.append(id)
            }

            let coupleLabel = "\(fGiven ?? fatherGiven ?? "?") \(groomSurname) × \(mGiven ?? motherGiven ?? "?") \(brideMaiden ?? "?")"
            if !linkageIDs.isEmpty {
                return GradeResult(
                    verdict: .supported,
                    isModelAssisted: false,
                    supportingEvidence: marriageIDs + linkageIDs.filter { !marriageIDs.contains($0) },
                    contradictingEvidence: [],
                    reasoning: "Marriage \(coupleLabel) within \(window.lowerBound)–\(window.upperBound) AND subject linkage (\(linkageIDs.joined(separator: ", "))).\(resolutionNote)"
                )
            }
            return GradeResult(
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: marriageIDs,
                contradictingEvidence: [],
                reasoning: "Couple attested (marriage \(coupleLabel) within \(window.lowerBound)–\(window.upperBound)); parental link unproven — no birth-index MMN or census-household linkage yet. Levels 2–3 target the link.\(resolutionNote)"
            )
        case .ambiguous(let candidates):
            return GradeResult(
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: candidates.map(\.id),
                contradictingEvidence: [],
                reasoning: "\(candidates.count) candidate marriages match the hinted pair within \(window.lowerBound)–\(window.upperBound) — not unique; disambiguation needed.\(resolutionNote)"
            )
        case .none:
            // Table row 5 — NEVER .contradicted on absence (asymmetric
            // verdict space §4.1: the record may sit outside the
            // searched window). Contrast gradeParentMarriage, whose
            // engine-origin kind does contradict on .none — a user
            // hunch must not be refuted by a bounded search coming back
            // empty.
            return GradeResult(
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "No BMD marriage found for the hinted pair (\(fatherGiven ?? "?") \(groomSurname) × \(motherGiven ?? "?") \(motherMaidenSurname ?? "?")) within \(window.lowerBound)–\(window.upperBound). The marriage may sit outside the searched window — not treated as refutation.\(resolutionNote)"
            )
        }
    }

    // MARK: - Ladder ceiling / exhaustion (§5.15.8)

    /// Highest deficit level `.parentCandidates` dispatches — level 1
    /// (parent-marriage), 2 (MMN linkage), 3 (census household). Level
    /// ≥ 4 returns `[]` (exhausted). Single source of truth so the UX
    /// layer's "exhausted hunch" test (§5.15.8) can't drift from the
    /// ladder in `deficitQueryParentCandidates`.
    static let parentCandidatesLadderCeiling = 3

    /// A `.parentCandidates` hunch is exhausted (§5.15.8) once every
    /// ladder level has been dispatched — i.e. the NEXT level
    /// (`attempts + 1`) would exceed the ceiling and `deficitQuery`
    /// returns `[]`. State-free: the ceiling is a fixed property of the
    /// kind, so the UX layer needn't build a `ResearchState` to ask.
    /// Returns false for non-`.parentCandidates` kinds.
    static func isParentCandidatesExhausted(_ hypothesis: ResearchHypothesis) -> Bool {
        guard case .parentCandidates = hypothesis.kind else { return false }
        return hypothesis.attempts + 1 > parentCandidatesLadderCeiling
    }

    // MARK: - Deficit ladder (§5.15.3)

    /// Per-kind expansiveness ladder for `.parentCandidates`:
    ///
    ///   level 1 → parent-marriage index probe. Groom surname =
    ///             `fatherSurname ?? subject.lastName`; window = payload
    ///             window; district fan-out per scope happens in the
    ///             orchestrator (`districtCode: ""` template, same as
    ///             `.parentMarriage`). `spouseSurname` carries the MMN
    ///             hint when known — the orchestrator then dispatches
    ///             both sides; when unknown, groom-side only and the
    ///             bride's maiden surname is recovered at grading time
    ///             from the post-1912 spouseSurname column / same-page
    ///             pairing. The given-name hint is deliberately NOT put
    ///             on the wire: a literal `fatherGiven=Bob` filter would
    ///             exclude the "Robert" registrations the nickname
    ///             machinery is required to match (§5.15.3 / AC 8) —
    ///             expansion happens client-side at grading.
    ///   level 2 → MMN linkage probe: the subject's OWN birth-index
    ///             search with the mothers-maiden-name axis set to
    ///             `motherMaidenSurname ??` (bride maiden recovered at
    ///             level 1). Rides the Part I §11.4 `.birth` focus
    ///             shape (FreeBMD motherSurname param). This is the
    ///             probe that turns "the couple existed" into "the
    ///             couple are the subject's parents."
    ///   level 3 → census household probe: census years where the
    ///             subject is aged 0–15, chapman-coded to the subject's
    ///             home county, tight birth-year range.
    ///   level ≥ 4 → `[]`; ladder exhausted — archive per §5.11.
    static func deficitQueryParentCandidates(
        for hypothesis: ResearchHypothesis,
        atLevel level: Int,
        state: ResearchState
    ) -> [RecordQuery] {
        guard case .parentCandidates(
            _, let fatherSurname, _, let motherMaidenSurname, let window
        ) = hypothesis.kind else {
            return []
        }
        switch level {
        case 1:
            guard let groomSurname = parentCandidatesGroomSurname(
                fatherSurname: fatherSurname, state: state
            ) else { return [] }
            return [RecordQuery(
                surname: groomSurname,
                givenName: nil,   // nickname expansion is grading-side; see ladder doc
                recordType: .marriage,
                yearFrom: window.lowerBound,
                yearTo: window.upperBound,
                gender: nil,
                region: nil,
                sourceParams: .freeBMD(FreeBMDParams(
                    districtCode: "",   // empty → orchestrator fans out across scope
                    wildcardSurname: false,
                    motherSurname: nil,
                    spouseSurname: normalisedHint(motherMaidenSurname)
                ))
            )]
        case 2:
            let subjectSurname = (state.subject.surname ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !subjectSurname.isEmpty else { return [] }
            guard let yearFrom = state.subject.birthYearFrom ?? state.subject.birthYearTo else {
                return []   // no usable subject birth estimate — MMN axis unanchorable
            }
            let yearTo = state.subject.birthYearTo ?? yearFrom
            // MMN axis: the hint when asserted, else the bride maiden the
            // level-1 probe recovered (unique match only — an ambiguous
            // couple can't anchor the axis).
            let mmnAxis: String? = normalisedHint(motherMaidenSurname) ?? {
                guard let groomSurname = parentCandidatesGroomSurname(
                    fatherSurname: fatherSurname, state: state
                ) else { return nil }
                guard case .parentCandidates(let fg, _, let mg, _, _) = hypothesis.kind else { return nil }
                return parentCandidatesMarriageEvidence(
                    fatherGiven: fg,
                    groomSurname: groomSurname,
                    motherGiven: mg,
                    motherMaidenSurname: nil,
                    window: window,
                    state: state
                ).recoveredBrideMaiden
            }()
            guard let mmn = mmnAxis else { return [] }
            return [RecordQuery(
                surname: subjectSurname,
                givenName: state.subject.givenName,
                recordType: .birth,
                yearFrom: yearFrom,
                yearTo: yearTo,
                gender: state.subject.gender,
                region: state.subject.region,
                sourceParams: .freeBMD(FreeBMDParams(
                    districtCode: "",   // empty → orchestrator/national query
                    wildcardSurname: false,
                    motherSurname: mmn,
                    spouseSurname: nil
                )),
                motherSurname: mmn
            )]
        case 3:
            let subjectSurname = (state.subject.surname ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !subjectSurname.isEmpty else { return [] }
            guard let birthFrom = state.subject.birthYearFrom ?? state.subject.birthYearTo else {
                return []
            }
            let birthTo = state.subject.birthYearTo ?? birthFrom
            let tolerance = ScoringRules.censusAgeTolerance
            // Subject aged 0–15 at enumeration.
            let applicableYears = ScoringRules.censusYears.filter { y in
                y >= birthFrom && y <= birthTo + 15
            }
            return applicableYears.map { year in
                RecordQuery(
                    surname: subjectSurname,
                    givenName: state.subject.givenName,
                    recordType: .census,
                    yearFrom: year,
                    yearTo: year,
                    gender: state.subject.gender,
                    region: state.subject.region,
                    sourceParams: .freeCen(FreeCenParams(
                        chapmanCode: state.subject.homeChapmanCode,
                        censusYear: year,
                        birthYearRange: (birthFrom - tolerance)...(birthTo + tolerance)
                    ))
                )
            }
        default:
            return []   // Exhausted — archive per §5.11
        }
    }

    // MARK: - Shared evidence helpers

    /// Effective groom-side surname (§5.15.1 payload semantics): the
    /// hint records exactly what the user asserted; the effective value
    /// resolves at probe/grade time as `fatherSurname ?? subject.lastName`
    /// under the paternal-naming convention.
    static func parentCandidatesGroomSurname(
        fatherSurname: String?, state: ResearchState
    ) -> String? {
        if let hinted = normalisedHint(fatherSurname) { return hinted }
        let subjectSurname = (state.subject.surname ?? "")
            .trimmingCharacters(in: .whitespaces)
        return subjectSurname.isEmpty ? nil : subjectSurname
    }

    /// Marriage-side evidence for the hinted couple. Splits state's
    /// marriage records into groom-side / bride-side entries by
    /// effective surname, applies the given-name hint filters through
    /// nickname equivalence (this is where "Bob" admits "Robert"), and
    /// reunites the sides via `MarriageEnrichmentEngine.match` on the
    /// BMD reference tuple — exactly the `.parentMarriage` §6.2
    /// machinery.
    ///
    /// When `motherMaidenSurname` is nil the bride's maiden surname is
    /// unknown: bride-side entries are admitted when their recorded
    /// spouse surname points back at the groom surname (post-1912
    /// spouseSurname column, or the value same-page-couple pairing
    /// recovered pre-1912), and `recoveredBrideMaiden` reports the
    /// unique match's bride surname for level-2 anchoring.
    struct ParentCandidatesMarriageEvidence {
        let outcome: MarriageEnrichmentEngine.MatchOutcome
        /// The matched bride's maiden surname, derivable only from a
        /// `.unique` outcome (bride-side record surname, or the
        /// groom-side record's spouse column).
        let recoveredBrideMaiden: String?
    }

    static func parentCandidatesMarriageEvidence(
        fatherGiven: String?,
        groomSurname: String,
        motherGiven: String?,
        motherMaidenSurname: String?,
        window: ClosedRange<Int>,
        state: ResearchState
    ) -> ParentCandidatesMarriageEvidence {
        let groomUpper = groomSurname.uppercased()
        let mmsUpper = motherMaidenSurname?.uppercased()
        let fgHint = normalisedHint(fatherGiven)
        let mgHint = normalisedHint(motherGiven)

        var grooms: [MarriageEnrichmentEngine.MarriageEntry] = []
        var brides: [MarriageEnrichmentEngine.MarriageEntry] = []
        for scored in state.scoredRecords {
            guard scored.verdict != .impossible else { continue }
            guard case .marriage = scored.record else { continue }
            for entry in MarriageEnrichmentEngine.entries(from: [scored]) {
                let surname = entry.surname.uppercased()
                if surname == groomUpper {
                    // Groom side — given-name hint filter, nickname-expanded.
                    if let fgHint,
                       !parentCandidatesGivenNamesAgree(fgHint, entry.givenName) {
                        continue
                    }
                    grooms.append(entry)
                } else if let mmsUpper, surname == mmsUpper {
                    // Bride side under the asserted maiden surname.
                    if let mgHint,
                       !parentCandidatesGivenNamesAgree(mgHint, entry.givenName) {
                        continue
                    }
                    brides.append(entry)
                } else if mmsUpper == nil,
                          entry.spouseSurname
                            .trimmingCharacters(in: .whitespaces)
                            .uppercased() == groomUpper {
                    // Maiden surname unknown — admit bride-side entries
                    // whose spouse column points back at the groom
                    // surname; her given name is checked against the
                    // motherGiven hint (§5.15.3 level 1).
                    if let mgHint,
                       !parentCandidatesGivenNamesAgree(mgHint, entry.givenName) {
                        continue
                    }
                    brides.append(entry)
                }
            }
        }

        let outcome = MarriageEnrichmentEngine.match(
            grooms: grooms,
            brides: brides,
            yearWindow: window,
            expectedGroomSpouseSurname: motherMaidenSurname,
            expectedBrideSpouseSurname: groomSurname
        )

        var recoveredBrideMaiden: String? = nil
        if case .unique(_, _, let fEvidence, let mEvidence) = outcome {
            if let m = mEvidence, case .marriage(let rec) = m.record,
               let maiden = rec.common.surname?
                    .trimmingCharacters(in: .whitespaces), !maiden.isEmpty {
                recoveredBrideMaiden = maiden
            } else if let f = fEvidence, case .marriage(let rec) = f.record,
                      let spouse = rec.spouseName?
                            .trimmingCharacters(in: .whitespaces), !spouse.isEmpty {
                // Post-1912 groom-side entries carry the bride's maiden
                // surname in the spouse column.
                recoveredBrideMaiden = spouse
            }
        }
        return ParentCandidatesMarriageEvidence(
            outcome: outcome,
            recoveredBrideMaiden: recoveredBrideMaiden
        )
    }

    /// Linkage leg (a): IDs of subject-plausible birth records whose
    /// MMN matches the matched bride's maiden surname. Subject-plausible
    /// = surname matches the subject's and (when both are known) the
    /// record year sits inside the subject's birth window ± tolerance.
    static func subjectBirthMMNLinkage(
        brideMaiden: String, state: ResearchState
    ) -> [String] {
        let brideUpper = brideMaiden.uppercased()
        let subjectSurname = (state.subject.surname ?? "")
            .trimmingCharacters(in: .whitespaces).uppercased()
        var ids: [String] = []
        for scored in state.scoredRecords {
            guard scored.verdict != .impossible else { continue }
            guard case .birth(let birth) = scored.record else { continue }
            guard let mmn = birth.mothersMaidenName?
                    .trimmingCharacters(in: .whitespaces), !mmn.isEmpty
            else { continue }
            if !subjectSurname.isEmpty {
                let recordSurname = (birth.common.surname ?? "")
                    .trimmingCharacters(in: .whitespaces).uppercased()
                guard recordSurname == subjectSurname else { continue }
            }
            if let recordYear = birth.birthYear,
               let from = state.subject.birthYearFrom,
               let to = state.subject.birthYearTo {
                let tolerance = ScoringRules.birthYearTolerance
                guard recordYear >= from - tolerance, recordYear <= to + tolerance else { continue }
            }
            guard mmn.uppercased() == brideUpper else { continue }
            ids.append(scored.id)
        }
        return ids
    }

    /// Linkage leg (b): IDs of census records whose household contains
    /// the subject as a child of the hinted couple (Part I §18.8 shape):
    /// head given name ≈ fatherGiven, wife given name ≈ motherGiven
    /// (both nickname-expanded), surname = subject's. Requires the
    /// subject's given name (an anonymous child can't be linked) and at
    /// least one couple given name to discriminate on.
    static func censusHouseholdLinkage(
        fatherGiven: String?,
        motherGiven: String?,
        state: ResearchState
    ) -> [String] {
        let fgReq = normalisedHint(fatherGiven)
        let mgReq = normalisedHint(motherGiven)
        guard fgReq != nil || mgReq != nil else { return [] }
        guard let subjectGiven = normalisedHint(state.subject.givenName) else { return [] }
        let subjectSurname = (state.subject.surname ?? "")
            .trimmingCharacters(in: .whitespaces).uppercased()

        var ids: [String] = []
        for scored in state.scoredRecords {
            guard scored.verdict != .impossible else { continue }
            guard case .census(let census) = scored.record else { continue }
            guard let household = census.household, !household.isEmpty else { continue }

            // Subject present as a child. Household member names are
            // display strings ("Darryl Cauldwell" or bare given name) —
            // compare given (first token) via nickname machinery and
            // surname (last token, when present) literally.
            let subjectAsChild = household.contains { member in
                guard isChildRelationship(member.relationship) else { return false }
                guard memberGivenName(member.name).map({
                    parentCandidatesGivenNamesAgree(subjectGiven, $0)
                }) == true else { return false }
                if !subjectSurname.isEmpty,
                   let memberSurname = memberSurname(member.name) {
                    return memberSurname == subjectSurname
                }
                return true
            }
            guard subjectAsChild else { continue }

            // Head of household — surname must be the subject's
            // (§5.15.3: "surname = subject's"), given name ≈ fatherGiven.
            guard let head = household.first(where: {
                $0.relationship.lowercased().contains("head")
            }) else { continue }
            if !subjectSurname.isEmpty,
               let headSurname = memberSurname(head.name),
               headSurname != subjectSurname {
                continue
            }
            if let fgReq {
                guard let headGiven = memberGivenName(head.name),
                      parentCandidatesGivenNamesAgree(fgReq, headGiven)
                else { continue }
            }

            // Head's spouse — given name ≈ motherGiven.
            if let mgReq {
                guard let wife = household.first(where: {
                    $0.relationship.lowercased().contains("wife")
                }), let wifeGiven = memberGivenName(wife.name),
                      parentCandidatesGivenNamesAgree(mgReq, wifeGiven)
                else { continue }
            }

            ids.append(scored.id)
        }
        return ids
    }

    /// Confirmed-parent conflict (§5.15.4 table row 4). A parent edge
    /// whose profile carries a field_sources-backed given name that
    /// disagrees with the corresponding hint beyond nickname
    /// equivalence. "Confirmed" = the `firstName` field has at least
    /// one `FieldSource` — a bare unsourced placeholder name does not
    /// refute a hunch.
    struct ConfirmedParentConflict {
        let parentID: String
        let role: String       // "father" / "mother"
        let hint: String
        let confirmed: String
    }

    static func confirmedParentGivenNameConflict(
        fatherGiven: String?,
        motherGiven: String?,
        subjectProfileID: String,
        snapshot: FamilyGraphSnapshot
    ) -> ConfirmedParentConflict? {
        let parents = snapshot.parentsOf(subjectProfileID)
        let checks: [(hint: String?, gender: Gender, role: String)] = [
            (fatherGiven, .male, "father"),
            (motherGiven, .female, "mother"),
        ]
        for (hintOpt, gender, role) in checks {
            guard let hint = normalisedHint(hintOpt) else { continue }
            for parent in parents where parent.gender == gender {
                guard let confirmed = normalisedHint(parent.firstName),
                      let backing = parent.sources[.firstName], !backing.isEmpty
                else { continue }
                if !parentCandidatesGivenNamesAgree(hint, confirmed) {
                    return ConfirmedParentConflict(
                        parentID: parent.id, role: role,
                        hint: hint, confirmed: confirmed
                    )
                }
            }
        }
        return nil
    }

    // MARK: - Private helpers

    /// The subject's identity-resolved birth record, if resolution
    /// succeeds — same resolver call `generateParentMarriage` makes.
    private static func identityResolvedBirthRecord(
        state: ResearchState, snapshot: FamilyGraphSnapshot
    ) -> ScoredRecord? {
        guard let profileID = state.subject.profileID else { return nil }
        let birthFacts = state.scoredRecords.filter { scored in
            guard scored.verdict == .fact else { return false }
            if case .birth = scored.record { return true }
            return false
        }
        guard !birthFacts.isEmpty else { return nil }
        let geoHypotheses = GeographicHypothesisGenerator.inferDistricts(
            for: profileID,
            snapshot: snapshot,
            eventYear: state.subject.birthYearFrom
        )
        let identity = SubjectIdentityResolver.resolve(
            candidateBirthFacts: birthFacts, hypotheses: geoHypotheses
        )
        guard case .resolved(let recordID, _) = identity else { return nil }
        return state.scoredRecords.first { $0.id == recordID }
    }

    /// Trim + empty→nil normalisation, mirroring the seed service's
    /// hint handling: an empty string is not an assertion.
    private static func normalisedHint(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Child-shaped census relationship strings.
    private static func isChildRelationship(_ relationship: String) -> Bool {
        let rel = relationship.lowercased()
        return rel.contains("son") || rel.contains("daughter") || rel.contains("child")
    }

    /// First token of a household member's display name — the given name.
    private static func memberGivenName(_ name: String) -> String? {
        let tokens = name.split(separator: " ")
        guard let first = tokens.first else { return nil }
        return String(first)
    }

    /// Last token of a multi-token member name, uppercased — the
    /// surname. Single-token names return nil (given name only; the
    /// enumerator omitted the shared household surname).
    private static func memberSurname(_ name: String) -> String? {
        let tokens = name.split(separator: " ")
        guard tokens.count > 1, let last = tokens.last else { return nil }
        return String(last).uppercased()
    }
}
