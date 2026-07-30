# DECISION_CORE_PAIR_SPEC — scorer exclusivity + geography-gate Stage 3

**Status:** Accepted 2026-07-31 (owner: "complete the decision-core pair"). Build DC1–DC5, test-first, each slice gated on `xcodebuild test`. This touches the **4-gate scorer** — the deterministic sandwich. Corpus before code; no behaviour change without a specimen.
**Absorbs:** memory `project_scorer_overacceptance_and_geography` (the two deferred fixes) and `LOCATION_MODEL_SPEC.md` Stage 3 (this spec is Stage 3's build plan; that file gains a pointer here).
**Live corpus (2026-07-30/31 dogfood):** Elizabeth Shaw @I332233297426@ — **11 mutually exclusive birth registrations all `.fact`** (1867–1871, five districts) + **3 different 1891 censuses all `.fact`** (Hayfield/Ilkeston/Belper) + 1 correct death `.fact`; Harry Marshall — 2 namesake probates `.fact` (1999/2006, he died ~1951); Mary E Land — 2 marriages `.fact` (1919/1941, unmarried subject); WHK 1909 marriage — geography `softFail "unknown district: Chesterfield"` on a record whose familyContext passed at reciprocal tier.

## Fix A — cross-record exclusivity pass (over-acceptance)

`fact` must mean "confident this is THEM". Gates are per-record, so eleven namesakes each pass individually; nothing checks they cannot all be true. The fix is a deterministic **post-classification pass** — per-record `classify` is untouched.

**`RecordScorer.applyExclusivity(_ scored: [ScoredRecord], subject:) -> [ScoredRecord]`**, called wherever a batch of classifications is assembled (the pipeline result path AND `FamilySearchHintRouting.route`).

- **Slots** (a person has at most one): `birth` (birth records + baptism-typed parish records), `death`, `burial`, `probate`, `census-<year>` (one household per census night). `marriage` is a slot but **non-singular** (remarriage is legitimate).
- **Discriminator** (deterministic, from existing machinery): the record's `familyContext` gate is a non-vacuous `.pass` (child/spouse/parent/MMN actually matched — `.skip` and `.softFail` don't count), OR the #CPC-Change4 cross-profile elevation predicate holds. Nothing else counts; no AI input.
- **Rule, singular slots** — among the `.fact` records in a slot:
  - 0 or 1 fact → unchanged.
  - \>1 fact, exactly **one** discriminated → that one keeps `.fact`; the rest demote to `.lead`.
  - \>1 fact, **zero** discriminated → **all demote** (namesake pile; when in doubt, split).
  - \>1 fact, **two-plus** discriminated → **all demote** (a genuine evidential contradiction — this is conflict-layer material, not silent acceptance).
- **Rule, marriage slot**: discriminated facts always keep (any number — WHK's two corroborated marriages). Undiscriminated marriage facts keep only when unrivalled (exactly one marriage fact total); two-plus undiscriminated → all demote (Mary E Land).
- Demotions append `GateResult(gate: .exclusivity, outcome: .softFail, reason: "N competing <slot> candidates — no single record is discriminated; needs family/cross-profile corroboration")` so the UI/MCP gates display explains itself. New `ScoringGate.exclusivity` case (additive; audit every switch over the enum).
- Verdicts only ever move **down** (fact → lead). `.impossible` and `.lead` inputs are never touched. Idempotent: running the pass twice is a no-op.

## Fix B — geography gate Stage 3 (subject-derived area + hierarchy walk)

Three defects in `checkGeography`: it keys solely off the **tree-home** Chapman code (a Nottinghamshire-born subject in a Derbyshire-home tree soft-fails their own home district); membership is substring/curated-list based ("unknown district: Chesterfield" on a DBY district); and an *unknown* (not *wrong*) district demotes records the family gate already confirmed.

1. **Subject-derived research area.** A per-subject accepted-county set replaces the single code: `{homeChapmanCode}` ∪ Chapman of the subject's own `region`/birth place ∪ death location ∪ `burialChapmanCode`, each resolved via `PlaceResolver`/`ChapmanCodeResolver` (nil resolutions skipped — never guessed). All district/county membership checks accept ANY member. No hardcoded regions; derived per subject.
2. **Hierarchy + validity walk.** When `PlaceResolver.resolveDistrict(record.district, year:)` (or `resolve(placeText:)` for county-ish fields) yields a `PlaceAuthority` id, decide by **containment**: the resolved node's county ∈ accepted set (temporal validity respected via the registry). Substring/curated fallback ONLY when resolution declines — existing behaviour preserved for unresolvable text. Military + foreign-metadata branches unchanged.
3. **Unknown never vetoes family-confirmed.** In `classify`'s verdict step: a geography `softFail` whose reason is unknown-district/no-location does **not** count toward `hasSoftFails` when the familyContext gate is a non-vacuous `.pass` — the family evidence outranks missing geo data. A *wrong* place (non-local, foreign, catchment-mismatch) still demotes; only **absence** of geographic knowledge is forgiven, and only under a real family match.

## Slices

- **DC1 — characterization corpus** (`DecisionCorePairTests.swift`): intended-behaviour tests from the live specimens above, written FIRST and failing: Elizabeth's 11 births → 0 facts/11 leads with exclusivity reasons; her 3×1891 censuses → all leads; her death → stays fact; Harry's 2 probates → both leads; Mary's 2 marriages → both leads; a 1-discriminated-of-3 births case → 1 fact + 2 leads; 2-discriminated births → all leads; WHK's two discriminated marriages → both keep; Worksop-district record for an NTT-born subject in a DBY-home tree → geography pass; Chesterfield district → pass via hierarchy; unknown-district + familyContext-pass → `.fact`; foreign/military behaviour pinned unchanged.
- **DC2 — exclusivity pass** + `.exclusivity` gate case + wiring into both batch sites.
- **DC3 — geography rebuild** per Fix B (gate function + the `classify` softFail interplay).
- **DC4 — suite reconciliation.** Full-suite run; every pre-existing test that flips is reviewed **individually** — a test asserting the old over-acceptance updates with a comment naming this spec; a test revealing genuine regression blocks the slice. No blind test edits.
- **DC5 — docs/memory**: LOCATION_MODEL_SPEC Stage 3 → pointer + as-built; memory updates; Health follow-up ("contradictory facts accepted" audit rule) queued to roadmap, not built here.

## Invariants

Deterministic sandwich holds: no AI input anywhere in either fix. Verdicts only demote in the exclusivity pass. Geography changes widen only via the subject's own recorded places. Fall back to current behaviour whenever resolution declines. When in doubt, split.


## As-built (2026-07-31, #DC0–#DC5)

- **DC1+DC2** `6172a0e` — `RecordScorer.applyExclusivity` (slots, non-vacuous familyContext discriminator, demote-only, idempotent) + `ScoringGate.exclusivity` + wiring at the pipeline's pre-clustering assembly (confirmedFacts/leads are computed partitions of scoredRecords, so demotion reconciles everything) and in `FamilySearchHintRouting`. 9 corpus tests from the live specimens.
- **DC3** — geography rebuilt per Fix B: `acceptedChapmanCodes(for:)` (home + subject's own region/death/burial places via ChapmanCodeResolver, declines skipped), hierarchy walk via `PlaceResolver.resolveDistrict` + `county(of:)` containment before any substring fallback, county/parish substring paths iterate the accepted set, and classify's `hasSoftFails` forgives unknown-district/no-location geography softFails ONLY under a genuine familyContext pass. 6 corpus tests (Worksop-NTT subject in DBY tree → pass; Chesterfield hierarchy → pass; Taunton/SOM → still demoted; unknown+family → fact; unknown alone → lead; foreign → impossible unchanged).
- **DC4** — full suite: 3,454 tests / 369 suites, zero legitimate flips (sole failure = the documented MultiWindowAppState parallel flake, green isolated). The corpus-first constraint held: nothing outside the specimens' behaviour changed.
- Known scope limits, deliberate: the pass runs at batch assembly, so mid-run adaptive anchoring still sees pre-pass facts (a full mid-run reflow was judged too invasive; the persisted result and everything downstream see post-pass verdicts). Persisted evidence from OLD runs keeps its stored verdicts — re-running research re-scores under the new rules.
