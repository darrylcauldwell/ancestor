# Architecture Decision Records

ADRs record one architectural decision each — the facts that forced it, the decision, its consequences, and (where applicable) the conditions under which it should be revisited. They are written once and amended only by superseding ADRs. Statuses: **Proposed** (awaiting Darryl's review), **Accepted** (binding), **Superseded** (points at its replacement). All six below arise from the July 2026 FamilySearch/GEDCOM X research round (R1 corpus + R2 synthesis).

| ADR | Title | Status |
|---|---|---|
| [ADR-001](ADR-001-domain-model-canonical.md) | The Ancestor domain model is canonical; no external standard becomes the internal schema | **Accepted** |
| [ADR-002](ADR-002-familysearch-two-bounded-surfaces.md) | FamilySearch integrates as two bounded surfaces, never as a schema driver | **Accepted** |
| [ADR-003](ADR-003-gedcomx-vocabulary-not-schema.md) | GEDCOM X is adopted as vocabulary, not schema | **Accepted** |
| [ADR-004](ADR-004-model-evolution-closed-list.md) | Model evolution is a closed four-item list | **Accepted** |
| [ADR-005](ADR-005-fs-tree-data-is-evidence.md) | FamilySearch-originated tree data is evidence, never conclusions | **Accepted** |
| [ADR-006](ADR-006-no-general-treeprovider.md) | No general TreeProvider abstraction | **Accepted** |
| [ADR-007](ADR-007-kinship-joins-core-swift-first.md) | Kinship primitives join the core push, respecced Swift-first | Proposed |
