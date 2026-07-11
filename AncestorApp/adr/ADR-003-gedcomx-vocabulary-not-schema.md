# ADR-003 — GEDCOM X is adopted as vocabulary, not schema

**Status:** Proposed 2026-07-11 — awaiting review
**Depends on:** ADR-001 (which rejects GEDCOM X as schema; this ADR harvests its surviving value)

## Context

The one asset of the rejected Option A that survives scrutiny is **vocabulary**. GEDCOM X's conceptual model (<https://github.com/FamilySearch/gedcomx/blob/master/specifications/conceptual-model-specification.md>) is the GENTECH-lineage formalisation of the evidence-vs-conclusion split (GENTECH Genealogical Data Model, <https://xml.coverpages.org/GENTECH-DataModelV11.pdf> — lineage claim high confidence, specifics medium per the research corpus). We independently rebuilt the same architecture: raw records held immutable, interpreted claims layered above, identity resolved by referencing evidence rather than merging it.

Two forces make a maintained mapping worth its cost:

- **It is the only vocabulary a genealogy-literate integrator recognises.** The FS compatibility review is conducted by people who think in Person-conclusions, personas, `SourceDescription`/`SourceReference`, and `EvidenceReference`. A document that presents our model in those terms is review collateral we will need anyway (research corpus, `standards.md` §5).
- **Where we exceed the standard, no standard has a slot.** Trust tiers (URL-derived, `SourceTierRegistry`), 4-gate per-record verdicts, convergence levels, lineage independence, negative searches, and the append-only field journal have no GEDCOM X equivalent — its `Attribution` is last-editor-only and its confidence is a crude High/Medium/Low. That layer stays ours **by design** and must be documented as deliberate, not hidden in extension fields.

Without a tie to code, mapping documents rot. The mitigation is a home and a habit, both specified below.

## Decision

Adopt GEDCOM X as **concept source and vocabulary only** — never as schema, serialisation, or interchange target. Concretely:

1. A **concept-mapping document** lives beside `AncestorApp/RESEARCH_PIPELINE_SPEC.md` and is a standalone artefact (not folded into any source spec). Core mappings:
   - `Profile` ↔ GEDCOM X Person (conclusion)
   - `LifeCluster` ↔ persona set resolved to one identity
   - `evidence_records` ↔ `EvidenceReference` targets
   - `field_sources` ↔ `SourceReference`
   - **Deliberate no-equivalents, documented as such:** trust tiers, 4-gate outcomes, convergence, negative searches, the field journal.
2. The document is **updated with every AncestorKit model migration** — a definition-of-done item on each ADR-004 evolution.
3. It doubles as the FS compatibility-review artefact: reviewers meet a genealogy-literate model described in their own terms.

## Consequences

**Positive:** captures 100% of Option A's surviving value at ~2% of its cost; makes our above-standard machinery explicit and defensible instead of invisible; review-ready collateral exists before it is demanded; the mapping is where sustained impedance would surface (feeding ADR-001 reversal condition 4).

**Negative:** a standing maintenance obligation on every migration — skipping it silently reverts this ADR; the mapping can create false comfort if read as a conversion spec (it is descriptive, not executable); writing it forces uncomfortable precision about places our model is genuinely weaker (that is the point, and ADR-004 is the outlet).

## Reversal conditions

If the document reveals sustained, painful impedance in two or more of the four ADR-004 evolution areas, that argues for deeper targeted evolution — recorded as ADR-001 reversal condition 4, and still not schema adoption.
