# ADR-005 — FamilySearch-originated tree data is evidence, never conclusions

**Status:** Accepted 2026-07-11 (Darryl)
**Depends on:** ADR-001 (canonical model), ADR-002 (FS Tree service is the module this governs)

## Context

The FS Family Tree is a single shared open-edit tree: any contributor on earth can edit any person, person IDs soften to 301 redirects on merge, and the Tree Change feed silently omits Source/Memory/Discussion edits (<https://developers.familysearch.org/main/docs/syncing-family-trees>). Structurally, FS tree content is eventually-consistent and stranger-editable — the exact class of input the Evidence Firewall exists for: **all external writers pass through `pending_facts`/`leads`** (CLAUDE.md, load-bearing invariants), and the deterministic sandwich requires conclusions made by our rules over stable local state.

FS's own contribution philosophy validates this posture rather than fighting it: "conclusions should be made by individuals not by computers"; hints are surfaced with confidence + pending/accepted/rejected status and never auto-applied (<https://developers.familysearch.org/main/docs/family-tree-matching-and-hinting>).

Two adjacent facts shape the write leg and the trust handling:

- FS certification's lowest write tier is exactly source-creation and source-attach: Create Sources → Attach Sources → Update Source (<https://www.familysearch.org/en/developers/docs/certification/sources>). `SourceDescription` needs only a Title; `SourceReference` is the attach-point (<https://developers.familysearch.org/main/docs/contributing-sources>).
- FS hint match-scores/star-ratings are proprietary and opaque, with no GEDCOM X backing (<https://www.familysearch.org/en/blog/introducing-3-star-record-hints-for-experienced-researchers> — currency of the 3-star UI unverified per `_contradictions.md`). Our trust model derives trust from cited URLs via `SourceTierRegistry`; LLM output may not assert a tier, and neither may a platform's opaque score.

**Unverified (label preserved from `_contradictions.md`):** the licensing restriction on displaying FS historical-record content (titles + confidence only, redirect to familysearch.org) is paraphrase-confirmed, not raw-fetched, and its exact scope (records only vs. persona data vs. citation text) is unconfirmed. Its resolution governs how an `EvidenceRecord` represents pointer-only evidence — decided in `FAMILYSEARCH_SOURCE_SPEC.md`, not here.

## Decision

1. **All FS tree content — persons, relationships, hints, matches — enters the app exclusively via `pending_facts`/`pending_relationships`/`leads` through the Evidence Firewall**, scored by the same 4-gate scorer as every other source. Nothing from the open-edit shared tree writes conclusions directly.
2. **The demo write leg is the smallest honest write:** create a `SourceDescription` from an existing `Citation` and attach it to the matched FS person. Person writes, relationship writes, and merges require a new ADR.
3. **FS hint scores are lead-ordering signals only** — never a trust-tier input, never a gate-verdict input. Source trust stays URL-derived.

## Consequences

**Positive:** both invariants hold by construction — no special-casing, FS is just another external writer; the write scope maps onto FS's lowest certification tier, so the demo demonstrates real certifiable capability without touching vital data on Beta (which is a snapshot of *real* production genealogical data, not fixtures: <https://developers.familysearch.org/main/docs/getting-started>); the human-review posture matches what FS mandates even of certified partners (RootsMagic: writes cannot be pushed silently — <https://community.rootsmagic.com/t/using-rootsmagic-with-family-search/14596>).

**Negative:** FS data reaches conclusions only at human-review speed — no bulk import of FS tree branches, by design; pointer-only evidence (if the licensing restriction extends to cached content) needs an explicit `EvidenceRecord` representation and a firewall URL-content-verification carve-out, both owed by the FS source spec; the deliberately minimal write leg means the demo shows less write surface than FS's deeper tiers — a scoping choice reviewers must be walked through.

## Reversal conditions

Widening the write scope (person/relationship/merge writes, reason-for-change UX per Tree Share+ requirements: <https://developers.familysearch.org/main/docs/contributing-to-the-familysearch-family-tree>) requires a new ADR, triggered only by production write certification becoming a product goal (ADR-001 reversal condition 1). The evidence-not-conclusions rule itself is invariant-derived and is not expected to reverse.
