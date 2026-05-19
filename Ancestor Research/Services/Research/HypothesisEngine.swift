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
        case .subjectIdentity, .parentMarriage, .clusterIsSubject,
             .burialAtParish, .secondMarriage:
            return []   // T12 fills these in
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
        case .subjectIdentity, .parentMarriage, .clusterIsSubject,
             .burialAtParish, .secondMarriage:
            return .inconclusiveStub   // T12 fills these in
        }
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
    ) -> RecordQuery? {
        switch hypothesis.kind {
        case .siblingExists:
            return deficitQuerySiblingExists(for: hypothesis, atLevel: level, state: state)
        case .subjectIdentity, .parentMarriage, .clusterIsSubject,
             .burialAtParish, .secondMarriage:
            return nil   // T12 fills these in
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
    case siblingExists
    case clusterIsSubject
    case burialAtParish
    case secondMarriage
}
