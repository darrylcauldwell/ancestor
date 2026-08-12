# Birth ↔ Death-Age Consistency Audit — Spec

**Status:** WON'T BUILD as a new rule — **already covered** (found on implementation, 2026-08-12).
The detection this spec proposed already exists end-to-end:
- **Apply-time detection (Fix A):** `AbsorptionPlan` already writes a death/burial record's
  age-**implied** birth as a corroborating `birthDate` value (`AbsorptionPlan.swift:144–147`,
  via `ApplyEngine.impliedBirthDate`). When that implied birth disagrees with the profile's
  existing birth, the **evidence-conflict layer opens a `birthDate` dispute** — verified live on
  Mary (applying her Belper 1962 death added `birthDate "calc 1890–1891"` and re-opened the
  birthDate dispute). So the conflict is *already* raised at apply time; a new rule would duplicate it.
- **Retroactive surfacing (Fix B):** `ContradictoryFactsAudit` (the tree-wide static twin of the
  exclusivity pass) + `get_open_disputes` already surface profiles holding contradictory facts in
  Health, so an existing conflict is already visible without re-detection.

A separate `BirthAgeConsistencyRule` would re-detect what the conflict layer detects and re-surface
what `ContradictoryFactsAudit` surfaces. **Not worth the duplication.**

**Residual improvements that are genuinely new (small, optional, deferred):**
1. **Tolerance to cut age-slop noise.** The conflict layer currently opens a dispute for *any*
   competing birth value, so a death-age-implied birth that is only ~1–2 years off a precise birth
   (honest headstone/registration age slop — e.g. Mary's calc-1890–91 vs 1889) opens a dispute that
   is really noise. A ±N-year tolerance on *age-implied* birth corroboration (treat within-tolerance
   as agreement, not conflict) would suppress those. This is a **refinement of the absorption /
   conflict layer**, not a new audit.
2. **Anchor-invalidated rejections** (the extension below) — re-open rejections when the birth
   anchor moves. Still novel; still worth doing on its own; not part of the (already-built) detection.

The original proposal is retained below for context.

---

**(Original) Status:** Proposed (2026-08-12).
**Driver (dogfood, Mary Lizzie Ward @I_1564737399@):** a misapplied 1891 census identity
("Mary L Ward, age 5" → birth ~1886) put a wrong birth year on the profile. Her burial
(Find a Grave memorial 216193100, shared headstone with husband Ernest Cauldwell) records
**died 30 May 1962, aged 72** → born **~1889**. Nothing in the app flagged the **3–4 year
conflict** between the applied birth (~1886) and the death evidence's own implied birth (~1889).
Worse, the wrong-but-confirmed birth then narrowed the birth-search window to ±2 years
(`ResearchSubject.yearRange(for: .birth)`), froze 171 namesake rows, and drove ~84 rejections
made against the wrong anchor. A single consistency check would have caught the misapplied
identity before any of that.

## The gap

The scorer's date gate computes an age-plausibility **from the profile's birth**
(observed: *"died 1962, age range 76–76 plausible (birth ~1886)"*) — but it never runs the
**reverse** check: does a death-shape record's **own** implied birth year (from its recorded
age-at-death, or its transcribed birth year) agree with the birth the profile already holds?
So a death/burial record can be applied for its death date while silently disagreeing with the
profile's birth by years, and no dispute is raised.

## The check (deterministic)

For a profile with a **confirmed** birth year `B = profile.birthDate.bestYear` and an applied
**death-shape** record (death / burial / probate / military) that yields an implied birth year
`I`:

- `I` is derived by the **existing** `ApplyEngine.impliedBirthDate(for:)` helper (age-at-death via
  `birthDateFromAge`, or the record's own transcribed `birthDate`/`birthYear` — e.g. Find a
  Grave's `birthDate`/`birthYear`, a headstone age, a probate `ageAtDeath`).
- **Conflict** iff `abs(B - I) > tolerance`.
- **Tolerance:** default **3 years** (configurable via the existing `AuditRuleOverride.thresholds`).
  Rationale: census ages are already treated as ±1 (`.calculated`), headstone/registration ages
  drift ±1–2; 3 years is comfortably outside honest slop but well under an identity error. DBY/
  county-neutral — no hardcoded regions.
- **Severity:** `warning` (a real discrepancy needing human judgement, not a hard `error`).

## Two surfaces

**(A) Apply-time — preventive (primary).** When a death-shape record carrying an age or a
transcribed birth is applied onto a profile that already holds a confirmed birth, run the check
*before* accepting it. On conflict, route it through the **evidence-conflict layer**
(`CONFLICT_LAYER_SPEC`) as an **open dispute** — "this record implies born ~1889 but the profile's
birth is ~1886; confirm identity" — instead of silently applying the death date over a
contradicted birth. (The death date itself can still apply; the dispute flags the *identity*.)

**(B) Audit sweep — retroactive.** A new `AuditEngine` rule `BirthAgeConsistencyRule`
(category `.issue`, so it runs even for thin profiles) that flags **existing** profiles where an
applied death-shape record's implied birth conflicts with the confirmed birth. This is what
catches Mary *now* (the conflict is already applied). Snapshotted like every other finding
(v55 `audit_findings`, surfaced via `get_audit_findings`). Because the raw age lives in
`evidence_records`, this rule is **evidence-aware**: it reads the profile's applied death-shape
evidence (via the ledger / `loadEvidenceForProfile`), not just the snapshot — the one deviation
from the pure snapshot-only rule pattern, called out so the engine wiring is explicit.

## One-click fix (dig-findings-become-audits)

The finding is **advisory, never auto-applied** — identity calls are the user's. Its action
opens a **side-by-side** of the disagreeing sources (e.g. census "age 5, 1891 → ~1886" vs burial
"aged 72, 1962 → ~1889") with the birth field, so the user can re-anchor or dismiss. Dismiss is
an `AuditRuleOverride` (per-profile mute) so a genuinely-reconciled profile stops nagging.

## Extension — anchor-invalidated rejections (folds in Mary's 84 discards)

When the user **materially re-anchors** the birth (birth year moves by > tolerance), the records
that were **rejected under the old anchor** were judged against a now-invalid assumption. Offer to
**re-open** them: reset `user_status` `discarded → unreviewed` (and clear the `record_rejections`
row) for records whose accept/reject verdict depends on the birth year (birth/baptism/christening,
and age-bearing census/death). This is the "you rejected 84 births thinking she was ~1886 — the
anchor is now ~1889, review them again" affordance. Scope it to birth-year-dependent record types
so unrelated rejections stay put. (Could ship as a follow-up after A+B.)

## Reuse / integration points

- `ApplyEngine.impliedBirthDate(for:)` + `birthDateFromAge(age:at:)` — already compute `I`.
- Evidence-conflict layer (`CONFLICT_LAYER_SPEC`) — the dispute channel for surface (A).
- `AuditEngine` rule protocol + `AuditRuleOverride.thresholds` — surface (B) + tolerance/mute.
- `ProjectDatabase.loadEvidenceForProfile` — the evidence read for the sweep.
- `updateEvidenceUserStatus` / `deleteRejection` — the rejection re-open (extension).

## Acceptance

1. Mary's profile raises a `warning`: *"birth ~1886 conflicts with burial-implied ~1889
   (aged 72, d. 30 May 1962) — confirm identity."*
2. Applying a death/burial whose age-implied birth is > 3 yr from a confirmed birth opens a
   dispute rather than silently standing.
3. **No false positive** when the two agree within ±3 years (census-age slop must not trip it).
4. A profile with no confirmed birth, or a death record with no age/birth signal, produces **no**
   finding (nothing to compare).
5. (Extension) Re-anchoring a birth by > tolerance re-opens the birth-year-dependent rejections
   for review; unrelated rejections are untouched.

## Risk

Low — additive audit rule + a conflict-layer hook; no change to the deterministic gates. Main
tuning risk is tolerance (too tight → noise on honest age slop); the 3-year default + per-rule
threshold override manage it. Test-first (a `BirthAgeConsistencyRuleTests` with the Mary shape:
census-1886 + burial-aged-72-1962 → one warning; census-1886 + burial-aged-76 → none).
