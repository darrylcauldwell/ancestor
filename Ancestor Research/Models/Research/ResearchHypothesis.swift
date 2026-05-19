import Foundation

/// A persistent, deterministic, testable claim produced by the research
/// pipeline. The framework type that generalises the bespoke "question →
/// engine → field on result" pattern (SubjectIdentityResolver,
/// SiblingInferenceEngine, MarriageEnrichmentEngine, etc.) into a uniform
/// generate → grade → persist lifecycle.
///
/// `ResearchHypothesis` is **separate** from `Workbench.Hypothesis`:
///   - Workbench hypotheses are user-authored, free-form, persisted in
///     the `hypotheses` table (migration v7).
///   - Research hypotheses are machine-generated, structured, regenerated
///     each run, persisted in `research_hypotheses` (migration v26).
///
/// A `.supported` ResearchHypothesis may be *promoted* into a
/// Workbench.Hypothesis by user action; that is the only crossing.
///
/// The `Verdict` and `Transition` types are nested to avoid colliding
/// with the existing top-level `HypothesisVerdict` enum in
/// `LifeCluster.swift` (which grades clusters with `.stronglySupported`
/// / `.supported` / `.weak` / `.contradicted` — a different concept).
///
/// See `AncestorApp/RESEARCH_PIPELINE_V2_SPEC.md` Part II §4.1.
nonisolated struct ResearchHypothesis: Identifiable, Sendable, Codable, Equatable {

    /// The three possible verdicts a grader can return. "Supported" =
    /// evidence points at the claim; "contradicted" = evidence rules it
    /// out; "inconclusive" = not enough evidence to decide either way.
    enum Verdict: String, Sendable, Codable, CaseIterable, Equatable {
        case supported
        case contradicted
        case inconclusive
    }

    /// One entry in a hypothesis's history. Records when the verdict
    /// changed, whether model input was involved, and a one-line reason
    /// for audit.
    struct Transition: Sendable, Codable, Equatable {
        let verdict: Verdict
        let isModelAssisted: Bool
        let at: Date
        let reason: String
    }

    /// Stable deterministic ID — `kind.identityKey(subjectProfileID)`.
    /// Re-runs upsert; user-rejection persists across runs keyed on this.
    let id: String

    /// Which profile this hypothesis is about. `nil` for tree-wide
    /// hypotheses that don't tie to one subject.
    let subjectProfileID: String?

    /// What's being claimed. Each case carries its own typed payload.
    let kind: HypothesisKind

    /// Latest grading. Always one of supported / contradicted / inconclusive.
    let verdict: Verdict

    /// Whether the verdict had model input (T8 / T9). Orthogonal to
    /// verdict — auto-promote and other deterministic-only gates use
    /// `isDeterministicallySupported` (= verdict == .supported &&
    /// !isModelAssisted) — never a bare verdict comparison.
    let isModelAssisted: Bool

    /// IDs of records that supported the verdict.
    let supportingEvidence: [String]

    /// IDs of records that contradicted the verdict (relevant for
    /// `.contradicted` only).
    let contradictingEvidence: [String]

    /// One-line human-readable rationale for the verdict.
    let reasoning: String

    /// When the hypothesis was first generated.
    let createdAt: Date

    /// Last time the verdict was recomputed.
    let lastTestedAt: Date

    /// How many levels of the per-kind expansiveness ladder have been
    /// dispatched against this hypothesis. T7's stall-recovery and the
    /// user's "investigate further" gesture both increment this on each
    /// deficit-query dispatch. When
    /// `deficitQuery(for: h, atLevel: attempts + 1, …)` returns `nil`,
    /// the hypothesis is exhausted at that kind's ladder ceiling — the
    /// caller archives it.
    var attempts: Int

    /// Trail of (verdict, timestamp, isModelAssisted, reason) so the
    /// UI can show "this hypothesis was inconclusive last run,
    /// supported now." Append-only on verdict change (skip
    /// identity-grade no-change events — see §10 residual question on
    /// growth policy).
    let history: [Transition]
}

nonisolated extension ResearchHypothesis {
    /// True iff the verdict is `.supported` AND no model input was used.
    /// Every promotion / auto-accept gate uses this helper — never a
    /// bare `verdict == .supported` comparison. Preserves the
    /// deterministic-wins rule: model output never writes facts.
    var isDeterministicallySupported: Bool {
        verdict == .supported && !isModelAssisted
    }
}

// MARK: - HypothesisKind

/// Closed enum with associated payloads (V2 spec Decision 1). Adding a
/// new kind requires touching the enum + three central switches in
/// `HypothesisEngine` (generate / grade / deficitQuery) + the kind's
/// `HypothesisEngine+<Kind>.swift` extension file with the three
/// static methods. Compile-time exhaustiveness catches "forgot to
/// handle the new kind."
nonisolated enum HypothesisKind: Sendable, Codable, Equatable, Hashable {

    /// "The subject's identity resolves to a unique birth record in
    /// this year window, with this district hint." Generator is
    /// `SubjectIdentityResolver`-shaped; grader returns
    /// `.supported` when SubjectIdentityResolver.resolve returns
    /// `.resolved`, `.contradicted` when it returns `.unresolved`,
    /// `.inconclusive` when `.ambiguous`.
    case subjectIdentity(birthYearWindow: ClosedRange<Int>, districtHint: String?)

    /// "There exists a BMD marriage between these two surnames in this
    /// year window." Generator emits one hypothesis per (mother MMN,
    /// father surname) pair from ParentInferenceEngine; grader runs
    /// MarriageEnrichmentEngine.match.
    case parentMarriage(motherSurname: String, fatherSurname: String, windowYears: ClosedRange<Int>)

    /// "This surname belongs to a parent of the subject" (mother → MMN
    /// from BMD birth index; father → subject's surname). Generator
    /// emits one hypothesis per (subject birth carrying MMN, parent
    /// gender) pair. Grader is purely BMD-birth-evidence; marriage
    /// given-name enrichment lands as a cross-reference from
    /// `.parentMarriage` via `HypothesisEngine.reconcileParentMarriages`
    /// (V2 spec §5.2.1). Bundled coupling rejected in the design pass.
    case parentInferred(gender: Gender, surname: String)

    /// "A sibling of the subject exists in this district, sharing this
    /// MMN, born in this year window." Generator emits one hypothesis
    /// per resolved subject birth where both parents are linked;
    /// grader runs SiblingInferenceEngine.
    case siblingExists(district: String, mmn: String, yearWindow: ClosedRange<Int>)

    /// "This life cluster is the subject." T7's working hypothesis for
    /// lead-only clusters; user-facing via §5.11.
    case clusterIsSubject(clusterID: UUID)

    /// "The subject was buried at this parish in this year window."
    /// Future kind; not in scope for T11/T12 but enumerated to show
    /// the framework absorbs new kinds without architectural change.
    case burialAtParish(parish: String, yearWindow: ClosedRange<Int>)

    /// "The subject had a second marriage after this year." Future kind.
    case secondMarriage(afterYear: Int)

    /// Compact discriminator for SQL filtering / UI grouping. Stable
    /// across builds (used as the `kind_discriminator` column value).
    var discriminator: String {
        switch self {
        case .subjectIdentity:  return "subjectIdentity"
        case .parentMarriage:   return "parentMarriage"
        case .parentInferred:   return "parentInferred"
        case .siblingExists:    return "siblingExists"
        case .clusterIsSubject: return "clusterIsSubject"
        case .burialAtParish:   return "burialAtParish"
        case .secondMarriage:   return "secondMarriage"
        }
    }

    /// Stable ID for this hypothesis under the given subject. Deterministic
    /// across runs so persisted rejection state survives. Builders compose
    /// the kind's payload into the key — different payloads = different
    /// hypotheses, same payload re-run = same ID = upsert.
    func identityKey(subjectProfileID: String?) -> String {
        let subject = subjectProfileID ?? "tree"
        switch self {
        case .subjectIdentity(let window, let districtHint):
            return "subjectIdentity:\(subject):\(window.lowerBound)-\(window.upperBound):\(districtHint ?? "")"
        case .parentMarriage(let mother, let father, let window):
            return "parentMarriage:\(subject):\(father.uppercased())x\(mother.uppercased()):\(window.lowerBound)-\(window.upperBound)"
        case .parentInferred(let gender, let surname):
            return "parentInferred:\(subject):\(gender.rawValue):\(surname.uppercased())"
        case .siblingExists(let district, let mmn, let window):
            return "siblingExists:\(subject):\(district.uppercased()):\(mmn.uppercased()):\(window.lowerBound)-\(window.upperBound)"
        case .clusterIsSubject(let clusterID):
            return "clusterIsSubject:\(subject):\(clusterID.uuidString)"
        case .burialAtParish(let parish, let window):
            return "burialAtParish:\(subject):\(parish.uppercased()):\(window.lowerBound)-\(window.upperBound)"
        case .secondMarriage(let afterYear):
            return "secondMarriage:\(subject):\(afterYear)"
        }
    }
}
