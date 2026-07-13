# AncestorApp/ — document index

One line per document: what it is, whether it's live, and when to read it. Convention: **governing/live docs and as-built phase references stay here; retired or fully-acted-on docs move to `archive/`** with their final status stamped in the header. Updated 2026-07-13 (post the conflict-layer CL1–CL6 + engine-foundation C+D shipping run).

## Start here

| Doc | Role | Status |
|---|---|---|
| `ROADMAP.md` | Routing: implementation order + phase state + gates | Living |
| `adr/` | Architecture decision records (001–006 Accepted; 007 rejected-as-proposed) | Binding |

## Live work

| Doc | Role | Status |
|---|---|---|
| `SANDWICH_AUDIT_2026-07.md` | Adversarial audit of the 4-gate scorer + decision core (DS-01..27) | Gate repairs awaiting triage; conflict-evidence cluster resolved |
| `CONNECTOR_AUDIT_2026-07.md` | Connector fix backlog — as-built record of what each connector now does | 55/58 shipped; FT-08/19/21 deferred |
| `FAMILYSEARCH_SOURCE_SPEC.md` | FS source plugin; §§14–19 = official-API pivot, read-leg acceptance | Blocked on Beta AppKey |
| `GEDCOMX_CONCEPT_MAPPING.md` | GEDCOM X ↔ our-model boundary contract (mandated by ADR-003) | Maintained per migration |
| `ENGINE_FOUNDATION_SPEC.md` | Engine robustness (#Change1–8) | Shipped (A+B 2026-05, C+D 2026-07) |
| `RESEARCH_PIPELINE_SPEC.md` | Governing architectural spec (Part I as-built; Part II remainder T9/T23/T31) | Governing |

## As-built references (shipped programmes)

| Doc | Role |
|---|---|
| `MODEL_EVOLUTION_SPEC.md` | Closed E1→E4 domain-model programme — **complete** (v34–v37 migrations, 2026-07-11) |
| `CONFLICT_LAYER_SPEC.md` | Evidence-conflict layer (GPS element 4): dispute producer, witness identity, resolution ladder — **Shipped 2026-07-13 (UI remainder noted in status)** |

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
| `KINSHIP_SPEC.md` | Stage 2, first item (decided 2026-07-11) | Core declared solid; Swift-first respec before build |

## `archive/`

Retired or fully-acted-on documents, final status stamped in each header. Includes (2026-07-11): `ARCHITECTURE_REVIEW_2026-07.md` (review acted on), `SUBJECT_SELF_NARROWING_SPEC.md` and `SWIFT_MCP_EVAL_BACKEND_SPEC.md` (shipped, as-built).
