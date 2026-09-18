# LOCATION_MODEL_SPEC

**Status:** Stages 0–3 SHIPPED; Part II Slices A–E SHIPPED; **Part III Slices 0, 0b and A SHIPPED 2026-08-17** (Places tab live) — the village→district blocker was never a data gap (the catalogue already held the parishes; four code defects hid them), so Stage 2(b) / Stage 4 / Slice D era-filtering are unblocked without any import. Stage 3 (decision-core geography-gate rebuild) SHIPPED 2026-07-31 as Fix B of `DECISION_CORE_PAIR_SPEC.md` (#DC3) — subject-derived accepted-county set, hierarchy+validity walk with substring fallback, absence-of-knowledge never vetoes family-confirmed records. Stage 4 gated on FS production-verify + village→district data.
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
- **Stage 3 — rebuild the geography gate (decision-core, test-first). SHIPPED 2026-07-31** as Fix B / #DC3 (see this file's status header): subject-derived accepted-county set via `RecordScorer.acceptedChapmanCodes(for:)`, hierarchy + validity walk with substring fallback, and absence-of-knowledge never vetoing a family-confirmed record.
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

**Slice A — single entry point + file hygiene. SHIPPED 2026-08-11.** Deleted the dead
`fs-place-ids.json` (0 code refs); added `Resources/Regions/README.md` naming each survivor and its
single owning loader. **Deviation from the literal acceptance ("registry is the ONLY loader"):** the
raw JSON is owned by three clean single-owner loader singletons — `LocationGazetteer` (uk-places),
`FreeBMDDistrictCatalogue` (freebmd-districts), `UKChapmanCodes` (uk-chapman-codes) — plus
`RegionConfig` (county-adjacency); `PlaceAuthorityRegistry` *composes* them. Collapsing all four into
the registry would make it a god-object and break the resolvers that read the loaders directly, so
the better design (one owner per file, no ad-hoc reads, README-documented) was kept intentionally.
The "one entry point" *intent* (no ad-hoc raw reads; canonical resolvers downstream) holds.

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

**Slice D — location picker (NEW, pillar 3). SHIPPED 2026-08-11.** The `LocationPicker`
type-ahead (gazetteer-backed, writes **both** the display string and the structured `*_location_code`)
already backed the edit / manual-fact / life-event / relationship surfaces; D closed the gaps:
  - **Coverage** — wired into `AddPersonView` (the one Add-Person surface still on a raw
    `TextField` + tree-derived `AutoSuggestService`), so every new profile's birthplace is captured
    against the one place authority. The now-dead `locationSuggestions` helper was removed.
  - **Hierarchy line** — the dropdown row and the matched-chip now show place → **RD** → county →
    country. The RD is resolved on the fly through the **same** `RegistrationDistrictResolver` the
    scorer/apply use (new `districtName(forPlace:chapman:)`), so what the user sees equals what an
    applied birth record would record — Slice C surfaced in the UI.
  - **Escape hatch** — the picker's existing "no gazetteer match → saved as freeform text" path is
    the escape hatch; a **nil code on non-empty text IS the resolve-later flag** (no new column —
    it's exactly what Slice E's normaliser targets). Foreign/abroad places (Lijssenthoek) take this
    path unblocked.
  - **Era-aware** — deferred as a no-op: `GazetteerEntry` already carries `validFrom`/`validTo`, but
    the bundled `uk-places.json` leaves them nil, so there is nothing to filter until the
    GENUKI/village backfill (Part I Stage 2(b)/4) populates windows. Wiring exists; data doesn't.
  *Accept (met):* a new person's birthplace populates both fields via the picker; an unmatched
  foreign place takes the flagged free-text path. `LocationNormalizeTests` covers the resolver line.

**Slice E — migrate legacy freeform → codes (the un-muddle). SHIPPED 2026-08-11 (deterministic
tier).** `LocationNormalizer` (pure) scans every profile's freeform, code-less birth/death place and
builds a **dry-run `Report`**: an unambiguous `PlaceResolver`/gazetteer hit → a *deterministic*
(apply-eligible) proposal; anything ambiguous/unknown → *left-freeform* (reported, never resolved —
"when in doubt, split"). The `LocationNormalizeReviewView` sheet (Settings → Data Cleansing →
"Normalise locations…") shows the confident matches ticked, applies **only** the ones the user keeps
(`apply(_:in:)` refuses a non-confident proposal), and **preserves display strings** — only the code
column is filled, one field at a time via `setProfileLocationCode`. **Zero wrong-resolution is
auto-committed** (nothing writes without a tick).
  - **Life-event locations — DONE 2026-08-11 (extension).** The normaliser now scans residence/
    occupation/burial/etc. `LifeEvent.location` too (`report(for:lifeEvents:)`), the `Proposal.Target`
    generalised to `profileField | lifeEvent`, applied via `setLifeEventLocationCode` (check-before-
    overwrite on the existing v15 `location_code` column), surfaced in the same review sheet. Tests:
    life-event report/skip-coded/skip-deleted-owner/apply-preserves-display.
  - **Deferred (gated follow-up):** ONLY the **local-model proposer** for the left-freeform tail
    remains. The deterministic backbone + review is what makes a model tier safe to add later (each
    model proposal still verified against the authority + human-reviewed — never a blind batch
    write); per the tiered-architecture rule, deterministic ships first and the model tier routes up
    only at the wall.
  *Accept (met):* dry-run report with deterministic / left-freeform counts; per-proposal apply;
  display preserved; no blind writes. `LocationNormalizeTests` (report split, skip-coded/empty/
  soft-deleted, apply-writes-code-preserves-display, refuse-non-confident, only-touches-named-field).

## Known coverage limit (carry forward)
Parishes in `freebmd-districts.json` resolve to their RD (Hognaston→Ashbourne works); a
**non-parish hamlet/farm/address** may not resolve below county until the village→RD backfill
(Part I Stage 2(b)/Stage 4). Slices B–D degrade gracefully to county for those; Stage 4 improves
coverage. Not a blocker for the running Mary case.

## Status (2026-08-11)
**A, B, C, D, E all SHIPPED.** The deterministic location model is end-to-end: file hygiene + single
owner per catalogue (A), picker writes codes for new input incl. Add Person (D), apply derives the RD
(C), the review layer discriminates by RD (B), and the batch normaliser structures the legacy
freeform tail — profile birth/death **and** life-event places — under review (E).

**Two honest remainders, both by choice/dependency, not oversight:**
1. **D "era-aware" picker filtering** — the code path is data-blocked: `GazetteerEntry` carries
   `validFrom`/`validTo` but the bundled `uk-places.json` populates neither, so any era filter would
   filter nothing. Unblocks with the GENUKI/village backfill (Part I Stage 2(b)/4). Not built to
   avoid dead UI over absent data.
2. **E local-model proposer** for the ambiguous freeform tail — a separate MLX effort the spec itself
   gates ("do last"); deterministic ships first per the tiered-architecture rule. The backbone that
   makes it safe (verified-against-authority, human-reviewed, no blind writes) is in place.

Downstream consumer not part of any slice: **sibling-by-RD clustering** (a consumer of C's field).

---

# Part III — the village→district unblock (Slice 0 SHIPPED 2026-08-17)

**The premise of Stage 2(b)/Stage 4 was wrong.** Three items in this spec were parked
waiting on "a village→district data source (the FS full tree / GENUKI import)": Part I
Stage 2(b), Part II Slice D's era-aware filtering, and the "Known coverage limit". No
import was needed. **The data already ships.** `Wensley & Snitterton` — a subject
family's home township across two censuses, scoring `unknown district` — is in
`freebmd-districts.json` under DBY/Bakewell (from 1839) and DBY/Matlock (to 1838).

Four defects sat between the catalogue and the gate (commit `00fc0b0`):

1. **HTML entities survived the scrape.** 685 distinct parish names carry a literal
   `&amp;`; nothing on the resolution path unescaped, while the record side does
   (`FreeCenSource.swift:847`). Two namespaces that could never meet. Also ~98 rows
   are footnote prose ("abolished 1.4.1935 and added to the parish of …"), not places.
2. **The gate never consulted the parish tier.** `PlaceResolver.resolveDistrict`
   matches only `kind == .registrationDistrict` (`PlaceAuthority+Resolution.swift:162`),
   but a census prints the civil PARISH in its district column.
3. **A compound civil parish was unreachable by its constituents.** A census names the
   settlement ("Wensley"), not the registration parish ("Wensley & Snitterton").
4. **Only the first comma segment was tried, and the county in the string ignored.**
   "Alport, Youlgreave, Derbyshire" lost the parish beside it; "Middleton, Derbyshire"
   resolved to **LAN**:Middleton-RD.

**Design note — the gate resolves parishes with `chapman: nil` deliberately.** Scoping
to the subject's own county would let any ambiguous name find an in-area answer and
pass: the gate marking its own homework. A parish must land in exactly ONE county to be
trusted, so bare "Wensley" (DBY via alias, NRY exact) declines rather than conveniently
becoming Derbyshire. `RegistrationDistrictResolver` derives the county from the place
TEXT instead, which is legitimate — the string states it.

**Verification was exhaustive, not sampled** (`GazetteerTreeCoverageTests`): all 88
distinct location strings from the live tree, asserting none resolves into a county it
contradicts. That check found defect 4; a ten-item spot check had passed. Coverage rose
from 42/88 to 64/88 with **zero contradictory-county resolutions**.

**The residue is pinned and categorised** — and it reframes Part III's remaining work:
- **9 strings / 8 places** are a genuine coverage gap (Alport, Pilhough, Darley Bridge,
  Bolehill, Priestcliffe, Stanton-in-Peak, Longcliffe Wharf, Holmgate).
- The rest are **ambiguous-by-design** (Turnditch, Winster, Wirksworth, Weston
  Underwood — correctly declined), **counties not districts**, or **typos to fix in the
  tree** (Ashborne, Bishop Storford, Leland, Darley Hall, a literal "-").

**Consequence for the curated-overlay tab (was the headline proposal):** its scope is
~9 strings, not the ~46 assumed. Options B (bulk import: GENUKI unusable, GB1900
CC-BY-SA into a closed binary), C (learned place edges — precedent `name_equivalences`
has no production reader or writer), and D (MLX proposer — measured 2/12 correct RDs,
**0 abstentions in 15** including an invented honeypot) were evaluated and rejected;
see the 2026-08-17 options panel. Decide the tab on the real number, not the assumed one.

## Slice 0b — era elimination + reported ambiguity (SHIPPED 2026-08-17, `22e6091`)

The parish hop was validity-blind, so **"Middleton, Derbyshire" for Ruth Brailsford's
1824 birth answered Bakewell RD — a district that did not exist until 1839.** Every
production caller already passed a year; the resolver discarded it. Now routed through
`PlaceAuthority.districts(forParish:year:chapman:)`.

Three findings, each from the exhaustive corpus rather than from reasoning:

- **Ties are the NORM.** UKBMD lists a parish under every district that ever covered
  part of it — Cromford is in both Bakewell and Belper at 1861. "Decline on any tie"
  was tried and cost 15 real places. The line that matters is **cross-county**: a wrong
  county mis-scores the gate; a rival district in the right county does not. Within a
  county the answer is chosen deterministically by id, keeping `districtID` a
  **canonicalisation** — `conflictsWithConfirmedBirth` compares two resolutions and
  needs determinism, not truth.
- **Ambiguity is reported, not hidden.** New
  `RegistrationDistrictResolver.candidates(forPlaceOrDistrict:chapman:year:)` returns
  every surviving district plus the segment that produced it. **This is the input the
  Slice A confidence score is computed from.**
- **A guessed county must not narrow the search.** Deriving the county via
  `ChapmanCodeResolver.chapmanCode(forPlaceText:)` also matches place NAMES and returns
  **LAN** for a bare "Middleton", making every countyless Middleton Lancastrian.
  Replaced by `statedChapman(in:)` — an explicit `(DBY)` suffix, or a segment that is
  literally a county name. *A county the string names is a fact; a county inferred from
  a place name is a guess.*

## Slice A — the Places surface (SHIPPED 2026-08-17, `84fd193` + `7389c19`)

**Built:** `Services/Cleanse/PlaceInventory.swift` (scoring, bind, set-aside),
`Views/Places/PlacesView.swift` (the tab), `RegistrationDistrictResolver.Candidates`
(parishes + eliminations), `PlaceAuthority.parishRecords(named:year:chapman:)`.
Tests: `PlaceInventoryTests` (13), `PlaceInventoryDecisionTests` (6), plus 4 in
`GeographyParishTierTests`. Full suite 3,734 / 405 green.

**Three corrections the build forced on this spec — each was a real defect:**

1. **Ambiguity is counted in PLACES, not surviving districts.** The table below says
   "surviving candidates: 1 → high". That is wrong in both directions, and the first
   implementation shipped the wrong answer because of it. "Warslow" is ONE settlement
   filed under two districts (Leek, then Staffordshire Moorlands after 1974) and scored
   as contested. "Middleton, Derbyshire" at 1824 is TWO settlements whose districts
   collapse to one once era filtering rules out Bakewell — and it scored **High**, which
   is exactly the Bakewell failure returning through the front door. The score now
   counts distinct parish names, unfiltered by year (a parish record inherits its
   district's window, so year-filtering answers "was this jurisdiction in force", not
   "did this village exist").
2. **A county filed only under subdivisions must expand, not veto.** `YKS` owns no
   registration districts — they all sit under `WRY`/`ERY`/`NRY` — so scoping
   "Sheffield, Yorkshire" to YKS matched nothing at all: a string that said MORE about
   where it was resolved to LESS. Dropping the county instead resolved a Yorkshire
   "Clayton" into Staffordshire and Sussex, which is worse. `statedChapmanScope(in:)`
   expands to the subdivisions and keeps the constraint the text supplied.
3. **Confidence floors at low, never unresolved, when candidates exist.** Enough
   deductions drove "City Hospital, Derby" to zero, and the row then read "Unresolved"
   while listing three candidate districts. `.unresolved` means the catalogue knows
   nothing about the text, and must keep meaning only that.

**All five deferrals CLOSED 2026-08-17** (`93e4547`, `d21417f`, `2108dc6`), plus Part II
Slice D's era-aware picker filtering and Slice E's local-model proposer:

- **Administrative co-occurrence — built, but RANKS ONLY.** The table below lists it as a
  score signal; it must not be one. A family that stayed in one district corroborates
  *every* ambiguous place in it, so a boost discriminates almost nothing while
  manufacturing high scores — and it compounds, one wrong binding raising the next
  ambiguous place toward the same wrong district. It sorts the candidates, states its
  count in words, and leaves confidence untouched (regression test asserts the score is
  identical with and without corroborating kin). Scope is one hop plus siblings; a
  transitive walk makes a county-bound tree one blob. **A decision never corroborates
  itself** — districts derived from the row's own text are excluded.
- **Recording the reason — built.** Migration v60 `place_decisions`: text, chosen
  district, reason, when, scope, era window. Supersede-then-insert, never update or
  delete, so the history answers "why is this recorded as Ashbourne?" later.
- **Per-field binding — built.** `bind` takes explicit occurrence ids; `bindAll` is the
  convenience. The pane pre-ticks every use only when they all belong to one person.
- **The picker's rival districts — built**, and it was a live bug, not just a gap.
  `districtName(forPlace:chapman:)` was a first-match with no year: 97 of 219 gazetteer
  places match more than one district inside their own county, so ~2 rows in 5 showed a
  rival, some of which did not exist yet ("Crich · Amber Valley", from 1994). It now
  resolves era-aware through `candidates(…)` and says "Belper or 2 others" rather than
  naming the first. It does NOT offer a choice — there is nowhere to store a district
  there — and routes that decision to this tab.
- **"Show all N nationally" — built** (`nationalCandidates(forPlaceOrDistrict:)`),
  ignoring both the stated county and every validity window.
- **Slice D "era-aware picker filtering"** — recorded in Part II as data-blocked because
  `uk-places.json` leaves `validFrom`/`validTo` nil. The DISTRICT catalogue carries
  `startYear`/`endYear`, which is the side that was actually needed. **Unblocked and shipped.**
- **Slice E local-model proposer — built** (`PlaceProposer`). The model is handed the
  closed list of parishes in the stated county and told to pick one or decline; the
  answer is verified against that list and rejected if it is not on it, near-misses
  included. Suggestions are labelled and never written without acceptance.

**Two defects the build exposed and fixed:**
1. *Data loss.* Binding wrote an `-RD` id into `birth_location_code`, and
   `LocationPicker`'s onChange clears any code the 275-entry gazetteer cannot resolve —
   which an `-RD` id never is. Decisions now live in their own table; binding does not
   touch the profile's location columns.
2. *The era window was inverted.* A windowed decision refusing to apply on an undated
   event made the feature inert exactly where it is needed (almost every district is
   windowed; undated events are what the resolver already declines on). The guard moved
   to bind time: a district that cannot hold the row's years is refused as the human
   tries it, naming the window and the year.

**Deliberately NOT built — the boundary, and why:**
- **Decisions do not reach the scorer, the geography gate, or the research pipeline.**
  They govern the Places tab only. An adversarial pass found four ways a naive
  injection subverts the deterministic sandwich: `RecordScorer.conflictsWithConfirmedBirth`
  computes ONE chapman and passes it to BOTH the record and the subject side, so a
  decided county would silently re-scope the *evidence*; `checkGeography` does not use
  this resolver at all (it goes via `PlaceResolver` unscoped, deliberately `chapman: nil`
  so the gate cannot mark its own homework); `acceptedChapmanCodes` derives the accepted
  county set from subject place TEXT and would widen what Gate 3 accepts; and
  `ResearchRunFactBridge` uses the subject-less `wouldApply` overload, so the unattended
  pipeline bypasses the guard entirely. **Routing decisions into any of these is a
  product decision with self-confirming risk and belongs in its own slice.**
- **No MCP write tool for decisions.** A decision is an input to the accept predicate
  with no review queue behind it — exactly what an agent is confidently wrong about.

---

### Original spec (below) — retained for the rules, which still hold

**Owner direction (2026-08-17), and it overrides the author's first design.** The
original draft split rows into "ambiguous → ask" and "resolved → stay quiet". That was
wrong for the same reason the Bakewell bug was wrong: **it let the app decide which
cases the user is allowed to see.** The boundary is also arbitrary — resolution
confidence is a continuum, not two states.

**Therefore: one uniform list. Every distinct location string in the tree, each with a
confidence score. Sorted ascending, so the work floats to the top; high-confidence rows
are a glance and a tick. The human always decides.**

### The score

Computed, explainable, no black box — every component is a reason string, because a
bare number becomes something you learn to ignore.

| Signal | Effect |
|---|---|
| Surviving candidates (`candidates(…)`) | 1 → high · 2+ → drops sharply |
| Match quality | exact parish > `&`/`and` variant > constituent of a compound > later comma segment |
| County | stated in the string > none (**never** inferred — see Slice 0b) |
| Era | event year known and it eliminated candidates > no year available |
| Administrative co-occurrence | candidate's RD already appears in this family's applied records |

Reads as *"Low — 4 candidates in Derbyshire; matched the bare parish name; no event
year applied"* versus *"High — exact parish, county stated, single candidate."*

**No geographic distance.** `uk-places.json` carries no coordinates (verified), so
"2 miles from Cromford" is not computable. Proximity must be **administrative**
(shared RD with family records), and must not be presented as distance.

### Three outcomes per row

1. **Bind** to a `PlaceAuthority` id — via the shipped `setProfileLocationCode` /
   `setLifeEventLocationCode` (`LocationNormalizer.swift:140-150`).
2. **Not a place** — a first-class outcome, not a forced mapping. Darley Hall is a
   house; City Hospital is a hospital. Precedent: `cleanse_unresolvable_flags` (v22).
3. **Leave** — undecided is allowed and must not nag.

### Rules

- **Bind per FIELD, not per string.** Binding "Middleton, Derbyshire" globally assumes
  every occurrence is the same Middleton — true for one family, false in general. Offer
  "apply to all N occurrences" as a convenience, never the default.
- **Record the REASON with the choice**, so a later session doesn't re-litigate it and a
  wrong binding is auditable.
- **Show what's at stake** — "affects 5 records across 2 people" — so highest-impact
  rows can be done first.
- **Nothing may score high that cannot be justified.** Middleton scoring high is a test
  failure; that property is exactly what was missing when it silently became Bakewell.
- **Never block.** Unresolved places keep working (existing invariant).

### Surfaces

- **The tab** — the backlog: every string, grouped by state, sorted by confidence.
- **The picker** (shipped, Slice D) — point of use. It already renders place → RD →
  county → country; it should also show *"4 possible matches — choose"* rather than
  silently taking the first.

### Narrowing before asking

Never present 25 national Middletons. County from the string → 4. Event year → fewer
still (1824 eliminates Bakewell). Then rank, with reasons. Keep a **"show all N
nationally"** escape hatch, because the county in the string is itself sometimes wrong
(emigrants, transcription errors) and a locked list would trap those.

### Acceptance

Ruth Brailsford's "Middleton, Derbyshire" (b. 1824) appears near the top of the list
scored LOW, showing Middleton-by-Wirksworth → Ashbourne RD and Middleton & Smerrill →
Matlock RD as candidates, with Bakewell **eliminated and shown as eliminated** ("began
1839"). Binding Wirksworth records the choice and its reason, and the row leaves the
queue. `GazetteerTreeCoverageTests` still passes — no binding may introduce a
contradictory county.
