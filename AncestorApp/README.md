# AncestorApp/ — document index

One line per **live** document: what it is and when to read it. This file carries **roles only
— no status**, so it has nothing to keep up to date.

**Convention (2026-07-16):** the only readers here are the developer and Claude, and both have
full git history — so a *completed* spec is **deleted**, not kept. Git history is the archive
(`git log --all --full-history -- AncestorApp/<file>` retrieves any removed spec). Only living
work lives in this folder.

**Where status lives (2026-09-18):** nowhere by hand. Open items are rows in `BACKLOG.md` with
stable IDs; status is derived with `git log --oneline --grep='#<ID>' --all`, or by invoking the
`backlog` skill. Status used to be duplicated across this file, the former `ROADMAP.md`, each spec's change
list and `MEMORY.md` — four hand-maintained copies that drifted 6–8 weeks apart. Design rationale
still belongs in the owning spec; sequencing and gates belong in `BACKLOG.md`.

## Start here

| Doc | Role |
|---|---|
| `BACKLOG.md` | **The single list** — every delivery unit, with gates, acceptance tests and sequencing narrative. Status derived from git |
| `adr/` | Architecture decision records — binding (001–006 Accepted; 007 rejected-as-proposed) |

## Governing / reference (ongoing)

| Doc | Role |
|---|---|
| `RESEARCH_PIPELINE_SPEC.md` | Governing architectural spec (Part I as-built engine; Part II remainder T9/T23/T31) |
| `GEDCOMX_CONCEPT_MAPPING.md` | GEDCOM X ↔ our-model boundary contract (mandated by ADR-003) |
| `published-schema-v1.ckdb` | Canonical CloudKit schema (prod 2026-07-08) — viewers' data contract |
| `family-bundle.schema.json` | Offline family-bundle contract (viewer test double) |

## Active / in-flight

Sequencing and gates for these live in `BACKLOG.md`; per-item state comes from git.

| Doc | Role |
|---|---|
| `SANDWICH_AUDIT_2026-07.md` | Adversarial audit of the 4-gate scorer (DS-01..27) — as-built record |
| `CONNECTOR_AUDIT_2026-07.md` | Connector fix backlog / as-built record (FT-19, FT-21, T1-C1 tail) |
| `SOURCE_WEIGHTING_SPEC.md` | Staged-dispatch source weighting (Change 6 gated on ADR-008) |
| `SOURCE_ACCESS_COMPLIANCE_2026-07.md` | Connector terms-of-service evidence (decisions gated on ADR-008) |
| `FAMILYSEARCH_SOURCE_SPEC.md` | FS deferred work (write leg, ARK detail-fetch, per-collection tiering, place/vocab) + reference (§16 licensing, GEDCOM X taxonomy) |
| `CROSS_PROFILE_CORROBORATION_SPEC.md` | Spouse-pair marriage corroboration across profiles (Change 5 gated on §14.B.2–6 for relationship entities) |

## Proposed — awaiting review

| Doc | Role |
|---|---|
| `DOSSIER_SPEC.md` | T9 investigation dossier + bounded adversarial challenge |

## Sequenced later (Stage 2 — gate: core declared solid)

| Doc | Role |
|---|---|
| `KINSHIP_SPEC.md` | Kinship primitives (ADR-007: Stage 2 first item; Swift-first respec before build) |
| `PROSE_CORPUS_SPEC.md` | Bio synthesis / prose corpus |
| `SOURCE_MEDIA_SPEC.md` | Record images / headstone media |

## Removed (completed — in git history)

Fully-delivered specs are removed once shipped; retrieve any via git. Their commits are the
record — `git log --all --full-history -- AncestorApp/<file>`.

Removed 2026-07-21 (shipped/superseded): `LEAD_DISCOVERY_SPEC`, `IMPORT_DEDUPE_SPEC`,
`PROFILE_LIFECYCLE_SPEC`, `PROFILE_SOURCES_LEDGER_SPEC`, `PROJECT_ONBOARDING_SPEC`,
`POSSIBLE_PEOPLE_CONTEXT_SPEC`, `RETIRE_POPOVER_SPEC`, `CLUSTERING_LIFESPAN_LOCATION_SPEC`,
`FAMILYSEARCH_READ_LEG_PLAN` (cookie read leg), and `FAMILYSEARCH_CLIENT_SPEC` (OAuth client
library shipped S1–S6b; its deferred work + follow-ups now live in `FAMILYSEARCH_SOURCE_SPEC`).

Removed 2026-07-16: `EVIDENCE_ABSORPTION_SPEC`, `TRIAGE_UX_DATA_QUALITY_SPEC`, `CAMPAIGN_REVIEW_SPEC`,
`SCOPE_AUDIT_2026-07`, `MODEL_EVOLUTION_SPEC`, `ENGINE_FOUNDATION_SPEC`, `CONFLICT_LAYER_SPEC`,
`PUBLISHER_SPEC`, `PHASE4_VIEWER_SPEC`.
