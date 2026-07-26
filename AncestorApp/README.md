# AncestorApp/ — document index

One line per **live** document: what it is and when to read it. Updated 2026-07-21.

**Convention (2026-07-16):** the only readers here are the developer and Claude, and both have
full git history — so a *completed* spec is **deleted**, not kept. Git history is the archive
(`git log --all --full-history -- AncestorApp/<file>` retrieves any removed spec). What shipped
is recorded in `ROADMAP.md` (phase state + Stage 1, with commit refs) and, for load-bearing
design rationale, in Claude's memory files. Only living work lives in this folder.

## Start here

| Doc | Role | Status |
|---|---|---|
| `ROADMAP.md` | Routing: phase state, implementation order (Stage 1/2/3), backlog | Living — single source of truth for what's done / next |
| `adr/` | Architecture decision records (001–006 Accepted; 007 rejected-as-proposed; 008 tosStatus fixes shipped, outreach/toggle outstanding) | Binding |

## Governing / reference (ongoing)

| Doc | Role |
|---|---|
| `RESEARCH_PIPELINE_SPEC.md` | Governing architectural spec (Part I as-built engine; Part II remainder T9/T23/T31) |
| `GEDCOMX_CONCEPT_MAPPING.md` | GEDCOM X ↔ our-model boundary contract (mandated by ADR-003) |
| `published-schema-v1.ckdb` | Canonical CloudKit schema (prod 2026-07-08) — viewers' data contract |
| `family-bundle.schema.json` | Offline family-bundle contract (viewer test double) |

## Active / in-flight

| Doc | Role | Status |
|---|---|---|
| `SANDWICH_AUDIT_2026-07.md` | Adversarial audit of the 4-gate scorer (DS-01..27) | **COMPLETE 2026-07-22** — all 14 gate repairs shipped; only DS-27(b) advisory feature deferred to Stage 2 |
| `CONNECTOR_AUDIT_2026-07.md` | Connector fix backlog / as-built record | Core 56/58 + deferred residue shipped 2026-07-22 (UV-01/06/08/09, T1-C2/C3/C4; UV-02 via DS-15); open: FT-19, FT-21 (blocked), T1-C1 (NEEDS-DARRYL) |
| `SOURCE_WEIGHTING_SPEC.md` | Staged-dispatch source weighting | Changes 0–5,7,8 shipped; live-verification pending + Change 6 gated on ADR-008 |
| `SOURCE_ACCESS_COMPLIANCE_2026-07.md` | Connector terms-of-service evidence | Decisions pending ADR-008 |
| `FAMILYSEARCH_SOURCE_SPEC.md` | FS deferred work (write leg, ARK detail-fetch, per-collection tiering, place/vocab) + reference (§16 licensing, GEDCOM X taxonomy) | Thinned 2026-07-21 — implemented surface removed; small follow-ups open |

## Proposed — awaiting review

| Doc | Role |
|---|---|
| `DOSSIER_SPEC.md` | T9 investigation dossier + bounded adversarial challenge |
| `CROSS_PROFILE_CORROBORATION_SPEC.md` | Spouse-pair marriage corroboration across profiles (#CPC-Change1..5; owner-declared next work item 2026-07-25) |

## Sequenced later (Stage 2 — gate: core declared solid)

| Doc | Role |
|---|---|
| `KINSHIP_SPEC.md` | Kinship primitives (ADR-007: Stage 2 first item; Swift-first respec before build) |
| `PROSE_CORPUS_SPEC.md` | Bio synthesis / prose corpus |
| `SOURCE_MEDIA_SPEC.md` | Record images / headstone media |

## Removed (completed — in git history)

Fully-delivered specs are removed once shipped; retrieve any via git. Their shipped state +
commits are recorded in `ROADMAP.md`.

Removed 2026-07-21 (shipped/superseded): `LEAD_DISCOVERY_SPEC`, `IMPORT_DEDUPE_SPEC`,
`PROFILE_LIFECYCLE_SPEC`, `PROFILE_SOURCES_LEDGER_SPEC`, `PROJECT_ONBOARDING_SPEC`,
`POSSIBLE_PEOPLE_CONTEXT_SPEC`, `RETIRE_POPOVER_SPEC`, `CLUSTERING_LIFESPAN_LOCATION_SPEC`,
`FAMILYSEARCH_READ_LEG_PLAN` (cookie read leg), and `FAMILYSEARCH_CLIENT_SPEC` (OAuth client
library shipped S1–S6b; its deferred work + follow-ups now live in `FAMILYSEARCH_SOURCE_SPEC`).

Removed 2026-07-16: `EVIDENCE_ABSORPTION_SPEC`, `TRIAGE_UX_DATA_QUALITY_SPEC`, `CAMPAIGN_REVIEW_SPEC`,
`SCOPE_AUDIT_2026-07`, `MODEL_EVOLUTION_SPEC`, `ENGINE_FOUNDATION_SPEC`, `CONFLICT_LAYER_SPEC`,
`PUBLISHER_SPEC`, `PHASE4_VIEWER_SPEC`.
