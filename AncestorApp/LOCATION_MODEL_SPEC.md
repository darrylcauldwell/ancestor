# LOCATION_MODEL_SPEC

**Status:** Stages 0–3 SHIPPED. Stage 3 (decision-core geography-gate rebuild) SHIPPED 2026-07-31 as Fix B of `DECISION_CORE_PAIR_SPEC.md` (#DC3) — subject-derived accepted-county set, hierarchy+validity walk with substring fallback, absence-of-knowledge never vetoes family-confirmed records. Stage 4 gated on FS production-verify + village→district data.
**Origin:** the 2026-07-25 location audit + the 2026-07-27 "full pass" decision.

## Problem

The app carries **two parallel place models**:

1. **LIVE (every decision uses this):** free-text strings (`Profile.birthLocation`,
   `LifeEvent.location`, each record's `birthPlace`/`district`/`parish`) + a flat
   `COUNTY:Place` gazetteer code + a county Chapman code. The geography gate
   (`RecordScorer.checkGeography`) scores by **lowercased substring matching**
   (`RecordScorer.swift:959` `place.contains(home)`) — name matching, not
   identity matching.
2. **DORMANT, already built (E3):** the typed `PlaceAuthority` hierarchy
   (`AncestorKit/PlaceAuthority.swift` + `+Resolution.swift`) —
   parish → registration-district → county → country, with temporal validity —
   materialised by `PlaceAuthorityRegistry` from the gazetteer + FreeBMD district
   catalogue. **Built, tested, consumed by essentially nothing** in the decision
   core.

Symptoms: a real village absent from the flat gazetteer (Turnditch) is a
"suspect location" false positive; `RegionConfig` scoring richness is
Derbyshire-only; ≥3 divergent place-text→Chapman parsers disagree; the FS
`placeARK` (the richest geographic signal we receive) is captured then dropped.

## Decision

Make `PlaceAuthority` the **canonical** place model, resolved at ingest, and
rebuild the geography gate as a hierarchy + validity walk. Connect the model we
already built; do not build a new one.

### ADRs

- **ADR-001 (holds): our model canonical; GEDCOM-X / FamilySearch = reference
  layer, not schema.** GEDCOM X is a FamilySearch-governed specification, not a
  neutral standard. We resolve FS ARKs / place strings **into** our own
  `PlaceAuthority` ids; FS is a hint, our hierarchy stays canonical.
- **ADR-002: the two backbones.** Chapman codes are the county-id layer
  (`DBY`, `NTT`, …); the FS/GEDCOM-X place graph is the external reference to
  resolve **into** the hierarchy. `PlaceAuthority` IS the graph (nodes + parent
  edges + validity); FS's graph maps 1:1.
- **ADR-003: districts lead in place-text resolution.** A registration-district
  match is more specific than a county-name-component match, so the canonical
  resolver tries full-district → component-district → component-county.
- **ADR-004: the geography gate stays deterministic and is rebuilt test-first
  with a fall-back.** It is load-bearing (the deterministic sandwich). No AI in
  the gate; PlaceAuthority is data. When either side is unresolved the gate
  falls back to today's substring logic — no regression for unresolved places.

## Model (as built)

`PlaceKind`: `.parish` ⊂ `.place` ⊂ `.registrationDistrict` ⊂ `.county` ⊂
`.country`. Node: `id`, `name`, `kind`, `parentID?`, `validFrom?`/`validTo?`,
`county?`, `country?`, `aliases`, `freeBMDCode?`. id conventions: county =
bare Chapman (`DBY`), RD = `DBY:Belper-RD`, place = `DBY:Turnditch`, parish =
`DBY:Belper-RD/Parish`. Resolution API: `ancestors(of:)`, `county(of:)`,
`registrationDistrict(of:)`, `districts(forParish:year:chapman:)`,
`district(named:chapman:)`, `valid(in:)`, `overlaps(years:)`.

## Stages

- **Stage 0 — gazetteer coverage + tolerant matcher. SHIPPED (`9a5ad83`).** 14
  real DBY/NTT villages added to `uk-places.json`; `LocationGazetteer.normalizeForMatch`
  strips trailing country (`", England"`) / Chapman (`"(DBY)"`) noise so messy
  stored forms resolve.
- **Stage 1 — spec + unify place parsing. SHIPPED.** This doc, plus the single
  canonical `ChapmanCodeResolver.chapmanCode(forPlaceText:)` (three tiers per
  ADR-003) replacing the divergent `ResearchSubject` / `ConflictDetector`
  copies (both now thin wrappers). Strictly more resolution than either old
  parser — a deliberate correctness gain, characterization-tested.
- **Stage 2 — the resolver primitive. SHIPPED.** `PlaceResolver.resolve(placeText:)`
  (free-text → PlaceAuthority id via the gazetteer + a strict disambiguation
  rule: single match, or an exact name/"name, county" hit, else decline) and
  `resolveDistrict(name:chapman:year:)` (district name → `DBY:Belper-RD` via
  `RegionConfig.districtAuthority`). Pure, ambiguity-declining; `PlaceResolverTests`.
  **Scope corrections found during build** (deviating from the original bullet):
  (a) the `v36` `*_place_authority_id` columns are the landing slot for an
  EXTERNAL FS id → **Stage 4**, not the internal id (a coded place already
  carries its internal id as `birthLocationCode`), so no column-population here;
  (b) village→RD `parentID` backfill is **blocked** on a village→district data
  source (the FS full tree / GENUKI import → Stage 4), so bare-village
  birthplaces resolve at county granularity while records that carry a
  `district` field (BMD/census) resolve at RD granularity via `resolveDistrict`.
  No gate change — Stage 3 composes this resolver.
- **Stage 3 — rebuild the geography gate (decision-core, test-first). DEFERRED — next focused session.**
  Its enabling primitive (`PlaceResolver`) is shipped and tested, so this stage
  is self-contained and ready to pick up. Characterization corpus first. Replace only the county-substring block with a
  hierarchy-containment + temporal-validity walk when both sides resolve; fall
  back to substring otherwise. Keep the military + foreign-metadata branches.
  De-Derbyshires the resolved path (registry covers all counties).
- **Stage 4 — FS enrichment + commit decisions (GATED).** Load
  `fs-place-ids.json` (inert seed today). Known gap: it maps Chapman/codes →
  numeric `fsId`, **not** the captured `ark:/…` — an ARK→PlaceAuthority path
  needs an ARK→fsId step + likely a full FS-tree regen. Decide keep/revert on
  the uncommitted `SearchDispatcher` soft-jurisdiction change. **Hard FS
  geo-filter stays parked** behind production verification.
- **Stage 5 — birth registration district as a first-class profile field. DEFERRED (dogfood 2026-08-05).**
  The place model already has `.registrationDistrict` as a `PlaceKind` with
  `registrationDistrict(of:)` / `resolveDistrict(name:chapman:year:)` — but there
  is nowhere on **Profile** to store one. `birthLocation` holds the event place
  (e.g. `Alport, Youlgreave, Derbyshire`); the BMD **registration district**
  (e.g. `Bakewell`) currently survives only inside the FreeBMD citation prose,
  not a structured field. So the apply card's "applying adds the more precise
  district" writes nothing durable or queryable, and birthplace-vs-district stay
  conflated at the profile layer.
  - **Consequence:** cannot cluster siblings by registration district, cannot
    structurally verify/relocate the GRO record, and a bare-hamlet birthplace
    (`Alport`) can't be distinguished from its RD (`Bakewell`) except by reading
    citation text.
  - **Direction:** add a typed `birthRegistrationDistrict` on `Profile` (a
    PlaceAuthority id, e.g. `DBY:Bakewell-RD`), populated by the BMD apply via
    `resolveDistrict`; `birthLocation` stays the event place. Extend to
    death/marriage RD later. Check-before-overwrite; **never** write the RD into
    `birthLocation` (the Abraham Twyford apply correctly preserved `Alport` — that
    behaviour must hold).
  - **Also surfaced (same session):** bare-hamlet birthplaces should resolve to a
    full hierarchy (`Alport` → `Alport, Youlgreave, Derbyshire, England`) — a
    driver for the `PlaceResolver` village→parent backfill blocked in Stage 2(b).
  - Discovered dogfooding Abraham Twyford (`EAB1E5BE-…`): Alport birth, Bakewell RD.

## Invariants

- Geography gate never overridden by AI; rebuilt test-first with a substring
  fall-back for unresolved places.
- No hardcoded regions — everything from the bundled catalogues (`UKChapmanCodes`,
  `FreeBMDDistrictCatalogue`, `uk-places.json`), never Derbyshire-specific code.
- Check-before-overwrite preserved on any place write.

---

# Part II — Canonical authority, uniform fields, and picker (plan, 2026-08-11)

Owner direction: **(1)** one canonical location source everything uses; **(2)** every
profile location field in one aligned typed format; **(3)** user input via a picker so
only correct formats are entered. Reconciled against Part I: the canonical model
(`PlaceAuthority`) and its resolvers already ship — this Part finishes *connecting* it,
adds the *picker* (new), and *migrates* legacy freeform. Running acceptance case:
**Mary Ward** (census birthplace Hognaston → Ashbourne RD; `freebmd-districts.json`
confirms Hognaston ∈ Ashbourne's 75 parishes) so her birth registration **7b/662** rises
and the Bakewell/Basford/Derby namesakes fall — provably, without hand-editing.

## Guiding rules (extend Part I invariants)
- **One entry point.** All place data flows through `PlaceAuthorityRegistry`/`PlaceResolver`.
  Raw catalogues (`uk-places.json`, `freebmd-districts.json`) are its *private inputs*, not
  loaded ad-hoc. `fs-place-ids.json` is dead (0 code refs) → delete; add `Regions/README.md`
  naming each survivor's role.
- **Canonicalise the claim, preserve the evidence.** Resolve the *profile's own* fields to
  PlaceAuthority ids; keep *source-record* place text **as-transcribed + best-effort code**.
  Never overwrite a display string with a resolved guess (Abraham's `Alport` must survive).
- **Deterministic decides; the model only proposes, verified.** Per ADR-004 the gate/dispatch
  never trust an AI place claim; the local model may *normalise freeform text*, and each
  proposal is resolved against the authority (declined if not confident) before use.
- **Graceful fallback everywhere.** Unresolved place → today's behaviour (county fan-out /
  substring). No place is worse off than now.

## Slices (dependency order; B is the high-value first cut)

**Slice A — single entry point + file hygiene.** Make `PlaceAuthorityRegistry` the only
loader of the raw catalogues; delete `fs-place-ids.json`; add `Regions/README.md`.
*Accept:* grep shows no service reads the raw JSON except the registry. *Risk:* low.

**Slice B — wire the resolver into the two live checks that still bypass it (fixes Mary).**
**B(i) SHIPPED 2026-08-11** — `RecordScorer.conflictsWithConfirmedBirth` now resolves the
subject's birthplace and the record's district to registration-district ids and compares by
identity (Hognaston→Ashbourne accepts, Bakewell/Basford reject). Three sub-fixes fell out of
build: (a) read the Chapman code from the stored `"(DBY)"` suffix rather than the county-name
resolver, whose `UKChapmanCodes.shared` singleton is parallel-fragile (was failing the full
suite non-deterministically); (b) a consonant-skeleton, county-scoped, unique-or-decline
canonicaliser maps FreeBMD's "Ashborne" to the catalogue's "Ashbourne"; (c) substring
fallback preserved for unresolved places. `LocationBirthDistrictTests`; full suite green.
**B(ii) — WON'T DO, SUPERSEDED BY THE SHIPPED FT-01 COUNTY-QUERY GATE (decided 2026-08-11).**
The sub-fix (i) below (replace the naive `districtsCompatible` token/substring compare with a
`PlaceResolver`-backed one) was **delivered as part of B(i)** — `conflictsWithConfirmedBirth`
now resolves both sides to RD ids and compares by identity, with the substring compare kept
only as an unresolved-places fallback. Sub-fix (ii) — narrow the FreeBMD dispatch to the
subject's birth registration district — was **investigated and declined**:
  - Its premise ("the dispatch fans out **all** home-county districts") is false under the
    shipping config. `FreeBMDParams.countyQueryEnabled = true` (`RecordTypes.swift:764`), so
    `freeBMDGeoAxes` takes the county branch (`SearchDispatcher.swift:626–639`) and emits **one
    `countyid` query** for the home county — not a per-district fan-out. The per-district loop
    only runs with that gate deliberately flipped off (`FreeBMDCountyProbeTests`).
  - So narrowing to the birth district would keep the request count at **1** (no efficiency
    win), trade the county query's **maximal recall** (a superset of every district) for a
    **recall-regression risk** on boundary/imprecise births registered in a neighbour district,
    and only marginally reduce namesake noise that **B(i) already filters at the review layer**.
    The one situational upside (a common surname overflowing the year-splitter) is already
    handled by the national common-surname guard (`SearchDispatcher.swift:663+`) + adaptive
    year-split. Net-negative → not built.
  - Additionally, `ResearchSubject` carries no birthplace (only county-level `homeChapmanCode`);
    B(ii) would first need a birth-district signal plumbed through `fromProfile` — cost with no
    payoff.
**Slice B is therefore COMPLETE at B(i):** the county query stays wide + polite (FT-01), and
B(i) discriminates wrong-district namesakes at review — Mary's Ashbourne 7b/662 accepts, her
Bakewell/Basford namesakes reject. *Result:* the correctness win is banked; efficiency was
already delivered by FT-01.

**Slice C — `birthRegistrationDistrict` as a first-class Profile field (= Part I Stage 5).
SHIPPED 2026-08-11.** Typed PlaceAuthority id (e.g. `DBY:Ashbourne-RD`), populated by BMD-birth
apply via the resolver; `birthLocation` stays the event place; check-before-overwrite; the RD is
never written into `birthLocation`. As built:
  - **Model** (`Profile.birthRegistrationDistrict: String?`) — additive, mirrors the
    `birthLocationCode` posture: derived metadata, **no `ProfileField` case / no `FieldSource`**
    (its provenance is the birth citation already on `birthDate`/`birthLocation`). Codable is
    back-compatible (absent key → nil).
  - **DB** — migration `v58_birth_registration_district` (nullable TEXT); load/insert wired;
    `setBirthRegistrationDistrictIfEmpty` enforces check-before-overwrite in SQL (fills only a
    NULL/empty column, so a user-set or earlier RD is never clobbered and re-apply is a no-op).
  - **Resolver** — B(i)'s district logic extracted to `RegistrationDistrictResolver` (one
    canonical path; `RecordScorer` now delegates to it), so the review layer and the apply layer
    resolve districts identically, including FreeBMD's "Ashborne"→"Ashbourne" tolerance.
  - **Apply** — `ApplyEngine.applyFactToSubject` resolves a **`.birth`** record's `district` (a
    death/marriage `district` is a different event and is ignored) to the RD id after the
    absorption-plan walk, and writes it via the check-before-overwrite path.
  - **Tests** — `BirthRegistrationDistrictTests` (8): Codable round-trip + pre-Slice-C back-compat,
    DB persistence, check-before-overwrite, resolver "Ashborne" tolerance, chapman-from-suffix,
    apply populates (Abraham keeps his place, gains the RD), death-record-doesn't-populate. Full
    suite green.
*Accept (met):* a birth apply leaves `birthLocation` untouched and adds the structured RD;
enables sibling-by-RD clustering (a downstream consumer, not part of C). *Risk:* schema add +
apply-path change — contained by the additive/derived design and the full-suite gate.

**Slice D — location picker (NEW, pillar 3).** A `PlaceAuthority`-backed type-ahead used by
*every* location input (Add Person, edit, manual fact). Era-aware, shows hierarchy
place→RD→county→country, writes **both** display string and code. **Escape hatch required:**
"not found → free-text + resolve-later flag" so obscure hamlets and **foreign/abroad** places
(Lijssenthoek) are never blocked. *Accept:* new person's birthplace populates both fields via
picker; foreign place takes the flagged free-text path. *Risk:* UI surface + escape-hatch design.

**Slice E — migrate legacy freeform → codes (the un-muddle; do last, human-in-loop).** One-pass
normaliser over existing `birthLocation`/`deathLocation`/life-event locations: deterministic for
structured/Chapman-suffixed forms; **local model proposes** for the freeform tail, each proposal
**verified** against the authority (decline if not confident) and surfaced for **review** — never
a blind batch write. Display strings preserved. *Accept:* dry-run report (deterministic /
model-proposed-verified / left-freeform counts); zero wrong-resolution auto-committed. *Risk:*
high (wrong-resolution) → dry-run + review surface, gated behind A–D.

## Known coverage limit (carry forward)
Parishes in `freebmd-districts.json` resolve to their RD (Hognaston→Ashbourne works); a
**non-parish hamlet/farm/address** may not resolve below county until the village→RD backfill
(Part I Stage 2(b)/Stage 4). Slices B–D degrade gracefully to county for those; Stage 4 improves
coverage. Not a blocker for the running Mary case.

## Suggested order to implement now
**A → B → C → D → E.** B is the first real cut: it's self-contained, uses only shipped primitives
(`PlaceResolver`, `FreeBMDDistrictCatalogue`), and turns Mary's 11-way tie into a clean 1 — the
provable win that justifies the rest.
