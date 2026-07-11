# ADR-004 — Model evolution is a closed four-item list

**Status:** Accepted 2026-07-11 (Darryl)
**Depends on:** ADR-001 ("canonical" is not "finished"); feeds ADR-003 (each evolution updates the mapping document)

## Context

The R2 model survey convicts the as-built model in exactly four places. Every one is **independently motivated by our own roadmap** — FS raises its priority but does not create the need:

1. **Foreign-ID lifecycle.** `externalIDs: [String: String]` (`AncestorKit/Sources/AncestorKit/Profile.swift:13`) holds one current ID per provider and cannot represent "this FS ID was merged into that one." FS 301 merge-forwarding makes deprecated-ID chains mandatory for even a *read-only* FS person link (<https://developers.familysearch.org/main/docs/merging>). The pattern is already proven in-house — outbound — as `published_ids.superseded_by` (`Ancestor Research/Services/ProjectDatabase.swift:909`); we invented the right answer for the publisher and never applied it inbound.
2. **Names.** One `marriedSurname` + one `nickName` cannot represent a twice-married woman, aliases, or non-Western structures. Every mature system — GEDCOM X, FS, WikiTree, RootsMagic, Legacy — converged on repeatable typed name-form lists (research corpus, `ecosystem-models.md` pattern 5). WikiTree ingest already silently drops `LastNameOther` (<https://github.com/wikitree/wikitree-api/blob/main/getProfile.md>) — a data-loss bug awaiting its first round-trip.
3. **Place authority.** The registration district — *the* pivot of UK BMD research — exists only as strings inside hypothesis payloads (`AncestorKit/Sources/AncestorKit/Research/ResearchHypothesis.swift:149`, `districtHint`). The flat `COUNTY:Place` code will not survive the already-planned 12k-parish GENUKI gazetteer expansion, nor map to FS's Places authority.
4. **Edge-existence provenance.** "This parent edge exists because of this baptism record" has no home — `field_sources` can source a marriage *date* but not the edge itself. This is the single most consequential GEDCOM X advantage because it touches the core value proposition: evidence-backed trees.

The hazard is scope: "align with GEDCOM X" is an open-ended invitation. The scope must be a closed list, not a programme.

## Decision

Exactly four model evolutions, in this order, each staged and independently valuable:

| # | Evolution | Size | Note |
|---|---|---|---|
| E1 | Typed external-identifier records with deprecation lifecycle (replaces `externalIDs`) | S | Mirrors `published_ids.superseded_by` inbound. **Prerequisite for any FS person linkage; do first.** |
| E2 | Typed repeatable name forms | M | `displayName` stays the projection, containing publisher/viewer blast radius. |
| E3 | Place-authority records (district as entity; jurisdiction chains with temporal validity) | M | Rides the planned GENUKI gazetteer expansion. |
| E4 | Edge-existence provenance | S | `field_sources` is keyed `(entity_id, entity_kind, field)`; an `existence` pseudo-field is a natural extension. |

**The list is closed.** Anything beyond it is a new decision (new ADR), not "alignment." Two small supporting items are spec-level, not schema programme, and do not reopen the list: the ARK/persona identity column on `evidence_records` (lands with the FS source spec) and an explicit test for the one-source-per-EvidenceRecord invariant.

## Consequences

**Positive:** all four known gaps close with no regressions; none of the work is stranded if FS approval never comes (each item pays for itself via WikiTree ingest, gazetteer expansion, or publisher symmetry); staging keeps each migration reviewable.

**Negative:** real migrations on shipped tables with publisher/viewer knock-on — `PublishedStore` and viewer rendering must eventually handle name-form lists; sequencing risk against Phase 4 production ceremony and the FS demo for one developer (mitigation: only E1 gates FS work; E2–E4 can trail); each evolution adds an ADR-003 mapping-document update to its definition of done.

## Reversal conditions

Not applicable to the list's contents (each item is independently justified). The *closure* is revisited only by writing a new ADR for any candidate fifth item — that is the mechanism working, not failing.
