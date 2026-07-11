# ADR-002 — FamilySearch integrates as two bounded surfaces, never as a schema driver

**Status:** Accepted 2026-07-11 (Darryl)
**Depends on:** ADR-001 (canonical model), ADR-005 (firewall posture), ADR-006 (no general TreeProvider)

## Context

FamilySearch is two different things, and pure "one more RecordSource" thinking is a category error for half of it:

1. **A record-search provider** — search/hints over historical records. This is exactly the shape of the existing `RecordSource` protocol (`Ancestor Research/Services/Research/RecordSource.swift:23`), which already carries `dataLineage`, `trustTier`, `evidenceDirectness`, `tosStatus`, and coverage axes across 8 working conformances; results map to the closed 9-kind `SourceRecord` enum (`AncestorKit/Sources/AncestorKit/Research/RecordTypes.swift:360`). The FS plugin is half-built: `Ancestor Research/Services/Sources/FamilySearchSource.swift` + `FamilySearchAuth/`, governed by `AncestorApp/FAMILYSEARCH_SOURCE_SPEC.md`.
2. **A shared open-edit tree platform** — person match, source-attach write-back, merge-redirect tracking. `RecordSource.search(query)` has no vocabulary for "attach this SourceDescription to FS person P" or "P was merged into Q". The demo's mandatory **write** leg has no home in the RecordSource shape at all.

FS protocol specificity is deep and must not leak inward: OAuth2/PKCE with support-ticket redirect-uri/Realm registration; 301 merge-forwarding and 410 for deleted persons; weak ETags + `If-Match` conditional POST (<https://developers.familysearch.org/main/docs/caching>); per-user rate limits shared with the user's other FS apps; Beta-vs-production environment scoping (<https://developers.familysearch.org/main/docs/getting-started>).

Items the research corpus flags as **unverified** (`_contradictions.md`) — design nothing against them until verified live on Beta:

- The `ChildAndParentsRelationship` ternary wire shape (prose-sourced, never raw-fetched).
- The HTTP 450 non-viable-merge status code (search-synthesis, medium confidence).
- The exact scope of the records-display licensing restriction (titles + link-out only; paraphrase-confirmed, direct fetch blocked).

## Decision

FamilySearch integrates as **exactly two bounded modules**, and nothing FS-shaped enters AncestorKit:

1. **FS-as-RecordSource plugin** — finish per `FAMILYSEARCH_SOURCE_SPEC.md`. Record search/hints mapped to `SourceRecord` at the adapter boundary; trust/lineage/directness declared on the plugin like the other 7 sources; titles + confidence + ARK link-out pending licensing-scope verification. This alone covers the demo's **read** leg.
2. **FS Tree service** — a new app-layer, deliberately FS-specific service (not a general TreeProvider, per ADR-006): OAuth/PKCE lifecycle, soft-ID handling (301 chains, 410, 450 once verified), ETag conditional writes, throttling, and the demo's **write** leg (scope fixed by ADR-005).

All GEDCOM X parsing, ternary-relationship handling, and FS HTTP quirks are confined to these two modules. A ternary-relationship adapter is **not designed** until the wire shape is verified against a live Beta fetch.

## Consequences

**Positive:** the demo (auth + read + write on Beta) is achievable with minimal blast radius; the read leg reuses proven machinery; the licensing restriction is naturally satisfied by the RecordSource lead/pending-fact presentation shape; each module is independently deletable if FS access ends — the WikiTree-lockout insurance logic, squared for a more gated platform.

**Negative:** two modules to own instead of one; the FS Tree service is a new seam with no precedent in the codebase and must be actively policed — FS tree code written "temporarily" tends to drift into AppState/ViewModels, the exact drift-class ApplyEngine was built to end; the source spec must be kept from growing tree-sync scope (write leg lives in the Tree service's own spec).

## Reversal conditions

None specific — bounded by ADR-006's trigger (a second funded tree-sync integration would prompt re-evaluating whether the FS Tree service generalises).
