# LOCATION_MODEL_SPEC

**Status:** in progress (Stage 0–1 shipped; 2–3 the unblocked core; 4 gated).
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
- **Stage 2 — resolve-at-ingest (additive).** Build `PlaceResolver.resolve(freeText:) → PlaceAuthority.id?`
  (normalize → split → gazetteer/district/parish → registry). Add a
  `PlaceAnnotator` pre-scoring step in `ResearchPipeline` (mirroring
  `CrossProfileAnnotator`) that stamps the resolved id; populate the already-
  migrated `v36` `*_place_authority_id` columns. Set gazetteer `parentID`
  (village → RD) resolved against `FreeBMDDistrictCatalogue` — never
  hand-guessed. Nothing consumes the id for decisions yet.
- **Stage 3 — rebuild the geography gate (decision-core, test-first).**
  Characterization corpus first. Replace only the county-substring block with a
  hierarchy-containment + temporal-validity walk when both sides resolve; fall
  back to substring otherwise. Keep the military + foreign-metadata branches.
  De-Derbyshires the resolved path (registry covers all counties).
- **Stage 4 — FS enrichment + commit decisions (GATED).** Load
  `fs-place-ids.json` (inert seed today). Known gap: it maps Chapman/codes →
  numeric `fsId`, **not** the captured `ark:/…` — an ARK→PlaceAuthority path
  needs an ARK→fsId step + likely a full FS-tree regen. Decide keep/revert on
  the uncommitted `SearchDispatcher` soft-jurisdiction change. **Hard FS
  geo-filter stays parked** behind production verification.

## Invariants

- Geography gate never overridden by AI; rebuilt test-first with a substring
  fall-back for unresolved places.
- No hardcoded regions — everything from the bundled catalogues (`UKChapmanCodes`,
  `FreeBMDDistrictCatalogue`, `uk-places.json`), never Derbyshire-specific code.
- Check-before-overwrite preserved on any place write.
