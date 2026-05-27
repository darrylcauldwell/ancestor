import Foundation

/// `.subjectSpouseMarriage(subjectSurname, spouseSurname, childYearWindow)`
/// kind — generator, grader, and expansiveness ladder. The pre-iteration
/// strategy from RESEARCH_PIPELINE_SPEC §5.14: when the subject is a thin
/// placeholder (surname only, no given name) and at least one linked child
/// carries an MMN anchor, the marriage index — not the birth index — is
/// the way back to the given name. Reuses `MarriageEnrichmentEngine.match`
/// for the two-sided BMD reunion (same machinery as `.parentMarriage`).
///
/// **Slice 1 scope.** Detection + probe + grading land here. Write-back
/// of the recovered given name to `state.subject.givenName` /
/// `pending_facts` is slice 2; the grader's `.supported` verdict records
/// the recoverable name in `reasoning` but does not mutate state.
nonisolated extension HypothesisEngine {

    // MARK: - Window defaults (§5.14.3)

    /// Window default — mirrors `.parentMarriage`. The earliest child's
    /// birth year minus 30 (parents typically marry within 30 years of
    /// first birth) up to + 1 (forgives a same-quarter overlap between
    /// marriage and first birth).
    private static let subjectSpouseMarriageWindowLowerOffset = -30
    private static let subjectSpouseMarriageWindowUpperOffset = 1

    // MARK: - Gender resolution (§5.14.4 ladder)

    /// Outcome of the four-rule precedence ladder. Carries the resolved
    /// gender (when one was reached) and the rule that fired so the
    /// hypothesis's `reasoning` can record provenance per spec.
    enum SubjectSpouseGenderResolution: Sendable, Equatable {
        case explicit(Gender)
        case surnamePattern(Gender)
        case topology(Gender)
        case unresolved

        var resolvedGender: Gender? {
            switch self {
            case .explicit(let g), .surnamePattern(let g), .topology(let g):
                return g
            case .unresolved:
                return nil
            }
        }

        var reasoningFragment: String {
            switch self {
            case .explicit(let g):
                return "gender \(g.rawValue) (explicit)"
            case .surnamePattern(let g):
                return "gender \(g.rawValue) (inferred from surname pattern across linked children)"
            case .topology(let g):
                return "gender \(g.rawValue) (inferred from tree topology — opposite-gender parent slot filled)"
            case .unresolved:
                return "gender unresolved (precedence ladder fell through; write-back blocked)"
            }
        }
    }

    /// Resolve the subject's gender per §5.14.4 precedence ladder:
    /// explicit > surname-pattern > topology > unresolved.
    /// Pure function over snapshot + the resolved per-child MMN map.
    static func resolveSubjectSpouseGender(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot,
        childMMNs: [String: String] = [:]
    ) -> SubjectSpouseGenderResolution {
        // Rule 1: explicit.
        if let g = state.subject.gender, g == .male || g == .female {
            return .explicit(g)
        }

        guard let subjectID = state.subject.profileID,
              let raw = state.subject.surname?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty
        else { return .unresolved }
        let upperSubjectSurname = raw.uppercased()
        let children = snapshot.childrenOf(subjectID)

        // Rule 2: surname-pattern across children. Requires BOTH child
        // fields (surname and MMN) to be non-empty — the rule
        // distinguishes father (surname matches but MMN doesn't) from
        // mother (MMN matches but surname doesn't); without an MMN we
        // can't tell, so fall through to rule 3 instead of guessing.
        // Mixed signals across children also fall through (§5.14.10
        // child-derived-signal-disagreement row).
        var surnameSignals: Set<Gender> = []
        for child in children {
            let childSurname = (child.lastName ?? "")
                .trimmingCharacters(in: .whitespaces).uppercased()
            let profileTrim: String? = child.mothersMaidenName?
                .trimmingCharacters(in: .whitespaces)
            let profileMMN: String? = profileTrim.flatMap { $0.isEmpty ? nil : $0 }
            let fallbackTrim: String? = childMMNs[child.id]?
                .trimmingCharacters(in: .whitespaces)
            let fallbackMMN: String? = fallbackTrim.flatMap { $0.isEmpty ? nil : $0 }
            let childMMN = (profileMMN ?? fallbackMMN ?? "").uppercased()

            // No discriminator available — both child fields needed
            // for the rule to fire.
            guard !childSurname.isEmpty, !childMMN.isEmpty else { continue }

            let subjectMatchesChildSurname = upperSubjectSurname == childSurname
            let subjectMatchesMMN = upperSubjectSurname == childMMN

            if subjectMatchesChildSurname && !subjectMatchesMMN {
                surnameSignals.insert(.male)
            } else if subjectMatchesMMN && !subjectMatchesChildSurname {
                surnameSignals.insert(.female)
            }
            // Both match (same-surname couple) or neither matches → no
            // surname-pattern signal for this child.
        }
        if surnameSignals.count == 1 {
            return .surnamePattern(surnameSignals.first!)
        }

        // Rule 3: topology — opposite-gender parent slot already filled
        // by a profile *other than* the subject.
        var topologySignals: Set<Gender> = []
        for child in children {
            let parents = snapshot.parentsOf(child.id)
            for parent in parents where parent.id != subjectID {
                guard let parentGender = parent.gender else { continue }
                switch parentGender {
                case .male:   topologySignals.insert(.female)
                case .female: topologySignals.insert(.male)
                case .other, .unknown: continue
                }
            }
        }
        if topologySignals.count == 1 {
            return .topology(topologySignals.first!)
        }

        // Rule 4: refuse.
        return .unresolved
    }

    // MARK: - Generator (§5.14.1 + §5.14.3)

    /// Emit one `.subjectSpouseMarriage` per distinct uppercased MMN
    /// across the subject's linked children (Q3 — same-MMN children
    /// collapse into one hypothesis; Q4 — different-MMN children seed
    /// separate hypotheses).
    ///
    /// `childMMNs` is the pre-resolved per-child MMN map sourced by the
    /// pipeline orchestrator (`runSubjectSpouseMarriageFlow`) — first
    /// the child's `Profile.mothersMaidenName`, then a fallback to the
    /// child's persisted research records (Q2 Option B). Generator-
    /// internal logic also reads `Profile.mothersMaidenName` directly
    /// for callers that bypass the orchestrator (the central switch
    /// passes `[:]`).
    static func generateSubjectSpouseMarriage(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot,
        childMMNs: [String: String] = [:]
    ) -> [ResearchHypothesis] {
        // Trigger conditions (§5.14.1).
        guard let subjectID = state.subject.profileID else { return [] }
        let subjectSurname = state.subject.surname?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !subjectSurname.isEmpty else { return [] }
        let trimmedGiven = (state.subject.givenName ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard trimmedGiven.isEmpty else { return [] }

        let children = snapshot.childrenOf(subjectID)
        guard !children.isEmpty else { return [] }

        // Group children by uppercased (groomSurname, brideSurname) pair —
        // one hypothesis per distinct marriage. The pair is derived per
        // child: groomSurname = child.lastName (father's surname under
        // paternal-naming convention), brideSurname = child.MMN (mother's
        // maiden). Both required; skip the child if either is missing.
        struct PairAccumulator {
            var groomDisplay: String
            var brideDisplay: String
            var childIDs: [String]
            var birthYears: [Int]
            var profileFieldProvenance: Bool
        }
        var byPair: [String: PairAccumulator] = [:]

        for child in children {
            // Profile field is primary; childMMNs fallback (Q2 Option B).
            let profileField = child.mothersMaidenName?
                .trimmingCharacters(in: .whitespaces)
            let usedFromProfileField = (profileField?.isEmpty == false)
            let resolvedMMN = (profileField?.isEmpty == false ? profileField : nil)
                ?? childMMNs[child.id]?.trimmingCharacters(in: .whitespaces)
            guard let brideSurname = resolvedMMN, !brideSurname.isEmpty else { continue }

            let childSurname = (child.lastName ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !childSurname.isEmpty else { continue }
            let groomSurname = childSurname

            let pairKey = "\(groomSurname.uppercased())x\(brideSurname.uppercased())"
            var acc = byPair[pairKey] ?? PairAccumulator(
                groomDisplay: groomSurname,
                brideDisplay: brideSurname,
                childIDs: [],
                birthYears: [],
                profileFieldProvenance: usedFromProfileField
            )
            acc.childIDs.append(child.id)
            if let year = child.birthDate?.bestYear {
                acc.birthYears.append(year)
            }
            // Provenance flag stays true if any child contributed via
            // profile field; only false when *every* child for this pair
            // came via the fallback.
            acc.profileFieldProvenance = acc.profileFieldProvenance || usedFromProfileField
            byPair[pairKey] = acc
        }
        guard !byPair.isEmpty else { return [] }

        let now = Date()
        let genderRes = resolveSubjectSpouseGender(
            state: state, snapshot: snapshot, childMMNs: childMMNs
        )

        var hypotheses: [ResearchHypothesis] = []
        for (_, acc) in byPair {
            // Skip pairs that don't actually involve the subject —
            // defensive guard. The subject must match groom or bride
            // (case-insensitive) to be a valid anchor.
            let upperSubject = subjectSurname.uppercased()
            let upperGroom = acc.groomDisplay.uppercased()
            let upperBride = acc.brideDisplay.uppercased()
            guard upperSubject == upperGroom || upperSubject == upperBride else {
                continue
            }

            // Window: use earliest child's birth year if any child has
            // one, else fall back to the subject's birth-year window.
            // The strategy is only meaningful when *some* anchor year
            // exists — otherwise we can't put the marriage in time.
            let yearAnchor: Int? = acc.birthYears.min()
                ?? state.subject.birthYearFrom
                ?? state.subject.birthYearTo
            guard let anchorYear = yearAnchor else { continue }
            let lower = anchorYear + subjectSpouseMarriageWindowLowerOffset
            let upper = anchorYear + subjectSpouseMarriageWindowUpperOffset
            let window = lower...upper

            let kind = HypothesisKind.subjectSpouseMarriage(
                groomSurname: acc.groomDisplay,
                brideSurname: acc.brideDisplay,
                childYearWindow: window
            )
            let provenance = acc.profileFieldProvenance
                ? "child profile field"
                : "child research records"
            let childCount = acc.childIDs.count
            let plural = childCount == 1 ? "child" : "children"
            let reasoning = "Pending grading — anchored by \(childCount) \(plural); marriage pair \(acc.groomDisplay) × \(acc.brideDisplay) (\(provenance)); \(genderRes.reasoningFragment)."

            hypotheses.append(ResearchHypothesis(
                id: kind.identityKey(subjectProfileID: subjectID),
                subjectProfileID: subjectID,
                kind: kind,
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: acc.childIDs,
                contradictingEvidence: [],
                reasoning: reasoning,
                createdAt: now,
                lastTestedAt: now,
                attempts: 0,
                history: []
            ))
        }
        return hypotheses
    }

    // MARK: - Grader (§5.14.4)

    /// Grade a `.subjectSpouseMarriage` by reading marriage records from
    /// state, splitting into groom-side (BMD entries indexed under
    /// groomSurname) and bride-side (entries indexed under brideSurname),
    /// and running `MarriageEnrichmentEngine.match`. The labels are
    /// BMD roles, not subject-vs-spouse — the subject's role (groom or
    /// bride) is decided at write-back time by the gender ladder.
    ///
    /// `.supported`     when match returns `.unique` — one BMD marriage
    ///                  attests the pair. `supportingEvidence` lists the
    ///                  one or two marriage record IDs.
    /// `.inconclusive`  when `.ambiguous` — `supportingEvidence` lists
    ///                  all candidate marriage IDs for §5.11 disambiguation.
    /// `.contradicted`  when `.none` — searched in the window, found
    ///                  no plausible marriage.
    static func gradeSubjectSpouseMarriage(
        _ hypothesis: ResearchHypothesis,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> GradeResult {
        guard case .subjectSpouseMarriage(let groomSurname, let brideSurname, let window) = hypothesis.kind else {
            return .inconclusiveStub
        }
        _ = snapshot
        let upperGroom = groomSurname.uppercased()
        let upperBride = brideSurname.uppercased()

        var grooms: [MarriageEnrichmentEngine.MarriageEntry] = []
        var brides: [MarriageEnrichmentEngine.MarriageEntry] = []
        for scored in state.scoredRecords {
            guard scored.verdict != .impossible else { continue }
            guard case .marriage = scored.record else { continue }
            let entries = MarriageEnrichmentEngine.entries(from: [scored])
            for entry in entries {
                let surname = entry.surname.uppercased()
                if surname == upperGroom {
                    grooms.append(entry)
                } else if surname == upperBride {
                    brides.append(entry)
                }
            }
        }

        let outcome = MarriageEnrichmentEngine.match(
            grooms: grooms,
            brides: brides,
            yearWindow: window,
            expectedGroomSpouseSurname: brideSurname,
            expectedBrideSpouseSurname: groomSurname
        )
        switch outcome {
        case .unique(let groomGiven, let brideGiven, let groomEv, let brideEv):
            var evidenceIDs: [String] = []
            if let g = groomEv { evidenceIDs.append(g.id) }
            if let b = brideEv, b.id != groomEv?.id { evidenceIDs.append(b.id) }
            let gLabel = groomGiven ?? "?"
            let bLabel = brideGiven ?? "?"
            return GradeResult(
                verdict: .supported,
                isModelAssisted: false,
                supportingEvidence: evidenceIDs,
                contradictingEvidence: [],
                reasoning: "Marriage \(gLabel) \(groomSurname) × \(bLabel) \(brideSurname) within \(window.lowerBound)–\(window.upperBound). Subject given name recoverable from this marriage."
            )
        case .ambiguous(let candidates):
            return GradeResult(
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: candidates.map(\.id),
                contradictingEvidence: [],
                reasoning: "\(candidates.count) candidate marriages found for \(groomSurname) × \(brideSurname) within \(window.lowerBound)–\(window.upperBound) — disambiguation needed (§5.11)."
            )
        case .none:
            return GradeResult(
                verdict: .contradicted,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "No BMD marriage found linking \(groomSurname) × \(brideSurname) within \(window.lowerBound)–\(window.upperBound)."
            )
        }
    }

    // MARK: - Write-back recovery (§5.14.4 — slice 2 support)

    /// The (groom-side, bride-side) given names recovered from a
    /// `.supported` `.subjectSpouseMarriage` hypothesis, plus enough
    /// citation context to build a `pending_facts` row. The grader's
    /// reasoning text carries these names as a string for the human
    /// reader; this helper exposes them programmatically for the
    /// orchestrator's write-back path.
    struct SubjectSpouseRecovery: Sendable, Equatable {
        let groomGiven: String?
        let brideGiven: String?
        let marriageRecordIDs: [String]
        let primarySourceURL: String?
        let primarySourceID: String?
        let primarySourceTitle: String?
        /// Concrete marriage-year from the matched record (not the
        /// hypothesis window). Lets Triage report "1882 Q3 Belper"
        /// rather than the broader search window.
        let matchedYear: Int?
        let matchedQuarter: String?
        let matchedDistrict: String?
    }

    /// Extract recovered names from a `.supported` hypothesis by reading
    /// its `supportingEvidence` IDs out of `scoredRecords`. Takes the
    /// records directly so both the pipeline (`state.scoredRecords`) and
    /// the UI (`result.allScoredRecords`) can call this helper without
    /// constructing a fresh `ResearchState`.
    ///
    /// Returns nil for non-supported hypotheses or when no marriage
    /// record was found in the supplied list (defensive — shouldn't
    /// happen since `.supported` requires evidence to have been
    /// collected).
    ///
    /// Side identification matches the grader's gating in
    /// `gradeSubjectSpouseMarriage`: groom-side surname == subjectSurname,
    /// bride-side surname == spouseSurname. The first non-nil given on
    /// each side wins.
    static func extractSubjectSpouseRecovery(
        from hypothesis: ResearchHypothesis,
        scoredRecords: [ScoredRecord]
    ) -> SubjectSpouseRecovery? {
        guard hypothesis.isDeterministicallySupported,
              case .subjectSpouseMarriage(let groomSurname, let brideSurname, _) = hypothesis.kind
        else { return nil }
        let upperGroom = groomSurname.uppercased()
        let upperBride = brideSurname.uppercased()

        var groomGiven: String? = nil
        var brideGiven: String? = nil
        var primaryURL: String? = nil
        var primaryID: String? = nil
        var primaryTitle: String? = nil
        var matchedYear: Int? = nil
        var matchedQuarter: String? = nil
        var matchedDistrict: String? = nil

        // Dictionary lookup so we don't repeat linear scans per
        // supporting-evidence ID.
        let byID = Dictionary(uniqueKeysWithValues: scoredRecords.map { ($0.id, $0) })
        for id in hypothesis.supportingEvidence {
            guard let scored = byID[id],
                  case .marriage(let marriage) = scored.record else { continue }
            let surname = (marriage.common.surname ?? "").uppercased()
            let trimmedGiven: String? = marriage.common.givenName?
                .trimmingCharacters(in: .whitespaces)
            let given: String? = trimmedGiven.flatMap { $0.isEmpty ? nil : $0 }

            // Label by BMD role: entries indexed under groomSurname are
            // groom-side and carry the groom's given name; entries
            // indexed under brideSurname are bride-side. This is true
            // regardless of which one matches the subject's stored
            // surname — gender resolution decides which side IS the
            // subject at write-back time.
            if surname == upperGroom, groomGiven == nil, let g = given {
                groomGiven = g
            } else if surname == upperBride, brideGiven == nil, let g = given {
                brideGiven = g
            }
            if primaryURL == nil, let url = marriage.common.detailURL, !url.isEmpty {
                primaryURL = url
                primaryID = marriage.common.sourceID
                primaryTitle = marriage.common.name
            }
            // First-record-wins for the matched-marriage detail. The
            // BMD index entries paired by reference tuple all carry the
            // same year/quarter/district, so the first non-nil values
            // suffice for the Triage banner.
            if matchedYear == nil { matchedYear = marriage.marriageYear }
            if matchedQuarter == nil, let q = marriage.quarter, !q.isEmpty { matchedQuarter = q }
            if matchedDistrict == nil, let d = marriage.district, !d.isEmpty { matchedDistrict = d }
        }

        if groomGiven == nil && brideGiven == nil { return nil }
        return SubjectSpouseRecovery(
            groomGiven: groomGiven,
            brideGiven: brideGiven,
            marriageRecordIDs: hypothesis.supportingEvidence,
            primarySourceURL: primaryURL,
            primarySourceID: primaryID,
            primarySourceTitle: primaryTitle,
            matchedYear: matchedYear,
            matchedQuarter: matchedQuarter,
            matchedDistrict: matchedDistrict
        )
    }

    /// Pick the gender-appropriate given name from a recovery, per the
    /// §5.14.4 routing table. Returns nil when the recovery has no
    /// usable name on the side gender-routing selects (e.g. female
    /// subject but bride-side wasn't matched).
    static func pickSubjectGivenName(
        from recovery: SubjectSpouseRecovery,
        resolvedGender: Gender
    ) -> String? {
        switch resolvedGender {
        case .male:   return recovery.groomGiven
        case .female: return recovery.brideGiven
        case .other, .unknown: return nil
        }
    }

    /// Cross-hypothesis reconciliation result per §5.14.4. Pure
    /// function output: the pipeline applies the side effects
    /// (state.subject mutation, pending-fact emission); this struct
    /// just says what they should be.
    enum SubjectSpouseWritebackDecision: Sendable, Equatable {
        /// No supported rows, or no gender-routed name across any
        /// supported row, or supported rows disagree on the name.
        /// `reason` is a one-line audit string.
        case noWriteback(reason: String)
        /// Write back this name. `citedMarriageRecordIDs` is the union
        /// of every contributing hypothesis's supporting evidence
        /// (deduped, order-preserved); `primarySourceURL`/title come
        /// from the first contribution that carried one. `pair` and
        /// `surname` are the surname pair + subject surname for
        /// human-readable pending-fact reasoning.
        case applyName(
            name: String,
            groomSurnameForLabel: String,
            brideSurnameForLabel: String,
            citedMarriageRecordIDs: [String],
            primarySourceURL: String?,
            primarySourceTitle: String?
        )
    }

    /// Reconcile across `.supported` `.subjectSpouseMarriage` hypotheses
    /// to decide write-back. Implements the four-case rule from
    /// §5.14.4:
    ///   - zero supported → `.noWriteback`
    ///   - one supported, gender-routed name extractable → `.applyName`
    ///   - multi supported, agree on name → `.applyName` citing all
    ///   - multi supported, disagree → `.noWriteback`
    /// Also handles the edge cases of "supported but no gender-routed
    /// name" (e.g. only the opposite-gender side reported) by returning
    /// `.noWriteback` with a descriptive reason.
    ///
    /// Pure over inputs — no I/O, no mutation. The pipeline calls this
    /// and applies the side effects.
    static func reconcileSubjectSpouseWriteback(
        hypotheses: [ResearchHypothesis],
        scoredRecords: [ScoredRecord],
        resolvedGender: Gender?
    ) -> SubjectSpouseWritebackDecision {
        let supported = hypotheses.filter { h in
            guard case .subjectSpouseMarriage = h.kind else { return false }
            return h.isDeterministicallySupported
        }
        guard !supported.isEmpty else {
            return .noWriteback(reason: "no .supported .subjectSpouseMarriage rows")
        }
        guard let g = resolvedGender else {
            return .noWriteback(reason: "subject gender unresolved")
        }

        struct Contribution {
            let pickedName: String
            let recovery: SubjectSpouseRecovery
            let groomSurname: String
            let brideSurname: String
        }
        var contributions: [Contribution] = []
        for h in supported {
            guard case .subjectSpouseMarriage(let groom, let bride, _) = h.kind,
                  let recovery = extractSubjectSpouseRecovery(
                    from: h, scoredRecords: scoredRecords
                  ),
                  let picked = pickSubjectGivenName(from: recovery, resolvedGender: g),
                  !picked.isEmpty
            else { continue }
            contributions.append(Contribution(
                pickedName: picked,
                recovery: recovery,
                groomSurname: groom,
                brideSurname: bride
            ))
        }
        guard !contributions.isEmpty else {
            return .noWriteback(reason: "supported rows carried no gender-routed given name")
        }
        // Case-insensitive equality so transcriber drift between two
        // marriage records doesn't fragment a genuine agreement.
        let distinct = Set(contributions.map { $0.pickedName.lowercased() })
        guard distinct.count == 1 else {
            let names = contributions.map(\.pickedName).joined(separator: ", ")
            return .noWriteback(reason: "supported rows disagree on recovered name [\(names)]")
        }
        let first = contributions.first!
        // Union of cited marriage record IDs across contributions —
        // dedupe in case the same record was cited by multiple rows
        // (shouldn't happen with Q3 dedup but defensive).
        var seenIDs: Set<String> = []
        var orderedIDs: [String] = []
        for c in contributions {
            for id in c.recovery.marriageRecordIDs where !seenIDs.contains(id) {
                seenIDs.insert(id)
                orderedIDs.append(id)
            }
        }
        // Primary source from the first contribution that carried a URL;
        // fall back to the first contribution unconditionally so the
        // pending fact at least has SOMETHING to cite.
        let primary = contributions.first { $0.recovery.primarySourceURL != nil }
            ?? first
        return .applyName(
            name: first.pickedName,
            groomSurnameForLabel: first.groomSurname,
            brideSurnameForLabel: first.brideSurname,
            citedMarriageRecordIDs: orderedIDs,
            primarySourceURL: primary.recovery.primarySourceURL,
            primarySourceTitle: primary.recovery.primarySourceTitle
        )
    }

    // MARK: - Expansiveness ladder (§5.14.9)

    /// Expansiveness ladder for `.subjectSpouseMarriage`.
    ///
    ///   level 1 → original window from the hypothesis payload
    ///             (`min(child.birthYear) − 30 … + 1`). The first-pass
    ///             dispatch sets `attempts: 1`.
    ///   level 2 → widen window by ±10 years (mirrors `.parentMarriage`
    ///             level 2 — picks up marriages outside the typical
    ///             parent-age range).
    ///   level ≥ 3 → nil. T31 (§5.7) revisits the ceiling once the eval
    ///               harness gives a unique-match-rate baseline.
    static func deficitQuerySubjectSpouseMarriage(
        for hypothesis: ResearchHypothesis,
        atLevel level: Int,
        state: ResearchState
    ) -> [RecordQuery] {
        guard case .subjectSpouseMarriage(let groomSurname, let brideSurname, let window) = hypothesis.kind else {
            return []
        }
        _ = state
        let (yearFrom, yearTo): (Int, Int)
        switch level {
        case 1:
            yearFrom = window.lowerBound
            yearTo = window.upperBound
        case 2:
            yearFrom = window.lowerBound - 10
            yearTo = window.upperBound + 10
        default:
            return []   // Exhausted — T31 revisits the ceiling later
        }
        // Single deficit-query (groom-side); the orchestrator's
        // `dispatchHypothesisDeficitQuery` switch fans this out into a
        // groom-side + bride-side pair across the scope's districts.
        return [RecordQuery(
            surname: groomSurname,
            givenName: nil,
            recordType: .marriage,
            yearFrom: yearFrom,
            yearTo: yearTo,
            gender: nil,
            region: nil,
            sourceParams: .freeBMD(FreeBMDParams(
                districtCode: "",   // empty → orchestrator fans out across scope
                wildcardSurname: false,
                motherSurname: nil,
                spouseSurname: brideSurname
            ))
        )]
    }
}
