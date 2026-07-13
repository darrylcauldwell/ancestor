import Foundation

/// Generates, tests, and grades `ResearchHypothesis` rows against the
/// current pipeline state. The single entry point that runs every kind's
/// generator + grader.
///
/// **T11 scaffold only.** This file lands the three central switches
/// (`generate`, `grade`, `deficitQuery`) and dispatches to per-kind
/// extension methods. Each extension file (one per kind) holds three
/// `static func` clauses: `generate<Kind>`, `grade<Kind>`, and
/// `deficitQuery<Kind>(for:atLevel:state:)`. Adding a new kind requires
/// touching `HypothesisKind` + the three central switches + adding the
/// kind's extension file. The compiler enforces completeness on the
/// central switches.
///
/// During T11, all generators return `[]` and graders return
/// `.inconclusive` — the engine is callable but produces no output
/// (legacy bespoke paths still drive sibling discovery, marriage
/// enrichment, etc.). T12 fills in the per-kind logic.
///
/// See `AncestorApp/RESEARCH_PIPELINE_V2_SPEC.md` Part II §4.2 and §7.1.
nonisolated enum HypothesisEngine {

    /// Result of grading a single hypothesis: the new verdict plus the
    /// evidence and rationale that drove it.
    struct GradeResult: Sendable {
        let verdict: ResearchHypothesis.Verdict
        let isModelAssisted: Bool
        let supportingEvidence: [String]
        let contradictingEvidence: [String]
        let reasoning: String

        static let inconclusiveStub = GradeResult(
            verdict: .inconclusive,
            isModelAssisted: false,
            supportingEvidence: [],
            contradictingEvidence: [],
            reasoning: "Grader not yet implemented for this kind (T11 scaffold)."
        )
    }

    /// Run every registered generator against `state`, dedup by stable
    /// ID against `persisted`, grade each fresh / refreshed hypothesis,
    /// and return the full set.
    ///
    /// T11 returns `persisted` unchanged — the generators produce no
    /// hypotheses, so there's nothing new to grade. T12 wires in the
    /// real per-kind logic.
    static func runAll(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot,
        persisted: [ResearchHypothesis]
    ) -> [ResearchHypothesis] {
        // Future: iterate over every HypothesisKind discriminator,
        // call generate(for:state:snapshot:), dedup by id against
        // persisted, then grade each fresh hypothesis with
        // grade(_:state:snapshot:). For T11 this is a no-op.
        _ = state
        _ = snapshot
        return persisted
    }

    // MARK: - Central switches

    /// Generate candidate hypotheses for one kind. Returns 0..N
    /// hypotheses depending on the kind's generator logic. Pure
    /// function — state in, hypotheses out, no side effects.
    static func generate(
        for kind: HypothesisKindDiscriminator,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> [ResearchHypothesis] {
        switch kind {
        case .siblingExists:
            return generateSiblingExists(state: state, snapshot: snapshot)
        case .parentInferred:
            return generateParentInferred(state: state, snapshot: snapshot)
        case .parentMarriage:
            return generateParentMarriage(state: state, snapshot: snapshot)
        case .subjectSpouseMarriage:
            return generateSubjectSpouseMarriage(state: state, snapshot: snapshot)
        case .birthYearCandidate:
            return generateBirthYearCandidate(state: state, snapshot: snapshot)
        case .parentCandidates:
            // §5.15.1 regeneration exemption — permanent, not a stub.
            // The engine never invents a hunch: `.user` rows are
            // materialised from the v32 seeds table by
            // `HypothesisSeedService`, and the regeneration cycle never
            // creates, deletes, or reshapes them — only re-grades them
            // (ResearchPipeline.runUserSeededHypothesisFlow).
            return []
        case .subjectIdentity, .clusterIsSubject,
             .burialAtParish, .secondMarriage:
            return []   // future kinds
        }
    }

    /// Grade an existing hypothesis against current evidence. Returns
    /// the new verdict + evidence + rationale; caller updates the
    /// hypothesis (verdict, lastTestedAt, history append) and persists.
    static func grade(
        _ hypothesis: ResearchHypothesis,
        state: ResearchState,
        snapshot: FamilyGraphSnapshot
    ) -> GradeResult {
        switch hypothesis.kind {
        case .siblingExists:
            return gradeSiblingExists(hypothesis, state: state, snapshot: snapshot)
        case .deathYearCandidate:
            return gradeDeathYearCandidate(hypothesis, state: state, snapshot: snapshot)
        case .parentIdentityCandidate:
            return gradeParentIdentityCandidate(hypothesis, state: state, snapshot: snapshot)
        case .parentInferred:
            return gradeParentInferred(hypothesis, state: state, snapshot: snapshot)
        case .parentMarriage:
            return gradeParentMarriage(hypothesis, state: state, snapshot: snapshot)
        case .subjectSpouseMarriage:
            return gradeSubjectSpouseMarriage(hypothesis, state: state, snapshot: snapshot)
        case .birthYearCandidate:
            return gradeBirthYearCandidate(hypothesis, state: state, snapshot: snapshot)
        case .parentCandidates:
            return gradeParentCandidates(hypothesis, state: state, snapshot: snapshot)
        case .subjectIdentity, .clusterIsSubject,
             .burialAtParish, .secondMarriage:
            return .inconclusiveStub   // future kinds
        }
    }

    // MARK: - Reconciliation

    /// Deterministic post-grading join (V2 spec §5.2.1): walks
    /// `.supported` `.parentMarriage` hypotheses and writes their
    /// marriage record IDs + given-name reasoning back onto the
    /// matching `.parentInferred` hypotheses, so the parent
    /// hypotheses' `supportingEvidence` and `reasoning` reflect both
    /// the BMD-birth attestation AND the cross-validated marriage.
    ///
    /// Inputs unchanged on disk — this is a pure transformation of
    /// the in-memory hypothesis list. Idempotent under same inputs;
    /// rerunning with the same hypotheses yields the same result.
    /// `isModelAssisted` stays `false` on both sides; deterministic
    /// gates remain honoured.
    ///
    /// Match rule: a `.parentMarriage(motherSurname:M, fatherSurname:F)`
    /// for subject S cross-references
    ///   `.parentInferred(gender:.female, surname:M)` for S, and
    ///   `.parentInferred(gender:.male,   surname:F)` for S.
    /// Case-insensitive surname comparison so transcriber capitalisation
    /// drift between BMD-index entries doesn't break the join.
    static func reconcileParentMarriages(
        hypotheses: [ResearchHypothesis]
    ) -> [ResearchHypothesis] {
        // Index parent hypotheses by (subject, gender, upper(surname))
        // for O(1) lookup. Only collect supported parent hypotheses —
        // unsupported ones don't need cross-references attached.
        struct ParentKey: Hashable {
            let subject: String
            let gender: Gender
            let surname: String   // uppercased
        }
        var byIndex: [ParentKey: Int] = [:]
        for (i, h) in hypotheses.enumerated() {
            guard case .parentInferred(let gender, let surname) = h.kind else { continue }
            byIndex[ParentKey(
                subject: h.subjectProfileID ?? "tree",
                gender: gender,
                surname: surname.uppercased()
            )] = i
        }

        var updated = hypotheses
        for marriage in hypotheses {
            guard marriage.isDeterministicallySupported,
                  case .parentMarriage(let mother, let father, _) = marriage.kind
            else { continue }
            let subject = marriage.subjectProfileID ?? "tree"

            let motherKey = ParentKey(subject: subject, gender: .female, surname: mother.uppercased())
            let fatherKey = ParentKey(subject: subject, gender: .male,   surname: father.uppercased())

            if let i = byIndex[motherKey] {
                updated[i] = applyMarriageCrossReference(
                    to: updated[i], from: marriage
                )
            }
            if let i = byIndex[fatherKey] {
                updated[i] = applyMarriageCrossReference(
                    to: updated[i], from: marriage
                )
            }
        }
        return updated
    }

    /// Apply one marriage hypothesis's cross-reference to one parent
    /// hypothesis. Idempotent — if the marriage's record IDs are
    /// already in the parent's `supportingEvidence` (e.g. from a
    /// prior `reconcileParentMarriages` call in the same run), they
    /// aren't duplicated, and the reasoning appendage isn't repeated.
    private static func applyMarriageCrossReference(
        to parent: ResearchHypothesis,
        from marriage: ResearchHypothesis
    ) -> ResearchHypothesis {
        let existing = Set(parent.supportingEvidence)
        var newEvidence = parent.supportingEvidence
        for id in marriage.supportingEvidence where !existing.contains(id) {
            newEvidence.append(id)
        }
        // Build the cross-reference reasoning sentence once per
        // marriage. Tag with the marriage's id so a second
        // reconciliation pass detects "already applied".
        let marker = "[cross-ref:\(marriage.id)]"
        let newReasoning: String
        if parent.reasoning.contains(marker) {
            newReasoning = parent.reasoning
        } else {
            newReasoning = parent.reasoning + " \(marker) " + marriage.reasoning
        }
        return ResearchHypothesis(
            id: parent.id,
            subjectProfileID: parent.subjectProfileID,
            kind: parent.kind,
            origin: parent.origin,
            verdict: parent.verdict,
            isModelAssisted: parent.isModelAssisted,
            supportingEvidence: newEvidence,
            contradictingEvidence: parent.contradictingEvidence,
            reasoning: newReasoning,
            createdAt: parent.createdAt,
            lastTestedAt: parent.lastTestedAt,
            attempts: parent.attempts,
            history: parent.history
        )
    }

    /// Per-kind expansiveness ladder. Returns the focused query for the
    /// given level on this hypothesis, or `nil` when the level exceeds
    /// the kind's ladder ceiling (= hypothesis exhausted at this kind).
    /// Callers pass `hypothesis.attempts + 1`; T7 and §5.11's user
    /// "investigate further" gesture are the two call sites.
    static func deficitQuery(
        for hypothesis: ResearchHypothesis,
        atLevel level: Int,
        state: ResearchState
    ) -> [RecordQuery] {
        switch hypothesis.kind {
        case .siblingExists:
            return deficitQuerySiblingExists(for: hypothesis, atLevel: level, state: state)
        case .deathYearCandidate:
            return deficitQueryDeathYearCandidate(for: hypothesis, atLevel: level, state: state)
        case .parentIdentityCandidate:
            return []   // CL6: linkage evidence arrives via the subject's own
                        // birth/census probes — no dedicated ladder yet.
        case .parentInferred:
            return deficitQueryParentInferred(for: hypothesis, atLevel: level, state: state)
        case .parentMarriage:
            return deficitQueryParentMarriage(for: hypothesis, atLevel: level, state: state)
        case .subjectSpouseMarriage:
            return deficitQuerySubjectSpouseMarriage(for: hypothesis, atLevel: level, state: state)
        case .birthYearCandidate:
            return deficitQueryBirthYearCandidate(for: hypothesis, atLevel: level, state: state)
        case .parentCandidates:
            return deficitQueryParentCandidates(for: hypothesis, atLevel: level, state: state)
        case .subjectIdentity, .clusterIsSubject,
             .burialAtParish, .secondMarriage:
            return []   // future kinds
        }
    }
}

/// Stable discriminator over `HypothesisKind` cases for use in central
/// switches that drive generation. (The full `HypothesisKind` carries
/// associated payloads; generation needs only the case to fan out
/// across.) Mirrors `HypothesisKind.discriminator` 1:1.
nonisolated enum HypothesisKindDiscriminator: String, CaseIterable, Sendable {
    case subjectIdentity
    case parentMarriage
    case parentInferred
    case siblingExists
    case subjectSpouseMarriage
    case birthYearCandidate
    case parentCandidates
    case clusterIsSubject
    case burialAtParish
    case secondMarriage
}
