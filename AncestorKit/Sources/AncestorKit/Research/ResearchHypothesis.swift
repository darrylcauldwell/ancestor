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
public nonisolated struct ResearchHypothesis: Identifiable, Sendable, Codable, Equatable {

    /// The three possible verdicts a grader can return. "Supported" =
    /// evidence points at the claim; "contradicted" = evidence rules it
    /// out; "inconclusive" = not enough evidence to decide either way.
    public enum Verdict: String, Sendable, Codable, CaseIterable, Equatable {
        case supported
        case contradicted
        case inconclusive
    }

    /// Who asserted this hypothesis. `.engine` (default) for rows the
    /// generate switches produce; `.user` for seeded hunches
    /// (RESEARCH_PIPELINE_SPEC §5.15.1, Decision E1). The engine's
    /// regeneration cycle never creates, deletes, or reshapes `.user`
    /// rows — only re-grades them. Only the user dismisses one.
    public enum Origin: String, Sendable, Codable, CaseIterable, Equatable {
        case engine
        case user
    }

    /// One entry in a hypothesis's history. Records when the verdict
    /// changed, whether model input was involved, and a one-line reason
    /// for audit.
    public struct Transition: Sendable, Codable, Equatable {
        public let verdict: Verdict
        public let isModelAssisted: Bool
        public let at: Date
        public let reason: String

        public init(verdict: Verdict, isModelAssisted: Bool, at: Date, reason: String) {
            self.verdict = verdict
            self.isModelAssisted = isModelAssisted
            self.at = at
            self.reason = reason
        }
    }

    /// Stable deterministic ID — `kind.identityKey(subjectProfileID)`.
    /// Re-runs upsert; user-rejection persists across runs keyed on this.
    public let id: String

    /// Which profile this hypothesis is about. `nil` for tree-wide
    /// hypotheses that don't tie to one subject.
    public let subjectProfileID: String?

    /// What's being claimed. Each case carries its own typed payload.
    public let kind: HypothesisKind
    /// CL5 ⟨G5⟩ — rival value-candidates share one group so the UI renders
    /// a single choose-one card; accepting one contradicts the rest.
    /// Nil for non-candidate kinds and legacy rows.
    public var candidateGroupID: String?

    /// Who asserted this hypothesis (§5.15.1). Orthogonal to `kind` so
    /// every future user-seedable kind reuses it unchanged. Legacy
    /// persisted rows (pre-v32) decode as `.engine`.
    public let origin: Origin

    /// Latest grading. Always one of supported / contradicted / inconclusive.
    public let verdict: Verdict

    /// Whether the verdict had model input (T8 / T9). Orthogonal to
    /// verdict — auto-promote and other deterministic-only gates use
    /// `isDeterministicallySupported` (= verdict == .supported &&
    /// !isModelAssisted) — never a bare verdict comparison.
    public let isModelAssisted: Bool

    /// IDs of records that supported the verdict.
    public let supportingEvidence: [String]

    /// IDs of records that contradicted the verdict (relevant for
    /// `.contradicted` only).
    public let contradictingEvidence: [String]

    /// One-line human-readable rationale for the verdict.
    public let reasoning: String

    /// When the hypothesis was first generated.
    public let createdAt: Date

    /// Last time the verdict was recomputed.
    public let lastTestedAt: Date

    /// How many levels of the per-kind expansiveness ladder have been
    /// dispatched against this hypothesis. T7's stall-recovery and the
    /// user's "investigate further" gesture both increment this on each
    /// deficit-query dispatch. When
    /// `deficitQuery(for: h, atLevel: attempts + 1, …)` returns `nil`,
    /// the hypothesis is exhausted at that kind's ladder ceiling — the
    /// caller archives it.
    public var attempts: Int

    /// Trail of (verdict, timestamp, isModelAssisted, reason) so the
    /// UI can show "this hypothesis was inconclusive last run,
    /// supported now." Append-only on verdict change (skip
    /// identity-grade no-change events — see §10 residual question on
    /// growth policy).
    public let history: [Transition]

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    /// `origin` defaults to `.engine` so the pre-§5.15 call sites
    /// (all engine-generated) stay source-compatible; copy sites that
    /// rebuild an existing hypothesis must pass the original's origin.
    public init(id: String, subjectProfileID: String? = nil, kind: HypothesisKind, origin: Origin = .engine, verdict: Verdict, isModelAssisted: Bool, supportingEvidence: [String], contradictingEvidence: [String], reasoning: String, createdAt: Date, lastTestedAt: Date, attempts: Int, history: [Transition]) {
        self.id = id
        self.subjectProfileID = subjectProfileID
        self.kind = kind
        self.origin = origin
        self.verdict = verdict
        self.isModelAssisted = isModelAssisted
        self.supportingEvidence = supportingEvidence
        self.contradictingEvidence = contradictingEvidence
        self.reasoning = reasoning
        self.createdAt = createdAt
        self.lastTestedAt = lastTestedAt
        self.attempts = attempts
        self.history = history
    }

    // MARK: - Codable (backwards-compatible origin)

    private enum CodingKeys: String, CodingKey {
        case id, subjectProfileID, kind, origin, verdict, isModelAssisted
        case supportingEvidence, contradictingEvidence, reasoning
        case createdAt, lastTestedAt, attempts, history
    }

    /// Custom decoder solely so `origin` decode-defaults to `.engine`:
    /// JSON encoded before the §5.15 field existed (v26–v31 rows, old
    /// backups) has no `origin` key and must keep decoding. Encoding
    /// stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.subjectProfileID = try c.decodeIfPresent(String.self, forKey: .subjectProfileID)
        self.kind = try c.decode(HypothesisKind.self, forKey: .kind)
        self.origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .engine
        self.verdict = try c.decode(Verdict.self, forKey: .verdict)
        self.isModelAssisted = try c.decode(Bool.self, forKey: .isModelAssisted)
        self.supportingEvidence = try c.decode([String].self, forKey: .supportingEvidence)
        self.contradictingEvidence = try c.decode([String].self, forKey: .contradictingEvidence)
        self.reasoning = try c.decode(String.self, forKey: .reasoning)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.lastTestedAt = try c.decode(Date.self, forKey: .lastTestedAt)
        self.attempts = try c.decode(Int.self, forKey: .attempts)
        self.history = try c.decode([Transition].self, forKey: .history)
    }

}

nonisolated extension ResearchHypothesis {
    /// True iff the verdict is `.supported` AND no model input was used.
    /// Every promotion / auto-accept gate uses this helper — never a
    /// bare `verdict == .supported` comparison. Preserves the
    /// deterministic-wins rule: model output never writes facts.
    public var isDeterministicallySupported: Bool {
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
public nonisolated enum HypothesisKind: Sendable, Codable, Equatable, Hashable {

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

    /// "The thin placeholder subject's marriage exists in this year
    /// window, with this groom × bride surname pair — pin it to recover
    /// the subject's given name." See RESEARCH_PIPELINE_SPEC §5.14.
    ///
    /// **BMD role labelling (slice 5).** The payload stores the BMD
    /// index's natural marriage shape: groomSurname = the man's surname
    /// (matches `child.lastName` under the standard paternal-naming
    /// convention); brideSurname = the woman's MAIDEN surname (matches
    /// `child.mothersMaidenName`). The hypothesis IS the marriage; the
    /// subject's role (groom or bride) is decided by the gender ladder
    /// at write-back time. This shape correctly handles:
    ///   • male father subject (groomSurname == subject.surname)
    ///   • female mother subject stored under MAIDEN (brideSurname == subject.surname)
    ///   • female mother subject stored under MARRIED — WikiTree convention
    ///     (groomSurname == subject.surname, but the bride IS the subject
    ///     because BMD indexes wives under maiden, not married)
    ///
    /// Generator emits one hypothesis per distinct (groom, bride) pair
    /// across linked children (Q3 — same-MMN children collapse; Q4 —
    /// different-MMN children seed separate hypotheses).
    case subjectSpouseMarriage(groomSurname: String, brideSurname: String, childYearWindow: ClosedRange<Int>)

    /// "This life cluster is the subject." T7's working hypothesis for
    /// lead-only clusters; user-facing via §5.11.
    case clusterIsSubject(clusterID: UUID)

    /// "Among the precise (span-0) birth-year values currently attested
    /// in `Profile.sources[.birthDate]`, this year is the correct one."
    /// One hypothesis per distinct competing candidate year; verdicts
    /// compare biographical fit deterministically and let T7 dispatch
    /// corroborating census + marriage probes when the fit margins are
    /// inconclusive. The disambiguator the directional-overwrite rule
    /// in `Profile` apply-paths deliberately *refuses* to perform on its
    /// own (refusing is the right call — silent "most-recent wins"
    /// would seed the wrong year half the time). See
    /// `project_multi_hypothesis_birth_year_plan` memory and
    /// RESEARCH_PIPELINE_SPEC.md Part II §5 (V2 hypothesis framework).
    ///
    /// Generator fires only when ≥ 2 distinct precise candidates compete
    /// for one profile. A single precise candidate is handled by
    /// subject-self-narrowing's pending-fact path (slice B); a wide
    /// range alone needs neither path.
    case birthYearCandidate(profileID: String, year: Int)

    /// CL5 (CONFLICT_LAYER_SPEC §4.7) — the death-year twin of
    /// `.birthYearCandidate`: emitted when ≥ 2 distinct precise death-year
    /// values compete (typically from an open deathDate dispute the R2
    /// ladder correctly refused to decide). Same discipline: hypothesis
    /// verdicts PROPOSE; the human accepts.
    case deathYearCandidate(profileID: String, year: Int)

    /// "The subject's parents might have been this couple" — the
    /// user-seeded hunch kind (RESEARCH_PIPELINE_SPEC §5.15, Decision
    /// E1). A hunch is a search directive, never data: it creates no
    /// profile, no edge, no field, no citation — it biases WHERE the
    /// engine looks, never WHAT it concludes. Rows of this kind carry
    /// `origin == .user`; the engine never generates them itself.
    ///
    /// Payload semantics (§5.15.1): hints record **exactly what the
    /// user asserted** — nothing is defaulted into the payload. At
    /// least one of the four name hints is non-empty (validated at
    /// intake). Effective values are resolved at probe time (e.g.
    /// groom surname = `fatherSurname ?? subject.lastName` under the
    /// paternal-naming convention) and the resolution is recorded in
    /// `reasoning`. `marriageWindow` defaults at intake to
    /// `subjectBirthYear − 30 … subjectBirthYear + 1` (mirrors
    /// `.parentMarriage` and §5.14.3); the user may narrow it.
    case parentCandidates(
        fatherGiven: String?,
        fatherSurname: String?,
        motherGiven: String?,
        motherMaidenSurname: String?,
        marriageWindow: ClosedRange<Int>
    )

    /// "The subject was buried at this parish in this year window."
    /// Future kind; not in scope for T11/T12 but enumerated to show
    /// the framework absorbs new kinds without architectural change.
    case burialAtParish(parish: String, yearWindow: ClosedRange<Int>)

    /// "The subject had a second marriage after this year." Future kind.
    case secondMarriage(afterYear: Int)

    /// Compact discriminator for SQL filtering / UI grouping. Stable
    /// across builds (used as the `kind_discriminator` column value).
    public var discriminator: String {
        switch self {
        case .subjectIdentity:        return "subjectIdentity"
        case .parentMarriage:         return "parentMarriage"
        case .parentInferred:         return "parentInferred"
        case .siblingExists:          return "siblingExists"
        case .subjectSpouseMarriage:  return "subjectSpouseMarriage"
        case .clusterIsSubject:       return "clusterIsSubject"
        case .birthYearCandidate:     return "birthYearCandidate"
        case .deathYearCandidate:     return "deathYearCandidate"
        case .parentCandidates:       return "parentCandidates"
        case .burialAtParish:         return "burialAtParish"
        case .secondMarriage:         return "secondMarriage"
        }
    }

    /// Stable ID for this hypothesis under the given subject. Deterministic
    /// across runs so persisted rejection state survives. Builders compose
    /// the kind's payload into the key — different payloads = different
    /// hypotheses, same payload re-run = same ID = upsert.
    public func identityKey(subjectProfileID: String?) -> String {
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
        case .subjectSpouseMarriage(let groomSurname, let brideSurname, let window):
            return "subjectSpouseMarriage:\(subject):\(groomSurname.uppercased())x\(brideSurname.uppercased()):\(window.lowerBound)-\(window.upperBound)"
        case .clusterIsSubject(let clusterID):
            return "clusterIsSubject:\(subject):\(clusterID.uuidString)"
        case .birthYearCandidate(let profileID, let year):
            // Profile ID is part of the payload (not just `subject`) so the
            // key stays self-describing if a future caller ever passes
            // `subjectProfileID: nil` with a non-nil payload profileID.
            // Under normal use the two match and `subject == profileID`.
            return "birthYearCandidate:\(profileID):\(year)"
        case .deathYearCandidate(let profileID, let year):
            return "deathYearCandidate:\(profileID):\(year)"
        case .parentCandidates(let fg, let fs, let mg, let mms, let w):
            // nil hints normalise to "" (§5.15.1) — same hunch re-seeded
            // with the same hints collides on this key and upserts.
            return "parentCandidates:\(subject):\(fg?.uppercased() ?? "")x\(fs?.uppercased() ?? "")x\(mg?.uppercased() ?? "")x\(mms?.uppercased() ?? ""):\(w.lowerBound)-\(w.upperBound)"
        case .burialAtParish(let parish, let window):
            return "burialAtParish:\(subject):\(parish.uppercased()):\(window.lowerBound)-\(window.upperBound)"
        case .secondMarriage(let afterYear):
            return "secondMarriage:\(subject):\(afterYear)"
        }
    }
}
