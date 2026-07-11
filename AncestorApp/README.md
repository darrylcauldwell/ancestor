# AncestorApp/ — document index

One line per document: what it is, whether it's live, and when to read it. Convention: **governing/live docs and as-built phase references stay here; retired or fully-acted-on docs move to `archive/`** with their final status stamped in the header. Updated 2026-07-11.

## Start here

| Doc | Role | Status |
|---|---|---|
| `ROADMAP.md` | Routing: phase state + live queues + what's parked | Living |
| `adr/` | Architecture decision records (6, all Accepted 2026-07-11) | Binding |

## Live work

| Doc | Role | Status |
|---|---|---|
| `CONNECTOR_AUDIT_2026-07.md` | Verified connector fix backlog (FT-nn + T1-nn), combined top-5 in §3 | Awaiting triage |
| `MODEL_EVOLUTION_SPEC.md` | Closed E1→E4 domain-model programme (Changes 1–4) | Accepted; E1 next |
| `FAMILYSEARCH_SOURCE_SPEC.md` | FS source plugin; §§14–19 = official-API pivot, read-leg acceptance | Blocked on AppKey |
| `GEDCOMX_CONCEPT_MAPPING.md` | GEDCOM X ↔ our-model boundary contract (mandated by ADR-003) | Maintained per migration |
| `ENGINE_FOUNDATION_SPEC.md` | Engine robustness; A+B shipped, C+D (#Change5–8) deferred — triage with the audit | Partially shipped |
| `RESEARCH_PIPELINE_SPEC.md` | Governing architectural spec (Part I as-built; Part II remainder T9/T23/T31) | Governing |

## As-built references (shipped phases)

| Doc | Role |
|---|---|
| `PUBLISHER_SPEC.md` | Phase 3 publisher as-built; §4 is the viewers' data contract |
| `PHASE4_VIEWER_SPEC.md` | Phase 4 viewers as-built (delivered + accepted 2026-07-10) |
| `published-schema-v1.ckdb` | Hand-authored canonical CloudKit schema (promoted to prod 2026-07-08) |
| `family-bundle.schema.json` | Offline family-bundle contract (viewer test double) |

## Sequenced later (on the road, gated)

| Doc | Stage | Gate |
|---|---|---|
| `PROSE_CORPUS_SPEC.md` | Polish (Stage 2) | Core declared solid |
| `SOURCE_MEDIA_SPEC.md` | Polish (Stage 2) | Core declared solid |
| `KINSHIP_SPEC.md` | Core (Stage 1, proposed) | Decision: respec Swift-first before build |

## `archive/`

Retired or fully-acted-on documents, final status stamped in each header. Includes (2026-07-11): `ARCHITECTURE_REVIEW_2026-07.md` (review acted on), `SUBJECT_SELF_NARROWING_SPEC.md` and `SWIFT_MCP_EVAL_BACKEND_SPEC.md` (shipped, as-built).
