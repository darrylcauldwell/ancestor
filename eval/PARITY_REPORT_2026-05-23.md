# Backend parity report — python vs swift-mcp (2026-05-23)

First end-to-end measurement of Swift pipeline drift against the
Python reference, per SWIFT_MCP_EVAL_BACKEND_SPEC #Change9.

**Sources**
- python: `eval/runs/2026-05-23T23-37-45.json`
- swift:  `eval/runs/2026-05-23T23-24-35.json`

**Method:** both backends run against the same 12-subject corpus.
Swift backend driven by `_swift_mcp_pipeline_call` (shipped in commits
`6072646` + `56b9dd3`), targeting the user's Cauldwell project DB
under `~/Library/Containers/dev.dreamfold.Ancestor-Research/…/projects/
788F5EA4-…sqlite` with the running app providing the
`RunRequestWatcher` that dequeues research_run_requests.

Diff produced by `eval/compare_backends.py`.

## Headline

| Metric | Value |
|---|---|
| Both-backend measured cells | 46 |
| Backends agree               | 25 (54%) |
| Backends disagree            | 21 |
| Only one backend measured    | 0 |
| Neither measured (unmeasurable kinds) | 8 |

Python headline: **37 supported** (target ≥34). Swift headline:
**0 supported** — because the V1 envelope shape doesn't populate
`supported_hypotheses[]`.

## Dominant drift signal

All 21 disagreements have the same shape: `python=supported`,
`swift=inconclusive`. Zero cases of swift-more-capable, zero
contradiction-vs-supported splits, zero contradiction-vs-inconclusive
splits.

Root cause is *not* a Swift pipeline bug — the Swift pipeline finds
facts. The drift is in the **envelope shape**:
`RunRequestWatcher.buildResultEnvelope` (introduced #Change3) emits
only the three verdicts (`parent_link_verdict`, `identity_verdict`,
`spouse_verdict`). It does not populate `supported_hypotheses[]`,
`contradicted_hypotheses[]`, `inconclusive_hypotheses[]`, or
`discovered_citations[]`. The harness's `_actual_verdict_for_kind`
derives birth/death/marriage/military/burial verdicts by matching
hypothesis kinds in `supported_hypotheses[]` — which is empty on the
Swift side, so they always read as `inconclusive`.

The spec called this out as deferred from V1:
> V1 envelope is verdicts-only; the hypothesis / citation arrays
> land with #Change4's MCP read tool.

But it didn't ship with #Change4. The next change is to fill the
envelope from `result.confirmedFacts` so the harness can measure
fact-derived kinds.

## Kinds the Swift pipeline got right (verdict path)

The three explicit-verdict kinds — measurable today because they
flow through `VerdictEmitter` — show stronger parity:

| Kind | Agree | Disagree | Notes |
|---|---|---|---|
| `spouse_disambiguation`  | 3/4  | 1/4 | strong — `VerdictEmitter.spouseVerdict` matches Python on Robert / Ernest / Stephen |
| `parent_link`            | (n/a)| (n/a)| Swift inconclusive everywhere; matches Python's inconclusive cases by coincidence not by signal |
| `identity_disambiguation` (root key) | 1/1 | 0 | John pair single case |

The two parent_link rows that "agreed" did so as
inconclusive-vs-inconclusive — not a meaningful positive signal.

## Drift inventory (per subject × kind)

Each row below is a subject × kind cell where python and swift
diverged. All 21 entries are `python=supported` × `swift=inconclusive`
— the envelope-shape gap.

| Subject | Kind | Python | Swift |
|---|---|---|---|
| Sarah Jane Byard         | birth_disambiguation    | supported | inconclusive |
| Charles H. Hodgkinson    | birth_disambiguation    | supported | inconclusive |
| Charles H. Hodgkinson    | marriage_disambiguation | supported | inconclusive |
| Catherine Hannah Bown    | birth_disambiguation    | supported | inconclusive |
| Catherine Hannah Bown    | death_disambiguation    | supported | inconclusive |
| Catherine Hannah Bown    | marriage_disambiguation | supported | inconclusive |
| George Bowden            | birth_disambiguation    | supported | inconclusive |
| Robert Cauldwell         | birth_disambiguation    | supported | inconclusive |
| Robert Cauldwell         | death_disambiguation    | supported | inconclusive |
| Robert Cauldwell         | marriage_disambiguation | supported | inconclusive |
| Robert Cauldwell         | military_service        | supported | inconclusive |
| Robert Cauldwell         | parent_link             | supported | inconclusive |
| Ernest Cauldwell         | birth_disambiguation    | supported | inconclusive |
| Ernest Cauldwell         | death_disambiguation    | supported | inconclusive |
| Ernest Cauldwell         | marriage_disambiguation | supported | inconclusive |
| Ernest Cauldwell         | parent_link             | supported | inconclusive |
| Mabel Cauldwell→Brewell  | marriage_disambiguation | supported | inconclusive |
| Lydia Kenworthy          | death_disambiguation    | supported | inconclusive |
| Elizabeth Cauldwell      | birth_disambiguation    | supported | inconclusive |
| Elizabeth Cauldwell      | death_disambiguation    | supported | inconclusive |
| Elizabeth Cauldwell      | marriage_disambiguation | supported | inconclusive |

The parent_link disagreements (Robert, Ernest) are interesting — those
are *verdict-emitted* on the Swift side, but inconclusive. Either:
- The Swift `VerdictEmitter.parentLinkVerdict` is stricter than the
  Python emit helper, or
- The household-members data shape on the Swift side differs from
  Python (Swift's `result.householdMembers` is fed by clustering /
  census plugins; Python's flows through `_extract_household_members`).

Worth a targeted look once the envelope-shape work lands and isolates
this signal from noise.

## What ships next

1. **Extend the Swift envelope** — populate `supported_hypotheses[]`,
   `contradicted_hypotheses[]`, `inconclusive_hypotheses[]`,
   `discovered_citations[]` from `result.confirmedFacts /
   .rejectedRecords / .leads` in `RunRequestWatcher.buildResultEnvelope`.
   Mirror Python's `_state_to_envelope` shape. Probably ~50 lines.
2. **Re-run parity** with the expanded envelope. Expect the 21 envelope-
   shape disagreements to either flip to `agree` or surface as *real*
   Swift drift (which is the signal we actually want).
3. **Investigate parent_link Robert / Ernest** if they remain
   disagreements after step 2.
