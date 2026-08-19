# SUBJECT_PLACE_MODEL_SPEC

**Status:** SPEC — consumer inventory complete (2026-08-19). Slice 1 landed (`3da954d`);
Slice 1.5 landed and `d58d542` replayed clean (2026-08-19).
**Origin:** owner observation, 2026-08-19: *"The goal was a singular location
format and approach used consistently."*

## Problem

**Storage is already uniform.** Every location in the model is a `(text, code)`
pair:

| | text | code |
|---|---|---|
| Profile birth | `birthLocation` | `birthLocationCode` |
| Profile death | `deathLocation` | `deathLocationCode` |
| Life event — incl. **census** and **residence** | `location` | `locationCode` |
| Relationship marriage | `marriageLocation` | `marriageLocationCode` |

Plus `Profile.birthRegistrationDistrict` (Slice C) — a *derived* district id,
written only by `ApplyEngine` from an applied birth record.

**`ResearchSubject` then flattens that one shape into five ad-hoc ones**
(`Services/Research/ResearchSubject.swift`):

```
region: Region?                                   :187
deathLocation: String?                            :194   text only — no code
homeChapmanCode: String                           :213   a derived county, as a bare string
residenceAxes: [ResidenceAxis]                    :231   (place, chapmanCode, yearFrom, yearTo)
burialPlace: String? / burialChapmanCode: String? :236/:239
```

Nothing on the subject says *"here are all the places we know about this person,
with their codes and their years."* So every consumer reads whichever flattened
field someone remembered to wire to it, and the gaps are arbitrary rather than
designed.

### The evidence that this is the actual defect

Four separate "additive arm" special cases have grown, one per source, each with
its own comment explaining the same underlying idea — that the events which
matter most are the ones that happened away from where a person was born:

1. **FreeCen** merges residence counties into its residence axis
   (`SearchDispatcher.swift:1058-1075`).
2. **FreeREG** appends a burial county for burial-shaped records
   (`SearchDispatcher.swift:1146-1155`).
3. **FreeBMD** got a death/burial county arm on 2026-08-18 (`d58d542`) — the
   third implementation of the same idea.
4. **Census and residence counties still never reach FreeBMD at all**, so a
   profile whose only locations are census residences is searched in the
   *project default* county. It could appear in five Staffordshire censuses and
   FreeBMD would still search Derbyshire.

Adding a fifth special case (a residence arm on FreeBMD) would have been the
obvious next move. It is the wrong one.

## Decision

One value type, carried as a collection.

```swift
nonisolated struct PlaceRef: Sendable, Equatable {
    let text: String            // what the tree says, verbatim
    let code: String?           // PlaceAuthority id when known
    let kind: PlaceKind         // birth | death | marriage | residence | census | burial
    let yearFrom: Int?          // event window; nil bounds are OPEN
    let yearTo: Int?
    let sensitive: Bool         // carried, never silently dropped
}
```

`ResearchSubject` carries `places: [PlaceRef]`. A consumer asks *"places of kind
X covering year Y"* rather than reading a bespoke field. County, district and
parish are derived **uniformly** by resolving `code` through `PlaceAuthority`,
falling back to text resolution — instead of each site re-parsing text its own
way.

### What this collapses

- The anchor becomes "resolve the best-evidenced ref", not a hand-written
  fallback chain.
- The four additive arms become **one rule**, stated once.
- A new source cannot miss an axis, because there is only one collection to read.
- Place decisions and census parish/district flow in as codes on the same refs.

## Invariants (must survive the refactor)

- **THE GATE MUST NOT MOVE — and the first draft of this invariant was
  unachievable.** It read: *"more place data may widen what is SEARCHED; it must
  never widen what the scorer ACCEPTS."* That firewall does not exist.
  `RecordScorer.applyExclusivity` (:368) and `applyExclusivityAcrossStore` (:1203)
  demote a stored `.fact` as soon as a SECOND `.fact`-verdict candidate appears in
  the same slot with no discriminator (:339, :408). Searching two more counties
  for a death is *exactly* how a second undiscriminated candidate arrives. Worse,
  `ContradictoryFactsAudit.demotions` (:57-72) re-runs that pass tree-wide over
  stored evidence — so the demotion surfaces days later, in a Health audit, on a
  record the user already applied, with nothing linking it back to a "location
  model cleanup".

  So it is TWO invariants, and both need proving:
  - **(a) Nothing accepted today may be rejected tomorrow** over the same corpus —
    the exclusivity risk. This is a *narrowing*, arrives late, and nobody is
    looking for it. **This is the dangerous one.**
  - **(b) Nothing rejected today may be accepted tomorrow** — the geography-gate
    risk, and the one everyone thinks of first.

  Note this applies retroactively: the FreeBMD death-county widening shipped in
  `d58d542` can surface a second death candidate and demote an applied fact. It
  should be replayed too.

- **A corpus replay diff is the only proof, and it is Slice 1.5 — before any
  behaviour change.** `evidence_records.gates_json` already persists every gate
  outcome AND its reason (`ProjectDatabase.swift:1372, :3980, :4191`), and
  `CampaignReviewService.reconstruct` (:55-63) already rebuilds `ScoredRecord`s
  from it. A harness that re-scores every stored record old-vs-new and diffs
  `(verdict, gate outcome, gate reason)` is cheap, and nothing else demonstrates
  either invariant.

- **`ConvergenceEngine` is place-blind and must stay so.** It reads zero location
  anywhere; `valueKey` keys on year only (:204-218). Pin that with an explicit
  assertion so a later slice cannot quietly add a place term.
- **An absent anchor stays absent.** `homeChapmanCode == ""` currently triggers a
  visible scope-skip ("no home county to anchor … widen to National"). A richer
  model must not manufacture an anchor where none should exist.
- **Sensitive events stay filtered.** `residenceAxes` filters `!event.sensitive`
  (`ResearchSubject.swift:852`). A generic collection must carry that, not lose it.
- **Request volume must not multiply.** Today one `homeChapmanCode`; a collection
  may yield several counties. Volunteer sources are not stress-test targets —
  any fan-out is bounded and stated, never emergent.
- **Precedence is explicit and tested.** Today: birth code → birth text → death
  code → death text → project default. Any "best evidenced" rule must reproduce
  that ordering or justify each change.

## Slices

*(sequence to be finalised from the consumer map)*

- **Slice 1 — characterization.** Pin today's behaviour first: the anchor
  derivation table, every source's emitted axes for a set of fixture subjects,
  and the gate's accept/reject decisions. The refactor is judged against these.
- **Slice 1.5 — the replay harness. LANDED 2026-08-19.**
  `Services/Research/ScoreReplay.swift` + `ScoreReplayTests` (19, always run) +
  `ScoreReplayCaptureTests` (opt-in, runs against a real project).

  **It replays BOTH stages, and that is the whole point.** A per-record
  `classify` replay would fingerprint two namesake 1891 households as two facts
  and report "no change" straight through the regression this spec calls
  dangerous — the demotion is not a property of any single record. So the
  harness re-runs `applyExclusivity` over the re-scored set, reproduced exactly
  as `ContradictoryFactsAudit.demotions` reproduces it (same slots, same ghost
  rivals, same user-discard exemption). Ghosts are read from STORED gates, not
  from the re-score: `isExclusivityGhost` tests for an `.exclusivity` softFail
  that only the pass itself appends, so deriving them from a fresh classify
  would always yield an empty set and silently drop the legacy flip-flop case.

  `ScoreReplay.narrowings` is the gate — a record that was a fact and no longer
  is. Everything else is reported for a human read; only a narrowing fails the
  build, because a widening is often the intended outcome.

- **`d58d542` replayed: CLEAN (2026-08-19).** Worktree at `d58d542^`, harness
  copied in, both sides run over the same 123 MB copy of the live project:
  **31,481 records across 152 profiles (322 fact / 31,159 not) — byte-identical
  captures.** So the commit re-scored nothing differently.

  **What that does and does not prove.** It proves the code change moved no
  verdict and no gate reason on the corpus as it stands. It does NOT clear the
  commit going forward, because its risk was never re-scoring — it was FETCHING:
  a widened death search brings back a second undiscriminated death candidate,
  which contests the slot and demotes an applied fact. A replay only re-scores
  what is already stored. That risk surfaces as a narrowing on the NEXT replay
  after new records land, which is the routine the harness is for.
- **Slice 2 — the type.** `PlaceRef` + `ResearchSubject.places`, populated
  alongside the existing fields. Nothing reads it yet. Zero behaviour change.
- **Slice 3 — one consumer at a time.** Move each reader to `places`, proving the
  characterization tests still pass at each step. The additive arms collapse here.
- **Slice 4 — delete the flattened fields.** Only once every reader has moved.
- **Slice 5 — the gap that started this.** Census and residence counties reach
  every source that can use them, by the single rule rather than a fifth arm.

## Acceptance

- A profile whose only locations are census residences is searched in **those
  counties**, on every source that can scope, not in the project default.
- The four additive-arm comments in `SearchDispatcher` are replaced by one rule.
- Characterization tests from Slice 1 pass unchanged throughout.
- No increase in request count for any subject that has a birth place today.

## What the mapping run found (2026-08-19)

**37 read sites, all in `SearchDispatcher`.** `DispatchStaging` reads none —
stated here so nobody budgets work for it. Outside the dispatcher and scorer,
almost nothing reads subject places at all: `residenceAxes`, `burialPlace` and
`burialChapmanCode` have **zero** consumers elsewhere. The defect seen from the
consumer side is not "each site reads a different field" but "most sites read the
one field that happens to be a bare `String`, and the rest read nothing."

**Two live defects, both caused by `region` being misnamed.** `fromProfile` builds
`region: .county(profile.birthLocation)` (`ResearchSubject.swift:936`) — a whole
freeform string stuffed into a case meaning "county name". Consequences:

1. **The prose corpus runs unconstrained.** `ProseCorpusSource.placeTokens` (:387)
   compares `entry.county` ("Derbyshire") against that payload ("Loscoe,
   Derbyshire, England") for equality. Never equal → no tokens → no place
   constraint. Live, in a registered source, and **no test catches it**.
2. **A doubled country in FamilySearch queries.** `homeCountry(from:)` (:512-515)
   takes the comma-tail of the same string `jurisdictionString` (:549) then
   appends to, yielding `"Loscoe, Derbyshire, England, England"`. Latent only
   because FamilySearch is deliberately unregistered as a record source
   (owner decision 2026-08-07) — it would fire the moment that changed.

Neither may be fixed tactically. Fixing (1) *narrows* the corpus, which is
exactly the (a) exclusivity risk above — it must ride the replay harness.

**`region` needs a compatibility shim, not deletion.** Eight of its 15 sites are
passthrough into `RecordQuery.region`, which is public AncestorKit API read
outside the dispatcher (`SourceRegistry.enabledSources` coverage filter,
`ProseCorpusSource`). That is a slice of its own.

**Two derivation paths sit five lines apart** in the FreeBMD arm added in
`d58d542`: the death county is re-parsed from text at the call site while the
burial county arrives pre-derived. Same need, two code paths, adjacent — the
clearest single argument for `PlaceRef.code`.

**Anchor-less rescue is inconsistent, and produces a false message.** FreeREG
appends its burial county BEFORE the empty-check (:1181-1192), so an anchor-less
subject with a burial county still gets queries. FreeCen merges residences AFTER
a guard that has already emptied (:1104, :1052), so an anchor-less subject *with
residence axes* is scope-skipped — and `scopeSkipReason` (:334) then reports "no
home county to anchor scope" about a person the tree does place geographically.

**`birthRegistrationDistrict` is never read by the scorer.**
`conflictsWithConfirmedBirth` re-resolves `subject.birthLocation` from scratch on
every call (`RecordScorer.swift:76-80`), ignoring the cited district
`ApplyEngine` wrote.

## Running the replay

```
# capture a baseline BEFORE the change (~2½ min on a 31k-record store)
TEST_RUNNER_RUN_SCORE_REPLAY=1 \
  TEST_RUNNER_SCORE_REPLAY_PROJECT=/path/to/copy-of-project.sqlite \
  TEST_RUNNER_SCORE_REPLAY_OUT=before.txt \
  xcodebuild test -project "Ancestor Research.xcodeproj" -scheme "Ancestor Research Tests" \
    -destination "platform=macOS" -skipMacroValidation \
    -only-testing:"Ancestor Research Tests/ScoreReplayCaptureTests"

# after the change, add a baseline and the run becomes a gate
… TEST_RUNNER_SCORE_REPLAY_BASELINE=before.txt TEST_RUNNER_SCORE_REPLAY_OUT=after.txt …
```

Three things bite, all learned the hard way:

- **The `TEST_RUNNER_` prefix is mandatory.** `xcodebuild` does not pass the
  caller's environment to the test process — it forwards only that namespace,
  stripping the prefix. Without it the suite silently skips, which on the
  console is indistinguishable from a pass.
- **Point it at a COPY — and at the SAME copy on both sides.** Two reasons.
  `ProjectDatabase.init` runs migrations, which is a write, so the replay's
  read-only guarantee (pinned by `replayingDoesNotTouchTheStore`) does not extend
  to the open. And a replay row is "what today's code decides", so if the tree is
  edited between the two captures the diff measures the owner's edits, not the
  code change. One frozen copy, both runs.
- **Capture names resolve inside the sandbox container's temp directory**
  (`~/Library/Containers/dev.dreamfold.Ancestor-Research/Data/tmp/`). A bare
  `before.txt` works; an absolute `/tmp/…` path is refused by the sandbox. The
  resolved path is printed.

## Open questions

- ~~Does the replay harness run against the owner's live project, a fixture
  corpus, or both?~~ **Both, for different jobs** (2026-08-19). The fixture suite
  proves the harness is trustworthy and runs on every build; the capture suite
  produces evidence about an actual change and is opt-in.
- `region`'s shim: keep `Region` as-is and populate it correctly, or deprecate it
  behind a computed property? The public-API surface decides this.
- Should Slice 5 (census/residence counties reach every source) ship behind the
  replay diff as well? It widens search, so by invariant (a) it must.
