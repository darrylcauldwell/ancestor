# Source Weighting — staged dispatch, free-sources-first

**Status: PROPOSED 2026-07-15 — awaiting owner acceptance.** Direction set by Darryl during
Barbara Ayre triage: "the free UK sources offer us capability to provide localised search to
parish, district and then region then national… the weighting for our app should be from the
known free sources."

## Problem (verified in code, 2026-07-15)

`SearchDispatcher.dispatch` enumerates every enabled source covering the record type and
fires them **in one parallel task group** — there is no cross-source ordering or weighting.
The escalation discipline exists only *within* sources (Chapman-code ladders: parish →
district → county → adjacent → national). FamilySearch is co-equal with the scoped free
sources on every axis of every run, and because FS answers **national** name+date queries
across all its collections, it dominates the evidence set with remote namesakes (live
evidence: Barbara Ayre's triage haystack — Northumberland parish personas surfaced by FS on
a Derbyshire-anchored subject; whole-campaign correction-tier noise, 2026-07-14/15).

Cost of the flat fan-out:
- **Precision** — remote namesake noise becomes leads/clusters the user must triage away.
- **Volume** — every run spends queries at every source even when the local, high-precision
  tier would have answered; volunteer sources have hard daily budgets
  (`feedback_volunteer_sources_rate_limits`), and every source relationship (pending Free UK
  Genealogy permission per ADR-008, pending FSI agreement) benefits from fewer total calls.
- **Identity** — the product's home is the free sources; FS is the breadth extender, not the
  default firehose.

Note on posture (ADR-008): the free sources' *published terms* currently forbid programmatic
access (permission emails drafted, unsent); the FS cookie path is the operator-authorized
interim. Staging is therefore justified on precision/volume/identity — not as compliance
relief — and reduces load on every provider regardless of how ADR-008 resolves.

## Design

Replace the flat fan-out with **staged dispatch**. Stages run sequentially; sources within a
stage keep today's parallel task-group + per-source strictness ladders + budgets + circuit
breakers + negative cache untouched.

- **Stage 1 — local free.** All free sources at the subject's local scope (home Chapman code
  / district / parish where the source supports it). Includes Wirksworth where applicable.
- **Stage 2 — adjacent free.** Same sources widened to adjacent counties, only for record
  types Stage 1 left unanswered (see "miss test" below).
- **Stage 3 — national free.** FreeBMD-class national indexes (already district-coded) and
  FreeREG/FreeCen national fan-out, again only for unanswered record types.
- **Stage 4 — FamilySearch breadth.** FS fires last, only for record types still unanswered
  OR for coverage the free tier structurally lacks (e.g. post-1983 GRO, overseas, FS-only
  collections). Its query axes are narrowed by everything earlier stages established
  (birth-year consensus, place axes per #Change9, family axes per #Change10).

**Miss test (per record type):** a stage's result is "answered" when it produced ≥1 record
with verdict ≥ `.lead` whose geography is consistent with the subject anchor — otherwise the
next stage fires. The searched-surface honesty envelope must record *skipped* stages the same
way it records negative searches today (a stage that never fired is not a covered search).

**Explicitly not a hard gate:** the run's scope parameter (user-chosen: parish … national)
still bounds every stage; a national-scope run still stages free-before-FS but does not skip
FS. A future per-run toggle ("FS: always / on-miss / never") is an open question below.

## Interactions audited before build

- **Convergence/witness collapse (DS-03)** — staging FS after a FreeBMD hit does not lose
  corroboration: same-GRO-line transcripts collapse to one witness anyway. Genuinely
  independent FS collections still arrive at Stage 4.
- **Negative cache / re-run behaviour** — a Stage-4 skip must not poison later runs into
  believing FS was searched; skipped ≠ negative.
- **Watcher campaigns** — per-profile staging multiplies wall-clock (sequential stages);
  bound each stage with the existing budget/breaker machinery and surface stage progress in
  the activity bus.
- **FS self-narrowing follow-ups** (#Change11 rescue, exact-birth-date gates) key off FS
  result shapes — verify they still fire when FS runs at Stage 4 with narrowed axes.

## Acceptance criteria

1. A Derbyshire-anchored subject whose death is answerable from FreeBMD locally never
   receives FS national-namesake personas in the same run (Barbara Ayre fixture).
2. A subject unanswerable from the free tier (e.g. post-1983 death, Kenneth-class) still
   reaches FS and resolves — no capability regression vs the 2026-07-14 fixes (#Change9–11).
3. Total outbound queries per campaign run drop measurably (dispatch log comparison on the
   2026-07-14/15 campaign profile set).
4. Searched-surface reporting distinguishes answered / negative / stage-skipped per source.

## Companion change — one research action + Sourcing report (DECIDED 2026-07-15)

Origin: Darryl asked whether Verify/Extend/Discover/All is the right way to think about
research at all. The design settled through three steps, each verified against the code:

1. **The Depth modes only pre-declare what the engine can infer.** They set (a) the
   strictness ladder (verify `[strict]`, extend `[strict,loose]`, discover
   `[loose,variant]`) and (b) stopping policy (verify's early-stop; All's extra iterations +
   fact cap). Query richness is already profile-data-driven in every mode.
2. **A "check/verify" intent seemed like the un-inferable residue** (user purpose:
   corroborate-before-trusting vs dig) — but examining what Verify *actually does* dissolved
   it: strict-only search + stop-as-soon-as-ANY-fact-corroborates. Not an audit; a truncated
   dig. Its honest deliverable — per-field sourcing verdicts — is a REPORT over persisted
   state, not a run type.
3. **Adaptive cost self-bounds where a check would be used**: on a rich profile, strict
   searches hit immediately, gaps are few, the run stops early — the dig IS the check. The
   expensive escalation only occurs on thin profiles, where discovery was wanted anyway.

**Decided design:**

- **One research action.** Strictness starts `.strict`, escalates `.loose` → `.variant` only
  on miss (same on-miss pattern as this spec's source stages). Stops when the profile's open
  gaps are answered, or stable-point detection / budgets bound it. Depth picker removed;
  sheet becomes subject → Scope → prose toggle → gaps → Run.
- **Sourcing report** (successor to what Verify pretended to be): per-field verdict —
  *corroborated* (level + independent-lineage count from `evidence_convergence`),
  *unsourced* (with the searched-surface from `negative_searches`, honestly distinguishing
  "not searched" from "searched, nothing found"), *contradicted* (open dispute, linked).
  Rendered per profile from persisted state — no run required — and tree-wide, which also
  feeds the publisher's empty `convergenceByProfile` badge slot (Phase 3 follow-up).
- **Kept:** Scope (user-owned geographic knowledge); focused runs (record-type focus);
  prose-extraction opt-in; `ResearchMode` internally + on the MCP `kick_off_research`
  surface for watcher/campaign compatibility (any explicit mode = override honoured; the
  in-app sheet always dispatches adaptive).

Validation at build: run the 2026-07-14/15 campaign fixture set under both models — queries
spent, wall-clock, new facts, junk-lead count must not regress (and total queries should
drop per this spec's main acceptance criteria).

## Non-goals

Source trust tiers (unchanged, URL-derived); per-source scoring weights in the 4-gate scorer
(the scorer stays source-blind); removing FS coverage (breadth is a feature — this spec
sequences it, it does not shrink it).

## Open questions for owner acceptance

1. ~~Stage 4 FS: on-miss only vs always-last?~~ **DECIDED 2026-07-15 (Darryl): on-miss
   only.** FS fires solely for record types the free tier left unanswered (plus the
   structural-coverage carve-outs above).
2. ~~Visible "source strategy" control vs silent engine behaviour?~~ **DECIDED 2026-07-15
   (Darryl, by pointing at the existing research sheet): no new control.** The sheet already
   expresses user intent via Depth (Verify/Extend/Discover/All) and Scope (parish …
   national) — staging runs silently *within* the chosen Scope, escalating stages only up to
   its bound. Build-time copy tweak only: the Scope/Depth descriptions mention that
   FamilySearch fires only when the free sources come up empty.
3. ~~Wirksworth placement?~~ **MOOT — DECIDED 2026-07-15 (Darryl): "Wirksworth was a source
   added for point in time which we can remove."** Retirement becomes **Change 0** of this
   spec's build (below); staging designs for the national free sources + FS only.

## Change 0 — retire the Wirksworth source (prerequisite)

Remove the live source: delete `WirksworthSource` + its tests, deregister in
`SourceBootstrap`, sweep dispatcher/lead-filter/region special-cases (~20 files reference
it — several are the region-specific carve-outs `feedback_no_hardcoded_regions` has been
pushing against, which is part of the point). **Keep for historical citations:** the
`SourceTierRegistry` wirksworth.org.uk URL→tier mapping and the GEDCOM exporter's
`wirksworth` source-metadata case — evidence rows and applied citations from past runs
remain valid and must keep resolving trust tier + export metadata. Python `sources/`
reference implementation untouched. Also closes the outstanding ADR-008 terms-review item
for wirksworth.org.uk (site was TLS-unreachable for terms fetch; removal moots it).
