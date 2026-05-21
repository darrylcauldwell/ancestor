import Foundation

/// `.parentMarriage(motherSurname, fatherSurname, windowYears)` kind —
/// generator, grader, and expansiveness ladder. Wraps
/// `MarriageEnrichmentEngine.match` (the BMD index returns each
/// marriage twice — groom-indexed and bride-indexed — and we reunite
/// them by `(year, quarter, district, vol, page)`).
///
/// **T12-parent Phase 1.** Generator walks `.parentInferred` pairs
/// from state and emits one `.parentMarriage` per (mother, father)
/// pair sharing the same subject. Grader reads marriage records from
/// `state.scoredRecords` (placed there by the legacy
/// `enrichParentsWithMarriage` path during Phase 1; Phase 2's
/// orchestration will dispatch the deficit query itself once the
/// legacy path is deleted).
///
/// `HypothesisEngine.reconcileParentMarriages` (in
/// `HypothesisEngine.swift`) walks supported `.parentMarriage`
/// hypotheses post-grading and writes their marriage record IDs +
/// given-name reasoning back onto the matching `.parentInferred`
/// hypotheses — the V2 spec §5.2.1 cross-reference mechanic.
nonisolated extension HypothesisEngine {

    /// Window default — mirrors `enrichParentsWithMarriage` today
    /// (subject birth − 30 to + 1).
    private static let parentMarriageWindowLowerOffset = -30
    private static let parentMarriageWindowUpperOffset = 1

    /// Emit one `.parentMarriage` per (mother, father) parent-pair
    /// derived from the subject's BMD birth records, subject to the
    /// search-storm gating policy (V2 spec §5.2.1 — same rules as the
    /// legacy `enrichParentsWithMarriage`):
    ///
    ///   • Both parents already linked → only emit for pairs whose
    ///     surnames match the linked parents (typically one).
    ///   • Else identity resolved → only emit for the pair derived
    ///     from the resolved birth record's MMN.
    ///   • Else → emit nothing. Without identity / linked-parents
    ///     anchor, fanning out marriage queries across every MMN is
    ///     mostly noise — a non-specific subject like "Jennifer Holmes
    ///     1948" attracts dozens of MMNs (Brooks, Hicks, Sambrook,
    ///     Dabbs, …) and each spawns a multi-district query fan-out.
    static func generateParentMarriage(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> [ResearchHypothesis] {
        guard let subjectProfileID = state.subject.profileID else { return [] }
        let subjectSurname = state.subject.surname?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !subjectSurname.isEmpty else { return [] }

        guard let subjectBirthYear = state.subject.birthYearFrom
                ?? state.subject.birthYearTo
        else { return [] }
        let lower = subjectBirthYear + parentMarriageWindowLowerOffset
        let upper = subjectBirthYear + parentMarriageWindowUpperOffset
        let window = lower...upper

        // Gating step 1: linked parents in the tree (case-insensitive
        // surnames so transcriber drift doesn't break the gate).
        let parents = snapshot.parentsOf(subjectProfileID)
        let knownFatherSurname = parents
            .first(where: { $0.gender == .male })?.lastName?
            .trimmingCharacters(in: .whitespaces)
        let knownMotherSurname = parents
            .first(where: { $0.gender == .female })?.lastName?
            .trimmingCharacters(in: .whitespaces)
        let bothParentsLinked = !(knownFatherSurname?.isEmpty ?? true)
            && !(knownMotherSurname?.isEmpty ?? true)

        // Gating step 2: subject identity resolution. Cheaper to
        // compute up front than per pair — same call SubjectIdentityResolver
        // makes in legacy.
        let birthFacts = state.scoredRecords.filter { scored in
            guard scored.verdict == .fact else { return false }
            if case .birth = scored.record { return true }
            return false
        }
        let geoHypotheses: [GeographicHypothesis] = {
            GeographicHypothesisGenerator.inferDistricts(
                for: subjectProfileID,
                snapshot: snapshot,
                eventYear: state.subject.birthYearFrom
            )
        }()
        let identity = SubjectIdentityResolver.resolve(
            candidateBirthFacts: birthFacts, hypotheses: geoHypotheses
        )
        let resolvedBirthRecordID: String? = {
            if case .resolved(let id, _) = identity { return id }
            return nil
        }()

        // No anchor → no marriage hypotheses. The legacy
        // `enrichParentsWithMarriage` returned `(proposals, [])`
        // here; the framework emits no `.parentMarriage` instead.
        guard bothParentsLinked || resolvedBirthRecordID != nil else {
            return []
        }

        var seenMMNs: Set<String> = []
        var results: [ResearchHypothesis] = []
        let now = Date()
        for scored in state.scoredRecords {
            guard scored.verdict != .impossible else { continue }
            guard case .birth(let birth) = scored.record else { continue }
            guard let mmn = birth.mothersMaidenName?
                .trimmingCharacters(in: .whitespaces), !mmn.isEmpty
            else { continue }
            // Dedup by upper-cased MMN — different records may carry
            // the same MMN with case variation; identityKey already
            // upper-cases, but dedup at generation keeps the array
            // tidy.
            let mmnKey = mmn.uppercased()
            guard seenMMNs.insert(mmnKey).inserted else { continue }

            // Apply the per-pair gate (same predicate as the legacy
            // path; mirrored case-insensitive surname compare).
            if bothParentsLinked {
                let mMatches = mmn.caseInsensitiveCompare(knownMotherSurname ?? "") == .orderedSame
                let fMatches = subjectSurname.caseInsensitiveCompare(knownFatherSurname ?? "") == .orderedSame
                guard mMatches && fMatches else { continue }
            } else if let resolvedID = resolvedBirthRecordID {
                // The MMN pair must derive from the resolved birth
                // record specifically — other MMNs from other (non-resolved)
                // candidate birth records are noise under this anchor.
                if scored.id != resolvedID { continue }
            }

            let kind = HypothesisKind.parentMarriage(
                motherSurname: mmn,
                fatherSurname: subjectSurname,
                windowYears: window
            )
            results.append(ResearchHypothesis(
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
            ))
        }
        return results
    }

    /// Grade a `.parentMarriage` against marriage records in state.
    /// Filters by the surname pair + year window, splits into
    /// groom-side (surname = father) and bride-side (surname = mother)
    /// entries, and runs `MarriageEnrichmentEngine.match`.
    ///
    /// `.supported`     when match returns `.unique` — one marriage
    ///                  links the pair. `supportingEvidence` lists the
    ///                  one or two record IDs (one per side that
    ///                  reported the match).
    /// `.inconclusive`  when `.ambiguous` — `supportingEvidence` lists
    ///                  all candidate IDs so the user can disambiguate
    ///                  via §5.11.
    /// `.contradicted`  when `.none` — searched in the window, found
    ///                  no plausible marriage. Surfaces in the archive
    ///                  view; the parent inference still stands on its
    ///                  own.
    static func gradeParentMarriage(
        _ hypothesis: ResearchHypothesis,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> GradeResult {
        guard case .parentMarriage(let motherSurname, let fatherSurname, let window) = hypothesis.kind else {
            return .inconclusiveStub
        }
        let upperMother = motherSurname.uppercased()
        let upperFather = fatherSurname.uppercased()

        // Split marriage records into groom-side and bride-side by
        // whose surname is on the index entry. The engine's
        // entries(from:) returns MarriageEntry per ScoredRecord.
        var grooms: [MarriageEnrichmentEngine.MarriageEntry] = []
        var brides: [MarriageEnrichmentEngine.MarriageEntry] = []
        for scored in state.scoredRecords {
            guard scored.verdict != .impossible else { continue }
            guard case .marriage = scored.record else { continue }
            let entries = MarriageEnrichmentEngine.entries(from: [scored])
            for entry in entries {
                let surname = entry.surname.uppercased()
                if surname == upperFather {
                    grooms.append(entry)
                } else if surname == upperMother {
                    brides.append(entry)
                }
            }
        }
        _ = snapshot

        let outcome = MarriageEnrichmentEngine.match(
            grooms: grooms,
            brides: brides,
            yearWindow: window,
            expectedGroomSpouseSurname: motherSurname,
            expectedBrideSpouseSurname: fatherSurname
        )
        switch outcome {
        case .unique(let fGiven, let mGiven, let fEvidence, let mEvidence):
            var evidenceIDs: [String] = []
            if let f = fEvidence { evidenceIDs.append(f.id) }
            if let m = mEvidence, m.id != fEvidence?.id { evidenceIDs.append(m.id) }
            let fLabel = fGiven ?? "?"
            let mLabel = mGiven ?? "?"
            return GradeResult(
                verdict: .supported,
                isModelAssisted: false,
                supportingEvidence: evidenceIDs,
                contradictingEvidence: [],
                reasoning: "Marriage \(fLabel) \(fatherSurname) × \(mLabel) \(motherSurname) within \(window.lowerBound)–\(window.upperBound)."
            )
        case .ambiguous(let candidates):
            return GradeResult(
                verdict: .inconclusive,
                isModelAssisted: false,
                supportingEvidence: candidates.map(\.id),
                contradictingEvidence: [],
                reasoning: "\(candidates.count) candidate marriages found for \(fatherSurname) × \(motherSurname) within \(window.lowerBound)–\(window.upperBound) — disambiguation needed."
            )
        case .none:
            return GradeResult(
                verdict: .contradicted,
                isModelAssisted: false,
                supportingEvidence: [],
                contradictingEvidence: [],
                reasoning: "No BMD marriage found linking \(fatherSurname) × \(motherSurname) within \(window.lowerBound)–\(window.upperBound)."
            )
        }
    }

    /// Expansiveness ladder for `.parentMarriage`. Levels mirror the
    /// dispatch a T7 second pass (V2 spec §5.3) would re-issue:
    ///
    ///   level 1 → original window from the hypothesis payload
    ///             (`subjectBirth − 30 ... +1`). Matches the first-pass
    ///             dispatch; `runParentHypothesisFlow` sets
    ///             `attempts: 1` after the first pass, so T7 looking
    ///             at `attempts + 1 = 2` skips this level.
    ///   level 2 → widen window by ±10 years on each side. T7's first
    ///             effective retry — picks up marriages that fell just
    ///             outside the default window.
    ///   level ≥ 3 → nil. T31 retunes the ceiling once eval-harness
    ///               data is available (adjacent-county step is the
    ///               natural next ladder rung per §5.3).
    ///
    /// The returned `RecordQuery` template has `districtCode: ""` —
    /// the orchestrator fans out across the scope's districts (same
    /// pattern as the first-pass marriage dispatch).
    static func deficitQueryParentMarriage(
        for hypothesis: ResearchHypothesis,
        atLevel level: Int,
        state: ResearchState
    ) -> [RecordQuery] {
        guard case .parentMarriage(let motherSurname, let fatherSurname, let window) = hypothesis.kind else {
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
            return []   // Exhausted — T31 will revisit the ladder ceiling
        }
        return [RecordQuery(
            surname: fatherSurname,
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
                spouseSurname: motherSurname
            ))
        )]
    }
}
