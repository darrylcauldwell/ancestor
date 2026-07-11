# Research Pipeline — Specification

**Status:** Combined. Part I (current state) is descriptive of the
shipped engine; Part II (V2) is accepted, implementation in progress.
**Supersedes:** the 2026-04-25 design-intent draft and the 2026-05-19
`RESEARCH_PIPELINE_V2_SPEC.md` (both folded into this single document
on 2026-05-22; the V2 split was a transitional artefact).
**Folds in:** `archive/LLM_RESEARCH_OPTIONS.md` (decision-staging
portfolio analysis; archived as the dated record).
**Date:** 2026-05-22 (post-T17 — sibling discovery shipped; consolidation
sweep).
**References:** `AncestorApp/PROSE_CORPUS_SPEC.md` (corpus + bio
synthesis subsystem), `AncestorApp/FAMILYSEARCH_SOURCE_SPEC.md`
(single-source coverage).

This document is in two parts. **Part I** is the as-built reference for
the pipeline as it actually runs today, plus the product-level design
requirements that motivated the architecture and the adjacent topics
(source-surfaced images, cross-source enrichment) that live alongside
it. **Part II** is the accepted V2 design pivot — the architectural
change that the seven remaining open tasks (T7, T8, T9, T11, T12, T23,
T31) collectively implement, plus three new task slots from the
user-facing reframe (§5.9 / §5.10 / §5.11).

Internal `§X` references within each Part are scoped to that Part.
Cross-Part references use "Part I §X" / "Part II §X".

---

# Part I — Current state (as-built)

This Part describes the pipeline as **built**. It is the baseline
against which Part II proposes change. Where this conflicts with any
earlier draft of this spec, the code wins.

## 1. What this is, and is not

**Is:** a behavioural inventory — what the code does today, with
file:line refs, constants, thresholds, and the design rationales
pinned in code comments. Read this when you need to know "does the
pipeline already do X?" before adding a new subsystem.

**Is not:** a design-intent doc. Several names from the historical
2026-04-25 draft (`StrategyAdvisor`, `LeadInvestigator`,
`BiographyDrafter`) never shipped under those names; the
actually-shipped LLM components are `ResearchInterpreter` and
`NarrativeAssembler`.

**Is not:** a tutorial. The user-facing flow is documented elsewhere;
this is the engine side.

The unifying principle: **decisions about facts are always deterministic
and always user-approved. The LLM only suggests where to look next.**
The runtime is Swift-only — a single signed Mac binary, no IPC, no
two-process debugging. The Python codebase is a reference implementation
for porting, never a runtime dependency.

---

## 2. Architecture in one screen

```
┌──────────────────────────────────────────────────────────────────────┐
│  User picks a subject (Profile, Lead, or untracked person)           │
└────────────────────────┬─────────────────────────────────────────────┘
                         │ ResearchSubject + ResearchConfig (mode + scope)
                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│  ResearchPipeline.research(subject:config:)                          │
│                                                                       │
│  per-iteration (1...maxIterations):                                  │
│    1. SearchDispatcher.dispatch  ──► raw [SourceRecord]              │
│    2. RecordScorer.classify       ──► [ScoredRecord] (4 gates)       │
│    3. dedup vs prior iterations                                      │
│    4. extract household members from census                          │
│    5. detect discrepancies vs existing tree                          │
│    6. refine subject from learned dates                              │
│    7. (between iterations) ResearchInterpreter.suggestNextSearch     │
│    8. stopping checks                                                │
│                                                                       │
│  post-loop (once):                                                   │
│    9.  ClusteringEngine.cluster                ──► [LifeCluster]     │
│    10. runParentHypothesisFlow                                       │
│        • generate(.parentInferred) + grade                           │
│        • generate(.parentMarriage)  + grade                          │
│        • reconcileParentMarriages                                    │
│    11. runSiblingHypothesisFlow (identity + parents gated)           │
│        • generate(.siblingExists)   + grade                          │
│    12. T7 second pass (when ≥1 inconclusive hypothesis has a         │
│        non-empty deficitQuery): dispatch, re-grade, re-reconcile     │
│    13. assemble ResearchResult                                       │
└────────────────────────┬─────────────────────────────────────────────┘
                         │ ResearchResult (clusters, hypotheses, discrepancies)
                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│  ClusterReviewView — user reviews + decides                          │
│    • Cluster Apply / Discard / Save-as-lead                          │
│    • Per-record Apply / Discard overrides                            │
│    • Hypothesis accept/apply (parent + sibling, projected from       │
│      result.hypotheses via the per-kind projection helpers)          │
│    • Compare candidates (MLX prose, optional)                        │
└────────────────────────┬─────────────────────────────────────────────┘
                         │ writes via ProjectDatabase (overwrite-safe)
                         ▼
                  Profile / Relationship / LifeEvent / Citation
```

**The deterministic-probabilistic-deterministic sandwich.** All
decisions about whether a record matches, whether two records
corroborate, whether a discrepancy is severe, and whether a fact is
committed are made by rules. The local reasoning model (MLX) is
restricted to between-iteration suggestions about *where to look next*
and post-hoc *prose comparison* of already-graded clusters. It cannot
override the scorer.

---

## 3. Decision rights — what decides what

**Status: Built.**

### 3.1 Always deterministic

| Question | Component | File |
|---|---|---|
| Does this source record match the subject? | `RecordScorer.classify` (4 gates) | `RecordScorer.swift:30` |
| Is the subject's identity uniquely pinned? | `SubjectIdentityResolver.resolve` | `SubjectIdentityResolver.swift:40` |
| Which districts might this subject have been registered in? | `GeographicHypothesisGenerator.inferDistricts` | `GeographicHypothesisGenerator.swift:57` |
| Are these records the same person? | `ClusteringEngine.cluster` (5 steps) | `ClusteringEngine.swift:25` |
| Are two sources independent corroboration? | `ConvergenceEngine.score` + `SourceLineage` | `ConvergenceEngine.swift` |
| Is this finding strongly enough corroborated? | `LifeCluster.hypothesisVerdict` | `LifeCluster.swift:131` |
| Does this record contradict the tree, and how severely? | `DiscrepancySeverityTable.severity` | per-tier table |
| What surnames do the parents have? | `ParentInferenceEngine.infer` | `ParentInferenceEngine` |
| What are the parents' given names (from BMD index pair)? | `MarriageEnrichmentEngine.match` | `MarriageEnrichmentEngine` |
| Are there candidate siblings in the same district? | `SiblingInferenceEngine.inferSiblings` | `SiblingInferenceEngine.swift:82` |
| What's the trust tier of this URL? | `SourceTierRegistry` | (URL-keyed) |

### 3.2 Probabilistic (MLX local model only)

| Task | Component | When |
|---|---|---|
| Suggest the next source / record type to focus on | `ResearchInterpreter.suggestNextSearch` | Between iterations of the pipeline |
| Compare candidate clusters in prose for the user | `ResearchInterpreter.compareCandidates` | On user request, in cluster review |
| Draft narrative summaries | `NarrativeAssembler` | On user request |

The model **cannot** classify records, decide convergence, or pick
winners. Its output is "advice for the next iteration" or "prose for
the user" — never a decision.

### 3.3 The deterministic-wins rule

When the model and the deterministic engine disagree, deterministic
wins. Convergence can upgrade a discrepancy severity but never
downgrade it. There is no path by which model output writes a Profile
field or a Relationship.

---

## 4. The RecordScorer — four gates and a verdict

**Status: Built with drift.** Gate machinery and roll-up match the
code; specific numeric constants in §4.3 have drifted from their
spec values as the source data revealed itself (census tolerance,
BMD birth-year tolerance). See §4.3 for the canonical pointer policy.

`RecordScorer.classify(record:subject:searchType:)` is the **only**
way a `SourceRecord` becomes a `ScoredRecord`. Each call runs four
gates and rolls them up into a verdict.

### 4.1 The gates

| Gate | Checks | Outcomes | Failure mode |
|---|---|---|---|
| **Name** | Surname similarity ≥0.7 AND given-name similarity ≥0.7. Middle-name guard: when subject has a middle name, record must agree (initial or substring). | `pass` / `fail` | Name `fail` always becomes `.impossible` — wrong person |
| **Date** | Record's year fits subject's birth window `[birthLow − tol, birthHigh + tol]`. Hard rules: died before born, married before born, age >110 at death, age <16 at marriage. | `pass` / `softFail` / `fail` / `impossible` | `impossible` short-circuits the entire roll-up to `.impossible` |
| **Geography** | Record district matches subject home district / Chapman code. Foreign-country tokens hard-fail. | `pass` / `softFail` / `fail` / `skip` | Mode-dependent: `.all` mode demotes failure to `.lead`; other modes treat it as `.impossible` |
| **Family context** (bonus) | Census household contains a known spouse/child, OR marriage record's spouse matches a known spouse profile. | `pass` / `softFail` / `skip` | `softFail` only — never decisive |

Name similarity uses the genealogy-specific scoring from Python (AU/A
swap=0.95, nicknames=0.85, containment=0.8) — NOT raw Levenshtein.

### 4.2 The roll-up

```
if anyGate.outcome == .impossible:           → .impossible (early return)
elif name.outcome == .fail:                  → .impossible
elif geo.outcome == .fail and mode != .all:  → .impossible
elif geo.outcome == .fail and mode == .all:  → .lead
elif zero fails AND zero softFails:          → .fact
elif zero fails AND ≥1 softFail:             → .lead
else:                                        → .lead
```

A record is a `.fact` only if every gate cleanly passes. Any softFail
(typically geography "unknown district" or family context "spouse not
present in household") drops it to `.lead`. Records become
`.impossible` when name fails outright, or when date is mathematically
incompatible (cannot have died in 1920 if married in 1925).

### 4.3 Key thresholds — pointer policy

**Policy:** the code owns the numbers, the spec owns the shape. Each
threshold below is a tunable design *decision*, but its *current
value* is whatever the cited code symbol returns. When the empirical
calibration drifts (as census age and BMD birth-year tolerances both
have — see in-code comments for the rationale), the code is updated;
the spec stays correct because it points at the code.

| Threshold (purpose) | Code symbol | Why it matters |
|---|---|---|
| Surname / given-name similarity floor | `RecordScorer` — both gates must clear independently | Below this, treat as different person, not transcription error |
| Census age tolerance | `ScoringRules.tolerance(for: .census)` | Self-reported, often rounded; 1841 deliberately rounded adults to nearest 5 |
| BMD birth-year tolerance | `ScoringRules.tolerance(for: .birth)` | Registration quarter ≠ actual birth date; Q4 birth + Q1 registration the next year |
| Marriage min age | `ScoringRules` constants | Younger = impossible (hard rule) |
| Marriage max age | `ScoringRules` constants | Older = impossible (hard rule) |
| Lifespan max | `ScoringRules.deathSanityCheck` | Age at death cap |
| Foreign-country token list | `RecordScorer.foreignCountryTokens` | Hard-fails geography gate in non-`.all` modes; UK-domestic genealogy only |

Three values are intentionally pinned in the spec (not the code)
because they are *contract-level decisions* rather than tunable
calibration: the §8 convergence ladder thresholds (≥3 lineages →
`.confirmed`, 2 lineages + trust ≥4 → `.probable`), the §9
identity-resolver minimum weight (0.25), and the §14.3.2
auto-approval minimum independent lineages (≥2). Changing any of
those is a doctrine change, not a tuning pass.

### 4.4 Recent corrections worth keeping in mind

- **Middle-name guard** (May 2026): five same-name Jennifer Holmes
  1947–49 births previously all passed because no middle-name
  comparison happened. Now `RecordScorer.middleNameMatches` rejects
  when subject has a middle name and record middle content disagrees.
  (T15.)
- **Birth-year window is a range, not a point** (T4): the date gate
  uses `[birthYearFrom, birthYearTo]` ± tolerance, not just
  `birthYearFrom`. Cluster verdict re-grades wide-window facts to
  `.lead`-equivalent when corroboration is thin.

---

## 5. The pipeline lifecycle

**Status: Built with drift.** The in-loop / post-loop split has
shifted from the original design: parent inference and marriage
enrichment moved to the post-loop phase via V2 §5.2 T12-parent
Phase 2. The step list below reflects what actually runs.

`ResearchPipeline.research(subject:config:)` is one async call that
returns a `ResearchResult`. Internally it runs **N iterations**
(mode-dependent maximum) followed by a single **post-loop** phase.

### 5.1 The iteration loop

For each iteration 1…`maxIterations`:

1. **Dispatch.** `SearchDispatcher.dispatch(subject:recordTypes:scope:mode:)`
   fans out to every applicable source and returns `[SourceRecord]`.
   The dispatcher honours the strictness ladder (§11) and
   scope-widening rules.
2. **Score.** Each raw record goes through `RecordScorer.classify` →
   `[ScoredRecord]`.
3. **Dedup.** Records already collected in prior iterations are
   filtered out before append. This catches the "same record
   re-fetched at every iteration" problem (T30) — historically,
   narrow scopes would silently double or triple count.
4. **Household extraction.** From census `.fact` records: pull
   `household` members and dedup by uppercase name against
   `state.householdMembers`.
5. **Discrepancy detection.** For each new `.fact` record, compare
   its key fields (birth year, death year) against existing subject
   data. Severity comes from
   `DiscrepancySeverityTable.severity(sourceTier:absDelta:convergence:)`
   — see §10.
6. **Subject refinement.** Confirmed facts feed back into the
   subject: a confirmed birth year tightens `birthYearFrom` /
   `birthYearTo`, a confirmed death year does the same. Census age +
   census year imply a birth year when none is known.
7. **Reasoning suggestion.** Between iterations only:
   `ResearchInterpreter.suggestNextSearch` may propose adding a
   record type to `state.activeRecordTypes`. The deterministic
   dispatch still decides what runs next.
8. **Stopping checks** (any one breaks):
    - confirmedFacts ≥ `config.maxFacts`
    - mode `.verify` AND at least one confirmed fact (verify stops
      as soon as anything corroborates)
    - dispatch returned zero records
    - **stable-point**: iteration >1 AND no new records since last
      iteration (catches the "narrowing search returns the same set
      forever" loop)

Parent inference and marriage enrichment used to run inside the
iteration loop (former steps 7–8); both moved to the post-loop phase
under V2 §5.2 T12-parent Phase 2. See §5.2 below.

### 5.2 The post-loop phase (one-shot)

After the iteration loop exits:

1. **Clustering.**
   `ClusteringEngine.cluster(records:sourceInfoMap:homeChapmanCode:)`
   runs the 5-step algorithm (§7). Marriage-enrichment records are
   filtered out of the cluster input — they describe the parents'
   marriage, not a candidate life of the subject, and surface as
   hypothesis evidence instead.
2. **Parent inference** (`runParentHypothesisFlow`). Generates
   `.parentInferred` hypotheses from birth records carrying MMN
   (`HypothesisEngine+ParentInferred`) and `.parentMarriage`
   hypotheses for the (mother, father) surname pairs
   (`HypothesisEngine+ParentMarriage`). The marriage-enrichment
   dispatch (groom-side + bride-side BMD queries) lives in the
   `.parentMarriage` grader. Reconciliation cross-references marriage
   evidence onto the parent hypotheses
   (`HypothesisEngine.reconcileParentMarriages`).
3. **Sibling discovery** (T17). `runSiblingHypothesisFlow` gates on
   subject identity resolved + both parents linked, generates a
   `.siblingExists` hypothesis, dispatches a focused FreeBMD query,
   grades. See §6.3 for the cross-district exception.
4. **T7 second pass.** If any hypothesis is `.inconclusive` and has a
   non-empty deficit query, the second pass dispatches the next
   ladder level, re-grades, re-reconciles (V2 §5.3).
5. **Result assembly.** A `ResearchResult` carries: `confirmedFacts`,
   `leads`, `allScoredRecords`, `clusters`, `discrepancies`,
   `householdMembers`, `searchHistory`, and `hypotheses` (the
   hypothesis framework superseded the legacy `proposedRelatives` and
   `proposedSiblings` fields; both have been deleted).

### 5.3 What state survives across iterations

`ResearchState` (see `ResearchState.swift`):

| Field | Persisted across iterations? | Notes |
|---|---|---|
| `scoredRecords` | Yes — appended (deduped) | Single source of truth; verdict partitions it |
| `proposedRelatives` | Yes — deduped + evidence accumulated | Stable IDs let re-runs upsert rather than duplicate |
| `discrepancies` | Yes — appended | No dedup; same discrepancy from two sources can appear twice |
| `householdMembers` | Yes — deduped by name | |
| `searchHistory` | Yes — appended | One entry per iteration |
| `subject` | Yes — refined each iteration | Date learning feeds back |
| `activeRecordTypes` | Yes | Reasoning model may add to this set between iterations |
| `marriageEnrichmentAttempted` | Yes (boolean) | One-shot guard |
| `enrichmentRecordIDs` | Yes — set of IDs | Filtered out of cluster input |
| `iteration` | Yes — current iteration number | Used by `searchHistory.searchKey` |

---

## 6. Inference engines

**Status: Built with drift.** Three engines exist as advertised, but
two architectural notes:

- The standalone `ParentInferenceEngine` type is now a test-only thin
  wrapper. Canonical parent-inference logic lives in
  `HypothesisEngine+ParentInferred.swift` (T12-parent Phase 2).
- Sibling discovery no longer requires same-district per record; see
  §6.3 for the cross-district exception (Helen Clare Cauldwell case).

The pipeline produces three kinds of inferred output beyond the raw
scored records: **parents**, **enriched parent given names**, and
**siblings**. Each runs as a pure function over the current
`ResearchState`.

### 6.1 Parent inference

**Canonical location:** `HypothesisEngine+ParentInferred.swift`. The
legacy standalone `ParentInferenceEngine` type still exists but is a
thin wrapper retained for tests only — the pipeline calls the
hypothesis-framework path.

**Input:** `state.scoredRecords` filtered for non-`.impossible`
verdicts (i.e. both `.fact` and `.lead`). The `mothersMaidenName`
field is a direct index transcription, so its reliability doesn't
depend on geography/family-context gates passing.

**Output:** `[ResearchHypothesis]` of `.parentInferred(gender,
surname)` kind — one mother (surname = MMN) and one father (surname =
subject's surname) per distinct MMN.

Algorithm (per record):

1. Filter to birth records with a non-empty `mothersMaidenName`.
2. Skip if record's source trust tier is below `.transcription`
   (community-only sources are too unreliable).
3. Compute parent birth window: `[subjectBirth − 45, subjectBirth − 18]`
   (parents 18–45 at child's birth).
4. Mother hypothesis: surname = MMN, gender = female, stable ID =
   `stableID(.parentOf(subjectID), .female, MMN)`.
5. Father hypothesis: surname = subject's surname, gender = male,
   stable ID likewise.
6. If a hypothesis with that stable ID already exists, append the new
   record to its `supportingEvidence`; do not create a duplicate.

The stable ID is the key invariant: re-running research must produce
the same hypothesis IDs so rejection state persists.

### 6.2 MarriageEnrichmentEngine

**Input:** the `(mother proposal, father proposal)` pairs that share
a `subjectID`, plus two FreeBMD marriage queries' results (groom-side
and bride-side).
**Output:** one of three outcomes:

| Outcome | Trigger | Effect |
|---|---|---|
| `.unique(fatherGiven, motherGiven, fatherEv, motherEv)` | Exactly one reference key `(year, quarter, district, vol, page)` matches between sides | Fill given names where present; either side may be nil (one-sided enrichment is a valid partial win) |
| `.ambiguous(candidates)` | ≥2 reference keys match | Show all candidates in UI; user picks during accept |
| `.none` | No reference key matches | Proposal stays surname-only |

The reference-tuple match is the join mechanism. The BMD index writes
each marriage twice (once under each party); matching by `(year,
quarter, district, vol, page)` reunites the pair.

Spouse-surname guard (T19): groom-side entries whose `spouseSurname`
≠ the expected bride surname are rejected outright, even though they
matched the source's filter. Closes an observed FreeBMD filter
leakage where `s_surname=Wheeldon` returned unrelated marriages.

### 6.3 SiblingInferenceEngine (T17)

**Input:** the subject's resolved birth record + a pool of candidate
birth records (focused FreeBMD queries — see exception below) + both
parent profile IDs + the snapshot.
**Output:** `[SiblingProposal]` — birth records matching the subject
on:

- Same surname
- Same mother's maiden name
- `|year − subject.birthYear| ≤ 20` (typical fertility span)
- Not the subject themselves
- Not already a known child of either parent in the snapshot

**Cross-district exception (audit pass 13).** Same-district was an
early requirement but was relaxed: real siblings are routinely
registered in adjacent districts when the family moves, when
boundaries change, or when a parish straddles two RDs. The deficit
query fans out across all districts in the subject's home Chapman
code (not just the subject's birth district); the engine then accepts
candidates from any district as long as the MMN matches. The Helen
Clare Cauldwell case (sister registered Derby, subject Belper, same
county) drove this change. MMN match carries the genealogical
weight; district was over-restrictive in practice.

The engine is otherwise strict by design. A confidence-of-result
mechanism doesn't exist; the contract is "if MMN + surname + window
all agree, this is a sibling."

### 6.4 Why parent inference accepts leads but sibling inference doesn't

The `mothersMaidenName` field is a direct transcription from the BMD
index — present regardless of whether geography or family-context
gates pass. So leads carry trustworthy MMN data even though their
geography didn't match. Sibling inference, by contrast, **depends on**
the subject's resolved district; if the subject isn't pinned via
`SubjectIdentityResolver`, the sibling engine returns `[]` (no key to
filter by).

---

## 7. ClusteringEngine — the 5-step algorithm

**Status: Built.**

Records become candidate lives via a five-step algorithm. Design
principle (`ClusteringEngine.swift:7`): **when in doubt, split**.
Over-splitting is recoverable (the UI shows merge candidates and lets
the user accept the merge). Over-merging writes wrong facts that are
hard to undo.

### 7.1 Step-by-step

1. **Seed.** Each distinct birth (by year OR district) seeds one
   cluster, lifespan `[birthYear, birthYear + 110]`. If there are no
   birth records, seed one cluster from the earliest record, lifespan
   `[earliest − 80, latest + 5]`.
2. **Assign.** For each unassigned record (chronological order),
   score against every existing cluster via
   ```
   score = 0.4 × dateCompatibility
         + 0.3 × locationConsistency
         + 0.3 × householdConfirmation
   ```
   Assign to the best-scoring cluster if `score ≥ 0.4`; otherwise
   create a new cluster.
3. **Split** (iterated until fixed point). A cluster is split when it
   contains any of:
   - ≥2 distinct birth records → keep oldest, split newer into a fresh cluster
   - ≥2 distinct death records → same
   - census-implied birth years differing by >5 years → split records above the midpoint
   - ≥2 distinct marriage spouses → peel one spouse group per iteration (so 4 spouses → 4 clusters)
4. **Merge candidates.** Identify clusters that **might** be the same
   person (one has only births, another only deaths, dates
   compatible, locations overlap). Set `mergeCandidate` pointers;
   **never auto-merge**.
5. (removed in Change 5) `scoreConfidence` — callers now derive
   `EvidenceConfidence` on demand via
   `LifeCluster.evidenceConfidence(sourceInfoMap:)`.

### 7.2 Assignment score components

| Component | Weight | Value table |
|---|---|---|
| Date compatibility | 0.4 | 1.0 inside lifespan; 0.5 within ±5 of either boundary; 0.0 otherwise |
| Location consistency | 0.3 | 1.0 same district; 0.7 same county; 0.3 same region; 0.0 non-local |
| Household confirmation | 0.3 | 1.0 census member is a known spouse/child by name; 0.5 surname match in family relation; 0.0 otherwise |

### 7.3 Why splitting matters

Real-world example: when a surname-only variant tier returned 80+
"Wheeldon" births across 50 years and several districts, the seed
step produced one cluster per distinct birth-year-or-district, and
the assignment step then refused to merge them across the 0.4
threshold. The result was many small candidate cards instead of one
mega-cluster with contradictory facts — the user picks the right one
rather than the algorithm guessing wrong.

---

## 8. ConvergenceEngine and source independence

**Status: Built.**

`ConvergenceEngine.score(records:sourceInfoMap:)` answers a single
question: how many **independent lineages** of evidence does the
cluster contain, and at what trust level?

### 8.1 SourceLineage

Two records share a lineage if they share a `SourceLineage` value —
defined per source. Two FreeBMD entries from different districts are
still **one** lineage. FreeBMD + FamilySearch are **two** lineages.
Three derivative sources that all transcribe the same official record
are still **three** lineages but are capped by directness (§8.3).

### 8.2 ConvergenceLevel mapping

```
≥3 lineages                                 → .confirmed
2 lineages AND summed trust score ≥4         → .probable
2 lineages, lower trust                      → .possible
1 lineage, ≥2 records                        → .possible
otherwise                                    → .singleSource
```

The summed trust score uses `SourceTrustTier.rawValue` per record
(community=1, transcription=2, primary=3 — approximate). Two
transcription-tier sources = score 4 = clears `.probable`.

### 8.3 Directness caps

Convergence can never exceed what the underlying directness supports:

- All records `derivative` → cap at `.possible`
- No `.primary` records → cap at `.probable`

This is asymmetric: convergence can upgrade severity (or quality) but
cannot downgrade. A single Wikipedia-citing-everything source can't
get promoted to `.confirmed` no matter how many lineages.

### 8.4 SourcingStrength (UI-facing)

`SourcingStrength(sourceCount, independentLineageCount, topTrustTier)`
— used by `LifeCluster.evidenceConfidence` and the three-axis
`ConfidenceBadgeView`. `isCrossReferenced` is true when
`independentLineageCount >= 2`.

---

## 9. Identity resolution

**Status: Built.**

Two collaborating pieces: a generator that proposes likely districts,
and a resolver that decides whether the subject's identity is pinned.

### 9.1 GeographicHypothesisGenerator

Walks the family graph and accumulates weight at each candidate
district from six signals, each year-decayed:

| Signal | Weight | Rationale |
|---|---|---|
| Subject's own birth location | 1.0 | Direct answer |
| Subject's own marriage location | 0.75 | Strong transitive |
| Children's birth locations | 0.55 | Parents at child's registration |
| Siblings' birth locations | 0.65 | Same parents → usually same district |
| Parents' marriage location | 0.50 | Weaker — marriage may predate residence |
| Spouse's birth location | 0.35 | Assortative mating; confounded |

Year decay: `decay(signalYear, eventYear) = 0.5 ^ (|Δt| / 25)`.
Half-life 25 years.

When a parish maps to multiple districts (boundary changes —
Wirksworth is in both Bakewell and Belper RDs at different periods),
the signal's weight is **split** across the districts: corroborating
signals from another source still elect the right one.

Output: `[GeographicHypothesis]` sorted by descending weight, weights
clamped to `[0, 1]`.

### 9.2 SubjectIdentityResolver

```
SubjectIdentityResolver.resolve(candidateBirthFacts:, hypotheses:) → SubjectIdentityResolution
```

Three outcomes:

- `.resolved(birthRecordID, districtName)` — exactly one candidate
  after applying the strongest hypothesis (weight ≥0.25); safe for
  downstream auto-promote.
- `.ambiguous(candidateIDs, reason)` — ≥2 candidates remain
  plausible; defer to human review.
- `.unresolved(reason)` — no candidates, or no usable geographic
  signal.

The 0.25 threshold is intentionally low: parish-to-district splits
divide weight, so a single signal at full weight (1.0) still clears
the gate after splits.

### 9.3 Why this matters

Resolved identity is the precondition for:

- **Auto-promote** (`AUTOMATION_AUTO_ACCEPT` automation path only —
  see §12)
- **Marriage enrichment** (when both parents aren't yet linked)
- **Sibling discovery** (always)

Closes the **Colin-Holmes failure** (May 2026): when there are
multiple same-name birth records and no district anchor on the
subject's profile, the older scorer treated them all as candidate
facts and downstream inference silently picked the first one. The
resolver now raises this case as `.ambiguous` so the pipeline defers
rather than guesses wrong.

---

## 10. Discrepancy detection

**Status: Built with drift.** The severity matrix and convergence
upgrade rule match the code, with one undocumented row drift at the
transcription tier's Δ=2 boundary (code returns `.refinement`; this
spec previously claimed `.none`). The §10.3 per-source tolerances
are aspirational — see the note at the bottom of this section.

When a `.fact` record's key field (birth year, death year) differs
from the existing tree value, the pipeline raises a
`ResearchDiscrepancy`. Severity comes from a deterministic table.

### 10.1 The severity table

`DiscrepancySeverityTable.severity(sourceTier:absDelta:convergence:)`
→ `(severity, reasoning)`. The boundaries below mirror what the code
returns today; if they drift, the code is authoritative — see the
pointer policy in §4.3.

Base severity by trust tier and delta (years):

| Tier | Δ = 0 | Δ = 1 | Δ = 2 | Δ = 3 | Δ ≥ 4 |
|---|---|---|---|---|---|
| **Primary** (CWGC, official) | `.none` | `.refinement` | `.refinement` | `.correction` | `.correction` |
| **Transcription** (FreeBMD, FreeCen, FreeREG) | `.none` | `.none` | `.refinement` | `.refinement` | `.conflict` |
| **Community** (FamilySearch, Find a Grave) | `.note` | `.note` | `.note` | `.conflict` | `.conflict` |

The Δ=2 boundary on the transcription tier is where the code's
behaviour split from earlier drafts of this spec — the table above
is canonical now.

### 10.2 Convergence can upgrade, never downgrade

```
.confirmed → max(base, .correction)
.probable  → max(base, .conflict)
.possible / .singleSource / .uncorroborated → base
```

A single FamilySearch hit at Δ=4 is a `.conflict`. The same finding
cross-referenced by `.confirmed` independent sources stays
`.conflict` (already ≥ the upgrade floor) — it doesn't reach
`.correction` until convergence promotes the cluster verdict to a
higher tier.

### 10.3 Per-source tolerances

Source characteristics drive the deltas:

| Source | Tolerance | Reason |
|---|---|---|
| FreeBMD birth | ±2 | Registration quarter ≠ actual birth date |
| FreeCen census | ±3 | Self-reported; 1841 rounded to nearest 5 |
| FreeBMD death | ±1 | Informant usually knows |
| Find a Grave | ±2 | Volunteer-transcribed from weathered headstones |
| CWGC | ±0 | Official military record |

> **Aspirational, not enforced.** The table above documents the
> intent. In the code today, the severity table uses *tier*
> (primary / transcription / community), not individual source
> identifier, so a FreeBMD birth record and a FreeCen census record
> share the same tier-based delta thresholds. Per-source tolerance
> enforcement would require either widening the severity table's key
> or pre-narrowing the delta at each source plugin. Tracked as a
> future task; not blocking.

---

## 11. SearchDispatcher

**Status: Built.**

`SearchDispatcher.dispatch(subject:recordTypes:scope:mode:)` is the
gateway to every source. Sources are dumb pipes; the dispatcher
decides what to ask.

### 11.1 Strictness ladder by mode

| Mode | Ladder | Semantics |
|---|---|---|
| `.verify` | `[.strict]` | One tight pass. Stop early on first fact. |
| `.extend` | `[.strict, .loose]` | Strict first; broaden if empty. |
| `.discover` | `[.loose, .variant]` | Skip strict; start at loose. |
| `.all` | `[.strict, .loose, .variant]` | Run every tier; dedupe afterward. |

Empty-then-broaden: within `.extend` and `.discover`, stop at the
first tier with non-empty results. `.all` always runs the full ladder.

### 11.2 Storm guards

The variant tier expands to all surname-variants × every district ×
every record type. Without bounds, surname-only queries (e.g.
"Cauldwell" with no given name) detonate into thousands of unrelated
records. Two guards:

1. **Variant-tier storm guard** (T38, `SearchDispatcher.swift:189–199`):
   skip variant tier when **all** queries are surname-only AND the
   year window spans >5 years. Narrow probes (known 1880 birth) stay
   bounded and useful.
2. **Phonetic-disable for surname-only** (T37): surname-only `.loose`
   queries downgrade to `.strict` so the source doesn't enable
   Phonetic (which has the same explosion shape).

### 11.3 Scope widening

Scope is a separate axis from strictness:

| Scope | What it widens to |
|---|---|
| `.parish` | (FreeBMD: no parish endpoint, returns no queries) |
| `.district` | Subject's home district only |
| `.county` | All districts in subject's Chapman code (DBY today) |
| `.adjacent` | County + neighbouring Chapman codes |
| `.national` | Full FreeBMD district catalogue, year-filtered to plausible coverage |

FreeBMD is district-coded; FreeCen and FreeREG are Chapman-coded;
CWGC is military-only with eligible war years; FindAGrave / Probate /
Wirksworth take a single query without scope branching.

### 11.4 ResearchFocus axis — record-type narrowing

A third axis orthogonal to mode (depth) and scope (geography):
**focus** selects which record types the pipeline dispatches.
Optional — when nil, the pipeline runs with the full
`activeRecordTypes` set (today: `birth`, `death`, `marriage`,
`census`, `burial`, `probate`, `parish`, `pedigree`). When set,
`ResearchState.init(subject:)` narrows `activeRecordTypes` to
`subject.focus.recordTypes` instead.

Why this exists: the profile view's "Missing facts" section
(`SharedProfileLayout.missingFactsSection`) wires each gap to a
"Research" button. Today every button fires the same full pipeline.
The user's mental model is "research the thing that's missing,"
not "run the full pipeline and hope it picks up the thing that's
missing." Focus closes that gap.

| Focus | Record types | Typical gap that triggers it |
|---|---|---|
| `.parents` | birth, census, baptism | "No parents" |
| `.siblings` | birth | (UI surfaces from profile, not from gap) |
| `.marriages` | marriage | "No marriages" / female maiden plumbing |
| `.death` | death, burial, probate, military | "Missing deathDate" / "Missing deathLocation" |
| `.birth` | birth, baptism | "Missing birthDate" / "Missing birthLocation" |
| `.children` | marriage, census | (UI surfaces from profile) |
| `.occupation` | census, probate | (UI surfaces from profile) |

`.parents` and `.children` are *macros* — they include multiple
record types because the genealogical task isn't single-source.
The dispatcher itself sees a `Set<RecordType>` either way; the
macro lives in `ResearchFocus.recordTypes`.

**Default mode override when focus is set.** The smart-default
mode picker in `ResearchConfigSheet` adapts to subject shape
(ghost → Discover, near-complete → Verify). A focused run breaks
that heuristic: "Research siblings" on a near-complete profile
still wants Discover (you don't have the siblings to verify
against). When focus is non-nil, default mode is `.discover`;
the user can still override via the sheet's mode picker.

**Out of scope.** Focus does not change the strictness ladder or
the scope axis — those stay orthogonal. Focus also does not yet
narrow post-processing (cluster review, lead generation, MMN
sibling discovery still fire if their inputs are present); a
later refinement can add focus-aware gating of secondary dispatch
paths (§11.5, §11.6) when empirical runs show they over-fire.

### 11.5 Marriage enrichment's secondary dispatch

Marriage enrichment runs its own focused queries — not via the
strictness ladder, but a single direct call per district (groom-side
and bride-side) targeting the same district set as the main
pipeline's scope. The gating policy (T29) prevents enrichment from
triggering one query per candidate MMN: it only runs pairs whose
surnames match either the linked parents OR the resolved-subject's
birth record.

### 11.6 Sibling discovery's tertiary dispatch

`findSiblings` issues one query: surname-only, the subject's
resolved birth district, year window `subject.birthYear ± 20`. No
fan-out, no strictness ladder. Gated on both parents linked +
identity resolved.

---

## 12. The cluster verdict and auto-promote

**Status: Built.** The `AUTOMATION_AUTO_ACCEPT` flag is debug-only;
release builds have no user-facing auto-promote from clusters. The
orthogonal pending-fact auto-approval at §14 is the only auto-
commit path in release.

### 12.1 LifeCluster.hypothesisVerdict

```
contradictory facts (>1 birth year OR >1 death year)? → .contradicted
≥2 lineages AND ≥1 fact?                              → .stronglySupported
≥2 lineages, any fact count                            → .supported
1 lineage AND ≥2 facts?                                → .supported
≥1 fact otherwise                                      → .weak
default                                                → .weak
```

This is the cluster-level grading that decides whether the pipeline
considers a candidate strong enough to auto-promote.

### 12.2 Auto-promote gate

`AUTOMATION_AUTO_ACCEPT` is a build flag that is **off in release**.
When defined (test automation only):

```
RunRequestWatcher → request.autoAccept == "confirmed"
  → autoAcceptStronglySupportedProposals(
      clusters where hypothesisVerdict == .stronglySupported,
      identity resolved (precondition T14)
    )
```

Today there is **no user-facing auto-promote** in the research
pipeline itself. Strongly-supported clusters surface in the UI with
the "Apply" button enabled, but the user clicks it; nothing writes
implicitly. The flag exists so end-to-end tests can drive a run from
request → application without UI interaction.

(See §14 below for the orthogonal pending-fact auto-approval feature
exposed through the MCP server — that operates on `pending_facts`
rows, not on cluster proposals.)

### 12.3 The cluster Apply button

Per-cluster Apply (cluster-level decision):

- `.confirmed` match quality → "Apply" button shown
- `.possible` match quality + a marriage record with `familyContext`
  gate passing (known spouse) → "Apply" button shown (T36 case)
- otherwise → "Save as lead" or "Discard"

Per-record decisions (T35) override the cluster gate per record:
user-accepted records always apply, user-discarded records always
skip, regardless of the gate predicate.

---

## 13. Evidence Firewall and the Apply contract

**Status: Built.**

### 13.1 The firewall

Anything outside the Swift process (MCP tools, MLX-extracted facts,
future external integrations) writes to **two tables only**:
`pending_facts` and `leads`. They never touch `profiles`,
`relationships`, or `life_events` directly. Promotion from
`pending_facts` to actual fields goes through scorer → hallucination
checks → human review.

Inside the Swift process, the same discipline holds: LLM output
(currently `ResearchInterpreter.suggestNextSearch` and
`compareCandidates`) does not write anything. Suggestions modify
`state.activeRecordTypes`; prose lands in the cluster review sheet as
advisory text.

### 13.2 The Apply contract

When the user clicks Apply on a cluster:

1. Iterate the cluster's records.
2. For each, determine effective decision:
   - user-accepted (per-record) → force apply
   - user-discarded (per-record) → force skip
   - else: apply iff `wouldApply(record)` (verdict `.fact` OR
     known-spouse marriage)
3. **Overwrite-safe**: every write checks "is the target field
   currently nil?" — Profile fields, marriage dates on relationships,
   birth/death locations. Existing data is **never** overwritten.
4. Records that apply add a citation; records that skip stay in the
   cluster as evidence history but don't write to fields.

The "fill nil only" rule is load-bearing. It's why the user can
re-run research as many times as they like without losing data:
every confirmed fact is additive.

---

## 14. MCP-driven auto-approval of pending facts

**Status: In-flight, gated off by default (2026-05-22).** Split into
MVP (shipped 2026-05-21, commit `960dfeb`) and Phase 2 (planned). On
review the MVP was judged to puncture the Evidence Firewall before
the defensive layer (§14.B.1) was built — the MVP gate validates
rule compliance, not source-value fidelity, so an AI that asserts a
value its source URL doesn't actually contain would pass every
criterion. The write path is therefore disabled at runtime
(`approve_pending_fact` refuses with `auto_approval_gate_disabled`)
until §14.B.1 ships. Dev override: set `ANCESTOR_MCP_AUTO_APPROVE=1`
in the MCP server's environment. `inspect_approval_decision`
(dry-run, read-only) remains enabled and is the right tool for
exercising gate logic without committing.

§14.A describes what runs today. §14.B describes the planned Phase 2
work that the spec previously described as part of the same feature
— including the reversibility contract, the bulk approval tool,
transaction-kind integration, and the defensive hallucination
re-checks. None of §14.B is shipped.

§13 establishes the Evidence Firewall: external proposals (MCP,
MLX-extracted, future integrations) write to `pending_facts` and
`leads` only, and promotion to a profile field requires human
review. This section narrows that human-review requirement for the
subset of pending facts where the deterministic rules' verdict is
**unambiguous**.

# §14.A MCP auto-approval — MVP (shipped)

### 14.1 Why this exists

The scoring system has matured to the point where, for many incoming
facts, the human review step is a rubber stamp. After an overnight
research run, the user faces a backlog of (say) 47 pending facts of
which maybe 35 are obvious confirms of what the structured pipeline
already established with multiple independent sources. Asking the
user to click "Accept" 35 times costs attention without adding
judgement. This section defines the conditions under which a fact
can be committed **by the rules acting through MCP**, leaving the
user to focus on the 12 facts that genuinely need a human eye.

### 14.2 Doctrine — the firewall narrowed, not removed

The deterministic-sandwich principle (§3.3) has been:

> AI proposes. Rules decide.

Extended here:

> AI proposes. Rules decide. **For unambiguous decisions, rules
> commit; for ambiguous ones, rules escalate to human review.**

The firewall is unchanged in shape — AI still does not write to
profiles directly. The MCP tool that performs auto-approval is not
AI deciding to commit; it is the rules acting on the rules' own
verdict, exposed through MCP so the harness can drive it.

**Hard principles:**

1. **Rules' authority extends to commit on unambiguous decisions
   only.** "Unambiguous" is defined precisely in §14.3; ambiguous
   facts stay in `pending_facts` for human review exactly as today.
2. **Every auto-approval is reversible, visible, and audit-traceable.**
   The user must be able to see what was committed without their
   keystroke and undo any of it without consequence.
3. **The user is supervisor, not gatekeeper.** They no longer touch
   every fact, but they retain final authority — they can disable
   auto-approval, narrow its scope, undo decisions, and investigate
   the rule trail behind any committed fact.
4. **Geography independence preserved.** The auto-approval gate
   derives its decisions from convergence + trust-tier + dispute
   criteria, never from hard-coded region knowledge.
5. **Conservative by construction.** Where the criteria are
   uncertain, default to human review. False auto-approvals are the
   failure mode to avoid; missed auto-approvals are merely throughput
   loss.
6. **MCP-side criteria are a subset of in-app review.** The MCP gate
   is simpler than the full app's review surface. Anything the MCP
   tool refuses can still be human-reviewed; nothing the MCP tool
   approves bypasses any check the human-review path would have run.

### 14.3 The auto-approval gate

A pending fact qualifies for auto-approval **only if all** of the
following hold. Failure of any single condition routes the fact to
normal human review.

**14.3.1 Source trust.** The fact's source (from
`pending_facts.source_url`, classified via `SourceTierRegistry`) must
be of tier **`primary`** or **`secondary`**. Tertiary, derivative,
and community-curated sources are *insufficient* for auto-approval.

**14.3.2 Convergence with the existing tree.** The fact must reach
**at least `.confirmed`** convergence (§8.2) when its proposed value
is combined with whatever the profile already has for the same
field. If the profile already has the same value from an independent
source in `field_sources`, the pending fact is corroborating. If
the profile has no existing value, the pending fact alone must reach
`.confirmed` from its sources to qualify. The `ConvergenceEngine`
computes this; the MCP-side evaluator re-implements the same lineage
/ trust / directness math (deliberately conservative) since the
`FieldResearcherMCP` package can't import the app's research module
today.

**14.3.3 No dispute would be created.** The fact's proposed value
must not contradict an existing value on the profile. If the profile
has `birthDate = 1820` and the pending fact proposes `birthDate =
1822`, auto-approval is **blocked** — committing would create (or
extend) a `FieldDispute`, which is exactly the kind of judgement
call a human must make.

Detection: query `field_sources` for the same `(entity_id, field)`
and check whether any existing `raw` value is meaningfully different
from the proposed value. The comparator is field-aware:

- **Dates** — different to the `GenealogicalDate.parsePreview`-
  canonical level (1820 ≠ 1822, but "21 Dec 1820" == "December 21,
  1820").
- **Locations** — different at the canonical-place-code level when
  available, otherwise fall back to trimmed string comparison.
- **Strings (occupation, etc.)** — case-insensitive whitespace-
  trimmed comparison.

A value that differs from the existing one but is *less specific*
(e.g. "Derbyshire" when existing is "Cromford, Derbyshire") is
treated as **conflicting** for auto-approval purposes — the user
should decide whether to record the broader value as an alternative
or upgrade the existing one.

**14.3.4 Field is in the auto-approvable set.** Some fields are
higher-stakes than others. Auto-approval applies only to a defined
subset:

- **Auto-approvable when the rest of the gate passes:** `birthDate`,
  `birthLocation`, `deathDate`, `deathLocation`, `marriageDate`,
  `marriageLocation`, `occupation` (as a life-event detail),
  `address`.
- **Never auto-approved** (always human-reviewed regardless of
  evidence): `firstName`, `middleName`, `lastName`,
  `marriedSurname`, `nickName`, `mothersMaidenName` — name
  corrections shape identity; `gender` — identity-shaping; `bio` —
  narrative, not a fact (see `PROSE_CORPUS_SPEC.md`).

The set is small and conservative on purpose. Expanding it is an
explicit design decision per field, not a quiet default.

**14.3.5 Hallucination checks have passed.** The Evidence Firewall's
existing checks (URL verification, source-tier plausibility,
hallucination rules) must already have passed before the pending
fact reaches the auto-approval gate. (Defensive re-run of those
checks at the MCP gate is Phase 2 work — see §14.B.)

### 14.4 MCP tool surface (MVP — two shipped tools)

**`approve_pending_fact(pending_fact_id) → result`.** Single-fact
primitive. Loads the pending fact, runs the gate evaluator, and
either commits or refuses with reason.

```jsonc
// Request
{ "pending_fact_id": "abc123" }

// Success
{
  "status": "approved",
  "profile_id": "@I1234@",
  "field": "birthDate",
  "value": "1820",
  "criteria_met": {
    "trustTier": "primary",
    "convergence": "confirmed",
    "independentSourceCount": 3,
    "wouldCreateDispute": false,
    "fieldAutoApprovable": true
  },
  "committed_at": "2026-05-21T14:32:00Z"
}

// Refusal
{
  "status": "refused",
  "reason": "convergence_insufficient",
  "detail": "Only 1 independent source lineage; need ≥ 2 for primary or ≥ 3 for non-primary trust tiers.",
  "still_pending": true
}
```

Refusal reasons (enumerated for testability):
`trust_tier_insufficient`, `convergence_insufficient`,
`would_create_dispute`, `field_not_auto_approvable`,
`hallucination_check_failed`, `pending_fact_not_found`,
`pending_fact_already_processed`.

**`inspect_approval_decision(pending_fact_id) → decision`.** Dry-run.
Same evaluation as `approve_pending_fact` but commits nothing.
Returns the verdict the rules would render. Used by Claude Code to
preview before committing, and as the basis for "what is queued for
auto-approval right now" diagnostics.

(A third tool, `auto_approve_qualifying`, is planned for Phase 2;
see §14.B.)

### 14.5 DB schema additions (v28, shipped)

Migration v28 adds three nullable columns to `pending_facts`:

```sql
ALTER TABLE pending_facts ADD COLUMN approval_method TEXT;       -- 'user' | 'rules'
ALTER TABLE pending_facts ADD COLUMN approval_rule_ids TEXT;     -- JSON array of gate criteria that passed
ALTER TABLE pending_facts ADD COLUMN approved_at DATETIME;       -- distinct from reviewed_at
```

- `approval_method` is `NULL` while the row is pending; set to
  `'user'` or `'rules'` on acceptance. `'rules'` implies committed
  via this section's MCP tool.
- `approval_rule_ids` records *which* gate criteria the rules
  evaluated to true at commit time — supports retrospective audit.
- `approved_at` is distinct from `reviewed_at` because the latter
  exists today and is documented as "user review timestamp".

Today's audit trail therefore lives entirely on the `pending_facts`
row. The richer transaction-row audit (§14.B) is Phase 2.

### 14.6 What ships in MVP

1. Migration v28 (the three pending_facts columns above).
2. MCP evaluator in the FieldResearcherMCP package implementing the
   gate (trust tier check, convergence count, dispute detection,
   field-set check).
3. MCP tools `approve_pending_fact` and `inspect_approval_decision`.
4. 39 unit tests over the pure helpers (year regex, value
   comparison, lineage parsing, URL host, auto-approvable field
   set membership).
5. **Runtime gate (added 2026-05-22):** `approve_pending_fact`
   checks the `ANCESTOR_MCP_AUTO_APPROVE` env var on every call and
   refuses with `auto_approval_gate_disabled` unless it is set to
   `1`/`true`. Default is unset, so the shipped binary's write path
   is off out of the box. Lifting this gate is contingent on §14.B.1
   landing; the gate is a single-line change to flip the default
   when that work is done.

# §14.B MCP auto-approval — Phase 2 (planned)

**Status: Paper-only.** Everything in this Part B is design, not
shipped code. The MVP's audit lives on `pending_facts` columns;
reversibility is currently *not* wired through the transactions
table even though earlier drafts of this spec implied it was.

### 14.B.1 Defensive hallucination re-run

The MCP tool should re-run the Evidence Firewall's checks (URL
verification, source-tier plausibility, hallucination rules) at the
gate, not assume they passed earlier in the pipeline. Failure of any
treated identically to gate failure (no auto-approval; human review
path unchanged).

### 14.B.2 `auto_approve_qualifying` bulk tool

```text
auto_approve_qualifying(profile_id?, dry_run?) → batch_result
```

Bulk operation. Iterates pending facts scoped to a profile (or all
if omitted), runs the gate on each, returns the list of committed +
refused + reason. When `dry_run: true`, returns what *would* commit
without writing. Useful for clearing a backlog in one harness
invocation. Until this ships, users call `approve_pending_fact` per
row.

### 14.B.3 Transaction kinds and commit-path integration

Add two new cases to `TransactionKind` (in `Models/Transaction.swift`):
`autoApproveFact` and `userAcceptPendingFact`. Rewire the commit
paths so:

- The MCP auto-approval commit creates a `transactions` row of kind
  `autoApproveFact`, plus a `field_changes` row representing the
  profile-column write, plus a `field_sources` row whose
  `created_by_transaction_id` points at it.
- The existing UI-driven pending-fact accept path (currently
  transaction-less) creates a symmetric `userAcceptPendingFact`
  transaction.

This makes "what auto-committed vs. what the user committed" a join
on `transactions.kind` rather than a column on `pending_facts`. More
importantly, it routes both paths through the existing transactional
undo machinery.

### 14.B.4 Reversibility (formal contract — currently not honoured)

Once §14.B.3 lands, an auto-approved fact is reversible exactly as a
user-accepted fact would be:

1. The acceptance is recorded as a `transactions` row of kind
   `autoApproveFact` linked to the resulting `field_sources` row(s)
   and `field_changes` row(s).
2. Undo replays the transaction backward (per the existing
   `undo_strategy` field): the field-source row is removed, the
   profile column reverts to its prior value, and the original
   `pending_facts` row returns to `review_status = 'pending'` for
   the user's attention.

**Current state (MVP, not Phase 2):** there is no transaction row,
so reversibility through the existing undo machinery does not exist
for rule-committed facts. The `pending_facts.approval_method`
column records the decision but doesn't let undo replay backwards.
This is the most important Phase 2 gap to close.

### 14.B.5 App-side audit surfaces

The user should be able to answer "what did the rules commit on my
behalf, and why?" without spelunking SQL.

- **Pending facts review screen** gains a secondary tab or filter
  "Auto-approved" listing facts the rules committed since the user
  last opened the app, with the rule trail visible per row.
- **Inspector card source badges** gain a subtle "rules" decoration
  on field-source rows whose creating transaction is of kind
  `autoApproveFact`.
- **Undo affordance** — each auto-approved fact reverts with one
  action via the §14.B.3/.B.4 machinery.
- A read endpoint `list_recent_auto_approvals(since?)` lets the
  harness summarise activity for the user.

### 14.B.6 Other Phase 2 work

- DB integration tests for the evaluator + commit path (MVP tests
  cover pure helpers only).
- Harness scripts / Claude Code commands that drive the MCP tools
  with sensible defaults.
- A user-toggleable preference for *whether* auto-approval is
  enabled at all (off by default until trust is earned in real use).
  **Gate: this preference depends on §14.B.3 transaction kinds being
  in place** so that "auto-approved" facts are reversible through the
  same audit surface as any other write. Until §14.B.3 lands,
  auto-approval is restricted to the harness/MCP surface (developer
  use); the user-facing toggle is not exposed.

### 14.B.7 Explicitly out of scope (both MVP and Phase 2)

- Auto-approving relationships, life events, or attachments — these
  carry more structural weight than scalar field values.
- Auto-rejecting at the other end of the confidence spectrum
  (low-confidence facts auto-discarded). Failing the gate routes to
  human review, never to rejection.
- Background daemons / scheduled auto-approval runs — no app-side
  timer or background task. Auto-approval is invoked explicitly via
  MCP, by the harness, when the user wants to drain their backlog.
- AI judgement about *whether* a pending fact qualifies for
  auto-approval. The decision is pure rule application; no LLM is
  asked.

---

## 15. Persistence model

**Status: Built.**

What ends up on disk per project (`*.sqlite`):

| Table | What | Pipeline write site |
|---|---|---|
| `profiles` | Subject identity, name, dates, locations | Apply (overwrite-safe) |
| `relationships` | Parent / spouse edges | Accept proposed-relative; accept sibling |
| `field_sources` | Per-field provenance | Every write |
| `field_changes` | Audit trail of mutations | Every write |
| `evidence_records` / `scored_records` (v4) | Persisted ScoredRecord with user status (savedAsLead / etc) | Apply, Save-as-lead, override-rejection |
| `research_discrepancies` (v4) | Persisted ResearchDiscrepancy | After each iteration |
| `pending_facts` (v4 + v28) | Outside-the-firewall candidate facts | Not pipeline; MCP / external |
| `leads` (v3) | Saved-as-lead candidates with full subject snapshot | Save-as-lead actions |
| `research_runs` (v2) | Run record per pipeline call | Pipeline entry / exit |
| `record_rejections` (v2) | Stable IDs of dismissed proposals / records | Reject proposed-relative; reject sibling |
| `negative_searches` (v2) | "Searched X, found nothing" | After each dispatcher pass |
| `hypotheses` (v7) | **Workbench** tentative claims (user-authored) | Workbench UI; not pipeline-generated |
| `research_hypotheses` (v26) | Pipeline-generated hypotheses (T11/T12) | Hypothesis engine — see Part II §4 |
| `focus_sets` / `open_questions` / `workbench_notes` (v7) | Workbench surfaces | Workbench UI |

The transient/persistent split (post-T11/T12):

- `ResearchResult.clusters` — **transient**, recomputed each run from
  `evidence_records`
- `ResearchResult.householdMembers` — **transient**, recomputed
- `ResearchResult.hypotheses` — **persistent** via `research_hypotheses`
  (v26). T11/T12-emitted hypotheses survive between runs; the
  hypothesis engine reads existing rows on entry and writes verdicts
  back. This is the one ephemeral-looking `ResearchResult` field that
  is actually backed by disk.
- `ResearchState` itself — in-memory only; nothing here persists
- Proposed-relative and proposed-sibling collections from the
  pre-T11/T12 design are gone — those code paths have been replaced
  by the hypothesis engine. Rejection state persists per stable record
  ID (`record_rejections`); accept paths create real `relationships`
  rows.

The deterministic re-runnability is the key invariant: same project +
same code = same output. Random IDs (`UUID()`) appear only for
*accepted* new profiles/relationships, not for ephemeral pipeline
output.

---

## 16. What the pipeline does NOT do today (the negative space)

**Status: Inventory (current). Tracks the design gaps Part II
proposes to close.**

Important inventory for Part II to push against:

1. **Cross-profile dedup.** Each `research(subject:)` call is
   independent. Researching mother after researching self refetches
   the shared marriage record and treats it as a fresh hit instead of
   recognising it. `ConvergenceEngine` operates per-cluster, never
   across clusters that span profiles.
   (`archive/LLM_RESEARCH_OPTIONS.md` G1.)
2. **Stall-aware planning.** When the dispatcher returns empty at
   every tier, the pipeline gives up. There is no mechanism that
   says "try a different angle" — e.g. probe an adjacent district,
   try the spouse's surname for a marriage record, etc. (G2.)
3. **Adaptive strictness escalation.** The strictness ladder is
   per-mode-static. `.verify` is always `[.strict]`. Empty-results
   don't promote `.verify` to `.extend` automatically. (G3.)
4. **Cross-cluster contradiction resolution.** When clustering
   produces two clusters with different birth years, the pipeline
   labels them both `.contradicted` but doesn't ask which is more
   plausible given the rest of the tree. (G5.)
5. **Family-graph plausibility for solo candidates.** A FreeBMD lead
   with right name + right year + right district passes scoring
   without checking "is this birth year inside the known parents'
   fertility window?". (G6.)
6. **Subtle merge detection.** `DiffEngine` catches near-exact
   duplicates. `John Caudwell Ashbourne 1845` ≈ `Jon Cauldwell
   Wirksworth 1845` slips through. (G7.)
7. **Evaluation harness.** No way today to measure "did this change
   improve coverage?" against a held-out corpus. Every improvement is
   "ship and hope."
8. **Persisted research hypotheses driving second passes.**
   ~~Each `findSiblings`, each `GeographicHypothesisGenerator` call,
   each `SubjectIdentityResolver` resolution is recomputed from
   scratch.~~ **[✓ closed by T11/T12, 2026-05.]** The v26
   `research_hypotheses` table is now the source of truth; T11
   wired persistence, T12-sibling and T12-parent dispatch reads
   prior verdicts before re-emitting work.
9. **Hypothesis-guided second pass.**
   ~~No mechanism re-runs the pipeline with focused queries derived
   from the *result* of the first pass.~~ **[✓ closed by T7,
   2026-05.]** The sibling-deficit query path (commit `de4cb61` +
   later MMN-filter and full-county fan-out work in `3902d59`,
   `8879fba`) re-runs the pipeline with focused queries derived from
   the first-pass result.
10. **MLX as planner / disambiguator.** The model only suggests
    record types between iterations and writes prose for the user. It
    doesn't propose hypotheses, doesn't grade, doesn't propose
    specific next searches. (T8/T9 target.)

This is the surface against which Part II proposes.

---

## 17. Source plugins — what's wired today

**Status: Built.**

| Source | Module | Trust tier | Scope axis | Strictness response |
|---|---|---|---|---|
| FreeBMD | `Services/Sources/FreeBMD/` | Transcription | District-coded (national catalogue) | Phonetic flip; variant fan-out |
| FreeCen | `Services/Sources/FreeCen/` | Transcription | Chapman-coded | Fuzzy flag flip; variant fan-out |
| FreeREG | `Services/Sources/FreeREG/` | Transcription | Chapman-coded; parish unimplemented | Fuzzy flag flip |
| CWGC | `Services/Sources/CWGC/` | Primary | Military-only (males), war years | `Tab=exact` for strict; off for loose |
| FindAGrave | `Services/Sources/FindAGrave/` | Community | Single query | n/a |
| Probate | `Services/Sources/Probate/` | Primary | Single query | Strict-only |
| Wirksworth | `Services/Sources/Wirksworth/` | Community / locale-specific | Single query | Strict-only |
| FamilySearch | `Services/Sources/FamilySearch/` | Community-to-transcription, mixed | Per-collection | See FAMILYSEARCH_SOURCE_SPEC |

Each source returns `[SourceRecord]`. The scorer normalises across
them via the `SourceRecord` enum's per-case fields. No source mutates
pipeline state directly.

**Adjacent subsystem:** none of the eight sources captures image
payloads (headstones, certificates, microfilm waypoints) that arrive
in their HTTP responses. See `SOURCE_MEDIA_SPEC.md` for the
source-surfaced media subsystem (paper-only, not yet started).

---

## 18. Product-level design requirements

**Status: Built.** All subsections describe shipped mechanics. The
prior `useLLM` claim per `ResearchConfig` mode (in the 2026-04-25
draft) was removed during the 2026-05-22 unification; the actual
struct carries only `maxIterations`, `maxFacts`, `mode`, `scope`.

Folded in from the 2026-04-25 design draft. These are the
user-facing problems the pipeline solves and the principles that
shape its outputs. Where the language describes future behaviour, see
Part II for the current roadmap.

### 18.1 The real problem: plausible wrong matches

The 4-gate scorer rejects impossible records. But the dangerous
records are plausible ones for the wrong person. 47 Thomas Lands
born in Derbyshire 1830–1840 all pass the gates. Presenting 30
"facts" for the user to sort through is not research assistance —
it's data dumping.

**The solution is cluster-based presentation, not record-by-record
review.**

### 18.2 Life clustering

Before presenting results to the user, the pipeline groups records
that appear to describe the same person's life (§7). The grouping is
**when in doubt, split**: over-splitting is recoverable (the UI shows
merge candidates and lets the user accept the merge); over-merging
writes wrong facts that are hard to undo.

**Confidence model:** the single-tier `ClusterConfidence` enum
described in earlier drafts was retired. The replacement is a
three-axis model — **match quality**, **sourcing strength**,
**inference depth** — derived on demand from a cluster's records
rather than stored as a single combined tier. See §8.4 and
`LifeCluster.evidenceConfidence(sourceInfoMap:)` for the canonical
definitions.

**User action:** Accept a cluster as "this is my Thomas Land" → all
records in the cluster become facts. Reject → all become impossible
for this profile. "Not sure" → records become leads.

### 18.3 Three research modes

A generic "Research" button doesn't communicate what the user should
expect. Three modes with different expectations:

| Mode | Goal | Precision/Recall | Stops when | Success looks like |
|------|------|-------------------|------------|-------------------|
| **Verify** | Confirm what's already in the tree | High precision, low recall | All known facts corroborated or contradicted | "3 facts confirmed, 1 discrepancy found" |
| **Extend** | Find missing facts (death date, marriage) | Medium | Missing fields filled or exhausted | "Found death date, found marriage record" |
| **Discover** | Find this person from scratch (ghost node) | Low precision, high recall | Candidate clusters identified | "Found 3 candidate matches, review needed" |
| **All** | Run verify → extend → discover in sequence on the same subject | Medium overall | Each phase's stop condition fires in turn | Combined output across all three phases |

`.all` is a shipped composite mode in `ResearchMode` that the whole-tree
runner uses to walk a subject through all three sub-modes back-to-back.
It is not a distinct strategy; it inherits each phase's behaviour and
output.

**A verify run that finds nothing is a success** — "we couldn't
disprove your data." **A discover run that finds nothing is a
failure** that needs reporting.

> **Note:** Part II §5.10 proposes collapsing these three modes into
> a single Research button with a four-level auto-escalation ladder
> (`StopPolicy.firstFact` / `.satisfied` / `.exhaustive`). The legacy
> mode names stay until that lands.

### 18.4 Evidence directness

Source independence is necessary but not sufficient. The convergence
engine needs a second axis — evidence directness:

| Source | Directness | Rationale |
|--------|-----------|-----------|
| CWGC | primary | Official military records |
| FreeBMD | directTranscription | Transcribed from GRO index pages |
| FreeCen | directTranscription | Transcribed from census enumeration books |
| FreeREG | directTranscription | Transcribed from parish registers |
| Find a Grave | derivative | Volunteer-contributed, often from secondary sources |
| FamilySearch | derivative | Mix of direct and user-submitted; default to derivative |
| Wirksworth | derivative | Compiled from various primary sources |
| Probate | primary | Government records |

Three derivative sources agreeing is weaker than one direct
transcription. The convergence engine incorporates this via the
directness caps in §8.3.

### 18.5 Discrepancy threshold justification

The severity table's thresholds (§10) are not arbitrary constants;
each is named and justified:

| Source type | Tolerance | Justification |
|------------|-----------|---------------|
| FreeBMD birth ±2 years | Registration quarter vs actual birth date. A December birth registered in January appears as the following year. |
| FreeCen census age ±3 years | Self-reported by household head, often rounded. Victorian adults frequently misstated age. 1841 census deliberately rounded adults to nearest 5. |
| FreeBMD death age ±1 year | Age at death recorded by informant (usually family). More reliable than census age. |
| Find a Grave dates ±2 years | Volunteer-transcribed from headstones which may be weathered. Sometimes from obituaries with errors. |
| CWGC dates ±0 | Official military records. If CWGC says 14 July 1918, it's 14 July 1918. |

> **Caveat (§10.3 reality):** the table above describes the *intended*
> per-source tolerance policy. As shipped, the severity engine
> applies a uniform date-tolerance constant rather than per-source
> values — see §10.3. Per-source tolerances are aspirational design,
> not enforced behaviour.

### 18.6 Review friction levels

Not all results need the same level of user attention. Stage by
friction:

| Category | Default action | User effort | Example |
|----------|---------------|-------------|---------|
| **Refinements** | Auto-stage for acceptance (one-click confirm-all) | Minimal — glance and confirm | "1834" → "15 Mar 1834" |
| **Confirmations** | Grouped for batch review | Low — scan and accept | Two sources agree on death year 1902 |
| **Corrections** | Individual review required | Medium — compare old vs new | Three sources say 1905, tree says 1902 |
| **Conflicts** | Must resolve before commit | High — evaluate evidence | FreeBMD says Belper, census says Ashbourne |
| **Discoveries** | Separate "new findings" section | High — evaluate if relevant | Census reveals unknown sibling |

The review queue sorts by friction level descending — hard decisions
first, easy confirmations last. Bulk actions: "Accept all
refinements" (friction 0), "Accept all confirmations" (friction 1).

### 18.7 Rejection memory

When a user rejects a record for a profile, that rejection is
sticky. Stored in `record_rejections`. Before presenting results,
the pipeline filters out previously rejected records. This prevents
the same wrong Thomas Land from appearing every time the user
researches.

**Equivalence learning:** When the user accepts "Robert" = "Bob"
during review, store in a user equivalences table (`name_equivalences`).
The name gate checks user equivalences in addition to the hardcoded
nickname table. The system learns from every review session.

### 18.8 Household members as first-class discoveries

Household members are the most valuable output of census research.
They reveal ancestors, siblings, and in-laws the user didn't know
existed. They are surfaced as first-class discoveries, not buried in
`ResearchState.householdMembers`.

Discovery types include: new ancestor revealed in census; maiden
name implied by mother-in-law; unknown sibling; unknown child;
spouse identified by marriage record; occupation revealed; address
found. The research result includes a `discoveries` array alongside
facts, leads, and discrepancies. The UI has a dedicated "Discoveries"
section showing what the system found that the user wasn't
explicitly looking for.

### 18.9 Per-profile research as the primary mode

Whole-tree research is a power-user batch mode. The primary product
is per-profile research, beautifully done, with output the user can
confidently act on in 5 minutes.

**The MVP of the research pipeline is:**
1. User selects one profile
2. Pipeline runs verify or extend mode
3. Results clustered into candidate lives
4. User reviews one cluster, accepts or rejects
5. Accepted facts flow through MergeEngine → tree updates
6. Total time: 2–3 minutes research, 2–3 minutes review

If this doesn't work well, whole-tree mode won't save it. Build this
first, make it excellent, then add batch modes.

---

## 19. Cross-source enrichment — patterns

**Status: Built (one shipped pattern).**

When a source response references a record that another source can
parse more richly, the pipeline runs a deterministic follow-up fetch
between dispatch and score. The first such pattern shipped 2026-05-20.

### 19.1 FS → FAG bridge

- **Trigger:** `FamilySearch`-sourced burial record with a non-nil
  `memorialID` (extracted from `rawFields["field.ExtRecordId.*"]`)
  and a nil `deathYear`.
- **Action:** call `FindAGraveSource.fetchDetail(recordID: "findagrave_\(memorialID)")`.
- **Combine:** append the FAG detail record alongside the original FS
  persona. Do not replace — replacing would silently downgrade the
  FS persona's trust tier (FS is `.transcription`, FAG is
  `.community`).
- **Where:** `enrichFagBridge` in `ResearchPipeline.swift`, called
  between dispatch and score. Deduplicates against prior iterations
  via `existingIDs`.

The bridge belongs in the pipeline, not the source, because the
source plugins should stay independent and because the dedup needs
pipeline state.

After bridging, both records share `memorialID`. Convergence treats
them as independent attestations (one confirms the *existence* of
the memorial via FS, the other confirms the *content* via FAG).
`refineSubject` folds the FAG-mined death year into the subject for
the next iteration, tightening downstream queries.

### 19.2 The general pattern

Future bridges follow the same shape:

1. Deterministic trigger (collection-title match + missing key field).
2. Single follow-up fetch via the second source's existing detail API.
3. Append-not-replace into the pipeline's record set.
4. Convergence engine handles the rest.

If a second bridge ships, the rationale and design considerations
move to a dedicated `CROSS_SOURCE_BRIDGES.md`. One pattern doesn't
justify a framework.

---


## 20. Glossary (the load-bearing names)

- **Verdict** — `RecordVerdict.fact | .lead | .impossible`. The
  scorer's per-record judgement.
- **Match quality** — `MatchQuality.confirmed | .possible | .wrong`.
  UI-side aggregation of verdicts within a cluster.
- **Convergence level** — `ConvergenceLevel.confirmed | .probable |
  .possible | .singleSource | .uncorroborated`. Cross-source
  agreement, lineage-aware.
- **Hypothesis verdict** — `HypothesisVerdict.stronglySupported |
  .supported | .weak | .contradicted`. Cluster-as-hypothesis
  grading. The auto-promote gate.
- **Discrepancy severity** — `.none | .note | .refinement |
  .conflict | .correction`. Severity of a source-vs-tree
  disagreement.
- **Trust tier** — `.primary | .transcription | .community`. Source
  authoritativeness.
- **Directness** — `.primary | .directTranscription | .derivative`.
  How many hops the data is from the original record.
- **Independent lineage** — Two records share a lineage if they come
  from the same source/origin. Independence comes from different
  lineages.
- **Resolved identity** — `SubjectIdentityResolution.resolved` —
  exactly one candidate birth record pinned.
- **Stable ID** — Deterministic ID for a proposal (parent / sibling)
  so re-runs upsert rather than duplicate.
- **Evidence Firewall** — The rule that external/AI-derived facts
  enter `pending_facts` / `leads`, never `profiles` / `relationships`
  directly.
- **Apply contract** — When user clicks Apply on a cluster:
  per-record decisions override the gate predicate; writes are
  overwrite-safe (fill nil only) with citations.

---

# Part II — Proposed future state (V2)

> **Deferred (2026-05-25):** Part II (T7/T8/T9/T11/T12/T23/T31 — the
> V2 hypothesis-framework pivot) is deferred until
> `ENGINE_FOUNDATION_SPEC.md` ships. Reason: the V2 pivot is a
> multi-session architectural change, and layering it on top of the
> current scorer's thin-profile failures would entrench the wobble.
> Foundation first. T7 stall-gate is the only Part II item small
> enough that it could fold into the foundation work if convenient.
> Part I (the as-built engine, sections 1–14 above) is the active
> reference.

This Part is the next architectural turn for the research pipeline.
It folds in the portfolio thinking from
`archive/LLM_RESEARCH_OPTIONS.md` (the gap inventory and tier-per-gap
analysis) and lays out how the seven remaining open tasks compose
into a coherent change, plus three new task slots from the §5.10 /
§5.11 user-facing reframe.

All design decisions called out in this Part were resolved on
2026-05-19 (see §7). Implementation begins with T11.

---

## 1. Why now

The pipeline as built (see Part I) ships strong deterministic
primitives: a 4-gate scorer, 5-step clustering, lineage-aware
convergence, an identity resolver, three inference engines. Five
recent tasks (T17 sibling discovery, T13 subject identity, T10
geographic hypothesis, T6 auto-promote gate, T5 cluster-level
hypothesis verdict) all share a shape: each one is a **purpose-built
question** wired to bespoke generation + bespoke testing + bespoke
acceptance.

That shape doesn't generalise. Adding the next testable question —
"burial at this parish?", "death certificate in this registry?",
"second marriage to a new spouse?" — currently means another bespoke
engine, another bespoke result field on `ResearchResult`, another
bespoke UI surface, another bespoke accept path. T11 + T12 want to
retire that pattern.

In parallel, `archive/LLM_RESEARCH_OPTIONS.md` (2026-05-15)
re-framed the LLM debate as a **portfolio of moves per gap**, not a
wholesale "more LLM or not." The remaining tasks line up against the
portfolio's recommendations: T7 / T11 / T12 are the deterministic
backbone; T8 / T9 are the local-MLX bolt-ons that earn their place
where the deterministic tier hits a wall. T23 (Sample Tree tour) and
T31 (empirical retuning) sit outside the architectural pivot but get
a short pass each.

---

## 2. The architectural thesis

> Replace the bespoke "question → engine → field on result" pattern
> with a uniform **ResearchHypothesis** lifecycle: generate, test,
> grade, persist, optionally act on, optionally promote.

Concretely:

- `ResearchHypothesis` becomes a first-class type, alongside
  `ScoredRecord`, `LifeCluster`, `ProposedRelative`,
  `SiblingProposal`.
- Each existing one-off is folded in as a *kind* of hypothesis with
  its own generator and grader. Sibling discovery becomes `kind:
  .siblingExists(...)`. Subject identity becomes `kind:
  .subjectIdentity(...)`. Marriage enrichment becomes a generator for
  `kind: .parentMarriage(...)`. New questions become new kinds
  without new fields on `ResearchResult`.
- A `HypothesisEngine` runs all generators against the current
  `ResearchState`, tests each hypothesis against available evidence,
  and grades each with a verdict (`.supported` / `.contradicted` /
  `.inconclusive`).
- Hypotheses persist (T11), keyed by `(profile_id, kind,
  deterministic_subject_hash)`, so re-runs **upsert** rather than
  re-create. Verdict transitions are observable across runs.
- A graded hypothesis can drive a focused second pass (T7) — e.g. a
  `.weak` cluster hypothesis spawns a targeted query designed to
  either upgrade it to `.supported` or push it to `.contradicted`.
  This is the deterministic version of "stall recovery."
- MLX enters only where deterministic generation can't reach:
  free-text disambiguation of ambiguous identity resolutions (T9)
  and next-search suggestion for hypothesis-weak verdicts the rules
  can't escalate (T8).

The deterministic-wins rule is preserved: MLX can propose a
hypothesis or a next-search direction, but the grader and the scorer
remain rule-based. No verdict comes from a model.

---

## 3. Gap inventory (folded from `archive/LLM_RESEARCH_OPTIONS.md`)

Seven coverage gaps observed against the current pipeline. Each
carries a recommended tier (cheapest that closes it) and an
evaluation metric.

| # | Gap | Cheapest tier | Eval metric |
|---|---|---|---|
| **G1** | Shared evidence not cross-applied across profiles. Researching self + then mother re-discovers shared marriage cert rather than propagating. | Deterministic | % of cluster-internal evidence that requires only one source fetch instead of N |
| **G2** | Stall on no-result. Source returns empty for configured query; pipeline gives up rather than try a different angle. | Deterministic first, MLX second | Held-out: out of N stalled profiles, how many additional `.fact` verdicts after deterministic stall recovery? After MLX planner on top? |
| **G3** | Phonetic / spelling variants not adaptively escalated. Strictness ladder exists but escalation is per-mode-static, not response-driven. | Deterministic | Variant-tier hit rate on held-out vs current static behaviour |
| **G4** | Ambiguous locations stall the cleanse step. "Newport" matches 3 counties; cleanse can't pick one from spouse/sibling context. | Deterministic + graph context first, MLX where graph context insufficient | Resolution rate on held-out "Newport"-shaped findings |
| **G5** | Cross-cluster contradiction unresolved. Cluster A says born 1850, cluster B says 1855; no mechanism asks which is more plausible. | MLX (planning-class) | Contradictions surfaced and resolved with user agreement, per tree |
| **G6** | Bare evidence not contextualised against family graph. A single FreeBMD lead passes scoring in isolation, never re-checked vs parents/siblings. | Deterministic for the check, MLX for the rationale prose | Coverage-rate change on held-out, with and without family-graph plausibility gate |
| **G7** | Subtle merge candidates missed. `John Caudwell Ashbourne 1845` ≈ `Jon Cauldwell Wirksworth 1845` slips past `DiffEngine`. | Mixed (deterministic for structural, MLX for subtle) | Precision/recall on labelled merge-candidate set |

Two more emerged during the V2 session:

| # | Gap | Cheapest tier |
|---|---|---|
| **G8** | One-off hypothesis pattern doesn't generalise. Adding "burial at parish" or "second marriage" today requires bespoke engine + bespoke result field + bespoke UI. | Deterministic refactor (T11+T12) |
| **G9** | No persistence of hypothesis state across runs. Re-running research from scratch loses the prior session's verdict transitions; user has no way to see "this hypothesis was `.weak` last time, `.supported` now." | Deterministic + new SQL table (T11) |

---

## 4. The proposed framework

### 4.1 `ResearchHypothesis` (T11)

A persistent, deterministic, testable claim. Replaces the bespoke
fields on `ResearchResult` (today: `proposedSiblings`, soon-to-be
`proposedXYZ` for every new question).

```swift
struct ResearchHypothesis: Identifiable, Sendable {
    /// Stable deterministic ID — `kind.identityKey(profileID)`.
    /// Re-runs upsert; user-rejection persists across runs.
    let id: String

    /// Which profile this hypothesis is about (or `nil` for tree-wide).
    let subjectProfileID: String?

    /// What's being claimed. Each case carries its own typed payload.
    let kind: HypothesisKind

    /// Latest grading. Always one of supported / contradicted / inconclusive.
    let verdict: HypothesisVerdict

    /// Whether the verdict had model input (T8 / T9). Orthogonal to verdict
    /// — see Decision 8. Auto-promote and several other downstream gates
    /// require `verdict == .supported && !isModelAssisted` (see helper below).
    let isModelAssisted: Bool

    /// IDs of records that supported the verdict.
    let supportingEvidence: [String]

    /// IDs of records that contradicted (relevant for `.contradicted` only).
    let contradictingEvidence: [String]

    /// One-line human-readable rationale for the verdict.
    let reasoning: String

    /// When the hypothesis was first generated.
    let createdAt: Date

    /// Last time the verdict was recomputed.
    let lastTestedAt: Date

    /// How many levels of the per-kind expansiveness ladder have been
    /// dispatched against this hypothesis. T7's stall-recovery and the
    /// user's "investigate further" gesture both increment this on each
    /// deficit-query dispatch. When `deficitQuery(for: h, atLevel: attempts + 1, …)`
    /// returns `nil`, the hypothesis is exhausted at that kind's ladder
    /// ceiling and the UI archives it under a collapsible section.
    var attempts: Int

    /// Trail of (verdict, timestamp) so the UI can show "weak last run → supported now."
    let history: [VerdictTransition]
}

extension ResearchHypothesis {
    /// True iff the verdict is `.supported` AND no model input was used.
    /// Every promotion / auto-accept gate uses this helper — never a bare
    /// `verdict == .supported` comparison. Preserves the deterministic-wins
    /// rule: model output never writes facts.
    var isDeterministicallySupported: Bool {
        verdict == .supported && !isModelAssisted
    }
}

/// Closed enum (Decision 1). Adding a new kind requires touching the enum,
/// the central generator switch, the central grader switch, and the central
/// deficit-query switch (Decision 5). Exhaustive switching catches "forgot
/// to handle the new kind" at compile time.
enum HypothesisKind: Sendable {
    case subjectIdentity(birthYearWindow: ClosedRange<Int>, districtHint: String?)
    case parentInferred(gender: Gender, surname: String)                                  // T12-parent Phase 1
    case parentMarriage(motherSurname: String, fatherSurname: String, windowYears: ClosedRange<Int>)
    case siblingExists(district: String, mmn: String, yearWindow: ClosedRange<Int>)
    case clusterIsSubject(clusterID: UUID)       // T7's working hypothesis
    case burialAtParish(parish: String, yearWindow: ClosedRange<Int>)
    case secondMarriage(afterYear: Int)
    // ... extensible by adding cases here + the three central switches
}

// Note: the shipped type uses `ClosedRange<Int>` (inclusive on both
// ends), not the open-ended `Range<Int>` an earlier draft of this
// spec showed. `.parentInferred` was added during T12-parent Phase 1
// and is not present in the older draft.

enum HypothesisVerdict: String, Sendable {
    case supported       // evidence points to claim
    case contradicted    // evidence rules claim out
    case inconclusive    // not enough evidence to decide
}

// Asymmetric verdict-space across kinds. `HypothesisVerdict` is a
// closed three-case enum at the type level, but in practice not every
// kind produces every verdict. `.parentInferred` never produces
// `.contradicted` — its grader treats "no birth record found
// carrying the MMN" as `.inconclusive`, not `.contradicted`, because
// only explicit no-parents context (foundling, ward, etc., which is
// outside V2 scope) would falsify the claim. The same asymmetry
// applies to `.parentMarriage` (absence of a marriage record is
// `.inconclusive`, not `.contradicted` — the marriage may sit in a
// year-window the search missed). Downstream UI must not assume
// "absence of `.supported`" implies "presence of `.contradicted`";
// `.inconclusive` is the dominant absent-evidence verdict for these
// kinds.

struct VerdictTransition: Sendable {
    let verdict: HypothesisVerdict
    let isModelAssisted: Bool
    let at: Date
    let reason: String
}
```

**Important design choice — separate from `Workbench.Hypothesis`.**
The existing `Hypothesis` type in `Models/Workbench/` is
user-authored, free-form, and lives on the workbench surface.
`ResearchHypothesis` is machine-generated, structured, regenerated
each run, and lives on the research surface. They share a name root
but not a table. A `.supported` `ResearchHypothesis` may be
*promoted* into a `Workbench.Hypothesis` by user action — that's the
only crossing.

### 4.2 `HypothesisEngine` (T12)

Earlier drafts of this spec described a `runAll(state:snapshot:persisted:)`
orchestrator that iterates over every kind, dedups, tests, grades.
**The shipped code doesn't use that shape and per Decision 10
(§7.10) it won't.** Instead, `ResearchPipeline` calls into the
per-kind machinery at well-defined integration points
(`runParentHypothesisFlow`, `runSiblingHypothesisFlow`, plus the T7
second-pass dispatcher). The central engine file hosts only the
three exhaustive switches plus the cross-kind reconciliation
(`reconcileParentMarriages`); no top-level orchestrator entry point.

Each `HypothesisKind` participates via **three thin central switches**
in `HypothesisEngine.swift`, each of which dispatches to per-kind
logic that lives in a `HypothesisEngine+<Kind>.swift` extension file
(Decision 5). The central switches stay small and exhaustive; the
per-kind logic stays adjacent (all three operations for
`.siblingExists` live in `HypothesisEngine+SiblingExists.swift` and
so on).

1. **`generate(for kind:state:snapshot:)`** —
   `(...) -> [ResearchHypothesis]`. Returns 0..N candidate hypotheses
   (typically deterministic: `.siblingExists` generates one per
   resolved subject birth where both parents are linked).
2. **`grade(_ hypothesis:state:snapshot:)`** —
   `(...) -> GradeResult`. Pure function over current evidence;
   returns `(verdict, supportingIDs, contradictingIDs, reasoning)`.
3. **`deficitQuery(for hypothesis:atLevel:state:)`** —
   `(...) -> RecordQuery?`. Per-kind expansiveness ladder: returns
   the focused query for the given level on this hypothesis, or
   `nil` when the level exceeds the kind's ladder ceiling. Callers
   pass `attempts + 1`; the call site (T7 stall-recovery or the user
   "investigate further" gesture) is what differs, not the function.
   `nil` is the exhaustion signal — no separate state flag needed.

Adding a kind = add the case to `HypothesisKind` + add a clause to
each central switch + add an extension file with the kind's three
operations as static methods. The compiler enforces completeness on
the central switches.

The existing one-offs slot in as generators + graders:

| Existing | Folds in as |
|---|---|
| `SubjectIdentityResolver.resolve` | grader for `.subjectIdentity` |
| `GeographicHypothesisGenerator.inferDistricts` | helper for the `.subjectIdentity` generator |
| `SiblingInferenceEngine.inferSiblings` | grader for `.siblingExists` |
| `MarriageEnrichmentEngine.match` | grader for `.parentMarriage` |
| `ParentInferenceEngine.infer` | generator for `.parentMarriage` (one per (mother MMN, father surname) pair) |

`ResearchResult` gains one new field:

```swift
let hypotheses: [ResearchHypothesis]
```

…and progressively loses **both** bespoke proposal fields:
`proposedSiblings` is removed by the final phase of T12-sibling
(sibling proposals become `.siblingExists` hypotheses; see §5.2);
`proposedRelatives` is removed by the final phase of T12-parent
(parent proposals become `.parentInferred` / `.parentMarriage`
hypotheses). Decision 3 commits to migrating both rather than leaving
one as legacy.

### 4.3 Persistence (T11)

SQL migration `v26_research_hypotheses` (already in the schema):

```sql
CREATE TABLE research_hypotheses (
    id TEXT PRIMARY KEY,
    subject_profile_id TEXT,
    kind_discriminator TEXT NOT NULL,
    kind_payload TEXT NOT NULL,         -- JSON
    verdict TEXT NOT NULL,
    is_model_assisted INTEGER NOT NULL DEFAULT 0,
    supporting_evidence TEXT NOT NULL,  -- JSON array of record IDs
    contradicting_evidence TEXT NOT NULL,
    reasoning TEXT NOT NULL,
    created_at DATETIME NOT NULL,
    last_tested_at DATETIME NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0, -- expansiveness levels dispatched so far
    history TEXT NOT NULL,              -- JSON array of VerdictTransition
    user_rejected INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (subject_profile_id) REFERENCES profiles(id)
);
CREATE INDEX idx_research_hypotheses_subject ON research_hypotheses(subject_profile_id);
CREATE INDEX idx_research_hypotheses_verdict ON research_hypotheses(verdict);
```

**Upsert semantics**: when the hypothesis engine produces a
hypothesis (via the per-kind `generate*` switch — see §4.2 and
Decision 7.10) whose stable ID already exists in the table, the
row is updated (verdict, evidence, reasoning, history append,
lastTestedAt) — not replaced. The `created_at` and `history` carry
forward.

**User-rejection persists**. A hypothesis the user has explicitly
dismissed (e.g. "this sibling isn't mine") flips `user_rejected = 1`
and is filtered out of UI display on subsequent runs.

---

## 5. Task-by-task — how each remaining task fits

### 5.1 T11 — Hypothesis type + persistence

**Status: Shipped 2026-05-19, commit `fe1c2b5`.**

**What lands:**
- `Models/Research/ResearchHypothesis.swift` with the type + kind
  enum + verdict enum + transition record.
- Schema-side migration creating `research_hypotheses` (already
  v26).
- `ProjectDatabase` extensions: `loadHypotheses(forProfile:)`,
  `upsertHypotheses(_:)`, `rejectHypothesis(_:)`.
- `ResearchResult.hypotheses: [ResearchHypothesis]` field (default
  `[]` so existing callers compile).

**What does NOT land in T11:**
- Generators or graders. T11 ships the type and table; T12 ships the
  engine that fills them.
- Migration of existing one-offs. The existing `proposedSiblings`
  field remains during the transition; the new `hypotheses` field
  sits beside it. Migration happens incrementally as each generator
  lands in T12.

**Eval criterion:** T11 is structural plumbing; success = unit tests
on round-trip persistence + the table queryable from the MCP server
(so external tooling can read hypothesis state).

### 5.2 T12 — HypothesisEngine: generate, test, grade

**Status: Shipped 2026-05-19, commit `cb8b05b`.** Sibling, parent-
inferred, and parent-marriage generators are all live; per the
"As-shipped note" below, dispatch is per-kind from the pipeline
rather than via a central `runAll`.

T12 splits into two sequenced sub-projects (Decision 3). Each
sub-project is itself executed as a 4-phase migration (Decision 2).
Total: 8 commits across T12, each individually bisectable, each
behaviour-identical to the prior commit until the final phase
deletes the legacy field.

#### T12-sibling — fold `.siblingExists` into the framework

> **As-shipped note (per Decision 7.10):** there is no central
> `HypothesisEngine.runAll`. Dispatch is per-kind from the pipeline —
> the post-loop phase calls `HypothesisEngine.generate(.siblingExists, …)`
> and `.grade(…)` directly through the per-kind switches. The phase
> table below preserves the original sequencing for git archaeology;
> Phase 1's "runAll entry point" reduced to per-kind dispatch by the
> time the work landed.

| Phase | What changes |
|---|---|
| 1 | `Services/Research/HypothesisEngine.swift` with central `generate` / `grade` / `deficitQuery` switches. `.siblingExists` case added with generator + grader + deficit-query clauses. Pipeline calls the engine per-kind. `result.hypotheses` field populated. `result.proposedSiblings` still populated by the legacy `findSiblings()` path. Both fields verified identical via tests. |
| 2 | Flip source of truth: `proposedSiblings` becomes `result.hypotheses.filter { kind matches .siblingExists, isDeterministicallySupported }.map(toLegacyShape)`. Legacy `findSiblings()` deleted. Output verified identical to Phase 1 by tests. |
| 3 | UI swaps to read `result.hypotheses` directly. `proposedSiblings` field still exists but unused. View diff trivial. |
| 4 | Delete `proposedSiblings` field. Pure deletion. |

**Generator/grader contract for `.siblingExists`**: generator runs
when `SubjectIdentityResolver` returns `.resolved` AND both parents
linked; emits one hypothesis per `(district, mmn, yearWindow)`.
Hypothesis ID = `sibling:\(profileID):\(district):\(mmn):\(yearWindowKey)`.
Grader runs the focused FreeBMD query + existing inference rule:
- `.supported` if ≥1 candidate sibling found AND user hasn't rejected it
- `.contradicted` if query returned zero candidates
- `.inconclusive` if query hit a source error / scope mismatch / quota guard

Deficit query for `.inconclusive`: retry the same district with the
next strictness tier (loose, if the first ran at strict).

#### T12-parent — fold `.parentInferred` and `.parentMarriage` into the framework

**Gate (resolved 2026-05-19, see §5.2.1):** the marriage-enrichment
coupling question is closed — `.parentInferred` and `.parentMarriage`
are two cross-referencing kinds with a deterministic reconciliation
step the pipeline invokes after both kinds have been graded.

| Phase | What changes |
|---|---|
| 1 | Both `.parentInferred(gender, surname)` and `.parentMarriage(motherSurname, fatherSurname, window)` kinds added together with their generate / grade / deficit-query clauses (separate extension files per Decision 5). `HypothesisEngine.reconcileParentMarriages` lands as an engine entry point that the pipeline calls after the per-kind dispatch of `.parentInferred` and `.parentMarriage` (per Decision 7.10 — no central `runAll`). `result.hypotheses` carries both new kinds with the marriage evidence already cross-referenced onto the parent hypotheses. `result.proposedRelatives` still populated by the legacy `ParentInferenceEngine.infer` + `enrichParentsWithMarriage` paths. Both surfaces verified projection-equal via tests. |
| 2 | Flip source of truth: `proposedRelatives` becomes a derived projection from `result.hypotheses` (supported `.parentInferred`s, with marriage evidence already folded in by reconciliation). Legacy inference paths deleted. Output verified identical to Phase 1. |
| 3 | UI swaps to read `result.hypotheses` directly. The "Already linked" detection, "Apply" action, and marriage-enrichment cross-validation cards re-target the new source — see §5.2.1 for how each affordance maps onto the two kinds. Bigger view diff than T12-sibling Phase 3. |
| 4 | Delete `proposedRelatives` field. Pure deletion. |

**Why this ordering (T11 → T12-sibling → T12-parent):**

- T11 is structural — no dependencies, fastest to bake.
- T12-sibling is the smaller test of the framework. Sibling
  discovery was added recently (T17) so the existing UI is narrow
  and the surgery is contained.
- T12-parent is the deeper change — older, more deeply integrated,
  more UI affordances. Doing it after T12-sibling lets us stress the
  framework once before tackling the bigger lift, and lets us write
  the marriage-enrichment design pass with full context.

**Eval criterion (cross-phase regression):** for both sub-projects,
the per-profile output after each phase exhibits **projection-equality
on the legacy field's shape** to the prior phase's output on a 5–10
profile snapshot corpus. "Projection-equality" excludes timestamps
(`createdAt`, `lastTestedAt`), JSON key ordering inside payloads, and
`attempts` counter values — these are expected to differ across runs
and don't constitute behaviour change. The on-disk persistence layer
itself is tested separately via dedicated upsert / round-trip unit
tests, not via the cross-phase regression.

Final phases gain the new transparency: `.contradicted` hypotheses
now surface with reasoning rather than vanishing silently.

#### 5.2.1 Marriage-enrichment design pass — addendum

**Status:** Resolved 2026-05-19, ahead of T12-parent Phase 1.

**Question:** does `.parentInferred(gender, surname)` contain
marriage-enrichment evidence **internally** (one kind whose grader
both proposes a parent and runs the marriage dispatch), or do
`.parentInferred` and `.parentMarriage(motherSurname, fatherSurname,
window)` exist as **two cross-referencing kinds** (one engine
reconciles them post-grading)?

**Decision:** **two cross-referencing kinds.** `.parentInferred`
claims "this surname belongs to a parent." `.parentMarriage` claims
"a BMD marriage joins these two surnames in the plausible window."
The pipeline reconciles the two after dispatching each kind through
the engine (per Decision 7.10 — no central `runAll`): a supported
`.parentMarriage` writes a cross-reference back onto the matching
mother + father `.parentInferred` hypotheses (their
`supportingEvidence` gains the marriage record ID, their `reasoning`
gains the "given name X from .parentMarriage:Y" sentence). The
reconciliation is deterministic and idempotent.

**Why two kinds, not one bundled kind:**

1. **Per-kind deficit-query ladders diverge.** An inconclusive
   `.parentInferred` (no birth record carrying MMN found) needs the
   main pipeline's whole-profile widening ladder — broaden the BMD
   birth search. An inconclusive `.parentMarriage` (no marriage hit)
   needs scope-first-then-strictness walk — widen the year window
   from ±30 to ±40, then try the next adjacent county. Different
   ladders mean different `deficitQuery*` clauses.
2. **Verdicts have to be separately observable.** A user asking "why
   is this parent proposal weak?" deserves to see *which* underlying
   claim failed: parent not proposable from any birth record (no
   MMN), or proposable but no marriage found to disambiguate the
   given name.
3. **Generator chaining matches the engine's pattern.**
   `.parentMarriage` naturally feeds off `.parentInferred` output:
   only when both mother and father parent-hypotheses are supported
   is there a (mother, father) pair worth marriage-searching.
4. **Identity-key stability under upsert.** One marriage links two
   parents. With one bundled kind, the marriage's record ID is
   duplicated across mother's and father's
   `.parentInferred.supportingEvidence` lists; re-runs can't dedupe
   across them. With two kinds, the marriage is one `.parentMarriage`
   row keyed by `parentMarriage:\(subject):\(motherSurname)x\(fatherSurname):\(window)`,
   the parent rows store the cross-reference once, and Decision 1's
   upsert semantics keep the on-disk state consistent across runs.
5. **Symmetry with the rest of the framework.** Every other kind
   carries one self-contained claim. Bundling enrichment into
   `.parentInferred` would be the framework's only kind hosting a
   sub-claim.

**Mechanics of cross-referencing:**

- `HypothesisEngine.generate(for: .parentInferred, ...)` emits one
  `.parentInferred` per (subject birth record, parent gender) pair
  carrying MMN.
- `HypothesisEngine.grade(_:state:snapshot:)` for `.parentInferred`
  is purely BMD-birth-evidence: verdict `.supported` when ≥1
  fact-or-lead birth record carries the MMN; `.contradicted` only
  when explicit no-parents context exists (foundling, etc. — out of
  V2 scope, will be `.inconclusive` in practice); `.inconclusive` if
  no birth record found.
- `HypothesisEngine.generate(for: .parentMarriage, ...)` walks
  supported `.parentInferred` pairs (same subject, opposite genders,
  surnames present) and emits one `.parentMarriage` per pair. Window
  is `subjectBirthYear − 30 ... subjectBirthYear + 1`.
- `HypothesisEngine.grade(_:state:snapshot:)` for `.parentMarriage`
  runs `MarriageEnrichmentEngine.match` against state's marriage
  records.
- **Reconciliation step:** after the pipeline has dispatched both
  `.parentInferred` and `.parentMarriage` through `generate` + `grade`,
  it calls `HypothesisEngine.reconcileParentMarriages`, which walks
  `.supported` `.parentMarriage` hypotheses and, for each, finds the
  two `.parentInferred` hypotheses they cross-reference. It appends
  the marriage record ID(s) to each parent's `supportingEvidence` and
  a sentence ("given name 'X' from marriage 'Y'") to each parent's
  `reasoning`. The reconciliation is a pure join over the hypothesis
  list — no dispatch, no model — so `isModelAssisted` on the parent
  hypotheses stays `false` and `isDeterministicallySupported` is
  preserved.

### 5.3 T7 — Hypothesis-guided second pass

**Status: Shipped (with documented partial gate).** The second-pass
loop, deficit-query dispatch, re-grade, and reconciliation are all
live. The two-condition stall gate (§7.4) is implemented with
condition (b) only because condition (a) requires dispatcher
instrumentation that doesn't exist yet; this is documented in the
code. The "≥30% of stalled profiles gain ≥1 new `.supported`
hypothesis" uplift target is unmeasured pending the eval harness
(§5.8 reframe).

**What lands:**
- A second-pass entry point in `ResearchPipeline` that runs after
  the first pass completes: `researchSecondPass(firstResult:state:)`.
- The pass examines `firstResult.hypotheses` and selects those with
  `verdict == .inconclusive` and a non-nil result from
  `deficitQuery(for: h, atLevel: h.attempts + 1, state: s)` (per
  Decision 5 — `nil` at any level means the kind's ladder ceiling is
  reached).
- For each, dispatch the returned query, append new evidence to
  `state`, increment the hypothesis's `attempts`, re-run each
  hypothesis's per-kind grader (`HypothesisEngine.grade(_:state:snapshot:)`),
  re-run `reconcileParentMarriages`, recompute clusters.

**Stall-detection contract (Decision 4)** — two-condition gate:

T7 fires the second pass iff both conditions hold:

1. **Variant-exhaustion**: the dispatcher has walked the full
   strictness ladder for every applicable source in the first pass
   (no headroom in the existing tier mechanism), AND
2. **Deficit-eligible inconclusive hypothesis**: the first pass
   produced at least one `.inconclusive` hypothesis whose
   `deficitQuery(for: h, atLevel: h.attempts + 1, state: s)` returns
   non-nil.

The second pass runs **at most once** per `research(...)` call.
Cost ceiling: roughly N additional focused queries where N = count
of deficit-eligible inconclusive hypotheses (typically 1–3 in
practice). Deficit queries respect the existing storm guards in
`SearchDispatcher` — they go through the dispatcher's normal path,
not around it.

Hypotheses where `deficitQuery(..., atLevel: attempts + 1, ...) ==
nil` are **exhausted** — the kind's ladder ceiling reached. The UI
archives these (see §5.11) and they fall through to T8's MLX
next-search fallback (§5.4) for one last try.

**Why deterministic and not MLX:** every kind's deficit query is a
deterministic rewrite of its own grader's inputs. "Try the next
adjacent district" is graph traversal; "widen the year window" is
arithmetic. MLX shouldn't decide where to look when the rules know
perfectly well.

**Eval criterion:** held-out corpus of profiles known to stall in
first pass — measure fact uplift after T7's second pass. Target:
≥30% of stalled profiles gain at least one new `.supported`
hypothesis.

### 5.4 T8 — MLX query strategist (Level 2, shipped slice 13)

**Status: Shipped 2026-05-26 (slices 13a/13b/13c).**

Originally scoped as a hypothesis-level fallback for T7-exhausted
rows; promoted in slice 13 to a between-iteration **Level-2 query
strategist** because the iteration-loop blind spot (broad fan-out
that doesn't adapt to what's just been learned) was a higher-leverage
target than the T7-stuck case.

**What ships:**

- `Models/Research/FocusedQuery.swift` — single-source, single-record-
  type targeted query with surname + given + year window + district +
  required `rationale` string. Pure data; converts to `RecordQuery`
  via `toRecordQuery()`.
- `SearchDispatcher.dispatchOne(focused:cache:)` — runs one
  `FocusedQuery` against the named source. Bypasses the strictness
  ladder and the multi-source fan-out. Returns `[]` gracefully when
  source ID doesn't match or year coverage misses.
- `ResearchInterpreter.suggestNextFocusedQuery(...)` — MLX-backed
  async function. Builds a system+user prompt carrying subject state,
  confirmed facts, hypothesis snapshot, household, already-searched
  list, and the BMD/census constants from `agent/rules.py`
  (`MOTHERS_MAIDEN_NAME_START`, `SPOUSE_SURNAME_START`, etc.). Parses
  the JSON response into a `FocusedQuery` or returns nil (model
  unavailable, output unparseable, or explicit `{"give_up": true}`).
- `ResearchPipeline.research()` wiring — between iterations, when the
  iteration produced 0 new records OR no confirmed facts, the
  pipeline calls the strategist. A non-nil suggestion is dispatched
  via `dispatchOne`, results scored + appended to `state.scoredRecords`,
  and `searchHistory` records the rationale for audit.

**Determinism contract.** MLX is allowed to choose *what* to ask;
deterministic code owns *what's true*. Specifically:

| Layer | Owner |
|---|---|
| Which query to dispatch next | MLX strategist |
| Source-side query shaping (district codes, etc.) | `FocusedQuery.toRecordQuery()` |
| Record scoring (4-gate) | `RecordScorer` deterministic |
| Verdict (`.fact` / `.lead` / `.impossible`) | `RecordScorer` deterministic |
| Hypothesis grade (`.supported` / `.contradicted`) | `HypothesisEngine` deterministic |
| Subject refinement from confirmed facts | `refineSubject` deterministic |
| §14.3 auto-approval gate | `MCPServer.evaluateApproval` deterministic |

No MLX output reaches verdict-grade evidence. The strategist's
`rationale` lives in `searchHistory.searchKey` for the audit trail
but doesn't influence scoring.

**Trigger condition (unproductive iteration).** The strategist fires
when `newRecordCount == 0 OR state.confirmedFacts.isEmpty`. Productive
iterations don't need MLX help — the deterministic engine is doing
its job. This keeps MLX inference cost bounded to the iterations
where it adds value.

**Fallback behaviour.** When MLX is unavailable (model not loaded,
ANE busy, output unparseable, or explicit `give_up`), the strategist
returns nil and the pipeline falls through to the next iteration's
normal fan-out. No new failure modes; MLX is purely additive.

**isModelAssisted flag.** Records gathered via a focused query are
not marked `isModelAssisted` — the records themselves came from a
deterministic source via a deterministic dispatcher. Only the
*decision to dispatch* was MLX-influenced, which the audit trail
preserves but the scorer doesn't act on.

**Why not the hypothesis-level fallback first?** The original T8
scope (post-T7 exhausted-ladder fallback) only fires on a small
sliver of subjects. The Level-2 between-iteration variant fires on
the much larger population of "iteration produced nothing useful" —
matching the bottleneck surfaced by the George H Brooks research
trace.

**Open follow-up (T8a, deferred).** The original hypothesis-level
fallback is still valuable when T7's deficit ladder exhausts on
specific kinds. Reserved for a future slice; the
`suggestForWeakHypothesis` entry point can be added alongside the
shipped `suggestNextFocusedQuery` without changing existing wiring.

**Why local MLX, not Claude API (Decision 7)**:

1. **App Store posture**. We stripped outbound AI calls in May 2026
   (T18, T20) specifically to clean the privacy disclosure surface.
   Re-introducing them is non-trivial — new privacy disclosure,
   possibly a new review cycle, and re-tackling "what does your app
   send where?"
2. **Task shape**. T8's calls are structured-output, tie-break /
   fallback, low-frequency. That's easier territory for a 7B-4bit
   model than the open-ended planning the portfolio doc was sceptical
   about.
3. **The escape valve is a measured fallback**. The eval harness
   (§5.8) will reveal whether MLX quality is genuinely insufficient.
   If it is, a future task escalates to API — at which point we
   tackle the App Store implications with eyes open, having data to
   defend the move.

Both `verdict` and `isModelAssisted = true` are set on hypotheses T8
influences (Decision 8). Downstream consumers use
`isDeterministicallySupported` to gate auto-promote and similar
deterministic-only paths.

**Eval criterion:** for the subset of stalled-and-T7-stuck profiles,
measure fact uplift after T8 fires. Target: ≥10% of T7-stuck
profiles gain at least one `.supported` hypothesis on the third
pass.

### 5.5 T9 — MLX free-text disambiguation pass

**Status: Paper-only. Not built.**

**What lands:**
- `ResearchInterpreter.disambiguateIdentity(candidates:state:)` entry
  point.
- Wired into the `.subjectIdentity` grader: when
  `SubjectIdentityResolver.resolve` returns `.ambiguous`, AND T7's
  deterministic deficit query also doesn't resolve it, AND the
  candidates have free-text fields the deterministic resolver can't
  compare (notes, occupations, partial addresses in raw record
  fields), T9 asks the model "given these candidates and what we
  know about the subject, which is most plausible?"
- Output is again structured: `(preferredCandidateID, confidence,
  reasoning)`. The resolver only acts on it when `confidence ≥
  threshold` (see §5.5.1), and even then the hypothesis grading
  flags it as model-assisted.

**Why MLX is right here and not for grading:**

The grader's contract is "rules decide, model never overrules." T9
doesn't overrule — it operates only when the rules return
`.ambiguous` (i.e. the rules have explicitly given up). The model is
breaking ties, not making findings.

#### 5.5.1 Threshold policy

The confidence threshold is load-bearing — set too high and T9 is a
no-op; set too low and the model overrules the rules in disguise.

> When T9 ships, the threshold will be the lowest value `θ` such
> that user-agreement rate on the eval-harness disambiguation corpus
> (per §5.8) at threshold `θ` is **≥ 75%**. Below 75%, the threshold
> is raised until either the rate clears or no remaining tie-breaks
> pass.

The specific numeric value of `θ` will be TBD until the harness has
corpus data. The setting rule is fixed now. T9 can ship with the
threshold pinned at "always reject" (no model output ever acted on)
until the harness produces enough data to set `θ` defensibly.

### 5.6 T23 — Guided Sample Tree tour (out of band)

**Status: Paper-only. Not built.**

**Out of architectural scope, in scope for completeness.** A
first-launch tour that walks the user through the Sample Tree's
features (Tree / Audit / Research / Leads / Settings). Pure UX work.
No pipeline impact.

**What lands:**
- An overlay coachmark sequence triggered when the user opens the
  Sample Tree from the welcome screen.
- ~5 steps: tree navigation, opening Audit, running Research on a
  sample subject, reviewing leads, finding Settings.
- "Skip tour" / "Don't show again" affordances.

**Build order independence:** T23 can ship at any time without
touching anything in §5.1–5.5.

### 5.7 T31 — Empirical retuning of the expansiveness ladder

**Status: Paper-only. Not built.** Depends on §5.8 (harness), §5.10
(button collapse), and a stable hypothesis-kind set (T11/T12 — done).

**Reshaped from the original framing.** The original T31 retuned
per-mode iteration counts and fact caps for the four research modes.
After §5.10 those modes collapse into a single auto-escalating
expansiveness ladder. T31 now retunes:

1. The default level → (strictness, scope) mapping for whole-profile
   research (the user-facing four-level ladder in §5.10).
2. Each hypothesis kind's expansiveness ladder defined by its
   `deficitQuery*` function (which levels exist, what they query).
3. The satisfaction threshold (`StopPolicy.satisfied` cutoff) — how
   strong a verdict counts as "enough" to stop auto-escalating.

**Build order:** T31 depends on the eval harness (§5.8), the
Research button collapse (§5.10), and at least T11/T12 having
stabilised so the hypothesis kinds aren't moving.

### 5.8 Eval harness (validation infrastructure)

**Status: Partial (2026-05-23).** Python-side scaffold shipped this
session; Swift-side measurement backend pending.

**What's shipped (this session, commits `516da79` → `99da91a`):**

- §5.8.5 GEDCOM citation matcher. Python `eval/citation_matcher.py`
  and Swift `Ancestor Research/Services/Research/CitationMatcher.swift`
  in sync per the Swift docstring's "keep in sync" instruction.
  Handles FreeBMD/GRO families with quarter+year+district primary
  keys and vol+page secondary, FamilySearch ARK matching, CWGC plot
  or date-of-death.
- §5.8.6 Runner. `eval/run_harness.py` invokes
  `agent.pipeline.research_person` per subject and emits the
  per-subject envelope used by the metrics. Flags: `--backend
  python|mock`, `--only @<profile-id>@`, `--corpus`, `--out`.
- §5.8.2 Certified subset. 12 corpus subjects under
  `eval/certified/*.yaml`, hitting every difficulty axis named in
  §5.8.4 plus several new ones (`sparse_evidence`, `cross_county`,
  `pre_civil_registration`, `geographic_outlier`,
  `name_change_at_marriage`). Reached the §5.8.1 T7 defensible-delta
  tier (10–12 profiles).
- §5.8.3 Per-kind verdict-agreement metric. The harness derives a
  `supported` / `inconclusive` verdict per kind from the envelope,
  compares against the corpus YAML's `expected_per_kind`, and
  reports per-subject + corpus-wide agreement counts.
  Verdict-comparison tolerates annotated forms
  (`supported_with_district_anomaly` etc. — see commit `de8e8f8`).

**What's not yet shipped:**

- Swift-driven backend (`--backend swift-mcp`). Currently the harness
  measures the *Python reference* implementation per CLAUDE.md, not
  the Swift product. Driving the Swift app via the existing
  `FieldResearcherMCP` server is the next major investment — call
  it §5.8.8.
- Precision/recall in the strict §5.8.3 sense. The current
  per-kind metric is "agreement" (did pipeline and corpus reach the
  same verdict). Precision/recall on top of the existing per-kind
  data is small follow-up.
- §5.8.7 build-order pre-conditions for T8/T9/T31. Those tasks
  remain paper-only — see §§5.4–5.6.

The §5.8.1 corpus-tier table below remains accurate. The §5.8.4
difficulty-axis list remains accurate but has been extended in
practice (subjects under `name_change_at_marriage`,
`cross_county_migration`, `geographic_outlier`,
`pre_civil_registration`, `sparse_evidence` axes all exist now).
Update §5.8.4 when a future revision pins the canonical axis list.

**Reframe (2026-05-22):** earlier drafts called this a *build*
prerequisite for T7 / T8 / T9 / T31. That was wrong — T7 shipped
without the harness, against unit tests, and works. The harness is
a *validation* prerequisite. Two ideas the earlier framing
conflated:

- **Build prerequisites**: code that must exist before you can
  *write* dependent code. The hypothesis engine + persistence (T11)
  is a real build prerequisite for T12. The harness is **not** a
  build prerequisite for T7.
- **Validation prerequisites**: infrastructure required to *claim*
  a target is met. T7's "≥30% of stalled profiles gain ≥1 new
  `.supported` hypothesis" target is unmeasured today — the harness
  is what would let us defend that number. Same applies to T8
  uplift, T9 user-agreement rate, T31 ladder retuning.

Status callouts elsewhere:

- **T7 shipped 2026-05-XX; uplift target unvalidated pending §5.8.**
- T8/T9 are not yet built and so don't yet need validation.
- T31 doesn't ship without the harness — it's *defined as* the
  application of the harness.

**Recommended ship order:** the 3-profile structural-plumbing tier of
the harness (§5.8.1 row 1) should ship as the next pipeline task. It
is small enough to land in one session, gives T7's uplift target its
first defensible number, and is a build prerequisite for the
10–12-profile T7 validation tier and the 20–30-profile T8/T9/T31
tiers. Everything else in §5.4–§5.7 and §5.9–§5.11 can sequence after
the minimal harness exists.

#### 5.8.1 Tiered corpus targets

Corpus size is gated by which decision the harness is asked to back.
Three-profile numbers can't carry irreversible ship decisions.

| Stage | Corpus size | Decisions backed |
|---|---|---|
| T11 / T12 ship | 3 profiles | Structural plumbing only |
| T7 ships with a defensible delta | 10–12 profiles | T7's "≥30% of stalled profiles gain ≥1 new `.supported` hypothesis" target |
| T8 / T9 escape-valve to API; T31 ladder retune | 20–30 profiles | Irreversible or shipping decisions |

#### 5.8.2 Two-corpus structure

| Corpus | Size | Cost | Used for |
|---|---|---|---|
| **Certified subset** | 20–30 profiles, manually verified | High (30 min — several hours per profile) | Precision/recall, per-kind metrics, evidence reproduction rate |
| **Known-errors corpus** | Grows over time, append-only | Low (write down the correction as you find it) | Regression suite: "does V2 surface the errors I already know about?" |
| **Full-regression set** | ~270 profiles, free | Zero | "Didn't break anything obvious" nightly check |

#### 5.8.3 Metrics

- **Precision** (% of `.fact` verdicts matching ground truth) on the
  certified subset.
- **Recall** (% of ground-truth facts surfaced as `.fact`) on the
  certified subset.
- **Contradiction count** (per profile) on the certified subset.
- **Evidence reproduction rate**: for each certified profile, the
  fraction of its existing citations that V2's pipeline surfaces.
- All four metrics reported **per hypothesis kind** so each task's
  eval criterion maps onto its kind's `.supported / .contradicted /
  .inconclusive` distribution.

#### 5.8.4 Difficulty stratification

> Every corpus addition must increase the corpus's coverage on at
> least one difficulty axis: known stallers (G2-shaped); known
> ambiguous-identity (T9's target); known multi-cluster
> contradictions (G5-shaped); known sparse-evidence subjects
> (single-lineage cases); foreign-record edge cases (`.all` mode). At
> all times the corpus must include at least one "should remain
> absent" hallucination guardrail subject.

#### 5.8.5 GEDCOM citation matcher (sub-deliverable)

To compute evidence reproduction rate, GEDCOM citation strings must
map to the pipeline's internal source records. A short matcher —
likely 50–150 lines near `SourceTierRegistry`, or as a new
`CitationMatcher` — does this mapping.

#### 5.8.6 Runner

- A CLI scheme target (`swift run eval` or equivalent) invokes
  `ResearchPipeline.research(...)` against each profile in whichever
  corpus is selected.
- **Snapshot-based**: each profile evaluates against a frozen
  `FamilyGraphSnapshot` taken at eval-start, so running T11 / T12
  doesn't drift the corpus as accepted relatives land back in the
  tree.
- Reporting: per-kind metrics for diagnosis, plus a **single headline
  number** — "net `.supported` deterministic hypotheses across the
  certified corpus" — for commit-message deltas.

#### 5.8.7 Build order

Ships **before** T7 (so T7 has a measurable uplift number on landing
— corpus at 10–12 profiles), **before** T8 / T9 (mandatory, corpus
at 20–30 profiles), and **before** T31.

### 5.9 Pipeline incrementality refactor (new task)

**Status: Paper-only. Not built.**

**Why**: today `ResearchPipeline.research(subject:config:)` is a
monolithic call — kicks off, runs to completion, returns one result.
"Research as a discrete event" doesn't match the actual user mental
model. The Research-button collapse in §5.10 depends on the pipeline
being able to *yield between levels*; this refactor is the
prerequisite.

**What lands**:

- `ResearchPipeline.research(...)` decomposes into a level-by-level
  state machine. Each level runs to completion, yields a
  `ResearchState`, and the caller decides whether to invoke the next
  level.
- `ResearchState` becomes persistable.
- New entry points: `startResearch(subject:initialLevel:)` returns a
  session handle; `continueResearch(session:)` runs the next level
  and yields; `pauseResearch(session:)` persists state and exits;
  `resumeResearch(session:)` rehydrates and is ready to continue. No
  behaviour change in the deterministic core.
- Existing call sites migrate to the new entry points. The legacy
  monolithic `research(subject:config:)` survives as a convenience
  wrapper.

**Eval criterion**: byte-identical (modulo projection-equality)
result between a single eager invocation of the legacy wrapper and a
level-by-level invocation of the new entry points, across the
certified corpus.

### 5.10 Research button collapse + auto-escalation UX (new task)

**Status: Paper-only. Not built.** Depends on §5.9.

**Why**: today the user picks one of four research modes (`.verify`,
`.extend`, `.discover`, `.all`) before they have any results —
exactly the choice they can't make well because they don't know what
the search will surface.

**What lands**:

- `ResearchMode` collapses to a `StopPolicy` enum with three cases:
  `.firstFact` (replaces `.verify`), `.satisfied` (replaces
  `.extend` / `.discover`), `.exhaustive` (replaces `.all`).
- A single Research button in the UI, replacing the mode picker.
  Default stop policy is `.satisfied`.
- A **default four-level expansiveness ladder** for whole-profile
  research:

  | Level | Strictness | Scope | Cost | Purpose |
  |---|---|---|---|---|
  | 1 | strict | district | 1× | Cheapest; lands if existing data is right |
  | 2 | loose | district | ~2× | Same location, spelling tolerance |
  | 3 | loose | county | ~10× | Widen location, keep loose match |
  | 4 | variant | adjacent | ~30× | Exhausted: every variant, every nearby district |

  `.national` scope sits **outside** the default ladder as an
  explicit override.

- **Per-kind override**: each `HypothesisKind` defines its own
  expansiveness ladder via `deficitQuery*`.
- A **progress indicator** + interactive **continue** affordance
  between levels.
- The progress indicator must support **pause** and **resume**.

### 5.11 Hypothesis investigation as user action (new task)

**Status: Paper-only. Not built.** Depends on §5.9 + §5.10.

**Why**: today's lead list grows large and overwhelming. Most leads
sit unsifted because the volume exceeds practical triage.

**What lands**:

- A `ResearchPipeline.investigateHypothesis(_:)` entry point. Takes
  a hypothesis ID, dispatches the next deficit-query level,
  increments `attempts`, re-grades.
- **Hypothesis lifecycle state machine** layered over the existing
  `verdict` axis:
  - `active` — UI shows "investigate further" affordance.
  - `exhausted` — `deficitQuery(..., atLevel: attempts + 1, ...) ==
    nil`; UI archives the hypothesis under a collapsible "exhausted"
    section, still revivable.
  - `archived` — user-dismissed; UI hides unless explicitly recalled.
  - `re-promoted` — new evidence flips a previously-exhausted
    hypothesis back to active.
- **UI surface in cluster review**: hypothesis cards showing the
  cluster's candidate identity, current verdict, evidence,
  attempt-count + ladder level, "investigate further" / "archive" /
  "promote to ghost profile" actions.
- **Lookahead UX**: clicking "investigate further" first reveals
  what the next level would do.

### 5.12 Design passes needed (UX surfaces requiring their own specs)

Five user-facing surfaces emerged from the V2 walk-through that are
either underspecified relative to their importance, or that fall out
of the §5.10 / §5.11 reframe. Each deserves its own design pass.

- **5.12.1 Discrepancy review surface** — dedicated review queue,
  sortable by severity, with triage actions.
- **5.12.2 Candidate-comparison UX (the Colin-Holmes case)** —
  structured side-by-side: both candidates' records, family
  contexts, geographic signals, evidence strength.
- **5.12.3 Search transparency — "why didn't we find X?"** —
  surface `searchHistory` and `negative_searches`.
- **5.12.4 Verdict transitions across runs** — `VerdictTransition`
  history field is genuinely powerful and currently invisible.
- **5.12.5 Confidence badge dimensionality** — primary indicator
  (verdict + model-assisted state) with the source-strength axes as
  a secondary, on-hover detail.

### 5.13 Worked example — post-loop trace for Kathleen Wheeldon

A concrete walk-through of the post-loop hypothesis phase
(§5.2 / §3) for one subject. Narrow scope: iteration loop and
pre-research state are taken as given. Subject details correspond to
the real-world discovery test that surfaced the verify-bias gap
documented in §16; the trace shows what each per-kind dispatch
produces and where the gap actually lives.

**Subject:** Kathleen Wheeldon, est. birth window 1922–1924, Bakewell
RD (Derbyshire). Tree state entering post-loop: subject profile
exists, no parent relationships linked, no sibling relationships
linked. Mode: `.discover`.

**State entering the post-loop phase:**

- `evidence_records` populated by the iteration loop. Key hits:
  - FreeBMD birth: *Kathleen Wheeldon, mother's maiden name Keyworth,
    Bakewell 1923 Q3, GRO ref 7b/…* — clustered as the subject's
    birth.
  - FreeCen 1939 register: *Wheeldon household, Bakewell area, head
    George, wife Florence, daughter Kathleen + others* — clustered
    with the FreeBMD birth.
- `result.hypotheses` empty.

**Per-kind dispatch (pipeline calls `HypothesisEngine` per kind, per
Decision 7.10 — no central `runAll`):**

1. **`.subjectIdentity`** — `SubjectIdentityResolver.resolve(subject:,
   state:)` runs against the cluster set.
   - One cluster matches the birth-year window and district.
   - Verdict: **`.supported`**. `isModelAssisted = false`.
   - Identity key: `subjectIdentity:<profileID>`.

2. **`.parentInferred(gender:, surname:)`** — generator walks birth
   records carrying MMN. The FreeBMD birth above contributes both a
   father-surname claim (subject's own surname `Wheeldon`) and a
   mother-surname claim (the MMN `Keyworth`).
   - Two hypotheses emitted:
     - `.parentInferred(gender: .male, surname: "Wheeldon")`
     - `.parentInferred(gender: .female, surname: "Keyworth")`
   - Grader: each is `.supported` — the birth record carries the
     MMN. Both have the birth record's ID in `supportingEvidence`.
   - Neither produces `.contradicted` even though no marriage has
     been found yet — see §4.1 asymmetric verdict-space note.

3. **`.parentMarriage(motherSurname:, fatherSurname:, windowYears:)`**
   — generator walks supported `.parentInferred` pairs (same subject,
   opposite genders). Finds (Wheeldon-male, Keyworth-female). Window:
   `subjectBirthYear − 30 … subjectBirthYear + 1` = `1893 … 1924`.
   - One hypothesis emitted:
     `.parentMarriage(motherSurname: "Keyworth", fatherSurname: "Wheeldon", windowYears: 1893…1924)`.
   - Grader runs `MarriageEnrichmentEngine.match` against state's
     marriage evidence (and dispatches a focused BMD marriage query
     if needed via the kind's level-1 `deficitQuery`).
   - One marriage hit returns: *George Wheeldon × Florence M
     Keyworth, Oct–Dec 1921, Bakewell, GRO ref 7b/1906*.
   - Verdict: **`.supported`**. The marriage record ID joins
     `supportingEvidence`.

4. **Reconciliation step** — pipeline calls
   `HypothesisEngine.reconcileParentMarriages` after both
   `.parentInferred` and `.parentMarriage` have been graded.
   - Walks supported `.parentMarriage` hypotheses; for each, finds
     the two `.parentInferred` hypotheses it cross-references
     (same subject, surnames matching mother/father claim).
   - Appends the marriage record ID onto each parent's
     `supportingEvidence`.
   - Appends one sentence per cross-reference to `reasoning`:
     - On the Wheeldon-male hypothesis: *"given name 'George' from
       .parentMarriage:Keyworth×Wheeldon:1893…1924"*.
     - On the Keyworth-female hypothesis: *"given name 'Florence'
       from .parentMarriage:Keyworth×Wheeldon:1893…1924"*.
   - `isModelAssisted` stays `false` (pure join, no dispatch, no
     model). `isDeterministicallySupported == true` on all three.

5. **`.siblingExists(district:, mmn:, yearWindow:)`** — generator
   gate: *`SubjectIdentityResolver` returned `.resolved` AND both
   parents linked*.
   - First conjunct: ✅ (step 1).
   - Second conjunct: ❌. The mother and father exist only as
     `.supported` hypotheses; no `relationships` rows have been
     written. **Generator skips.** Zero `.siblingExists` hypotheses
     emitted.
   - This is where the verify-bias gap surfaces — the three brothers
     known to exist will not be searched on this run.

**Final state after post-loop:**

| Hypothesis | Verdict | Det.-supported | Notes |
|---|---|---|---|
| `subjectIdentity:<pid>` | `.supported` | yes | one cluster, no ambiguity |
| `parentInferred:male:Wheeldon` | `.supported` | yes | birth-record MMN + marriage cross-ref ("George") |
| `parentInferred:female:Keyworth` | `.supported` | yes | birth-record MMN + marriage cross-ref ("Florence") |
| `parentMarriage:Keyworth×Wheeldon:1893…1924` | `.supported` | yes | BMD marriage Bakewell 1921 Q4 |
| `siblingExists:*` | — | — | not emitted; gate failed (parents not yet linked) |

**What changes on the next run, after the user accepts the parent
proposals:**

- `relationships` gains a mother and father edge for Kathleen. Real
  profile rows exist for George Wheeldon and Florence Keyworth.
- Re-run enters the post-loop phase with the gate's second conjunct
  satisfied.
- `.siblingExists` generator emits one hypothesis per
  `(district, mmn, yearWindow)`: here, one hypothesis for `(Bakewell,
  Keyworth, 1922…1936)` (or however the year window is set by the
  expansiveness ladder).
- Grader dispatches the focused BMD birth query and grades against
  the inference rule. The three brothers ought to land as
  `.supported`.

**What this trace illustrates:**

1. The post-loop phase is *per-kind dispatch*, not a single big
   call. Each kind's `generate` / `grade` runs in its own pass.
2. Reconciliation is the only cross-kind step, and it is a pure
   deterministic join — no dispatch, no model.
3. The `.parentInferred` ↔ `.parentMarriage` cross-reference
   (Decision §5.2.1) is where given-name evidence reaches the parent
   hypotheses; without it, the parent hypotheses would carry only
   surnames.
4. The sibling discovery gap is **structural, not algorithmic**:
   `.siblingExists` requires parents-linked, which requires user
   acceptance, which requires the run-then-review-then-rerun loop.
   Closing this gap would mean either (a) lifting the gate to
   `.supported` parent hypotheses (less safe — accepts unverified
   parents into the sibling search), or (b) chaining a second
   internal post-loop pass after auto-promote of high-confidence
   parents (covered by §14 MCP auto-approval where shipped).

### 5.14 `.subjectSpouseMarriage` — pre-iteration hypothesis for thin placeholders (new task)

**Status: Designed; not yet implemented.** Sliced 0–4 below;
implementation gated on this spec being signed off.

**Why this exists.** The shipped pipeline assumes the subject carries
enough self-identifying signal (typically a given name + a usable
birth-year window) for `SearchDispatcher` to discriminate. When the
subject is a placeholder created during a previous run's
parent-inference — surname only, no given name, parents-of-known-child
ghost — the iteration loop has nothing to anchor on. Observed
2026-05-27 with a `Brooks` placeholder (parent of Tom Brooks): the
loop produced 605 candidate records and 613 leads, none of them
actionable, while the parent-inference layer downstream produced a
confidently nonsensical "Father: Brooks · 560 sources" hypothesis from
surname-only matches. ENGINE_FOUNDATION §Change1's thin-subject
verdict cap correctly held the records at `.lead`; the failure was
upstream, in not having a strategy for thin subjects at all.

**The thesis.** For a thin placeholder subject who has at least one
linked child carrying a known mother's-maiden-name (MMN), the **marriage
index is the right anchor — not the birth index**. The subject's own
birth record is invisible until the given name is known. The subject's
*marriage* record is reachable via the surname pair (subject's surname
× child's MMN), and once found it carries the given name. The
`.parentMarriage` kind already implements exactly this lookup for the
subject's own parents (§4.1, §6.2); `.subjectSpouseMarriage` is the
missing peer — same machinery, anchor shifted forward one generation.

#### 5.14.1 Trigger conditions

The pre-iteration phase fires when **all** of:

1. Subject has a recorded surname (otherwise the marriage query has no
   groom anchor at all).
2. Subject has no given name (`(subject.givenName ?? "").trimmed.isEmpty`).
   The wider `InformationDensity.thin` predicate also catches wide
   birth-year windows, but those aren't this strategy's problem — a
   subject with a given name but a 30-year window is researched by the
   normal iteration loop with cluster splitting. This strategy is
   specifically given-name recovery.
3. Subject has a `profileID` (no profile = nothing to look up children
   for, and no row to write back to).
4. `snapshot.childrenOf(subject.profileID)` is non-empty.
5. At least one of those children yields a usable MMN anchor for the
   subject's spouse. The anchor is resolved per child by reading, in
   order:
   1. The child's `Profile.mothersMaidenName` field (recorded, synced
      from WikiTree / GEDCOM / user entry).
   2. If empty: the child's persisted `scored_records` (from prior
      research runs on the child), filtered for BMD birth records with
      a non-empty `mothersMaidenName`. Requires a new
      `ProjectStore.scoredRecords(forProfileID:)` read path — see
      §5.14.3 below. Accepts both `.fact` and `.lead` verdicts; the
      MMN is a direct index transcription whose reliability doesn't
      depend on geography/family-context gates (mirrors §6.4).
   3. If still empty: fall back to the child's linked father (resp.
      mother) in the tree with a recorded surname, where the linked
      parent is *not* the subject. The linked parent's surname stands
      in for the spouse anchor; the child's MMN is then taken from
      that linked parent's `lastName` if subject is male, or treated
      as unavailable if subject is female (since the linked father's
      surname doesn't encode the wife's maiden).

When any of (1)–(5) fail, the phase is skipped and the iteration loop
runs as today; the UI must surface a thin-subject signal in Triage so
the user understands why no progress was made (see §5.14.6).

#### 5.14.2 Where it sits in the pipeline

`ResearchPipeline.research(subject:config:)` gains one new phase
**before** the iteration loop, plus a **storm-guard short-circuit**
that bypasses the iteration loop entirely when the probe leaves the
subject thin. Full lifecycle:

```
research(subject:config:):
    state = ResearchState(subject: …)
    if triggerConditions hold:
        runSubjectSpouseMarriageFlow(state: &state, snapshot: …, cache: …)
          → may mutate state.subject.givenName
          → may append a .subjectSpouseMarriage hypothesis
          → may emit a pending_facts row (firewall, §5.14.5)
    # STORM-GUARD (slice 5): when the probe ran but the subject is
    # still thin (no name recovered — ambiguous / no-match / gender
    # unresolved), skip the iteration loop AND the post-loop phase.
    # Return early with just the hypothesis row + the marriage records
    # collected during the probe. The Triage banner shows the user the
    # next step.
    if preIterationProbeRan && state.subject.givenName.isEmpty:
        return ResearchResult(hypotheses: preIterationHypotheses, …)
    for iteration in 1…maxIterations: …   (existing §5.1)
    post-loop hypothesis phase            (existing §5.2)
    result assembly
```

The timing is load-bearing. Subject refinement *after* the iteration
loop is too late — the loop would have dispatched against the thin
subject and produced no usable evidence. Refining *before* lets the
loop see a rich subject and do its normal work. This is the only
hypothesis kind that runs pre-iteration; all existing kinds remain
post-loop.

#### 5.14.3 The probe

Modelled directly on `HypothesisEngine+ParentMarriage` (§6.2) — same
two-sided BMD dispatch, same `MarriageEnrichmentEngine.match` reunion.
Differences are in the anchor pair, the year window, and the
recovered-name routing.

- **Surname pair (groom, bride):** **`(child.lastName, child.MMN)`**
  derived per linked child (slice 5 — see refactor note below). The
  generator builds the set of distinct uppercased `(groom, bride)`
  pairs across the children and emits one hypothesis per distinct pair
  (Q3 + Q4 decisions). Children sharing a pair collapse into the same
  hypothesis's `supportingEvidence`. Children with a *different* pair
  (different MMN OR different child surname — step-children) seed a
  separate hypothesis. The window for each hypothesis uses the
  earliest birth year among children sharing its pair. The generator
  also asserts the subject's surname matches one of the pair (case-
  insensitive) — a defensive guard against re-parented anchors.
- **Refactor note (slice 5).** The hypothesis kind's payload is
  `(groomSurname, brideSurname, childYearWindow)` — BMD role labels,
  not `(subject.surname, spouseSurname)`. This correctly handles all
  three storage conventions: male father subject, female mother stored
  under maiden, female mother stored under married (WikiTree
  convention). The subject's role (groom or bride) is decided at
  write-back time by the §5.14.4 gender ladder, not encoded in the
  payload. Before slice 5 the payload was subject-relative, which
  produced a bogus `(Land, Land)` pair for the user's maiden-stored
  `Land` mother placeholder.
- **MMN resolution per child** (Q2 decision — Option B). For each
  linked child, the MMN is resolved by reading in order:
  (i) the child's `Profile.mothersMaidenName` field, then (ii) the
  child's persisted `scored_records` for BMD birth records with a
  non-empty `mothersMaidenName`. Reading another profile's research
  records is a new pipeline access path; it requires
  `ProjectStore.scoredRecords(forProfileID:)` — read-only, no
  firewall implication, ~30 lines plus a test. The provenance of the
  MMN (profile field vs. record-derived) is recorded in the
  hypothesis's `reasoning` so the audit trail is intact.
- **Year window:** `min(child.birthYear) − 30 … min(child.birthYear) + 1`.
  Mirrors `.parentMarriage` and uses the *earliest* child's birth year
  so the marriage must predate every child. The `+1` forgives
  same-quarter overlap between marriage and first-child birth.
- **Dispatch shape:** two FreeBMD marriage queries — groom-indexed
  (`surname=subject.surname, spouseSurname=child.MMN`) and bride-indexed
  (`surname=child.MMN, spouseSurname=subject.surname`) — across the
  window, fanning out across `config.scope`'s districts the same way
  `.parentMarriage`'s level-1 deficit query does.
- **Reunion:** `MarriageEnrichmentEngine.match(grooms:, brides:,
  yearWindow:, expectedGroomSpouseSurname:, expectedBrideSpouseSurname:)`
  — the BMD index writes each marriage twice; the
  `(year, quarter, district, vol, page)` tuple reunites the two sides.

#### 5.14.4 Outcomes

Per-hypothesis grading (one row per distinct MMN per Q3+Q4):

| `match` returns | Verdict | Hypothesis action | Pending fact |
|---|---|---|---|
| `.unique(fGiven, mGiven, fEv, mEv)` | `.supported` | one `.subjectSpouseMarriage` with the two marriage record IDs as `supportingEvidence` | one row per recovered name (write-back decided after cross-hypothesis reconciliation, below) |
| `.ambiguous(candidates)` | `.inconclusive` | one `.subjectSpouseMarriage` with all candidate marriage IDs in `supportingEvidence` | none |
| `.none` | `.contradicted` | one `.subjectSpouseMarriage` with `contradictingEvidence: []` and a "searched and found nothing in window" reasoning | none |

**Cross-hypothesis reconciliation for write-back.** When the generator
emitted hypotheses for multiple distinct MMNs (Q4 case — children
disagree on MMN), the write-back is decided across the resulting
`.supported` rows, not per-row:

- **Zero `.supported`** → no write-back.
- **One `.supported`** → write back the gender-appropriate given name
  from that match.
- **Multiple `.supported` agreeing on the subject's recovered given
  name** (typical remarriage case — same subject, two marriages, same
  person) → write back the agreed name; emit one pending fact citing
  both marriages. Both hypotheses become candidates for a downstream
  `.secondMarriage` (§4.1) — out of scope here but unblocked.
- **Multiple `.supported` disagreeing on the recovered given name**
  → do NOT write back. This is a real contradiction (two different
  people marrying under the same surname pair) — the user must
  resolve via §5.11 / Triage. The hypotheses themselves stay
  `.supported`; only the write-back is suppressed. Reasoning on
  each row records the conflict.

**Gender-appropriate side extraction.** Once gender is resolved (by
the precedence ladder below), the side mapping is mechanical:
- `male` → use `fGiven` (groom).
- `female` → use `mGiven` (bride). Note: under WikiTree's married-
  surname convention (memory: `wikitree_married_surname_convention.md`),
  a female subject's `surname` is the husband's surname, so the *groom*
  in the matched marriage carries `subject.surname` and the *bride* is
  the subject herself, indexed under her maiden surname (= child's
  MMN). The pair still reads `(groom=subject.surname, bride=child.MMN)`
  regardless of subject gender; gender only decides which side's given
  name is the subject's.

**Gender resolution — precedence ladder (Q1 decision).** Subject
gender is resolved at the start of the probe via the first rule that
fires:

1. **Explicit.** `subject.gender ∈ {.male, .female}` → use as given.
   No inference; the user (or WikiTree sync) has decided.
2. **Surname pattern** (per-child signal). Deterministic on a single
   child anchor; if more than one linked child produces a different
   answer, see §5.14.10 child-derived-signal-disagreement row.
   - `subject.surname == child.surname` AND `subject.surname != child.MMN`
     → **male** (paternal surname inheritance — subject is the father).
   - `subject.surname == child.MMN` AND `subject.surname != child.surname`
     → **female** (subject stored under maiden surname — non-WikiTree
     convention, but appears in GEDCOM imports). Note: this branch
     does NOT fire under the standard WikiTree married-surname
     convention, where `subject.surname == child.surname` for mothers
     too.
   - Both surnames match (`subject.surname == child.surname ==
     child.MMN`) → ambiguous (same-surname couple); fall through.
   - Neither matches → fall through.
3. **Topology** (the Q1 Option A inference). Inspect
   `snapshot.parentsOf(child)`:
   - One parent slot held by a profile *other than* the subject, with
     `gender == .male` → subject is **female** (mother slot inferred).
   - One parent slot held by a non-subject profile with `gender == .female`
     → subject is **male**.
   - Both slots empty or both held by the subject → fall through.
4. **Refuse to infer.** Emit the hypothesis as `.inconclusive` with
   both candidate given names in `reasoning`; do not write back to
   `state.subject.givenName`. User disambiguation via §5.11.

The rule that fired must be recorded in the hypothesis's `reasoning`
field so Triage can surface it:
- *"Recovered given name 'John' — gender inferred male from surname
  pattern (Brooks shared with child Tom; MMN Smith differs)."*
- *"Recovered given name 'Mary' — gender inferred female from
  topology (father slot held by linked profile John Brooks)."*
- *"Recovered marriage Brooks × Smith — subject gender unresolved
  (both surnames match child's); open the hypothesis to disambiguate."*

Recording the rule keeps the inference auditable and lets a future
eval-harness pass measure per-rule accuracy.

#### 5.14.5 Write-back contract

Two distinct writes, both required:

1. **In-memory `state.subject.givenName`** — set immediately after
   `.unique` so the iteration loop sees a rich subject. This is the
   load-bearing write; without it the strategy is no better than
   surfacing a hypothesis card.
2. **Firewall-respecting `pending_facts` row** for persistence. The
   recovered given name is genealogical evidence and must flow through
   the Evidence Firewall (§13.1) — not a direct profile write. The
   pending fact carries:
   - `field`: `givenName`
   - `value`: recovered given
   - `source_url` + `source_tier`: from the matched marriage record(s)
   - `supporting_record_ids`: the marriage record IDs
   - `hypothesis_id`: the `.subjectSpouseMarriage` row's stable ID

   **Auto-approval gate — narrow carve-out (Q5 decision — Option B).**
   §14.3 today blocks these pending facts on two independent gates:
   §14.3.4 lists `firstName` in the never-auto-approved set, and
   §14.3.1 requires source tier `.primary` or `.secondary` (FreeBMD is
   `.transcription`). Slice 4 lands an amendment to §14.3.4 carving
   out given names recovered through this specific deterministic path.
   The carve-out qualifies a pending fact for auto-approval iff **all**
   of:
   (i) `hypothesis.verdict == .supported` AND `hypothesis.kind ==
       .subjectSpouseMarriage`,
   (ii) the underlying `MarriageEnrichmentEngine.match` returned
        `.unique` (not `.ambiguous`),
   (iii) the matched marriage's source tier ≥ `.transcription`,
   (iv) the subject's `firstName` was empty *before* the recovery
        (recovery, not correction — identity isn't being reshaped, it's
        being established for the first time).
   The carve-out is intentionally narrow: it does NOT generalise to
   other `firstName` writes, only to those carrying a
   `hypothesis_id` pointing to a `.supported` `.subjectSpouseMarriage`.
   The §14.3.1 tier requirement is also relaxed to `.transcription`
   under this carve-out (since the original gate was set for
   non-BMD-shaped fields).

   **Convergence relaxation under the carve-out.** §14.3.2 normally
   requires ≥ 2 independent lineages (or one lineage + a corroborating
   existing field_source). For a thin-placeholder recovery, the
   profile is empty (no existing field_sources) and the only source
   is FreeBMD — one lineage. Without relaxation the carve-out can
   never fire. We therefore treat the BMD reference-tuple match
   between groom-side and bride-side as **structural convergence
   within the source**: when `MarriageEnrichmentEngine.match` returns
   `.unique`, both sides of the BMD index agreed on the same
   `(year, quarter, district, vol, page)` tuple — a deterministic
   cross-check that the standard lineage-count model doesn't capture.
   For Q4 multi-hypothesis remarriage agreement, the same logic
   applies independently per matched marriage, and the §5.14.4
   reconciliation enforces given-name agreement across them — so
   multi-hypothesis confirmation is *stronger* than single-hypothesis,
   not weaker. The other §14.3 gates (no-dispute, hallucination
   checks, URL verification) continue to apply unchanged.

   Multi-hypothesis remarriage case (Q4): when two `.supported`
   `.subjectSpouseMarriage` hypotheses agree on the recovered given
   name, the §5.14.4 reconciliation emits one pending fact citing both
   marriages; the carve-out gate evaluates that single fact against
   the strongest-tier marriage source.

The hypothesis itself persists via the existing `research_hypotheses`
table (§4.3, no new migration needed).

#### 5.14.6 UX guidance

Triage should make the strategy visible when it fires and clear when
it can't:

- **Strategy fires + unique match:**
  *"Recovered given name 'John' from BMD marriage Brooks × Smith,
  Belper 1882 Q3. Iteration loop will use this."*
- **Strategy fires + ambiguous:**
  *"Found N candidate marriages for Brooks × Smith near 1882; given
  name not auto-set. Open the hypothesis to disambiguate."*
- **Strategy fires + no match:**
  *"Searched marriages Brooks × Smith near 1882; none found. Subject
  remains thin — manual research needed."*
- **Strategy can't fire (no surname, no child, no MMN anchor):**
  *"This profile is too thin to research effectively. Add a given
  name in the profile editor, or link a child whose mother's-maiden-
  name is known."*

In all four cases the iteration loop still runs; the strategy is
*additive*, never replacing the existing dispatch path. UX wording
above is normative for §5.10 (Research-button collapse) — the strings
appear in the collapsed-research summary.

#### 5.14.7 Proposed `HypothesisKind` shape

Adds one closed-enum case in §4.1:

```swift
case subjectSpouseMarriage(
    subjectSurname: String,
    spouseSurname: String,
    childYearWindow: ClosedRange<Int>
)
```

…and a discriminator + `identityKey` clause in `ResearchHypothesis.swift`:

```swift
// discriminator
case .subjectSpouseMarriage: return "subjectSpouseMarriage"

// identityKey
case .subjectSpouseMarriage(let sub, let spouse, let window):
    return "subjectSpouseMarriage:\(subjectProfileID ?? "tree"):\(sub.uppercased())x\(spouse.uppercased()):\(window.lowerBound)-\(window.upperBound)"
```

Plus a new extension file `HypothesisEngine+SubjectSpouseMarriage.swift`
holding `generateSubjectSpouseMarriage` / `gradeSubjectSpouseMarriage` /
`deficitQuerySubjectSpouseMarriage`, and clauses in the three central
switches in `HypothesisEngine.swift`. The `runSubjectSpouseMarriageFlow`
orchestrator on `ResearchPipeline` is the pre-iteration analogue of
`runParentHypothesisFlow`. Closed-enum / three-switch invariants (§4.2)
unchanged.

#### 5.14.8 Decision rights

Fully deterministic. No MLX involvement. `isModelAssisted: false` on
every emitted hypothesis. The match is index-tuple equality
(`MarriageEnrichmentEngine.match`), the write-back is name extraction
from a structured marriage record. The deterministic-wins rule (§3.3)
applies without exception.

#### 5.14.9 Expansiveness ladder

Initial proposal:

- **Level 1** — original window (`min(child.birthYear) − 30 … + 1`),
  groom-side + bride-side dispatch as above. The first-pass dispatch
  sets `attempts: 1`.
- **Level 2** — widen window by ±10 years on each side (mirrors
  `.parentMarriage` level 2). Picks up marriages outside the typical
  parent-age range.
- **Level ≥ 3** — `nil`; ladder exhausted. T31 (§5.7) revisits the
  ceiling once the eval harness gives us a unique-match-rate baseline.

#### 5.14.10 Edge cases the spec must cover

| Case | Behaviour |
|---|---|
| Subject has surname but `gender == .unknown` AND none of the precedence-ladder rules 2/3 fire | Strategy fires; recovers both given names; emits `.inconclusive` with both in reasoning; **does not write back** to subject |
| Subject has surname but `gender == .unknown` AND surname-pattern rule (§5.14.4 ladder rule 2) resolves cleanly | Subject gender inferred; write back the gender-appropriate side; reasoning records the rule |
| Children disagree on MMN (different mothers / transcriber drift / mis-linked child) | Strategy fires; emits one `.subjectSpouseMarriage` per distinct MMN (Q3+Q4 — Option A+B). Both `.unique` → remarriage candidate (user accepts both, downstream `.secondMarriage` work). One `.unique` + one `.none` → the `.none` MMN is likely transcriber drift or mis-linked; user resolves. Both `.none` → neither marriage attested in window; subject remains thin |
| Children disagree on the surname-pattern gender signal (child A → subject is father, child B → subject is mother) | Strategy does not fire on the surname-pattern rule; falls through to topology (ladder rule 3); if topology also doesn't decide, fall to refuse (ladder rule 4) |
| Single child but child's own MMN is missing AND child has no linked father | Strategy does not fire — no anchor |
| Child has linked father whose surname differs from subject.surname (subject is the mother) | Subject is female by tree topology — see §5.14.4 ladder rule 3 |
| Multiple `.unique` candidates after window expansion (level 2 returns a different unique match than level 1) | Treat as ambiguous overall; the level-2 attempt cannot override a level-1 `.supported` |
| Subject already has a given name AND a wide birth window (so `InformationDensity == .thin` for the window reason) | Strategy does NOT fire — out of scope; handled by clustering today |
| Subject has been researched previously and the hypothesis is `.user_rejected` | Strategy does not fire; respect persisted rejection (§4.3) |

#### 5.14.11 Slicing plan

Sized **L** end-to-end. Implementation order, each slice mergeable
in isolation:

- **Slice 0 — Spec (this section).** No code. Acceptance: user signs
  off on the design or asks for amendments.
- **Slice 1 — Detection + probe + match.** Add `HypothesisKind` case;
  add identityKey clause; add three central-switch clauses; ship
  `HypothesisEngine+SubjectSpouseMarriage.swift` with generator +
  grader + deficitQuery. Wire `runSubjectSpouseMarriageFlow` into
  `ResearchPipeline.research()` *before* the iteration loop. Add
  `ProjectStore.scoredRecords(forProfileID:)` read path (Q2 decision —
  reads the child's persisted research records to recover MMN when
  the profile field is empty). Per-rule gender resolution per
  §5.14.4 ladder, recorded in `reasoning`. **Does not yet write back**
  — subject stays thin; the loop still produces nothing on a thin
  placeholder. This slice is observable purely via the hypothesis
  row.
- **Slice 2 — Write-back.** Mutate `state.subject.givenName` on
  `.unique`; emit the `pending_facts` row through `ProjectStore`
  (firewall-respecting). After this slice, a thin Brooks placeholder
  with a Tom-Brooks child and known MMN produces a rich John-Brooks
  iteration on the next run.
- **Slice 3 — UX.** Triage surfaces (§5.14.6) wired through the
  research result and the Research-button collapse summary (§5.10);
  hypothesis card in cluster review showing the matched marriage.
- **Slice 4 — Tests + §14.3.4 carve-out.** Unit tests for: trigger
  predicate (all branches of §5.14.1); generator per-distinct-MMN +
  same-MMN dedup (Q3+Q4); grader outcomes (`.unique` / `.ambiguous` /
  `.none`); cross-hypothesis reconciliation (Q4 four cases); gender
  precedence ladder (Q1 — all four rules); MMN provenance fallback
  (Q2 — profile field → scored_records); write-back idempotence
  (re-running doesn't duplicate pending facts); rejection
  persistence. Lands the §14.3.4 amendment in the same slice (Q5 —
  Option B): narrow carve-out for `firstName` pending facts carrying a
  `hypothesis_id` pointing to a `.supported` `.unique`
  `.subjectSpouseMarriage`, tier ≥ `.transcription`, subject
  `firstName` empty pre-recovery. Carve-out tests cover: positive
  case (all four conditions met → auto-approves); each condition
  failing in isolation (still routes to human review); multi-
  hypothesis remarriage case (Q4 — two agreeing `.supported` rows →
  single pending fact gated on strongest tier).

Slice ordering is **not** flexible: slice 1 lands the data shape that
slices 2–4 build on; slice 2 produces the observable behaviour change
the user requested; slice 3 surfaces it; slice 4 locks it.

#### 5.14.12 Out of scope

- Bug A (parent-inference grader counting surname-only matches as
  supporting evidence) is separate, S-sized, and tracked outside this
  amendment. It should ship alongside slice 2 so the bogus
  "Father: Brooks · 560 sources" card is fixed even when this
  strategy can't fire.
- Bug C (Triage gives no signal at all when subject is thin) is also
  separate and S-sized; it should ship as part of slice 3 since the
  wiring overlaps.
- Re-running this strategy across the *whole tree* (sweeping all
  thin-placeholder profiles in one batch) is a §5.10 concern, not
  this section's.

#### 5.14.13 Design decisions

All five resolved 2026-05-27 before slice 1. Each item below records
the decision and where it was folded into the sub-sections above.

---

**Q1 — Gender inference: DECIDED.**

Resolved 2026-05-27. Folded into §5.14.4 as a four-rule precedence
ladder: explicit > surname-pattern > topology > refuse. Each rule is
deterministic and the rule that fired is recorded in the hypothesis's
`reasoning` field so Triage can surface it and a future eval-harness
pass can measure per-rule accuracy.

Surname-pattern (rule 2) is the strongest everyday signal — when the
subject's surname matches the child's surname and differs from the
child's MMN, the subject is the father; the symmetric case identifies
the mother. Topology (rule 3) covers cases where surname-pattern is
ambiguous (same-surname couple) or absent (subject.surname differs
from both). Refuse (rule 4) is the floor — never write back when
nothing resolves.

See §5.14.4 for the full ladder and §5.14.10 for the cross-child
disagreement behaviour.

---

**Q2 — Source of the child's MMN: DECIDED.**

Resolved 2026-05-27. Option B chosen: MMN is resolved per child by
reading `Profile.mothersMaidenName` first, falling back to the child's
persisted `scored_records` (BMD birth records with non-empty MMN)
when the profile field is empty. Catches the "child researched but
findings still in `pending_facts`" gap that Option A would have lost.

Implementation cost is contained: ~30 lines for
`ProjectStore.scoredRecords(forProfileID:)`, a read-only access path
with no firewall implication. The pipeline doesn't write to other
profiles' state; it only reads. Provenance (profile field vs.
record-derived) is recorded in the hypothesis's `reasoning`.

Folded into §5.14.1 clause 5 (trigger predicate), §5.14.3 (MMN
resolution per child), and §5.14.11 slice 1 (read path added).

---

**Q3 — Multiple children with the same MMN: DECIDED.**

Resolved 2026-05-27. Option A chosen: one canonical
`.subjectSpouseMarriage(Brooks, Smith, window)` per distinct MMN, with
all children listed in `supportingEvidence`. Dedup-at-generation
mirrors `HypothesisEngine+ParentMarriage`'s pattern
(`HypothesisEngine+ParentMarriage.swift:110–115`) and keeps
`supportingEvidence` semantically meaningful — these N children all
anchor the same marriage hypothesis.

Slice 1 generator: build the set of distinct uppercased MMNs from
the linked children's anchors (per §5.14.1 clause 5), emit one
hypothesis per distinct MMN, attach every child whose MMN matches the
canonical key to that hypothesis's `supportingEvidence`. The window
uses the *earliest* child's birth year across all children sharing
that MMN.

---

**Q4 — Children disagree on MMN: DECIDED.**

Resolved 2026-05-27. Option B chosen: when children carry different
MMNs, the generator emits one `.subjectSpouseMarriage` per distinct
MMN (Tom Brooks → Brooks × Smith, Sarah Brooks → Brooks × Jones)
and lets the BMD evidence sort it out. The four outcome cases:

- **Both `.unique`, same recovered given name** → genuine remarriage.
  Write back the agreed name; both hypotheses become candidates for a
  downstream `.secondMarriage` (§4.1).
- **Both `.unique`, different recovered given names** → real
  contradiction (two different people). Don't write back; user
  resolves via §5.11.
- **One `.unique` + one `.none`** → the `.none` MMN is likely
  transcriber drift or a mis-linked child. The `.unique` one drives
  write-back per the single-supported case.
- **Both `.none`** → neither marriage attested in window; subject
  stays thin.

This decision falls out of Q3's "one canonical hypothesis per distinct
MMN" naturally — no extra generator branch needed, no new
`ResearchDiscrepancy` shape, no skip-on-disagreement gate. The
trade-off is that we surface evidence to the user instead of
blocking on a tree-level disagreement; the four-case reconciliation in
§5.14.4 keeps write-back safe in the disagreement subcases.

Folded into §5.14.3 (generator per-distinct-MMN), §5.14.4
(cross-hypothesis reconciliation for write-back), and §5.14.10
(edge-case table updated).

---

**Q5 — Auto-approval of the recovered given name: DECIDED.**

Resolved 2026-05-27. Option B chosen: amend §14.3.4 alongside slice 4
with a narrow carve-out for given names recovered through a
`.supported` `.unique` `.subjectSpouseMarriage`. Closes the
per-placeholder friction loop while keeping the firewall's
identity-shaping protection on every other `firstName` path intact.

Carve-out conditions (all four required):
(i) `hypothesis.verdict == .supported` AND
    `hypothesis.kind == .subjectSpouseMarriage`,
(ii) the underlying `MarriageEnrichmentEngine.match` returned
     `.unique`,
(iii) the matched marriage's source tier ≥ `.transcription`,
(iv) subject's `firstName` was empty *before* the recovery (recovery,
     not correction).

All other §14.3 gates (convergence, no-dispute, hallucination checks)
continue to apply unchanged. The §14.3.1 tier requirement is also
relaxed to `.transcription` under this carve-out (the original
`.primary`/`.secondary` requirement targeted non-BMD-shaped fields).

Multi-hypothesis remarriage case (Q4): when two `.supported` rows
agree on the recovered given name, the §5.14.4 reconciliation emits
one pending fact citing both marriages; the carve-out evaluates against
the strongest-tier marriage source.

The carve-out is intentionally narrow: it does NOT generalise to
other `firstName` writes — only those carrying a `hypothesis_id`
pointing to a `.supported` `.subjectSpouseMarriage`. Folded into
§5.14.5 (write-back contract) and §5.14.11 slice 4 (carve-out lands
with the test slice, gated on the slice 2 behavioural shift being
observable in eval first).

### 5.15 `.parentCandidates` — user-seeded hypotheses (Epic 13, new task)

**Status: Accepted 2026-07-11 (Darryl) — buildable per the §5.15.12 slicing plan.** Roadmap Epic 13
(2026-07-05 agentic-harness discussion). Sliced 0–5 below;
implementation gated on this entry being signed off.

**Why this exists.** Canonical scenario: the user says *"I think
George Wheeldon's parents might have been called Bob & Sue."* Today
that hunch has no structured home. Workbench notes hold prose the
engine never reads; the only executable encoding is tentative
placeholder parents (§5.15.9), which plants unproven identities in
the tree to make the engine notice them. This section makes the
hunch a first-class `ResearchHypothesis` that steers targeted probes
— parent-marriage index searches, mother's-maiden-name birth axes,
census household matching — through the standard verdict lifecycle,
without the hunch itself ever touching the tree.

**Doctrine — a hunch is a search directive, never data.**
Non-negotiable, and the reason this feature is safe to build:

1. **Invisible to the tree.** A seeded hypothesis creates no
   profile, no edge, no field, no citation. Nothing reaches the
   tree until real records survive the 4-gate scorer, clustering,
   and the normal accept path (Part I §13.2) — identical to
   engine-generated hypotheses.
2. **Biases WHERE, never WHAT.** The hunch adds focused queries to
   the dispatch plan. Scoring, verdicts, clustering, convergence,
   and auto-promote are untouched. The deterministic sandwich
   (Part I §3.3) applies without exception; `isModelAssisted:
   false` on every path in phases (a) and (b).
3. **Distinct from family testimony.** "Aunt Vera wrote that his
   parents were Bob & Sue" is *evidence* — a citable source that
   enters through the review queue with a trust tier. A hunch is
   *not evidence* and never acquires a tier; it is a question the
   user wants asked. The two must not share a pipe.
4. **Refutable, and refutation is remembered.** Standard verdict
   lifecycle (`.supported` / `.contradicted` / `.inconclusive`)
   with `attempts` accounting, verdict history, and persisted
   user-rejection (§4.3). Rejection memory (Part I §18.7) is
   honoured: a hunch cannot resurrect records the user discarded.

#### 5.15.1 Kind shape (Decision E1)

One **specific typed kind** plus an orthogonal **provenance field**
— not a generic `.userSeeded` case:

```swift
case parentCandidates(
    fatherGiven: String?,
    fatherSurname: String?,
    motherGiven: String?,
    motherMaidenSurname: String?,
    marriageWindow: ClosedRange<Int>
)

// discriminator
case .parentCandidates: return "parentCandidates"

// identityKey (nil hints normalise to "")
case .parentCandidates(let fg, let fs, let mg, let mms, let w):
    return "parentCandidates:\(subject):\(fg?.uppercased() ?? "")x\(fs?.uppercased() ?? "")x\(mg?.uppercased() ?? "")x\(mms?.uppercased() ?? ""):\(w.lowerBound)-\(w.upperBound)"
```

…and one new field on `ResearchHypothesis` (all kinds):

```swift
/// Who asserted this hypothesis. `.engine` (default) for rows the
/// generate switches produce; `.user` for seeded hunches. The
/// engine's regeneration cycle never creates, deletes, or reshapes
/// `.user` rows — only re-grades them. Only the user dismisses one.
public enum Origin: String, Sendable, Codable { case engine, user }
public let origin: Origin
```

**Why not one generic `.userSeeded(claim: String, axes: [String:
String])`?** Every property of the shipped framework argues against
it:

- **Decision 1 (§7.1) is the closed enum.** The three central
  switches are exhaustive over typed payloads; a generic case would
  smuggle a fourth, stringly-typed inner dispatch on dictionary
  contents — runtime parsing where the framework promises
  compile-time completeness.
- **`identityKey` needs deterministic composition.** Typed payloads
  compose keys for free; an open dictionary needs ordering and
  normalisation rules to avoid duplicate hypotheses for the same
  hunch.
- **Graders and deficit ladders are per-shape anyway.** A parent
  hunch drives marriage/MMN/census probes; a burial hunch would
  drive parish probes. A generic kind saves nothing — the per-shape
  logic still has to exist, minus type safety.
- **Malformed external input must not reach the engine.** A typed
  payload is constructed in-process after validation (§5.15.2); a
  bag of strings pushes parsing into the grader.

The genuinely generic aspect — *who asserted it* — factors into
`origin`, which every future user-seedable kind (burial place,
second marriage, emigration) reuses unchanged. New hunch shapes
arrive as new typed kinds via the normal Decision 1 path.

Payload semantics: hints record **exactly what the user asserted** —
nothing is defaulted into the payload. At least one of the four
name hints must be non-empty (validated at intake). Effective
values are resolved at probe time (e.g. groom surname =
`fatherSurname ?? subject.lastName` under the paternal-naming
convention) and the resolution is recorded in `reasoning`.
`marriageWindow` defaults at intake to `subjectBirthYear − 30 …
subjectBirthYear + 1` (mirrors `.parentMarriage` and §5.14.3); the
user may narrow it.

#### 5.15.2 Seed intake and validation

External surfaces never write `research_hypotheses` directly — that
table is engine-owned (generate/grade/upsert switches, §4.2–§4.3),
and an external writer racing pipeline upserts is the class of bug
the firewall exists to prevent. Instead, intake mirrors the
sanctioned `research_run_requests` orchestration pattern (v24,
`kick_off_research`):

Migration `v32_user_hypothesis_seeds`:

```sql
CREATE TABLE user_hypothesis_seeds (
    id TEXT PRIMARY KEY,                -- seed_<uuid>
    profile_id TEXT NOT NULL,
    kind_discriminator TEXT NOT NULL,   -- 'parentCandidates' only, this epic
    payload TEXT NOT NULL,              -- JSON name hints + optional window
    status TEXT NOT NULL DEFAULT 'queued', -- queued | materialised | refused
    refusal_reason TEXT,
    hypothesis_id TEXT,                 -- set on materialisation
    requested_by TEXT NOT NULL,         -- 'mcp' | 'workbench'
    created_at DATETIME NOT NULL,
    FOREIGN KEY (profile_id) REFERENCES profiles(id)
);
ALTER TABLE research_hypotheses
    ADD COLUMN origin TEXT NOT NULL DEFAULT 'engine';
```

The app-side request watcher (the same one servicing
`research_run_requests`) materialises queued seeds: constructs the
typed payload, computes the `identityKey`, and upserts one
`research_hypotheses` row with `origin = 'user'`, `verdict =
inconclusive`, `attempts = 0`. Re-seeding identical hints collides
on `identityKey` and upserts — no duplicates.

**Validation (refuse with a reason, write nothing):**

- all four name hints empty → `no_name_hints`;
- `profile_id` unknown → `profile_not_found`;
- no derivable marriage window (subject has no usable birth-year
  estimate and none supplied) → `no_subject_birth_estimate`;
- the matching hypothesis row exists with `user_rejected = 1` →
  `previously_rejected` (the user dismissed this exact hunch;
  re-seeding must be a deliberate un-reject, not a silent revival).

If the tree already holds a *confirmed* parent whose given name
conflicts with a hint beyond nickname equivalence, the seed is
accepted but materialised straight to `.contradicted` (§5.15.4) —
the user learns immediately rather than after a wasted run.

#### 5.15.3 The probes — per-kind deficit ladder

All probes ride existing machinery; nothing here invents a new
dispatch path. Storm guards (Part I §11.2) apply unchanged.

- **Level 1 — parent-marriage index probe.** Groom-side FreeBMD
  marriage query: surname = `fatherSurname ?? subject.lastName`,
  given-name filter `fatherGiven` expanded through the nickname
  table (Part I §18.7 — "Bob" matches "Robert"). When
  `motherMaidenSurname` is known, bride-side query + reference-tuple
  reunion via `MarriageEnrichmentEngine.match` (Part I §6.2), exactly
  as `.parentMarriage` level 1. When unknown, groom-side only; the
  bride's maiden surname is recovered from the post-1912
  `spouseSurname` column or pre-1912 same-page-couple pairing
  (Part I §11.5), then her given name is checked against
  `motherGiven`. Window = payload window; district fan-out per
  `config.scope`.
- **Level 2 — MMN linkage probe.** Re-dispatch the *subject's own*
  birth-index search with the mothers-maiden-name axis set to
  `motherMaidenSurname ??` (bride maiden recovered at level 1).
  Rides the Part I §11.4 `.birth` focus shape. This is the probe
  that turns "the couple existed" into "the couple are the
  subject's parents."
- **Level 3 — census household probe.** Census years where the
  subject is aged 0–15; match households (Part I §18.8) containing
  the subject as child with head given name ≈ `fatherGiven` and
  spouse given name ≈ `motherGiven` (nickname-expanded), surname =
  subject's.
- **Level ≥ 4 — `nil`; ladder exhausted.** Archive per §5.11.

**T7 gate carve-out (Decision E4).** The two-condition stall gate
(§7.4) exists to stop the engine burning queries on its own
speculations. A user directive is not speculation: in the post-loop
phase, `origin == .user` rows with `attempts == 0` are dispatched at
level 1 **unconditionally** — the user asked. Subsequent levels ride
the normal T7 stall gate and the §5.11 "investigate further"
gesture, both incrementing `attempts` as standard.

#### 5.15.4 Grading (Decision E5 — supported requires linkage)

A unique Bob × Sue marriage proves the *couple* existed — not that
they are George's parents. `.supported` therefore requires the full
deterministic linkage chain, not mere couple attestation:

| Evidence state | Verdict |
|---|---|
| Marriage match `.unique` for the hinted pair (given names agreeing via nickname equivalence) **AND** subject linkage: subject's birth record carries MMN = the matched bride's maiden surname, OR a census household contains the subject as child of the hinted couple | `.supported` — marriage + linkage record IDs in `supportingEvidence` |
| Marriage match `.unique` but no linkage evidence yet | `.inconclusive` — reasoning: "couple attested; parental link unproven"; levels 2–3 target the link |
| Subject's identity-resolved birth record carries an MMN conflicting with a non-nil `motherMaidenSurname` hint | `.contradicted` — reasoning names both values + record ID |
| Tree already holds a confirmed (field_sources-backed) parent whose given name conflicts with a hint beyond nickname equivalence | `.contradicted` — `contradictingEvidence` cites the edge |
| No marriage / no linkage found in window | `.inconclusive` — **never** `.contradicted` (asymmetric verdict space, §4.1: the record may sit outside the searched window) |

Grading is a pure function over evidence, per-kind grader in
`HypothesisEngine+ParentCandidates.swift`. No MLX involvement;
`isModelAssisted: false` always in phases (a)/(b).

#### 5.15.5 What reaches the tree

Nothing, from the hypothesis itself. Records the probes surface
flow through the normal machinery: scorer → `.parentInferred` /
`.parentMarriage` flows → `ProposedRelative` → the standard accept
path. Pending facts arising from these probes face the **unmodified**
Part I §14.3 auto-approval gates — this section adds no carve-outs
(contrast §5.14.5, which needed one; a hunch never does, because a
hunch asserts nothing). The acceptance test for this is a DB diff:
seed + probe + grade must produce zero writes to `profiles`,
`relationships`, `life_events`, or `citations`.

#### 5.15.6 Rejection memory

- `record_rejections` (Part I §18.7) filters probe results before
  scoring, as everywhere. A hunch cannot resurface the wrong Thomas
  Land the user already discarded.
- `user_rejected = 1` on the hypothesis row (§4.3) stops
  regeneration *and* dispatch: the generate switch skips rejected
  seeds, and no deficit level is ever dispatched for a rejected
  row. Intake refuses matching re-seeds (§5.15.2).
- User discards of individual records during review persist across
  runs and re-probes, per the existing contract.

#### 5.15.7 Entry surfaces — three phases, in arrival order

**Phase (a) — MCP (Decision E2).** New tool:

```
submit_hypothesis
  profile_id                        (required)
  kind: "parent_candidates"         (required; only value this epic)
  father_given, father_surname,
  mother_given, mother_maiden_surname  (each optional; ≥ 1 required)
  marriage_window_start / _end      (optional; derived when absent)
→ validates synchronously (read-only checks per §5.15.2),
  INSERTs one user_hypothesis_seeds row, returns seed_id
→ refuses with a structured reason code on validation failure
```

Reads: `profiles` (existence, birth estimate), `research_hypotheses`
(rejection check). Writes: `user_hypothesis_seeds` **only**. The
firewall doctrine (Part I §13.1, §14.2) is intact: evidence writes
remain `pending_facts` + `leads`; a hunch row is orchestration, the
same tier as `research_run_requests`.

*Why a new tool and not a parameter on `kick_off_research`:*
seeding ≠ running — hunches accumulate between runs, several can
target one profile, and a seed's lifecycle (persists, re-grades
across runs) outlives any single run request. Overloading the run
queue would smuggle a second lifecycle through a table whose rows
complete and die. The harness flow stays two calls:
`submit_hypothesis` → `kick_off_research`. Phase (b) shares the
seeds table with no MCP involvement.

**Phase (b) — Workbench UI.** "Add a hunch" affordance on the
profile's research surface: four hint fields + optional window;
writes the same seeds table (`requested_by = 'workbench'`).
Hypothesis card in Triage/cluster review shows verdict, history,
attempts/ladder level, investigate / dismiss actions — the §5.11
surface, no new card type.

**Phase (c) — natural-language intake (out of scope; pointer
only).** The local MLX model parses "I think his parents were Bob &
Sue" into a seed payload. This is input parsing, not verdict work —
grading stays deterministic — but it is model-assisted intake and
deserves its own design pass alongside T9's threshold discipline
(§5.5.1). It consumes the seeds table unchanged.

#### 5.15.8 Refuted and exhausted hunches — UX

The user explicitly asked a question; the answer must not be
buried:

- `.contradicted` user hypotheses sort to the **top** of the Triage
  hypothesis list, with reasoning naming the conflicting values
  ("hunch says mother maiden *Sue …*; birth index MMN says
  *Jones*") and linking the contradicting records.
- The research-complete summary includes one line per user
  hypothesis whose verdict changed this run ("Your hunch about
  George Wheeldon's parents: contradicted").
- Exhausted rows (`deficitQuery == nil` at `attempts + 1`) archive
  under the §5.11 collapsible section — revivable, never deleted.
- Dismissal flips `user_rejected = 1`; the verdict history
  (`VerdictTransition` trail) is retained for audit. A tested-and-
  failed hunch is a research result worth keeping.

#### 5.15.9 The interim path that works today (document, don't build)

Add tentative placeholder parents "Bob Wheeldon" / "Sue Wheeldon" to
the tree. The familyContext gate and the parent-marriage machinery
(Part I §6.2, §5.14) exploit them; evidence upgrades or contradicts
them. This works now with zero code. The feature is still worth
building over it because:

1. **Placeholder pollution.** Placeholders are real `profiles` rows
   — visible in the tree, the viewers, and publish snapshots; a
   wrong one needs manual deletion and drags edges with it.
2. **No verdict lifecycle.** A placeholder cannot be
   `.contradicted`; it just sits there looking like a person.
3. **Refutation isn't first-class.** Deleting a failed placeholder
   erases the memory that the hunch was tested and failed;
   `user_rejected` + history keep it, and rejection memory stops it
   silently returning.
4. **Partial hints aren't honestly encodable.** "Sue, maiden
   surname unknown" forced into a "Sue Wheeldon" profile asserts a
   surname the hunch never claimed. The typed payload holds exactly
   the claim, no more.

#### 5.15.10 Relationship to T9 (Decision E3 — not folded)

The roadmap floated folding Epic 13 into T9. **Rejected.** T9
(§5.5) is the MLX free-text disambiguation pass: model-assisted,
fires only after the rules return `.ambiguous`, paper-only, and
blocked on the §5.8 harness threshold policy (§5.5.1). Epic 13 is
deterministic end-to-end once seeded, rides shipped rails (T11
persistence, T12 switches, T7 deficit dispatch, §5.14 marriage
machinery), and is independently shippable now. Folding would chain
a buildable deterministic feature to an unbuilt model feature for
no shared code. (The roadmap's "hypothesis-driven planning" gloss
better describes T7/T8 — both shipped.)

The genuine kinship is phase (c) only: parsing free text into a
typed seed is model work, and whatever T9-adjacent pass eventually
builds it adopts this section's seeds table and `origin` provenance
unchanged. That forward-compatibility is deliberate design, not
coupling.

#### 5.15.11 Acceptance criteria

1. `submit_hypothesis` with valid hints → one `user_hypothesis_seeds`
   row; after watcher materialisation, exactly one
   `research_hypotheses` row with `origin = 'user'`, discriminator
   `parentCandidates`, `verdict = inconclusive`, `attempts = 0`,
   `isModelAssisted = false`.
2. Re-submitting identical hints upserts on `identityKey` — no
   duplicate hypothesis rows.
3. All-nil hints, unknown `profile_id`, underivable window, or
   previously-rejected hunch → structured refusal; zero rows
   written.
4. The next research run on the subject dispatches the level-1
   probe regardless of T7's stall conditions; `searchHistory`
   records it; storm guards still bound total dispatch.
5. Marriage `.unique` + MMN/census linkage → `.supported` citing
   both record sets; marriage-only → `.inconclusive` with
   linkage-unproven reasoning.
6. MMN conflict (or confirmed-parent given-name conflict) →
   `.contradicted`, reasoning naming both values.
7. DB diff across seed + probe + grade shows zero writes to
   `profiles`, `relationships`, `life_events`, `citations`. Parent
   proposals reach the tree only via the standard accept path.
8. Hint "Bob" matches recovered "Robert" via the nickname /
   `name_equivalences` tables (Part I §18.7).
9. `record_rejections` filtering applies to probe results;
   `user_rejected = 1` → no regeneration, no dispatch, intake
   refusal on re-seed.
10. Ladder exhaustion (level 4 → `nil`) archives the row per §5.11
    with `attempts == 3`; verdict history preserved on dismissal.
11. Pending facts arising from these probes face unmodified
    Part I §14.3 gates — no new auto-approval carve-out exists in
    the diff.

#### 5.15.12 Slicing plan

Sized **M** end-to-end (roadmap concurs). Order fixed: 1 → 2 → 3 →
{4, 5}; MCP (slice 3) lands before Workbench (slice 4) per the
arrival-order doctrine in §5.15.7.

- **Slice 0 — Spec (this section).** No code. Acceptance: sign-off
  or amendments.
- **Slice 1 [S] — Types + migration.** v32 (seeds table + `origin`
  column); `.parentCandidates` case, discriminator, `identityKey`,
  Codable round-trip + persistence tests in AncestorKit.
- **Slice 2 [M] — Engine.** `HypothesisEngine+ParentCandidates.swift`
  (generator reads seeds; grader per §5.15.4; deficit levels 1–3);
  clauses in the three central switches; pipeline wiring including
  the T7 carve-out for `origin == .user` rows and the
  regeneration exemption.
- **Slice 3 [S] — MCP.** `submit_hypothesis` tool + synchronous
  validation + watcher materialisation + refusal reason codes.
- **Slice 4 [M] — UX.** Workbench "Add a hunch" form; Triage
  hypothesis card wiring (verdict, history, investigate, dismiss);
  refuted-hunch prominence; research-summary line.
- **Slice 5 [S] — End-to-end tests.** Acceptance criteria 1–11,
  including the DB-diff no-tree-write assertion.

#### 5.15.13 Non-goals / out of scope

- Natural-language hunch parsing (phase c) — pointer only, §5.15.7.
- A generic free-text `.userSeeded` kind — rejected, §5.15.1.
- Other hunch shapes (burial place, second marriage, death abroad)
  — future typed kinds; `origin` and the seeds table already
  accommodate them.
- Family-testimony ingestion — evidence, not directive; enters as a
  citable source through the review queue (doctrine item 3).
- Any change to §14.3 auto-approval gates.
- Whole-tree hunch sweeps or batch seeding.
- Editing a seed in place — dismiss and re-seed instead (identity
  keys make edits ambiguous).

#### 5.15.14 Proposed decisions log

To be resolved at review; each mirrors the §5.14.13 pattern.

- **E1 — Kind naming: specific `.parentCandidates` + `origin`
  provenance field**, not a generic `.userSeeded` payload case.
  Preserves Decision 1's closed enum, typed payloads, and
  deterministic `identityKey` composition; provenance factors into
  an orthogonal, reusable field. (§5.15.1)
- **E2 — MCP shape: new `submit_hypothesis` tool writing a
  `user_hypothesis_seeds` staging table**, not a `kick_off_research`
  parameter and not a direct `research_hypotheses` write. Seeding
  and running are different lifecycles; the engine keeps sole
  ownership of its table; the firewall's evidence-write set is
  untouched. (§5.15.2, §5.15.7)
- **E3 — Not folded into T9.** Deterministic, independently
  shippable slice on shipped rails; T9 is unbuilt, model-assisted,
  and threshold-blocked. Phase (c) is the only junction, and it
  adopts this design unchanged. (§5.15.10)
- **E4 — T7 stall-gate carve-out.** `origin == .user` rows get one
  unconditional level-1 dispatch (`attempts == 0`) in the post-loop
  phase; later levels ride the normal gate. The stall gate guards
  against engine speculation; a user directive isn't speculation.
  (§5.15.3)
- **E5 — `.supported` requires the linkage chain.** Couple
  attestation alone is `.inconclusive`; supported needs marriage
  match + subject linkage (MMN or census household). Prevents the
  hunch's own confirmation bias from inflating verdicts. (§5.15.4)

---

## 6. Holistic architecture (post-V2)

```
┌─────────────────────────────────────────────────────────────────────────┐
│  ResearchPipeline.research(subject:, config:)                           │
│                                                                          │
│  PASS 1 (deterministic iterative core):                                 │
│    1. dispatch  →  score  →  dedup                                      │
│    2. extract household / detect discrepancies / refine subject         │
│    3. (between iterations) ResearchInterpreter.suggestNextSearch        │
│    4. stopping checks                                                   │
│                                                                          │
│  POST-PASS-1 (one-shot):                                                │
│    5. ClusteringEngine.cluster                                          │
│    6. runParentHypothesisFlow                                           │
│       • HypothesisEngine.generate(.parentInferred), .grade              │
│       • HypothesisEngine.generate(.parentMarriage), .grade              │
│       • HypothesisEngine.reconcileParentMarriages                       │
│    7. runSiblingHypothesisFlow                                          │
│       • HypothesisEngine.generate(.siblingExists), .grade               │
│       (gated on identity resolved + both parents linked)                │
│                                                                          │
│  PASS 2 (T7: hypothesis-guided second pass, fires when                  │
│           ≥1 inconclusive hypothesis has a non-empty deficitQuery):     │
│    8. For each inconclusive hypothesis with a deficit query:            │
│       a. dispatch deficit query (per-kind levels)                       │
│       b. (T8 — paper-only: MLX fallback when ladder exhausted)          │
│    9. score / dedup / append to state                                   │
│   10. re-grade each hypothesis; append VerdictTransition on change      │
│   11. HypothesisEngine.reconcileParentMarriages                         │
│                                                                          │
│  PASS 3 (T9 — paper-only: MLX tie-break for residual ambiguity)         │
│                                                                          │
│  RESULT ASSEMBLY:                                                       │
│   12. clusters (recomputed if Pass 2 added evidence)                    │
│   13. hypotheses (all kinds, persisted; legacy fields deleted)          │
└─────────────────────────────────────────────────────────────────────────┘

Persistence: research_hypotheses (v26) — upserted across runs, with
             attempts column tracking expansiveness ladder progress.
             research_sessions (new in §5.9) — persisted ResearchState
             for pause/resume.
             record_rejections (v2) — extended to reject by hypothesis ID.
             evidence_records (v4) — unchanged.
```

The diagram describes the **engine** lifecycle. User-facing surfaces
sit above it: the single Research button + auto-escalation (§5.10)
drives Pass 1 level-by-level via §5.9's incremental entry points;
hypothesis investigation cards (§5.11) drive Pass 2's deficit queries
on user gesture. Both go through the same engine paths shown here —
they're not separate code paths.

**Key invariants preserved**:

- Deterministic-wins. Graders are rules; MLX (T8/T9) only enters
  when rules return `.inconclusive` / `.ambiguous`.
- Evidence Firewall. Hypothesis verdicts don't write to Profile or
  Relationship; user accept actions still go through
  `acceptProposedRelative` / `acceptSiblingProposal` paths.
- Apply contract. Overwrite-safe fill-nil-only.
- **Re-runnability is preserved for deterministically-graded
  hypotheses only.** For any hypothesis whose `isModelAssisted ==
  true`, the verdict may differ between runs of the same project on
  the same code. The `isModelAssisted` flag is the visible
  annotation; every consumer gates accordingly via
  `isDeterministicallySupported`.

---

## 7. Decisions made

Substantive design choices resolved during the 2026-05-19 spec
walk-through, plus the post-V2 implementation-driven decision (7.10)
recorded after the framework had landed for three kinds. Each
carries a **Validation** annotation that's a living status, updated
as the implementation tests the decision.

### 7.1 — `HypothesisKind` shape and per-kind code organisation

**Resolution**: **closed Swift enum with associated values, with
per-kind logic decomposed into extension files**. The three central
switches in `HypothesisEngine.swift` stay thin entry points — each
switch dispatches to per-kind static methods defined in a
`HypothesisEngine+<Kind>.swift` extension. All three operations for a
given kind (`generate*`, `grade*`, `deficitQuery*`) live adjacent in
one file.

**Validation: validated.** Has held across three kinds
(`.siblingExists`, `.parentInferred`, `.parentMarriage`) without
strain. Compile-time exhaustiveness has caught at least one
forgotten-kind bug during development.

### 7.2 — Migration of `proposedSiblings` (T12-sibling)

**Resolution**: **hard migration executed as four bisectable phases**
— Phase 1 in-place duplicate, Phase 2 flip source of truth, Phase 3
swap UI to read `result.hypotheses` directly, Phase 4 delete
`proposedSiblings` field.

**Validation: validated.** All four phases landed; the legacy field
is deleted; sibling discovery routes through the framework
exclusively.

### 7.3 — Fold `proposedRelatives` into the framework too (T12-parent)

**Resolution**: **yes, with the same four-phase pattern as
T12-sibling, sequenced after it.**

**Validation: validated.** All four phases landed; `proposedRelatives`
deleted; parent inference routes through `.parentInferred` +
`.parentMarriage` with reconciliation.

### 7.4 — Stall-detection contract for T7

**Resolution**: T7's second pass fires when **both** (a) the
dispatcher has walked the full strictness ladder for every applicable
source AND (b) ≥1 `.inconclusive` hypothesis has a non-nil
`deficitQuery`.

**Validation: partially validated.** T7 shipped with the looser
gate (condition b only) because condition (a) — dispatcher
strictness-ladder instrumentation — doesn't exist yet. The
two-condition gate remains the target; the interim ships with
condition (b) only and the code documents the deferral.

### 7.5 — Deficit query declaration style and ladder shape

**Resolution**: **central switch in `HypothesisEngine`** dispatching
to per-kind extension methods (per Decision 1's revised
organisation). Signature: `deficitQuery(for hypothesis:atLevel:state:) -> RecordQuery?`.
Each kind defines its own expansiveness ladder; `nil` at any level =
the kind's ceiling reached = hypothesis exhausted.

**Validation: partially validated.** Per-kind ladders work for
`.siblingExists` and `.parentMarriage` (level 1, level 2,
exhausted). The signature in the shipped code uses
`[RecordQuery]` (returning `[]` for exhaustion / no-ladder)
rather than `RecordQuery?` — semantically equivalent (`[]` ⇔ `nil`)
but slightly different shape. `.parentInferred` returns `[]` at
every level by design (the main pipeline's widening ladder is the
right escalation path), which technically conflates "no ladder"
with "exhausted".

**Open issue — to resolve before T8 starts.** T8 (§5.4) treats
exhaustion as the trigger for MLX fallback. With the current `[]`
contract conflating "no ladder" and "exhausted", T8 cannot
distinguish "kind has no ladder, escalate via the pipeline's
widening" from "kind has a ladder and we've walked off the end —
escalate via MLX." Before T8 ships, the contract should narrow to a
three-state return:

```swift
enum DeficitQueryResult {
    case query(RecordQuery)   // a focused query at this level
    case exhausted            // ladder ceiling reached — T8 fires
    case noLadder             // no per-kind ladder — pipeline widens
}
```

`.parentInferred` returns `.noLadder` at every level; `.siblingExists`
and `.parentMarriage` return `.query(...)` at levels 1–N, then
`.exhausted`. T8 fires only on `.exhausted`. See also §5.4 — this
note is mirrored in the T8 task as a blocker.

### 7.6 — Eval harness scope and rollout

**Resolution**: commit to a 3-profile starter corpus that grows over
time, with three refinements: per-hypothesis-kind reporting,
snapshot-based evaluation, single headline number.

**Validation: unvalidated (component not built).** No eval harness
exists; no corpus; T7's uplift target is unmeasured. See §5.8 for
the reframe of harness as validation infrastructure (not a build
prerequisite for T7 itself).

### 7.7 — Local MLX vs Claude API for T8 / T9

**Resolution**: **local MLX for T8 and T9 as the initial path,
because the App Store posture is the binding constraint, not model
quality.** T18/T20 (May 2026) stripped outbound AI calls specifically
to clean the privacy disclosure surface ahead of submission;
re-introducing them is a posture decision, not a technical one — new
privacy disclosure, possibly a new review cycle, the "what does your
app send where?" answer changes.

API escalation is expected, not a contingency. The eval harness
(§5.8) is what produces the evidence to defend that escalation —
when MLX leaves findings on the table at measurable rates against the
20–30-profile certified corpus, the App Store work to re-enable
outbound calls is justified. The local-MLX-first sequencing buys time
to build that evidence; it does not prejudge the eventual answer.

**Validation: unvalidated (component not built).** T8 and T9 are
both paper-only; the decision is not yet load-bearing.

### 7.8 — MLX nondeterminism representation

**Resolution**: **orthogonal `isModelAssisted: Bool` field** on
`ResearchHypothesis`, not a new verdict case. Auto-promote and
similar deterministic-only gates use the
`isDeterministicallySupported` helper.

**Validation: validated.** Field is present on the shipped
`ResearchHypothesis` type; `isDeterministicallySupported` helper
exists and is referenced wherever the gate matters. Default value is
`false` because T8/T9 haven't shipped yet — but the plumbing is in
place to flip it when they do.

### 7.9 — Cluster-aware scoring (out of V2 scope)

**Resolution**: deferred. Important (gates the G1 cross-profile
dedup task) but neither in the current task list nor a prerequisite
for any V2 task.

**Validation: deferred (intentionally).**

### 7.10 — Per-kind dispatch from the pipeline; no centralised `runAll`

**Resolution**: pipeline calls per-kind hypothesis-engine paths
directly (`runParentHypothesisFlow`, `runSiblingHypothesisFlow`, T7
second-pass dispatcher) rather than going through a single
`HypothesisEngine.runAll(state:snapshot:persisted:)` orchestrator.
The central engine file hosts only the three exhaustive switches
plus cross-kind reconciliation (`reconcileParentMarriages`).

**Why decided after T12 landed.** The original §4.2 proposed a
top-level `runAll` orchestrator. After three kinds shipped through
per-kind paths, the orchestrator had not paid rent: integration
points wanted different ordering (parent → marriage →
reconciliation; sibling separate; T7 second-pass selectively),
which meant `runAll` would have been a thin wrapper around the
per-kind calls. The abstraction was load-bearing as a
*compile-time exhaustiveness* construct (the central switches),
not as a *runtime orchestrator*.

**Validation: validated by absence.** Three kinds shipped; the
pipeline integration is clear; no missing-functionality regressed
from the orchestrator's absence.

---

## 8. Build order

Build dependencies (post-decisions). Shipped tasks marked **[✓
shipped]**; corpus-size annotations are validation needs, not build
prerequisites — see §5.8 reframe.

```
T11 [✓ shipped] (type + v26 migration + persistence helpers)
 └─→ T12-sibling Phase 1–4 [✓ shipped] (.siblingExists folds in)
      └─→ T12-parent design-pass [✓ shipped] (marriage-enrichment coupling, §5.2.1)
           └─→ T12-parent Phase 1–4 [✓ shipped] (.parentInferred + .parentMarriage fold in)
                ├─→ T7 [✓ shipped, looser gate] (second pass; deficit queries via level-dispatch)
                │       [uplift target unvalidated — needs §5.8 corpus 10–12]
                ├─→ Eval harness runner + 3-profile starter corpus (§5.8) [NOT BUILT]
                │    └─→ corpus grows to 10–12 → validates T7 uplift target
                │         └─→ corpus grows to 20–30 → validates T8 / T9 / T31
                ├─→ §5.9 Pipeline incrementality refactor [NOT BUILT]
                │    ├─→ §5.10 Research button collapse + auto-escalation UX [NOT BUILT]
                │    └─→ §5.11 Hypothesis investigation as user action [NOT BUILT]
                │         └─→ T8 (MLX next-search for exhausted-ladder) [NOT BUILT]
                │              └─→ T9 (MLX disambiguation for residual ambiguity) [NOT BUILT]
                ├─→ T31 (ladder retuning) [NOT BUILT — defined as the harness applied]
                ├─→ T23 (Sample Tree tour) [NOT BUILT, paper-only UX]
                └─→ §5.12 Design passes [NOT BUILT, paper-only UX]
```

**What's shipped (engine foundation):** T11, T12-sibling, T12-parent
(including the §5.2.1 design pass and the reconciliation step), and
T7 with the looser one-condition gate. Approximately the first
12 sessions of the original estimate.

**What's not built:** eval harness, §5.9 incrementality refactor,
§5.10 Mode→StopPolicy collapse, §5.11 investigation UI, T8/T9 MLX
work, T23 tour, T31 ladder retuning, §5.12 design passes.

Estimated remaining: **~12–16 sessions** to land §5.9, §5.10, §5.11,
T8, T9, T31, the harness, and the design passes. The estimate is
unchanged from the original 24–32 total; the difference is that
~12 sessions of foundation are now behind us.

### 8.1 Recommended pragmatic sequencing

The dependency graph above is correctness-oriented. The pragmatic
ordering — what to build next, given what's shipped — is different:

1. **Minimal harness (§5.8.1 row 1 — 3-profile structural-plumbing
   tier).** Smallest unit of harness that gives T7 a defensible
   number and unblocks all later validation work. Ship next.
2. **§5.9 Pipeline incrementality refactor.** Pure refactor;
   byte-identical output behind a more flexible API. Build
   prerequisite for §5.10 and §5.11.
3. **§5.10 (Research button collapse) and §5.11 (Hypothesis
   investigation) in parallel.** Both depend on §5.9 only.
4. **T8 / T9 / T31 as parallel tracks once the harness has reached
   the 20–30-profile certified corpus.** None of these three depends
   on the others; each gates on harness data. T8 also gates on the
   `deficitQuery` contract narrow (Part B(c) / Decision 7.5).
5. **T23 + §5.12 design passes — any time.** UX surfaces with no
   pipeline dependencies; ship when the team has UX bandwidth.

---

## 9. What this V2 does NOT do

Holdovers, explicitly out of scope:

- **G1 (cross-profile dedup).** Important, but not in the current
  task list. Future task. **Dependency note:** Decision 7.9
  (cluster-aware scoring) must come before G1 if either is taken up
  — cross-profile dedup needs cluster-aware match strength to know
  when two clusters across profiles describe the same person.
- **G7 (subtle merge detection).** Same.
- **MLX as primary grader.** No. Graders stay rule-based. MLX only
  enters when rules return inconclusive/ambiguous.
- **Per-source autotuning.** Today's per-source strictness configs
  (T37, T38) are static and stay static.
- **Cluster-aware scoring.** §7.9 flagged. Prerequisite for G1.
- **Workbench.Hypothesis ↔ ResearchHypothesis automatic crossover.**
  A `.supported` ResearchHypothesis can be promoted to a
  Workbench.Hypothesis by user action only.

---

## 10. Residual questions deferred to implementation time

Small, well-bounded questions that don't require resolution before
T11 starts.

1. **Escape-valve threshold for Local→API escalation (T8, T9)**. The
   eval harness will give us per-task miss-rate numbers; the
   threshold at which we file an "escalate to Claude API" task is
   TBD pending those numbers.
2. **Hypothesis kinds we haven't yet enumerated.** §4.1's enum lists
   the kinds we know we need. Future kinds (death-in-district,
   occupation-trajectory, address-change-event) are out of V2 scope
   but slot in via the same three-switch + extension-file pattern.
3. **`history` array growth policy.** Append-only on **verdict
   change** (skip identity-grade no-change events) is the recommended
   starting policy; revisit and add compaction-above-N if the harness
   shows unbounded growth on the certified corpus.

---

## 11. Net summary

The architectural pivot is from bespoke "research question → bespoke
engine" to a generalisable `ResearchHypothesis` framework, **plus**
the user-facing reframe that exposes the framework as a single
Research button with auto-escalation and per-hypothesis
investigation. The seven existing tasks compose around it:

- **Engine foundation**: T11, T12 (sibling + parent sub-projects).
- **Deterministic stall-recovery**: T7.
- **MLX bolt-ons** (gated on eval-harness data): T8, T9.
- **Independent**: T23 (Sample Tree tour), T31 (ladder retuning).

Plus three new task slots from the §5.10–5.11 reframe:

- **Pipeline incrementality** (§5.9) — prerequisite for the
  user-facing reframe.
- **Research button collapse + four-level expansiveness ladder**
  (§5.10).
- **Hypothesis investigation as user action** (§5.11).

And five UX design passes (§5.12) running in parallel where they
fit: discrepancy review, candidate comparison, search transparency,
verdict transitions across runs, confidence badge consolidation.

The eval harness (§5.8) is the load-bearing prerequisite for T7 / T8
/ T9 / T31. Corpus size gates downstream tasks: 3 profiles → ships
with T11/T12; 10–12 → required before T7; 20–30 → required before T8
/ T9 / T31.

Invariants preserved through V2: deterministic-wins (rules grade,
model never overrules); Evidence Firewall (hypothesis verdicts don't
write to Profile or Relationship); Apply contract (overwrite-safe
fill-nil-only). Re-runnability is preserved for
**deterministically-graded hypotheses only** —
`isModelAssisted == true` hypotheses may vary between runs;
consumers gate via `isDeterministicallySupported`.

---

*End of specification.*
