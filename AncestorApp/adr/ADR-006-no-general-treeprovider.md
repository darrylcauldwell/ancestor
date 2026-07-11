# ADR-006 — No general TreeProvider abstraction

**Status:** Proposed 2026-07-11 — awaiting review
**Depends on:** ADR-001 (AncestorKit is the shipped contract), ADR-002 (the FS Tree service stays FS-specific)

## Context

Option D in the R2 analysis proposed provider-independent `RecordProvider`/`TreeProvider` protocols, with our model as one implementation behind the layer. Its two halves fare very differently:

- **The RecordProvider half already exists and is paid for.** `RecordSource` (`Ancestor Research/Services/Research/RecordSource.swift:23`) *is* that abstraction — 8 working conformances, with richer provider metadata (`dataLineage`, `trustTier`, `evidenceDirectness`, `tosStatus`, coverage axes) than a fresh design would dare include.
- **The TreeProvider half fails the instance-count test.** Enumerate the tree-sync implementations a decade could plausibly fund: FamilySearch (demo-gated; Beta access explicitly does not imply approval — <https://developers.familysearch.org/main/docs/app-approval-considerations>); WikiTree (bespoke twin already exists; our write access currently blocked); Ancestry — no public API, closed FTM protocol; MyHeritage — no public API; Findmypast — Hints API docs archived (<https://github.com/findmypast/public_docs>). That is one gated instance plus one legacy bespoke instance.

Designing a general abstraction from that base is speculative generality: FS's quirks (ternary relationships, 301 chains, ETag opt-in, change-feed blind spots, 450) do not generalise, so the first design would be wrong exactly where it matters. Two further costs are structural: a generic `TreeProvider.write()` is precisely the hole through which something bypasses the Evidence Firewall someday — abstraction layers are where invariants go to die; and demoting AncestorKit to "one implementation behind the layer" inverts its actual role as the compiled, shipped contract of the publisher and both viewers, adding a permanent indirection tax on every feature, borne by one developer, for consumers that don't exist.

Option D's *motivating observation* — FS's tree role needs a seam that RecordSource lacks — is correct, and is honoured as the bounded FS-specific Tree service of ADR-002.

## Decision

**No general TreeProvider abstraction is built.** `RecordSource` remains the only provider abstraction in the codebase. The FS Tree service (ADR-002) is deliberately FS-specific — its OAuth, soft-ID, and conditional-write handling are not designed for reuse. This decision is revisited only when a **second funded, production-grade tree-sync integration is committed** — the moment two real instances exist to abstract over, and not before.

## Consequences

**Positive:** zero indirection tax; no months of protocol design during a live shipping window with no user-visible output (the classic second-system trap); the firewall has one fewer generic write surface to police; the FS demo is not delayed behind abstraction work.

**Negative:** if a second tree platform does materialise, the FS Tree service gets refactored toward an abstraction *then*, with FS-specific assumptions to unpick — an accepted cost, cheaper than premature generality because the second instance's real shape informs the design; until then, any WikiTree write-path revival (currently moot — account blocked for writes since 2026-05-22) would be a second bespoke module rather than a plugin.

## Reversal conditions

1. Ancestry or MyHeritage opens a documented public tree API (ADR-001 reversal condition 3) **and** integrating it is funded product work — that is the re-evaluation trigger for a TreeProvider, not for schema adoption.
2. Any other second production-grade tree-sync integration is committed and funded (e.g., WikiTree write access restored *and* twin-sync promoted to a product feature).
