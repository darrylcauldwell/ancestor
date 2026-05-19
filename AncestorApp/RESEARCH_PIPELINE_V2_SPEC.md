# Research Pipeline V2 — Specification

**Status:** Accepted (design decisions resolved 2026-05-19; implementation pending)
**Companion:** `RESEARCH_PIPELINE_AS_BUILT.md` (what exists today)
**Supersedes:** `archive/LLM_RESEARCH_OPTIONS.md` (decision-staging doc folded in here)
**Date:** 2026-05-19

This document is the next architectural turn for the research pipeline. It folds in the portfolio thinking from `LLM_RESEARCH_OPTIONS.md` (the gap inventory and tier-per-gap analysis) and lays out how the seven remaining open tasks compose into a coherent change.

All design decisions called out in this spec were resolved on 2026-05-19 (see §7). Implementation begins with T11.

---

## 1. Why now

The pipeline as built (see `RESEARCH_PIPELINE_AS_BUILT.md`) ships strong deterministic primitives: a 4-gate scorer, 5-step clustering, lineage-aware convergence, an identity resolver, three inference engines. Five recent tasks (T17 sibling discovery, T13 subject identity, T10 geographic hypothesis, T6 auto-promote gate, T5 cluster-level hypothesis verdict) all share a shape: each one is a **purpose-built question** wired to bespoke generation + bespoke testing + bespoke acceptance.

That shape doesn't generalise. Adding the next testable question — "burial at this parish?", "death certificate in this registry?", "second marriage to a new spouse?" — currently means another bespoke engine, another bespoke result field on `ResearchResult`, another bespoke UI surface, another bespoke accept path. T11 + T12 want to retire that pattern.

In parallel, `LLM_RESEARCH_OPTIONS.md` (2026-05-15) re-framed the LLM debate as a **portfolio of moves per gap**, not a wholesale "more LLM or not." The remaining tasks line up against the portfolio's recommendations: T7 / T11 / T12 are the deterministic backbone; T8 / T9 are the local-MLX bolt-ons that earn their place where the deterministic tier hits a wall. T23 (Sample Tree tour) and T31 (empirical retuning) sit outside the architectural pivot but get a short pass each.

---

## 2. The architectural thesis

> Replace the bespoke "question → engine → field on result" pattern with a uniform **ResearchHypothesis** lifecycle: generate, test, grade, persist, optionally act on, optionally promote.

Concretely:

- `ResearchHypothesis` becomes a first-class type, alongside `ScoredRecord`, `LifeCluster`, `ProposedRelative`, `SiblingProposal`.
- Each existing one-off is folded in as a *kind* of hypothesis with its own generator and grader. Sibling discovery becomes `kind: .siblingExists(...)`. Subject identity becomes `kind: .subjectIdentity(...)`. Marriage enrichment becomes a generator for `kind: .parentMarriage(...)`. New questions become new kinds without new fields on `ResearchResult`.
- A `HypothesisEngine` runs all generators against the current `ResearchState`, tests each hypothesis against available evidence, and grades each with a verdict (`.supported` / `.contradicted` / `.inconclusive`).
- Hypotheses persist (T11), keyed by `(profile_id, kind, deterministic_subject_hash)`, so re-runs **upsert** rather than re-create. Verdict transitions are observable across runs.
- A graded hypothesis can drive a focused second pass (T7) — e.g. a `.weak` cluster hypothesis spawns a targeted query designed to either upgrade it to `.supported` or push it to `.contradicted`. This is the deterministic version of "stall recovery."
- MLX enters only where deterministic generation can't reach: free-text disambiguation of ambiguous identity resolutions (T9) and next-search suggestion for hypothesis-weak verdicts the rules can't escalate (T8).

The deterministic-wins rule is preserved: MLX can propose a hypothesis or a next-search direction, but the grader and the scorer remain rule-based. No verdict comes from a model.

---

## 3. Gap inventory (folded from `LLM_RESEARCH_OPTIONS.md`)

Seven coverage gaps observed against the current pipeline. Each carries a recommended tier (cheapest that closes it) and an evaluation metric.

| # | Gap | Cheapest tier | Eval metric |
|---|---|---|---|
| **G1** | Shared evidence not cross-applied across profiles. Researching self + then mother re-discovers shared marriage cert rather than propagating. | Deterministic | % of cluster-internal evidence that requires only one source fetch instead of N |
| **G2** | Stall on no-result. Source returns empty for configured query; pipeline gives up rather than try a different angle. | Deterministic first, MLX second | Held-out: out of N stalled profiles, how many additional `.fact` verdicts after deterministic stall recovery? After MLX planner on top? |
| **G3** | Phonetic / spelling variants not adaptively escalated. Strictness ladder exists but escalation is per-mode-static, not response-driven. | Deterministic | Variant-tier hit rate on held-out vs current static behaviour |
| **G4** | Ambiguous locations stall the cleanse step. "Newport" matches 3 counties; cleanse can't pick one from spouse/sibling context. | Deterministic + graph context first, MLX where graph context insufficient | Resolution rate on held-out "Newport"-shaped findings |
| **G5** | Cross-cluster contradiction unresolved. Cluster A says born 1850, cluster B says 1855; no mechanism asks which is more plausible. | MLX (planning-class) | Contradictions surfaced and resolved with user agreement, per tree |
| **G6** | Bare evidence not contextualised against family graph. A single FreeBMD lead passes scoring in isolation, never re-checked vs parents/siblings. | Deterministic for the check, MLX for the rationale prose | Coverage-rate change on held-out, with and without family-graph plausibility gate |
| **G7** | Subtle merge candidates missed. `John Caudwell Ashbourne 1845` ≈ `Jon Cauldwell Wirksworth 1845` slips past `DiffEngine`. | Mixed (deterministic for structural, MLX for subtle) | Precision/recall on labelled merge-candidate set |

Two more emerged during this session:

| # | Gap | Cheapest tier |
|---|---|---|
| **G8** | One-off hypothesis pattern doesn't generalise. Adding "burial at parish" or "second marriage" today requires bespoke engine + bespoke result field + bespoke UI. | Deterministic refactor (T11+T12) |
| **G9** | No persistence of hypothesis state across runs. Re-running research from scratch loses the prior session's verdict transitions; user has no way to see "this hypothesis was `.weak` last time, `.supported` now." | Deterministic + new SQL table (T11) |

---

## 4. The proposed framework

### 4.1 `ResearchHypothesis` (T11)

A persistent, deterministic, testable claim. Replaces the bespoke fields on `ResearchResult` (today: `proposedSiblings`, soon-to-be `proposedXYZ` for every new question).

```swift
struct ResearchHypothesis: Identifiable, Sendable {
    /// Stable deterministic ID — `kind.identityKey(profileID)`.
    /// Re-runs upsert; user-rejection persists across runs.
    let id: String

    /// Which profile this hypothesis is about (or `nil` for tree-wide).
    let subjectProfileID: String?

    /// What's being claimed. Each case carries its own typed payload.
    let kind: HypothesisKind

    /// Latest grading. Always one of supported / contradicted / inconclusive.
    let verdict: HypothesisVerdict

    /// Whether the verdict had model input (T8 / T9). Orthogonal to verdict
    /// — see Decision 8. Auto-promote and several other downstream gates
    /// require `verdict == .supported && !isModelAssisted` (see helper below).
    let isModelAssisted: Bool

    /// IDs of records that supported the verdict.
    let supportingEvidence: [String]

    /// IDs of records that contradicted (relevant for `.contradicted` only).
    let contradictingEvidence: [String]

    /// One-line human-readable rationale for the verdict.
    let reasoning: String

    /// When the hypothesis was first generated.
    let createdAt: Date

    /// Last time the verdict was recomputed.
    let lastTestedAt: Date

    /// Trail of (verdict, timestamp) so the UI can show "weak last run → supported now."
    let history: [VerdictTransition]
}

extension ResearchHypothesis {
    /// True iff the verdict is `.supported` AND no model input was used.
    /// Every promotion / auto-accept gate uses this helper — never a bare
    /// `verdict == .supported` comparison. Preserves the deterministic-wins
    /// rule: model output never writes facts.
    var isDeterministicallySupported: Bool {
        verdict == .supported && !isModelAssisted
    }
}

/// Closed enum (Decision 1). Adding a new kind requires touching the enum,
/// the central generator switch, the central grader switch, and the central
/// deficit-query switch (Decision 5). Exhaustive switching catches "forgot
/// to handle the new kind" at compile time.
enum HypothesisKind: Sendable {
    case subjectIdentity(birthYearWindow: Range<Int>, districtHint: String?)
    case parentMarriage(motherSurname: String, fatherSurname: String, windowYears: Range<Int>)
    case siblingExists(district: String, mmn: String, yearWindow: Range<Int>)
    case clusterIsSubject(clusterID: UUID)       // T7's working hypothesis
    case burialAtParish(parish: String, yearWindow: Range<Int>)
    case secondMarriage(afterYear: Int)
    // ... extensible by adding cases here + the three central switches
}

enum HypothesisVerdict: String, Sendable {
    case supported       // evidence points to claim
    case contradicted    // evidence rules claim out
    case inconclusive    // not enough evidence to decide
}

struct VerdictTransition: Sendable {
    let verdict: HypothesisVerdict
    let isModelAssisted: Bool
    let at: Date
    let reason: String
}
```

**Important design choice — separate from `Workbench.Hypothesis`.** The existing `Hypothesis` type in `Models/Workbench/` is user-authored, free-form, and lives on the workbench surface. `ResearchHypothesis` is machine-generated, structured, regenerated each run, and lives on the research surface. They share a name root but not a table. A `.supported` `ResearchHypothesis` may be *promoted* into a `Workbench.Hypothesis` by user action — that's the only crossing.

### 4.2 `HypothesisEngine` (T12)

```swift
@MainActor
enum HypothesisEngine {
    /// Run every registered generator against the current state.
    /// Each generator returns 0..N candidate hypotheses; the engine
    /// dedups by stable ID against persisted hypotheses, tests each
    /// fresh / refreshed hypothesis against available evidence, grades
    /// it, and returns the full set.
    static func runAll(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot,
        persisted: [ResearchHypothesis]
    ) -> [ResearchHypothesis]
}
```

Each `HypothesisKind` participates via **three central switches** in `HypothesisEngine` (Decision 5):

1. **`generate(for kind:state:snapshot:)`** — `(...) -> [ResearchHypothesis]`. Returns 0..N candidate hypotheses (typically deterministic: `.siblingExists` generates one per resolved subject birth where both parents are linked).
2. **`grade(_ hypothesis:state:snapshot:)`** — `(...) -> GradeResult`. Pure function over current evidence; returns `(verdict, supportingIDs, contradictingIDs, reasoning)`.
3. **`deficitQuery(for hypothesis:state:)`** — `(...) -> RecordQuery?`. Declares what one focused query would flip the verdict, or `nil` if the kind has no deterministic deficit query (T7 falls through to T8's MLX next-search in that case).

All three switches live alongside each other in `HypothesisEngine.swift` so every kind's behaviour is greppable in one place. Adding a kind = add the case to `HypothesisKind` + add a clause to each of the three switches; the compiler enforces completeness.

The existing one-offs slot in as generators + graders:

| Existing | Folds in as |
|---|---|
| `SubjectIdentityResolver.resolve` | grader for `.subjectIdentity` |
| `GeographicHypothesisGenerator.inferDistricts` | helper for the `.subjectIdentity` generator |
| `SiblingInferenceEngine.inferSiblings` | grader for `.siblingExists` |
| `MarriageEnrichmentEngine.match` | grader for `.parentMarriage` |
| `ParentInferenceEngine.infer` | generator for `.parentMarriage` (one per (mother MMN, father surname) pair) |

`ResearchResult` gains one new field:

```swift
let hypotheses: [ResearchHypothesis]
```

…and **loses** the bespoke `proposedSiblings` field (sibling proposals become `.siblingExists` hypotheses; `proposedRelatives` is the only legacy field that stays, because parent inference predates this framework and has deeply embedded UI affordances. Migration plan: keep both surfaces in V2; consolidate in V3.)

### 4.3 Persistence (T11)

New SQL migration `v8_research_hypotheses`:

```sql
CREATE TABLE research_hypotheses (
    id TEXT PRIMARY KEY,
    subject_profile_id TEXT,
    kind_discriminator TEXT NOT NULL,
    kind_payload TEXT NOT NULL,         -- JSON
    verdict TEXT NOT NULL,
    supporting_evidence TEXT NOT NULL,  -- JSON array of record IDs
    contradicting_evidence TEXT NOT NULL,
    reasoning TEXT NOT NULL,
    created_at DATETIME NOT NULL,
    last_tested_at DATETIME NOT NULL,
    history TEXT NOT NULL,              -- JSON array of VerdictTransition
    user_rejected INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (subject_profile_id) REFERENCES profiles(id)
);
CREATE INDEX idx_research_hypotheses_subject ON research_hypotheses(subject_profile_id);
CREATE INDEX idx_research_hypotheses_verdict ON research_hypotheses(verdict);
```

**Upsert semantics**: when `HypothesisEngine.runAll` produces a hypothesis whose stable ID already exists in the table, the row is updated (verdict, evidence, reasoning, history append, lastTestedAt) — not replaced. The `created_at` and `history` carry forward.

**User-rejection persists**. A hypothesis the user has explicitly dismissed (e.g. "this sibling isn't mine") flips `user_rejected = 1` and is filtered out of UI display on subsequent runs. (Same mechanism as today's `record_rejections`, just on hypothesis IDs.)

---

## 5. Task-by-task — how each remaining task fits

### 5.1 T11 — Hypothesis type + persistence

**What lands:**
- `Models/Research/ResearchHypothesis.swift` with the type + kind enum + verdict enum + transition record.
- `v8` migration creating `research_hypotheses`.
- `ProjectDatabase` extensions: `loadHypotheses(forProfile:)`, `upsertHypotheses(_:)`, `rejectHypothesis(_:)`.
- `ResearchResult.hypotheses: [ResearchHypothesis]` field (default `[]` so existing callers compile).

**What does NOT land in T11:**
- Generators or graders. T11 ships the type and table; T12 ships the engine that fills them.
- Migration of existing one-offs. The existing `proposedSiblings` field remains during the transition; the new `hypotheses` field sits beside it. Migration happens incrementally as each generator lands in T12.

**Eval criterion:** T11 is structural plumbing; success = unit tests on round-trip persistence + the table queryable from the MCP server (so external tooling can read hypothesis state).

---

### 5.2 T12 — HypothesisEngine: generate, test, grade

T12 splits into two sequenced sub-projects (Decision 3). Each sub-project is itself executed as a 4-phase migration (Decision 2). Total: 8 commits across T12, each individually bisectable, each behaviour-identical to the prior commit until the final phase deletes the legacy field.

#### T12-sibling — fold `.siblingExists` into the framework

**What lands across phases:**

| Phase | What changes |
|---|---|
| 1 | `Services/Research/HypothesisEngine.swift` with `runAll` entry point + central `generate` / `grade` / `deficitQuery` switches. `.siblingExists` case added with generator + grader + deficit-query clauses. `result.hypotheses` field populated. `result.proposedSiblings` still populated by the legacy `findSiblings()` path. Both fields verified identical via tests. |
| 2 | Flip source of truth: `proposedSiblings` becomes `result.hypotheses.filter { kind matches .siblingExists, isDeterministicallySupported }.map(toLegacyShape)`. Legacy `findSiblings()` deleted. Output verified identical to Phase 1 by tests. |
| 3 | UI swaps to read `result.hypotheses` directly. `proposedSiblings` field still exists but unused. View diff trivial. |
| 4 | Delete `proposedSiblings` field. Pure deletion. |

**Generator/grader contract for `.siblingExists`**: generator runs when `SubjectIdentityResolver` returns `.resolved` AND both parents linked; emits one hypothesis per `(district, mmn, yearWindow)`. Hypothesis ID = `sibling:\(profileID):\(district):\(mmn):\(yearWindowKey)`. Grader runs the focused FreeBMD query + existing inference rule:
- `.supported` if ≥1 candidate sibling found AND user hasn't rejected it
- `.contradicted` if query returned zero candidates
- `.inconclusive` if query hit a source error / scope mismatch / quota guard

Deficit query for `.inconclusive`: retry the same district with the next strictness tier (loose, if the first ran at strict).

#### T12-parent — fold `.parentInferred` and `.parentMarriage` into the framework

**Gate**: before Phase 1 of T12-parent, a short **design pass** resolves the marriage-enrichment coupling — does `.parentInferred` contain enrichment evidence internally, or do `.parentInferred` and `.parentMarriage` exist as two cross-referencing kinds? Resolved in a one-section spec addendum, not a code change. Phase 1 begins only after the design pass lands.

**What lands across phases:**

| Phase | What changes |
|---|---|
| 1 | `.parentInferred(gender, surname)` and (per design pass) `.parentMarriage(motherSurname, fatherSurname, window)` kinds added with their generate / grade / deficit-query clauses. Generator runs against subject's confirmed birth records carrying MMN, mirroring `ParentInferenceEngine.infer`. `result.hypotheses` carries the new kinds. `result.proposedRelatives` still populated by the legacy `ParentInferenceEngine` + `MarriageEnrichmentEngine` paths. Both surfaces verified identical via tests. |
| 2 | Flip source of truth: `proposedRelatives` becomes a derived projection from `result.hypotheses`. Legacy inference paths deleted. Cross-validation between `.parentInferred` and `.parentMarriage` (one hypothesis enriches the other's `reasoning` and `supportingEvidence`) implemented via the engine, not via in-place mutation. Output verified identical to Phase 1. |
| 3 | UI swaps to read `result.hypotheses` directly. The "Already linked" detection, "Apply" action, and marriage-enrichment cross-validation cards re-target the new source. Bigger view diff than T12-sibling Phase 3 — the parent UI has more affordances. |
| 4 | Delete `proposedRelatives` field. Pure deletion. |

**Why this ordering (T11 → T12-sibling → T12-parent):**

- T11 is structural — no dependencies, fastest to bake.
- T12-sibling is the smaller test of the framework. Sibling discovery was added recently (T17) so the existing UI is narrow and the surgery is contained.
- T12-parent is the deeper change — older, more deeply integrated, more UI affordances. Doing it after T12-sibling lets us stress the framework once before tackling the bigger lift, and lets us write the marriage-enrichment design pass with full context.

**Eval criterion:** for both sub-projects, the per-profile hypothesis set after each phase is byte-identical to the prior phase's output on a 5–10 profile snapshot corpus. Final phases gain the new transparency: `.contradicted` hypotheses now surface with reasoning rather than vanishing silently.

---

### 5.3 T7 — Hypothesis-guided second pass

**What lands:**
- A second-pass entry point in `ResearchPipeline` that runs after the first pass completes: `researchSecondPass(firstResult:state:)`.
- The pass examines `firstResult.hypotheses` and selects those with `verdict == .inconclusive` and `kind` whose grader supports "what would I need to flip this?" — call it a *deficit query*.
- For each, issue **one focused query** designed to settle the hypothesis. Examples:
  - `.subjectIdentity` inconclusive (≥2 candidates after geographic filter) → query FreeCen 1881/1891/1901 in each candidate's district for the same household; whichever district produces a credible parents-and-subject household resolves it.
  - `.clusterIsSubject` weak (one cluster, one fact, no corroboration) → re-query an adjacent district at the next strictness tier.
  - `.parentMarriage` inconclusive (no marriage hit) → widen the year window from ±30 to ±40, OR try the next adjacent county.
- Append new evidence to `state`, re-run `HypothesisEngine.runAll`, recompute clusters.

**Stall-detection contract (Decision 4)**:

T7 fires the second pass when **both** are true:

1. **Variant-exhaustion**: the dispatcher has walked the full strictness ladder for every applicable source in the first pass (no headroom in the existing tier mechanism), AND
2. **Deficit-eligible inconclusive hypothesis**: the first pass produced at least one `.inconclusive` hypothesis whose `deficitQuery(for:)` returns non-nil.

The second pass runs **at most once** per `research(...)` call. Cost ceiling: roughly N additional focused queries where N = count of deficit-eligible inconclusive hypotheses (typically 1–3 in practice).

Hypotheses with `deficitQuery == nil` fall through to T8's MLX next-search fallback (§5.4) — the rules have explicitly given up, so we ask the model.

**Why deterministic and not MLX:** every kind's deficit query is a deterministic rewrite of its own grader's inputs. "Try the next adjacent district" is graph traversal; "widen the year window" is arithmetic. MLX shouldn't decide where to look when the rules know perfectly well.

**Eval criterion:** held-out corpus of profiles known to stall in first pass — measure fact uplift after T7's second pass. Target: ≥30% of stalled profiles gain at least one new `.supported` hypothesis.

---

### 5.4 T8 — MLX next-search suggestion for weak verdicts

**What lands:**
- An MLX prompt + a `ResearchInterpreter.suggestForWeakHypothesis(hypothesis:state:availableSources:)` entry point.
- Wired into T7's second pass: when T7 finds an inconclusive hypothesis whose generator has **no deficit query** (the rules genuinely don't know what to try), T8 is the fallback. It asks the model "given this hypothesis and what we know, what would you search?"
- Output is restricted to `(sourceID, recordType, queryHints)` — structured, not free-form. The deterministic dispatcher still builds and runs the query.

**Why local MLX, not Claude API (Decision 7)**:

`LLM_RESEARCH_OPTIONS.md` §6 argued the Claude API has the latency/quality edge for planner-class tasks. We're shipping T8 on local MLX anyway because:

1. **App Store posture**. We stripped outbound AI calls in May 2026 (T18, T20) specifically to clean the privacy disclosure surface. Re-introducing them is non-trivial — new privacy disclosure, possibly a new review cycle, and re-tackling "what does your app send where?"
2. **Task shape differs from the portfolio doc's framing**. T8's calls are structured-output, tie-break/fallback, low-frequency. That's easier territory for a 7B-4bit model than the open-ended planning the portfolio doc was sceptical about.
3. **The escape valve is a measured fallback, not a permanent ceiling**. The eval harness (§5.8) will reveal whether MLX quality is genuinely insufficient. If it is, a future task escalates to API — at which point we tackle the App Store implications with eyes open, having data to defend the move.

Both `verdict` and `isModelAssisted = true` are set on hypotheses T8 influences (Decision 8). Downstream consumers use `isDeterministicallySupported` to gate auto-promote and similar deterministic-only paths.

**Eval criterion:** for the subset of stalled-and-T7-stuck profiles, measure fact uplift after T8 fires. Target: ≥10% of T7-stuck profiles gain at least one `.supported` hypothesis on the third pass. (Lower bar than T7 because T8 is the last resort.)

---

### 5.5 T9 — MLX free-text disambiguation pass

**What lands:**
- `ResearchInterpreter.disambiguateIdentity(candidates:state:)` entry point.
- Wired into the `.subjectIdentity` grader: when `SubjectIdentityResolver.resolve` returns `.ambiguous`, AND T7's deterministic deficit query also doesn't resolve it (e.g. census didn't disambiguate), AND the candidates have free-text fields the deterministic resolver can't compare (notes, occupations, partial addresses in raw record fields), T9 asks the model "given these candidates and what we know about the subject, which is most plausible?"
- Output is again structured: `(preferredCandidateID, confidence, reasoning)`. The resolver only acts on it when `confidence ≥ threshold` (TBD), and even then the hypothesis grading flags it as model-assisted.

**Why MLX is right here and not for grading:**

The grader's contract is "rules decide, model never overrules." T9 doesn't overrule — it operates only when the rules return `.ambiguous` (i.e. the rules have explicitly given up). The model is breaking ties, not making findings.

Tie-breaks that T9 settles set `isModelAssisted = true` on the resulting hypothesis (Decision 8). Auto-promote and other deterministic-only gates skip these via `isDeterministicallySupported`. The user-facing UI surfaces a model-assisted badge so the user knows to treat the verdict with appropriate scepticism.

Same App Store / local-vs-API rationale as T8 (Decision 7): MLX now, escape valve to API later if eval harness shows quality is insufficient.

**Eval criterion:** held-out corpus of profiles where `SubjectIdentityResolver` returns `.ambiguous`; measure resolution rate via T9, with user-agreement as the success signal. Target: ≥50% user-agreement on tie-breaks. Low target because tie-breaks are inherently hard.

---

### 5.6 T23 — Guided Sample Tree tour (out of band)

**Out of architectural scope, in scope for completeness.** A first-launch tour that walks the user through the Sample Tree's features (Tree / Audit / Research / Leads / Settings). Pure UX work. No pipeline impact.

**What lands:**
- An overlay coachmark sequence triggered when the user opens the Sample Tree from the welcome screen.
- ~5 steps: tree navigation, opening Audit, running Research on a sample subject, reviewing leads, finding Settings.
- "Skip tour" / "Don't show again" affordances.

**Build order independence:** T23 can ship at any time without touching anything in §5.1–5.5. Recommended to slot in between the V2 framework landing and the MLX work, when there's a stable target for the tour to walk against.

---

### 5.7 T31 — Empirical retuning of research modes (out of band)

**Out of architectural scope, in scope for the eval harness.** Today the four research modes (`.verify`, `.extend`, `.discover`, `.all`) have hand-picked iteration counts (2, 4, 4, 6) and fact caps (20, 50, 100, 200). These were guesses.

**What lands:**
- The eval harness from §5.8 (build once, use everywhere).
- A short experiment that runs every mode against the held-out corpus and reports precision/recall/runtime per mode.
- Updated `ResearchConfig` constants based on observed knees in the precision/recall curve.

**Build order:** T31 depends on the eval harness, which is also a prerequisite for T8/T9. Recommended order: eval harness lands first (§5.8), T31 then runs as a one-shot experiment to retune the constants.

---

### 5.8 Eval harness (prerequisite for T8 / T9 / T31)

Not a numbered task, but a load-bearing piece of infrastructure that ships before T8 / T9 / T31 can have defensible deltas. The portfolio doc (`archive/LLM_RESEARCH_OPTIONS.md` §9) sketched this; Decision 6 commits to its shape with three refinements and a starter-then-grow corpus strategy.

**What lands:**

- **Corpus**: starts at **3 hand-curated profiles** drawn from the user's real tree, each with a documented ground-truth `.fact` set + "should remain absent" set (the hallucination-guardrail check). Grows over time as the user finds more difficult cases worth canonicalising — the file format is append-only so new profiles slot in without churn.
- **Runner**: a CLI scheme target (`swift run eval` or equivalent) that invokes `ResearchPipeline.research(...)` against each profile in the corpus. **Snapshot-based** (refinement 2): each profile evaluates against a frozen snapshot of the family graph at that profile's id, taken at eval-start, so running T11 / T12 doesn't drift the corpus as accepted relatives land back in the tree.
- **Metrics**: precision (% of `.fact` verdicts matching ground truth), recall (% of ground-truth facts surfaced as `.fact`), contradiction count. Reported **per hypothesis kind** (refinement 1) so each task's eval criterion maps onto its kind's `.supported / .contradicted / .inconclusive` distribution.
- **Reporting**: per-kind metrics for diagnosis, plus a **single headline number** (refinement 3) — "net `.supported` deterministic hypotheses across the corpus" — that goes into commit messages as the before/after delta.
- **CI**: optional; manual `swift run eval` is enough to start.

**Eval criterion** (recursive but real): the harness itself is "successful" once each currently-pending task can be reasoned about with a before/after number rather than handwaving.

**Build order:** ships **before** T7 (so T7 has a measurable uplift number on landing), **before** T8 / T9 (mandatory — these can't be evaluated without it), and **before** T31 (which is purely the harness applied to mode constants).

---

## 6. Holistic architecture (post-V2)

```
┌─────────────────────────────────────────────────────────────────────────┐
│  ResearchPipeline.research(subject:, config:)                           │
│                                                                          │
│  PASS 1 (deterministic iterative core, ~unchanged from today):          │
│    1. dispatch  →  score  →  dedup                                      │
│    2. extract household / detect discrepancies / refine subject         │
│    3. ParentInferenceEngine.infer                                       │
│    4. (first iteration with proposals) MarriageEnrichmentEngine.match   │
│    5. (between iterations) ResearchInterpreter.suggestNextSearch        │
│    6. stopping checks                                                   │
│                                                                          │
│  POST-PASS-1 (unchanged):                                               │
│    7. ClusteringEngine.cluster                                          │
│                                                                          │
│  NEW: HypothesisEngine.runAll(state, snapshot, persisted)               │
│    • Generators per kind (SubjectIdentity, ParentMarriage,              │
│      SiblingExists, ClusterIsSubject, ...)                              │
│    • Graders per kind (deterministic)                                   │
│    • Persistent upsert keyed on stable hypothesis ID                    │
│    • Return [ResearchHypothesis]                                        │
│                                                                          │
│  PASS 2 (T7: hypothesis-guided second pass, fires when                  │
│           strictness exhausted AND ≥1 inconclusive deficit hypothesis): │
│    8. For each inconclusive hypothesis with a deficit query:            │
│       a. dispatch deficit query                                         │
│       b. (T8 fallback if no deficit query) MLX next-search              │
│    9. score / dedup / append to state                                   │
│   10. HypothesisEngine.runAll again — re-test, re-grade                 │
│                                                                          │
│  PASS 3 (T9: MLX tie-break for residual ambiguity)                      │
│   11. For each ambiguous .subjectIdentity hypothesis the rules          │
│       couldn't settle:                                                  │
│       a. MLX disambiguate (structured output, threshold-gated)          │
│       b. annotate the hypothesis as model-assisted                      │
│                                                                          │
│  RESULT ASSEMBLY:                                                       │
│   12. clusters (recomputed if Pass 2 added evidence)                    │
│   13. hypotheses (all kinds, persisted)                                 │
│   14. legacy fields — during T12 transition only, derived as            │
│       projections of `hypotheses`. Deleted by final phase of each       │
│       T12 sub-project (proposedSiblings, then proposedRelatives).       │
└─────────────────────────────────────────────────────────────────────────┘

Persistence: research_hypotheses (v8) — upserted across runs.
             record_rejections (v2) — extended to reject by hypothesis ID.
             evidence_records (v4) — unchanged.
```

**Key invariants preserved**:

- Deterministic-wins. Graders are rules; MLX (T8/T9) only enters when rules return `.inconclusive` / `.ambiguous`.
- Evidence Firewall. Hypothesis verdicts don't write to Profile or Relationship; user accept actions still go through `acceptProposedRelative` / `acceptSiblingProposal` paths.
- Apply contract. Overwrite-safe fill-nil-only.
- Re-runnability. Same project + same code = same hypothesis set + same verdicts (modulo MLX nondeterminism in T8/T9, which is annotated on the hypothesis).

---

## 7. Decisions made

Eight substantive design choices resolved during the 2026-05-19 spec walk-through, plus one carry-over from the original spec draft. Each is now load-bearing for the corresponding task. Section numbers match the walk-through order so inline "Decision N" references throughout the spec resolve to "§7.N".

### 7.1 — `HypothesisKind` shape

**Resolution**: **closed Swift enum with associated values**. Adding a new kind requires touching the enum + three central switches in `HypothesisEngine` (generate / grade / deficitQuery) — explicit, greppable, compile-time exhaustive.

Rejected alternative (protocol-based, open kinds): more open but worse for persistence (type-erased payloads) and loses compile-time exhaustiveness. The openness doesn't buy us much because each kind requires per-case domain logic anyway.

### 7.2 — Migration of `proposedSiblings` (T12-sibling)

**Resolution**: **hard migration executed as four bisectable phases** — Phase 1 in-place duplicate (new framework runs alongside legacy `findSiblings()`, outputs verified identical), Phase 2 flip source of truth (legacy field becomes a projection of `result.hypotheses`, original engine deleted), Phase 3 swap UI to read `result.hypotheses` directly, Phase 4 delete `proposedSiblings` field.

Rejected alternative (soft migration, leave legacy field indefinitely): "we'll evaluate later if it's worth removing" typically becomes "we never get around to it," leaving the framework permanently asymmetric.

Full phase-by-phase contract in §5.2 (T12-sibling).

### 7.3 — Fold `proposedRelatives` into the framework too (T12-parent)

**Resolution**: **yes, with the same four-phase pattern as T12-sibling, sequenced after it.** The argument for folding it: consistency. The earlier argument against (UI complexity) is solved by the phasing — Phase 3 absorbs the UI surgery in one bisectable commit, Phase 4 deletes the legacy field.

A short **marriage-enrichment design pass** sits between T12-sibling Phase 4 and T12-parent Phase 1 to resolve whether `.parentInferred` and `.parentMarriage` are one bundled hypothesis or two cross-referencing kinds (residual question §10.1).

Rejected alternative (defer to follow-up task): leaves the framework asymmetric for an unbounded period, and re-builds context cost when we eventually do it.

### 7.4 — Stall-detection contract for T7

**Resolution**: T7's second pass fires when **both** (a) the dispatcher has walked the full strictness ladder for every applicable source AND (b) ≥1 `.inconclusive` hypothesis has a non-nil `deficitQuery`.

Rejected alternatives: zero-new-facts iteration (fires too often, wastes source quota on cases where the rules haven't tried everything yet); confidence-floor stall (adds extra knobs to tune per mode, when the existing verdict axis is the better signal); variant-exhaustion alone (fires even when there's nothing concrete to retry).

The two-condition contract requires every kind to declare a deficit query — costed in T11 anyway, so no new cost.

### 7.5 — Deficit query declaration style

**Resolution**: **central switch in `HypothesisEngine`** alongside the `generate` and `grade` switches. All three switches live in one file, keyed off the same `HypothesisKind` enum.

Rejected alternative (per-kind handler structs in separate files): co-locates the three pieces nicely per kind but spreads kind-handling across the codebase. We chose the central-switch pattern in §7.1 and this decision applies the same logic — one place to find every kind's behaviour.

Rejected alternative (discovered, via reflection): magical, fragile, not seriously considered.

### 7.6 — Eval harness scope and rollout

**Resolution**: commit to the `archive/LLM_RESEARCH_OPTIONS.md` §9 spec with **three refinements**, executed as a **3-profile starter corpus that grows over time**:

1. Per-hypothesis-kind reporting (not per-gap-class) — matches the framework's natural unit.
2. Snapshot-based evaluation — each profile evaluates against a frozen `FamilyGraphSnapshot` taken at eval-start, so accepted relatives from prior runs don't drift the corpus.
3. Single headline number — "net `.supported` deterministic hypotheses across the corpus" — for commit-message deltas, in addition to per-kind diagnostics.

Full spec in §5.8.

### 7.7 — Local MLX vs Claude API for T8 / T9

**Resolution**: **local MLX for T8 and T9** as initial path. Escape-valve to API in a future task if the eval harness shows MLX is leaving findings on the table (threshold quantified when harness data exists).

Rejected alternative (Claude API directly): re-introducing outbound AI calls would partially undo the App Store posture work shipped in May 2026 (T18, T20). Worth doing only with data to defend the move — which the eval harness provides.

### 7.8 — MLX nondeterminism representation

**Resolution**: **orthogonal `isModelAssisted: Bool` field** on `ResearchHypothesis`, not a new verdict case. Auto-promote and similar deterministic-only gates use the `isDeterministicallySupported` helper (= `verdict == .supported && !isModelAssisted`).

Rejected alternative (new `.modelSupported` verdict case): conflates verdict and provenance, which are orthogonal axes. Would also force inventing `.modelContradicted` and `.modelInconclusive` to be consistent, doubling the verdict enum to capture what is really one bit of metadata.

Mitigation for the flag's mild error-prone-ness: every consumer uses `isDeterministicallySupported` (or an analogous helper), never bare `verdict ==` comparisons for promotion decisions.

### 7.9 — Cluster-aware scoring (out of V2 scope)

**Resolution**: deferred. Important (gates the G1 cross-profile dedup task in `archive/LLM_RESEARCH_OPTIONS.md` §8) but neither in the current task list nor a prerequisite for any V2 task. Tracked here so it isn't lost.

---

## 8. Build order

Strict dependencies (post-decisions):

```
T11 (type + v8 migration + persistence helpers)
 └─→ T12-sibling Phase 1–4 (.siblingExists folds in)
      └─→ T12-parent design-pass (marriage-enrichment coupling)
           └─→ T12-parent Phase 1–4 (.parentInferred + .parentMarriage fold in)
                ├─→ Eval harness (§5.8)
                │    ├─→ T7 (second pass; deficit queries)
                │    │    ├─→ T8 (MLX next-search for T7-stuck)
                │    │    └─→ T9 (MLX disambiguation for residual ambiguity)
                │    └─→ T31 (mode retuning, one-shot experiment)
                └─→ T23 (Sample Tree tour, any time post-T12)
```

Recommended session-by-session sequence:

1. **T11** (~1–2 sessions). `ResearchHypothesis` type, `v8` migration, persistence helpers, MCP read-only exposure. Unit-test round-trip.
2. **T12-sibling** (~2–3 sessions). Four bisectable commits (Phase 1–4) folding `.siblingExists` in. Tests assert byte-identical output to T17's existing engine between phases.
3. **T12-parent design pass** (~½ session, doc only). Spec addendum resolving the marriage-enrichment coupling — one bundled `.parentInferred` kind whose grader includes enrichment, vs two cross-referencing `.parentInferred` + `.parentMarriage` kinds. Decision recorded before code.
4. **T12-parent** (~3–4 sessions). Four bisectable commits folding parents + marriage enrichment in per the design pass. Tests assert byte-identical output to existing `ParentInferenceEngine` + `MarriageEnrichmentEngine` between phases.
5. **Eval harness** (~1–2 sessions). §5.8 deliverables: runner, 3-profile starter corpus with ground-truth annotations, per-kind reporting, single-headline summary.
6. **T7** (~2 sessions). Second-pass loop, deterministic deficit queries only. First task with eval-harness-backed delta in its commit message.
7. **T31** (~1 session). One-shot retuning experiment using the harness.
8. **T8** (~2 sessions). MLX fallback for T7-stuck hypotheses with no deficit query. Sets `isModelAssisted = true`.
9. **T9** (~2 sessions). MLX tie-break for residual `.subjectIdentity` ambiguity. Sets `isModelAssisted = true`.
10. **T23** (~1–2 sessions). Sample Tree tour. Slot in anywhere after T12-parent stabilises.

Estimated total: 16–21 sessions. Each task commit-message carries the eval-harness delta (from §5.8 onwards). T11 / T12 commits use byte-equality regression tests as their delta.

---

## 9. What this V2 does NOT do

Holdovers, explicitly out of scope:

- **G1 (cross-profile dedup).** Important, called out in §3, but not in the current task list. Future task.
- **G7 (subtle merge detection).** Same.
- **MLX as primary grader.** No. Graders stay rule-based. MLX only enters when rules return inconclusive/ambiguous.
- **Per-source autotuning.** Today's per-source strictness configs (T37, T38) are static and stay static. Adaptive tuning is a future task.
- **Cluster-aware scoring.** §7.9 flagged. Out of V2 scope.
- **Workbench.Hypothesis ↔ ResearchHypothesis automatic crossover.** A `.supported` ResearchHypothesis can be promoted to a Workbench.Hypothesis by user action only — no automatic flow.

---

## 10. Residual questions deferred to implementation time

Small, well-bounded questions that don't require resolution before T11 starts. Each will surface naturally during the task that gates it and is captured here so it isn't lost.

1. **Marriage-enrichment coupling** (gates T12-parent Phase 1). Should `.parentInferred` contain enrichment evidence internally, or do `.parentInferred` and `.parentMarriage` exist as two cross-referencing kinds with the engine reconciling them? Resolved by the half-session design pass between T12-sibling completion and T12-parent Phase 1 (per §8 sequence step 3).

2. **MLX confidence threshold for T9 tie-breaks**. T9 only acts on the model's preferred candidate when its self-reported confidence ≥ some threshold. The threshold is "TBD when harness lands" — to be set empirically once we can measure agreement-rate per threshold value.

3. **Escape-valve threshold for Local→API escalation (T8, T9)**. The eval harness will give us per-task miss-rate numbers; the threshold at which we file a "escalate to Claude API" task is TBD pending those numbers.

4. **Hypothesis kinds we haven't yet enumerated.** §4.1's enum lists the kinds we know we need (`subjectIdentity`, `parentMarriage`, `siblingExists`, `clusterIsSubject`, `burialAtParish`, `secondMarriage`). The framework is designed to absorb new kinds without architectural change. Future kinds (death-in-district, occupation-trajectory, address-change-event) are out of V2 scope but slot in via the same three-switch pattern when their task lands.

---

## 11. Net summary

This spec is the single architectural pivot from bespoke "research question → bespoke engine" to a generalisable `ResearchHypothesis` framework. Five of the seven remaining tasks (T7, T8, T9, T11, T12) compose around it. Two (T23, T31) sit outside as independent. The eval harness (§5.8) is the load-bearing prerequisite for T7 / T8 / T9 / T31 — it ships between T12 and T7.

Eight design decisions resolved on 2026-05-19 (see §7) close the holistic-alignment gate that prompted this spec. Implementation begins with T11.

Invariants preserved through V2: deterministic-wins (rules grade, model never overrules); Evidence Firewall (hypothesis verdicts don't write to Profile or Relationship); Apply contract (overwrite-safe fill-nil-only); re-runnability (same project + code = same deterministic hypothesis set, modulo `isModelAssisted` annotation on T8/T9-influenced verdicts).

---

*End of V2 spec.*
