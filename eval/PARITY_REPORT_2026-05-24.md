# Backend parity report — python vs swift-mcp (2026-05-24)

Second parity measurement, taken after the V1 envelope-shape gap was
closed (commit `19290c2`). The Swift envelope now carries the full
hypothesis arrays, so the harness's per-kind metric can derive
verdicts for every measurable kind — surfacing *real* Swift drift
rather than missing-data drift.

**Sources**
- python: `eval/runs/2026-05-24T09-19-08.json`
- swift:  `eval/runs/2026-05-24T00-12-09.json`

Diff produced by `eval/compare_backends.py`. Previous run:
`eval/PARITY_REPORT_2026-05-23.md`.

## Headline

| Metric | 2026-05-23 | 2026-05-24 | Δ |
|---|---|---|---|
| Both-backend measured cells   | 46    | 46     | — |
| Backends agree                | 25 (54%) | **31 (67%)** | **+6 / +13pp** |
| Backends disagree             | 21    | 15     | −6 |
| Only one backend measured     | 0     | 0      | — |
| Neither measured (unmeasurable) | 8   | 8      | — |
| Swift headline (supported)    | 0     | **25** | +25 |
| Python headline (supported)   | 37    | 37     | — |

The envelope expansion (commit `19290c2`) accounts for almost all
of the gain: 13 percentage points of agreement recovered, Swift
`supported` headline went from 0 → 25.

## Remaining disagreements — three patterns

### Pattern A — Swift still missing Python-found facts (11 of 15)

The dominant pattern. Swift pipeline didn't surface a record that
Python did. Now that the envelope-shape gap is closed, these are
**real Swift pipeline drift** worth investigating.

| Subject | Kind | Notes |
|---|---|---|
| Catherine Hannah Bown   | birth_disambiguation    | Expected `inconclusive`; Python over-claims `supported`, Swift correctly stays inconclusive — **Python regression** |
| Catherine Hannah Bown   | death_disambiguation    | Expected `supported`; Swift misses |
| Catherine Hannah Bown   | marriage_disambiguation | Expected `supported`; Swift misses |
| George Bowden           | birth_disambiguation    | Expected `supported_with_year_correction`; Swift misses |
| Robert Cauldwell        | death_disambiguation    | Expected `supported`; Swift misses |
| Robert Cauldwell        | marriage_disambiguation | Expected `supported`; Swift misses |
| Robert Cauldwell        | military_service        | Expected `supported`; Swift CWGC integration likely needs check |
| Robert Cauldwell        | parent_link             | Expected `supported`; Swift VerdictEmitter.parentLinkVerdict stays inconclusive |
| Ernest Cauldwell        | marriage_disambiguation | Expected `supported`; Swift misses |
| Ernest Cauldwell        | parent_link             | Expected `supported`; same as Robert — verdict path |
| Elizabeth Cauldwell     | birth_disambiguation    | Expected `supported`; Swift misses |
| Elizabeth Cauldwell     | death_disambiguation    | Expected `supported`; Swift misses |

The parent_link drift on Robert + Ernest is verdict-emitter level —
both subjects expected `supported`, Python emits `supported`, Swift
emits `inconclusive`. Either:
- `VerdictEmitter.parentLinkVerdict` is stricter than its Python
  counterpart, or
- `result.householdMembers` on the Swift side doesn't carry the
  member-name tokens the verdict reads.

The fact-derived misses (birth/death/marriage) collectively suggest
the Swift extend-mode pipeline isn't dispatching the same searches
the Python one does — different ladder, different rate-limit guards,
or simply doesn't reach the records before stopping.

### Pattern B — Swift better than Python (1 of 15)

| Subject | Kind | Python | Swift | Expected |
|---|---|---|---|---|
| Charles Herbert Hodgkinson | death_disambiguation | inconclusive | **supported** | supported |

Swift found Charles's death registration where Python missed it.
Python regression candidate — worth a Python-side trace to see what
search the Swift dispatcher ran that Python didn't.

### Pattern C — Swift over-claims (3 of 15)

| Subject | Kind | Python | Swift | Expected |
|---|---|---|---|---|
| George Bowden | death_disambiguation | inconclusive | supported | `out_of_scope` |
| George Bowden | marriage_disambiguation | inconclusive | supported | `not_yet_verified` |
| Catherine Hannah Bown | birth_disambiguation | supported | inconclusive | `inconclusive` |

George's expected verdicts (`out_of_scope`, `not_yet_verified`) are
not in the standard `supported/contradicted/inconclusive` ladder —
the corpus YAML uses them to mark "shouldn't be searched" /
"deferred research." The harness's annotated-verdict tolerance
(commit `de8e8f8`) probably maps these to `inconclusive` for
agreement purposes, so Swift's `supported` is a real false positive:
the Swift pipeline confirmed records that the corpus considers out-
of-scope.

George Bowden is the `geographic_outlier_handling` subject — born
outside Derbyshire, the spec expects the engine to *recognise* his
out-of-scope-ness rather than confirm any records. Worth looking at
why Swift dispatched outside the home region and Python didn't.

The Catherine Bown birth row sits in Pattern A but is also flagged
here: expected is `inconclusive`, Python claims `supported` (a
Python regression), Swift correctly stays inconclusive.

## Per-kind agreement (corpus-wide)

| Kind | Python expected match | Swift expected match | Notes |
|---|---|---|---|
| birth_disambiguation     | 7/9   | 6/9    | Swift slightly worse |
| death_disambiguation     | 7/8   | 4/8    | Swift materially weaker |
| marriage_disambiguation  | 7/10  | 3/10   | Swift materially weaker |
| military_service         | 1/1   | 0/1    | Swift CWGC needs review (Robert) |
| parent_link              | 8/11  | 6/11   | Swift verdict-emitter drift |
| spouse_disambiguation    | 3/4   | 3/4    | parity |
| baptism_disambiguation   | 1/1   | 1/1    | parity |
| burial_disambiguation    | 0/1   | 0/1    | parity — both miss Stephen Sherwin |
| identity_disambiguation  | 1/1   | 1/1    | parity |

## What ships next

The three patterns suggest three different threads:

1. **Pattern A — Swift extend-mode reaches fewer records.** Trace one
   subject (Ernest is the easiest) through both pipelines side-by-
   side. Compare which search keys ran, which records came back,
   which gates passed. Likely a dispatcher / strictness-ladder
   difference. (Probably M-sized, multi-session.)
2. **Pattern B — Charles's death.** One subject, one kind. Lightweight
   Python-side investigation: what search did Swift run that Python
   didn't? Either close the gap (Python regression) or document the
   coverage difference. (S-sized.)
3. **Pattern C — George Bowden over-claim.** Swift confirms records
   for a subject the corpus considers out-of-scope. Look at why the
   geography gate is letting through hits the scoring should soft-
   fail. (S-sized.)

Plus: re-examine `VerdictEmitter.parentLinkVerdict` strictness —
Robert + Ernest both expected `supported`, Swift emits
`inconclusive`. May be the most surgical single fix in the report.
