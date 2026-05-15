# Research Confidence — Specification

**Status:** Draft. No changes implemented yet.
**Scope:** SwiftUI `Ancestor Research` app (`/Users/darrylcauldwell/Development/ancestor/Ancestor Research/`)
**Date:** 2026-05-15
**Author context:** Manual UX testing surfaced a recurring contradiction: a single FreeBMD birth record can simultaneously show a "Moderate" parent-inference proposal and a "Weak" cluster card for the same underlying evidence, because the app currently uses a single tier badge (`Weak / Moderate / Strong`) to communicate three structurally different signals — match quality, sourcing strength, and inference depth. This spec separates those three into independent UI dimensions, eliminates the contradiction at source, and aligns the model with how working genealogy researchers actually document evidence.

---

## 1. Problem statement

The current confidence model uses one enum (`ClusterConfidence: weak | moderate | strong`) and one verdict (`RecordVerdict: fact | lead | impossible`), surfaced in the UI as a single colour-coded tier badge per card. The same badge appears on:

1. Cluster cards in cluster review
2. Proposed-relative cards in parent inference
3. Profile detail views
4. Audit findings

Across these surfaces, the badge is asked to communicate at least three different things:

| Axis | The question it answers | Today's surface |
|---|---|---|
| **Match quality** | "Does this record describe the right person?" | Implicit in `RecordVerdict`; surfaces as gate ticks (✓/✗) on records |
| **Sourcing strength** | "How many independent sources corroborate this?" | `ClusterConfidence` (heavily weighted on convergence count); has no dedicated UI element |
| **Inference depth** | "How many derivational leaps did we take?" | Hidden — parent inferences inherit cluster confidence directly |

**The contradiction is by design but reads as a bug.** A single-record cluster with a fully-passing FreeBMD birth record gets `ClusterConfidence.weak` (one source can't corroborate itself, per `ConvergenceEngine` rules) but a parent-inference derived from the same record reports `Moderate` (because the record-verdict is `fact`). The user sees two different tier badges on adjacent cards driven by the same evidence and reasonably wonders which to trust.

The four downstream effects:

1. **Cognitive load**: every screen requires the user to mentally reconcile multiple tiers
2. **Erased signal**: bundling sourcing strength into one badge loses information about WHY confidence is what it is — was the gate match weak, or do we just have one source?
3. **Wrong message**: "Weak" reads as doubt about whether the data is correct. For a single-source fact record, the data is correct; what's "weak" is the corroboration count
4. **Future-incompatible**: as Field Researcher findings, GEDCOM imports, and multi-source convergence land, the single-badge model becomes less expressive, not more

---

## 2. Design decisions locked during planning

Settled before implementation; not open questions for the implementation phase:

| Decision | Choice | Rationale |
|---|---|---|
| Number of axes | **Three** — match quality, sourcing strength, inference depth | Each answers a question the others can't; researchers track them separately |
| UI representation | **Three separate visual elements**, not one composite tier | Explicit separation eliminates the conflation that caused the problem; matches researcher mental model |
| Primary axis | **Match quality** is primary (most prominent); sourcing is secondary; inference depth is tertiary (only shown when > 0) | Match quality is what determines "is this even the right person?" — everything else is qualification |
| Match-quality model | **Reuse `RecordVerdict`** (`fact / lead / impossible`); no new type | The 4-gate scorer is the right place to compute this; no need to duplicate |
| Match-quality display | Three icons + colour: ✓ green (confirmed = fact), ? amber (possible = lead), ✗ red (impossible) | Already aligns with the gate-tick visual language in cluster cards |
| Sourcing-strength model | **Source count + independent-lineage count + top trust tier** as a struct | `ConvergenceEngine` already produces this signal; surfacing it directly avoids re-derivation |
| Sourcing-strength display | Chip with count + qualifier: "1 source", "3 sources · cross-referenced", "primary + 2 transcriptions" | Concrete and informative; no abstract tier |
| Inference-depth model | **Integer count** of derivational steps from a directly-observed record | 0 = direct fact; 1 = one inference step (parent from child's record); n = nested |
| Inference-depth display | Pill badge: "Inferred — 1 step" (only when > 0) | Direct evidence doesn't need a label; inferred evidence always does |
| `ClusterConfidence` enum fate | **Remove entirely** in Change 5 once all consumers are migrated | Old enum can't be cleanly mapped onto the three new axes; keeping a shim would re-introduce the conflation |
| Stored-vs-derived | **Derive on display** from stored components; do not persist a single combined "confidence" enum | Lets the model evolve without schema churn; keeps the source of truth at the data layer |
| Migration approach | **Breaking, not backwards-compatible.** Re-derive confidence from existing records at first launch after the change ships | Single-user app — no cross-version compat needed; clean break is cheaper than alias layer |
| Schema impact | Remove the `cluster_confidence` column if persisted; add derived fields if needed | Reassess during Change 1 once the data model is concrete |
| Relationship to `RESEARCH_PIPELINE_SPEC` | This spec **amends** §4 of `RESEARCH_PIPELINE_SPEC.md` (cluster confidence rules). The pipeline spec gets a brief amendment commit after this lands | Avoid spec drift |
| Colour vocabulary | Keep current green / amber / red per axis, but each axis has its own colour interpretation | Match-quality green = "right person"; sourcing green = "cross-referenced"; inference green = "direct" |
| Accessibility | Each badge carries explicit textual label and tooltip; colour is never the only signal | Same standard as the rest of the app per the AppTypography convention |

---

## 3. The three axes — locked semantics

### 3.1 Match quality

```swift
nonisolated enum MatchQuality: String, Sendable, Codable {
    case confirmed   // RecordVerdict.fact: all 4 gates pass with no soft fails
    case possible    // RecordVerdict.lead: gates pass but at least one soft fail
    case wrong       // RecordVerdict.impossible: name hard-fail or date hard-fail
}
```

Derived directly from `RecordVerdict`. **Per-record-per-subject** — the same FreeBMD record can be `confirmed` for one subject and `wrong` for another. No change to gate computation.

**Aggregation rules** for surfaces that need a single match-quality across multiple records (cluster card, profile detail):

- Best-record-wins: the cluster/profile's match quality = the strongest match across its records (i.e. `confirmed` beats `possible` beats `wrong`)
- Counts surface separately as part of sourcing strength

### 3.2 Sourcing strength

```swift
nonisolated struct SourcingStrength: Sendable, Codable {
    let sourceCount: Int              // distinct records contributing
    let independentLineageCount: Int  // distinct evidence lineages per ConvergenceEngine
    let topTrustTier: SourceTrustTier // best trust tier across sources
}
```

Computed by `ConvergenceEngine` (logic already exists; this exposes it explicitly). **Lineage independence** is the convergence-aware count — two FreeBMD records of the same event don't count as two lineages; a FreeBMD birth + a FindAGrave grave + a parish baptism are three lineages.

**Display rules**:

| State | Chip text |
|---|---|
| `sourceCount == 1` | "1 source" |
| `sourceCount > 1`, `independentLineageCount == 1` | "N sources · same lineage" |
| `sourceCount > 1`, `independentLineageCount >= 2` | "N sources · cross-referenced" |
| `topTrustTier == .primary` | suffix "· primary record" |

### 3.3 Inference depth

```swift
nonisolated struct InferenceDepth: Sendable, Codable {
    let steps: Int            // 0 = direct, 1 = one derivation, etc.
    let chain: [String]       // human-readable provenance chain
}
```

- **0 steps** — fact read directly from a source record (e.g. birth date from a BMD index entry)
- **1 step** — derived from a direct record (e.g. mother's identity from a child's birth record; spouse's birth window from a marriage record's age field)
- **2+ steps** — nested derivation (e.g. grandparent inferred from a parent's inferred birth record). Each step traverses one inference engine output.

**Display rule**: only render the inference badge when `steps > 0`. Direct facts get no inference label.

---

## 4. UI representation

### 4.1 Combined badge layout

A new `ConfidenceBadgeView` SwiftUI component renders the three axes horizontally:

```
[✓ Confirmed]  [3 sources · cross-referenced · primary]  [Inferred — 1 step]
   match              sourcing                              inference (when >0)
```

- **Match quality**: icon-led, primary visual weight. Green/amber/red, with text label.
- **Sourcing strength**: chip style, secondary visual weight. Neutral background with optional green outline when cross-referenced.
- **Inference depth**: pill style, tertiary visual weight, rendered only when `steps > 0`. Italicised label.

### 4.2 Surfaces that get the new badge

1. **Cluster review cards** — replaces the existing "Weak / Moderate / Strong" tier badge
2. **Proposed-relative cards** (parent inference) — replaces inherited cluster-confidence tier; sourcing reflects the record(s) the inference was derived from; inference depth is set to 1+
3. **Profile detail header** — when implemented, shows the aggregate confidence for the profile's identity
4. **Audit findings** — when applicable, uses match-quality icon only (audits don't carry sourcing context)

### 4.3 Tooltips

Each axis carries its own tooltip text:

- Match-quality `confirmed`: "All scoring gates passed — name, date, geography, and family context all consistent."
- Match-quality `possible`: "The record matched on name and date but at least one gate soft-failed."
- Sourcing chip: "N records contribute, from M independent lineages. Cross-referenced means ≥2 lineages agree."
- Inference badge: "This finding was derived from a directly-observed record. Each step adds derivation distance from primary evidence."

---

## 5. Internal data model

### 5.1 New types

Three new types in `Models/Research/`:

```swift
nonisolated enum MatchQuality: String, Sendable, Codable { … }
nonisolated struct SourcingStrength: Sendable, Codable { … }
nonisolated struct InferenceDepth: Sendable, Codable { … }
```

Plus a combined wrapper for surfaces that want all three:

```swift
nonisolated struct EvidenceConfidence: Sendable, Codable {
    let matchQuality: MatchQuality
    let sourcing: SourcingStrength
    let inference: InferenceDepth
}
```

### 5.2 Removed types

Once Change 5 lands:

- `ClusterConfidence` enum (currently `weak / moderate / strong`) — removed entirely
- `LifeCluster.confidence: ClusterConfidence` — replaced by computing `EvidenceConfidence` on demand from cluster members
- Any persisted `cluster_confidence` column — drop in a schema migration

### 5.3 Engines that produce confidence

- `RecordScorer` continues to produce `RecordVerdict` per record; mapping to `MatchQuality` is a thin shim
- `ConvergenceEngine` exposes `SourcingStrength` (logic already largely present)
- `ParentInferenceEngine` attaches `InferenceDepth.steps = 1` to its proposals; nested inferences increment
- `ClusteringEngine` no longer assigns a single tier; instead, callers compute `EvidenceConfidence` from cluster members via a new helper

---

## 6. Migration

Single-user app — breaking change is acceptable. Approach:

1. Change 1 introduces the new types but leaves `ClusterConfidence` intact
2. Change 2 computes both old and new in parallel; old stays for backwards-compat of in-flight UI
3. Change 3 ships the new `ConfidenceBadgeView` and migrates the cluster card
4. Change 4 migrates the remaining display surfaces
5. Change 5 removes `ClusterConfidence`, drops any persisted column, updates the spec
6. Change 6 amends `RESEARCH_PIPELINE_SPEC.md` §4

At each step, the test suite stays green. No data loss — confidence is derived from records, which don't change.

---

## 7. Numbered Changes with acceptance criteria

### Change 1 — Confidence model types

- Add `MatchQuality`, `SourcingStrength`, `InferenceDepth`, `EvidenceConfidence` to `Models/Research/`
- Add `RecordVerdict.matchQuality` computed property (returns the corresponding `MatchQuality` case)
- No callers yet; existing code untouched. Set up for Change 2.

**Acceptance criteria:**
- **AC1.1** All four new types compile with `Sendable`, `Codable`, doc comments.
- **AC1.2** `RecordVerdict(.fact).matchQuality == .confirmed`; `.lead → .possible`; `.impossible → .wrong`.
- **AC1.3** `SourcingStrength` default initialiser yields `(0, 0, .transcription)` and is `Codable` round-trip stable.
- **AC1.4** `InferenceDepth.direct` static returns `(steps: 0, chain: [])`.

### Change 2 — Compute the three axes alongside existing confidence

- `ConvergenceEngine` gains `sourcingStrength(for: LifeCluster) -> SourcingStrength`
- `ParentInferenceEngine` attaches `InferenceDepth` to each proposed relative
- `LifeCluster` gains `var evidenceConfidence: EvidenceConfidence { computed }` derived from members
- Old `ClusterConfidence` continues to exist and serve current UI; no display change yet

**Acceptance criteria:**
- **AC2.1** `ConvergenceEngine.sourcingStrength(for:)` returns `sourceCount == cluster.records.count`.
- **AC2.2** Two FreeBMD records of the same event yield `independentLineageCount == 1`; one FreeBMD + one CWGC yields `2`.
- **AC2.3** A parent-inference proposal carries `inferenceDepth.steps == 1`.
- **AC2.4** `LifeCluster.evidenceConfidence.matchQuality` is the strongest `MatchQuality` across cluster members.
- **AC2.5** Full test suite passes — no behaviour change observable externally.

### Change 3 — `ConfidenceBadgeView` SwiftUI primitive

- New `Views/Components/ConfidenceBadgeView.swift`
- Renders match-quality icon + sourcing chip + (conditional) inference pill
- Accepts an `EvidenceConfidence` and renders all three axes in one horizontal row
- Tooltips per axis per §4.3
- Migrate the cluster card in `ClusterReviewView` to use it; other surfaces follow in Change 4

**Acceptance criteria:**
- **AC3.1** `ConfidenceBadgeView(confidence: …)` renders three axes when `inference.steps > 0`, two when `steps == 0`.
- **AC3.2** Match-quality icon colour: green for `.confirmed`, amber for `.possible`, red for `.wrong`. Snapshot-tested.
- **AC3.3** Sourcing chip text matches the §3.2 table for representative inputs.
- **AC3.4** Tooltip strings present on each axis; accessibility labels include the axis name + value.
- **AC3.5** Cluster cards visually adopt the new badge; the legacy tier badge is removed from cluster cards specifically.

### Change 4 — Migrate remaining display surfaces

- Proposed-relative cards (parent inference) adopt `ConfidenceBadgeView`
- Profile detail header (where confidence is currently shown) adopts it
- Audit findings — adopt the match-quality icon only (sourcing context doesn't apply)
- Any other surface in `Views/` showing a tier badge gets migrated

**Acceptance criteria:**
- **AC4.1** Proposed-relative cards no longer show "Weak / Moderate / Strong"; they show the three-axis badge with sourcing reflecting the records the inference is derived from.
- **AC4.2** A parent-inference card derived from a single fact record renders as: ✓ Confirmed · 1 source · Inferred (1 step).
- **AC4.3** No view in `Views/` uses `ClusterConfidence` enum directly; grep confirms.
- **AC4.4** Visual regression check on representative test profiles — no surface left behind.

### Change 5 — Remove `ClusterConfidence`

- Delete the `ClusterConfidence` enum
- Remove `LifeCluster.confidence` (stored property); rely on derived `evidenceConfidence`
- Migrate any test that asserts on the old enum to assert on the new types
- Drop any persisted `cluster_confidence` column via schema migration (v22)
- Re-derive confidence on first launch after migration

**Acceptance criteria:**
- **AC5.1** `ClusterConfidence` no longer compiles (file removed; no callers).
- **AC5.2** v22 migration drops the `cluster_confidence` column if present.
- **AC5.3** Existing tests that previously asserted `confidence == .weak` etc. updated to assert on `evidenceConfidence.matchQuality` / `.sourcing` / `.inference`.
- **AC5.4** First-launch re-derivation produces stable confidence for the test corpus.

### Change 6 — Spec amendments

- Amend `RESEARCH_PIPELINE_SPEC.md` §4 to reference the new three-axis model
- Add a forward-reference from `RESEARCH_PIPELINE_SPEC.md` to this spec
- Update any project README / GUIDE doc that documents confidence tiers

**Acceptance criteria:**
- **AC6.1** `RESEARCH_PIPELINE_SPEC.md` §4 no longer describes `Weak / Moderate / Strong` as the canonical confidence model.
- **AC6.2** A short paragraph in `RESEARCH_PIPELINE_SPEC.md` points readers to `RESEARCH_CONFIDENCE_SPEC.md` for the canonical model.
- **AC6.3** No other doc in the repo still describes the old tier model as current behaviour (`grep -ri "ClusterConfidence" *.md` returns empty in the live-spec sense; historical references in commit messages are fine).

---

## 8. Out of scope

- **WikiTree-imported confidence**. WikiTree records carry their own provenance metadata; mapping into this model is a separate exercise once the import path is reviewed.
- **Cross-tree confidence merging** (e.g. resolving conflicts when two source trees disagree). Deferred — the current pipeline handles disputes via `field_disputes`, which is orthogonal.
- **User-overridable confidence**. The user can today accept/reject leads to influence confidence; manual confidence overrides are a separate feature.
- **Field Researcher (LLM) confidence**. The Evidence Firewall already classifies findings; mapping LLM confidence levels into the three-axis model is a follow-up.
- **Visual tuning** (exact colours, spacing, glyph choices). Locked in §4 at a structural level; pixel-level tuning is a polish pass during Change 3.

---

## 9. Open questions

- **Q1** Should the sourcing chip distinguish between "transcription-only" vs "primary record" more visually, beyond just appending "· primary record"? **Default:** no — text suffix is enough for first ship.
- **Q2** When a cluster has 3 records all classified `.lead` (no `.fact`), should `MatchQuality` aggregate to `.possible` or should the cluster surface a separate "no fact records yet" indicator? **Default:** `.possible`; revisit if confusing.
- **Q3** For nested inferences (depth > 1), should the chain be displayed in the badge tooltip or only in a "Full Detail" view? **Default:** tooltip shows the chain; full provenance lives in profile detail.
- **Q4** Should `RecordVerdict` itself be renamed to `MatchQuality` and the enum cases renamed (`fact` → `confirmed` etc.) to align vocabulary across layers? **Default:** keep both — `RecordVerdict` is the scorer's output, `MatchQuality` is the UI-facing aggregation. Same shape, different namespace.
