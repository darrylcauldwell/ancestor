# Research Pipeline — Specification

**Status:** Combined. Part I is an **as-built engine reference** for
the pipeline as it runs today (read it to answer "does the pipeline
already do X?"). Part II is the accepted V2 design; its engine
foundation (T7/T8/T11/T12/§5.14/§5.15) has shipped, and a forward
tail remains (T9, §5.9/§5.10/§5.11, T31, T23, the eval-harness Swift
backend, §5.12 design passes, §14.B.2–.6).
**Date:** 2026-05-22 (post-T17 consolidation sweep); Part II shipped
tasks collapsed to git-pointers 2026-07-21.
**References:** `AncestorApp/PROSE_CORPUS_SPEC.md` (corpus + bio
synthesis subsystem), `AncestorApp/FAMILYSEARCH_SOURCE_SPEC.md`
(single-source coverage), `AncestorApp/DOSSIER_SPEC.md` (T9
investigation dossier — supersedes the narrow §5.5 T9).

Internal `§X` references within each Part are scoped to that Part.
Cross-Part references use "Part I §X" / "Part II §X".

---

# Part I — Current state (as-built engine reference)

This Part describes the pipeline as **built**. Where it conflicts
with any earlier draft, the code wins.

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
elif zero fails AND zero softFails:           → .fact
elif zero fails AND ≥1 softFail:              → .lead
else:                                        → .lead
```

A record is a `.fact` only if every gate cleanly passes. Any softFail
(typically geography "unknown district" or family context "spouse not
present in household") drops it to `.lead`. Records become
`.impossible` when name fails outright, or when date is mathematically
incompatible (cannot have died in 1920 if married in 1925).

**Amendment (#CPC-Change4, 2026-07-26 —
`CROSS_PROFILE_CORROBORATION_SPEC.md`):** one bounded elevation clause
extends the roll-up. A **marriage** record carrying a reciprocal-tier,
**strong-anchor** cross-profile annotation (a tree-linked spouse's
persisted record at the same canonical GRO reference, stamped
pre-scoring by `CrossProfileAnnotator` from persisted evidence only)
classifies `.fact` when its sole blocker is insufficient SUBJECT
information: `failed == [date(insufficient-information)]` with zero
softFails and clean name/geography/family passes, or the
ENGINE_FOUNDATION #Change1 thin-subject cap (which the same annotation
exempts). Contradiction-shaped failures — date mismatch, any softFail,
`.impossible` — are never overridden, and the clause re-checks the
subject's recorded death against the marriage year itself (margin 0):
the nil-window guard fires before the date gate's death check, so an
"insufficient information" fail can mask a marriage-after-death
contradiction the predicate must refuse on its own inputs. Ordering consequence for the §15
re-runnability invariant: a subject's verdict is now a deterministic
function of (subject facts, spouse's persisted evidence state); same
DB state still yields same output, but whole-tree run ORDER matters
transiently — cross-profile state converges through the existing
re-run loop plus the #CPC-Change2 post-persist sweep trigger.

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

`ResearchPipeline.research(subject:config:)` is one async call that
returns a `ResearchResult`. Internally it runs **N iterations**
(mode-dependent maximum) followed by a single **post-loop** phase.
(Parent inference and marriage enrichment run in the post-loop phase,
moved there from the iteration loop under V2 §5.2 T12-parent Phase 2.)

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

The pipeline produces three kinds of inferred output beyond the raw
scored records: **parents**, **enriched parent given names**, and
**siblings**. Each runs as a pure function over the current
`ResearchState`. Two architectural notes: the standalone
`ParentInferenceEngine` type is now a test-only thin wrapper (canonical
parent-inference logic lives in `HypothesisEngine+ParentInferred.swift`,
T12-parent Phase 2); and sibling discovery no longer requires
same-district per record (§6.3, the cross-district exception).

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

When a `.fact` record's key field (birth year, death year) differs
from the existing tree value, the pipeline raises a
`ResearchDiscrepancy`. Severity comes from a deterministic table. The
§10.3 per-source tolerances are aspirational — see the note at the
bottom of this section.

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
> or pre-narrowing the delta at each source plugin. **Forward item:
> per-source discrepancy tolerances — tracked, not blocking.**

---

## 11. SearchDispatcher

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

The `AUTOMATION_AUTO_ACCEPT` flag is debug-only; release builds have
no user-facing auto-promote from clusters. The orthogonal
pending-fact auto-approval at §14 is the only auto-commit path in
release.

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

**MVP + defensive re-run shipped; write path gated off by default.**
The MVP shipped 2026-05-21 (`960dfeb`); the §14.B.1 defensive
hallucination re-run shipped 2026-07-11/13 (ENGINE_FOUNDATION #Change8
core + MCP wiring `c2d112d`). The write path is disabled at runtime by
explicit user choice (`ANCESTOR_MCP_AUTO_APPROVE` env var, default
unset → `approve_pending_fact` refuses with
`auto_approval_gate_disabled`), no longer by missing safeguards.
`inspect_approval_decision` (dry-run, read-only) remains enabled and is
the right tool for exercising gate logic without committing. §14.A–§14.6
below describe what runs today; §14.B.2–.6 are the forward Phase-2 tail.

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

> **Update 2026-07-13 (CONFLICT_LAYER CL6, 2e432ad):** the §14.3 gate additionally refuses when the target profile carries an OPEN `field_disputes` row — field-level disputes on the target field, and structural kinds (timeline/parentRole/spouseIdentity) that field_sources recomputation cannot see. Refusal reason `open_dispute_on_target`.

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
explicit design decision per field, not a quiet default. (§5.14.5
lands one narrow carve-out: a `firstName` recovered through a
`.supported .unique .subjectSpouseMarriage` when the field was empty.)

**14.3.5 Hallucination checks have passed.** The Evidence Firewall's
existing checks (URL verification, source-tier plausibility,
hallucination rules) run at the MCP gate (§14.B.1, shipped) —
failure is treated identically to gate failure (no auto-approval;
human review path unchanged).

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
`approval_method TEXT` (`'user'` | `'rules'`), `approval_rule_ids
TEXT` (JSON array of gate criteria that passed), `approved_at
DATETIME` (distinct from `reviewed_at`). Today's audit trail lives
entirely on the `pending_facts` row; the richer transaction-row audit
(§14.B) is Phase 2.

### 14.6 What ships in MVP

Migration v28; the MCP evaluator implementing the gate; the two MCP
tools; 39 unit tests over the pure helpers; and the runtime gate (the
`ANCESTOR_MCP_AUTO_APPROVE` env-var default-off write path). The
§14.B.1 contingency is satisfied (shipped 2026-07-11/13); flipping the
default is a single-line change and purely a user decision now.

# §14.B MCP auto-approval — Phase 2 (forward)

**§14.B.1 shipped 2026-07-11/13** (app core #Change8 + MCP mirror
`c2d112d`): the MCP tool re-runs the Evidence Firewall's checks (URL
verification, source-tier plausibility, hallucination rules) at the
gate rather than assuming they passed earlier; failure is treated
identically to gate failure. The rest of Part B is forward design. The
MVP's audit lives on `pending_facts` columns; reversibility is not yet
wired through the transactions table.

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

Important inventory for Part II to push against. (Two former items —
persisted hypotheses driving second passes, and the hypothesis-guided
second pass — are now closed by T11/T12 and T7 respectively; see
Part II.)

1. **Cross-profile dedup.** Each `research(subject:)` call is
   independent. Researching mother after researching self refetches
   the shared marriage record and treats it as a fresh hit instead of
   recognising it. `ConvergenceEngine` operates per-cluster, never
   across clusters that span profiles. (G1.)
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
   "ship and hope." (See Part II §5.8 — the Python scaffold shipped;
   the Swift/MCP backend is the forward item.)
8. **MLX as planner / disambiguator.** The model only suggests
    record types between iterations and writes prose for the user. It
    doesn't propose hypotheses, doesn't grade, doesn't propose
    specific next searches. (T8 shipped as a between-iteration query
    strategist; T9 disambiguation is the forward target.)

This is the surface against which Part II proposes.

---

## 17. Source plugins — what's wired today

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

These are the user-facing problems the pipeline solves and the
principles that shape its outputs. Where the language describes future
behaviour, see Part II for the current roadmap. (The `ResearchConfig`
struct carries only `maxIterations`, `maxFacts`, `mode`, `scope` — the
per-mode `useLLM` flag from the 2026-04-25 draft was removed.)

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
`ResearchState.householdMembers`. Discovery types include: new
ancestor revealed in census; maiden name implied by mother-in-law;
unknown sibling; unknown child; spouse identified by marriage record;
occupation revealed; address found.

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

**One shipped pattern.** When a source response references a record
that another source can parse more richly, the pipeline runs a
deterministic follow-up fetch between dispatch and score. The first
such pattern shipped 2026-05-20.

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

# Part II — V2 hypothesis framework (engine foundation shipped; forward tail remaining)

This Part is the accepted V2 architectural turn for the research
pipeline: replacing the bespoke "question → engine → field on result"
pattern with a uniform **ResearchHypothesis** lifecycle. The engine
foundation has shipped; the forward tail is enumerated in §5 and the
build order in §8.

## 1. Why now

The pipeline as built (Part I) ships strong deterministic primitives:
a 4-gate scorer, 5-step clustering, lineage-aware convergence, an
identity resolver, three inference engines. Five earlier tasks (T17
sibling discovery, T13 subject identity, T10 geographic hypothesis, T6
auto-promote gate, T5 cluster-level hypothesis verdict) each share a
shape: a **purpose-built question** wired to bespoke generation +
bespoke testing + bespoke acceptance. That shape doesn't generalise —
adding "burial at this parish?", "death certificate in this
registry?", "second marriage?" each meant another bespoke engine,
field, UI surface, and accept path. T11 + T12 retire that pattern.

---

## 2. The architectural thesis

> Replace the bespoke "question → engine → field on result" pattern
> with a uniform **ResearchHypothesis** lifecycle: generate, test,
> grade, persist, optionally act on, optionally promote.

Concretely:

- `ResearchHypothesis` becomes a first-class type. Each existing
  one-off folds in as a *kind* of hypothesis with its own generator
  and grader. New questions become new kinds without new fields on
  `ResearchResult`.
- A `HypothesisEngine` runs the generators, tests each hypothesis
  against available evidence, and grades each with a verdict
  (`.supported` / `.contradicted` / `.inconclusive`).
- Hypotheses persist (T11), keyed by `(profile_id, kind,
  deterministic_subject_hash)`, so re-runs **upsert** rather than
  re-create. Verdict transitions are observable across runs.
- A graded hypothesis can drive a focused second pass (T7) — the
  deterministic version of "stall recovery."
- MLX enters only where deterministic generation can't reach:
  free-text disambiguation of ambiguous identity resolutions (T9) and
  next-search suggestion for weak verdicts the rules can't escalate
  (T8).

The deterministic-wins rule is preserved: MLX can propose a
hypothesis or a next-search direction, but the grader and the scorer
remain rule-based. No verdict comes from a model.

---

## 3. Gap inventory

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

Two more emerged during the V2 session, both closed by the shipped
framework: **G8** (one-off hypothesis pattern doesn't generalise —
closed by T11+T12) and **G9** (no persistence of hypothesis state
across runs — closed by T11 + the v26 table).

---

## 4. The framework (T11 + T12) — shipped

**Shipped: T11 `fe1c2b5`, T12 `cb8b05b`.** `ResearchHypothesis`
(`Models/Research/ResearchHypothesis.swift`) is a persistent,
deterministic, testable claim carrying `id` (stable
`kind.identityKey(profileID)`), `subjectProfileID`, `kind`, `verdict`,
`isModelAssisted`, `supportingEvidence`, `contradictingEvidence`,
`reasoning`, `attempts` (expansiveness levels dispatched), and a
`history` verdict trail. `HypothesisKind` is a **closed Swift enum**
(cases `.subjectIdentity`, `.parentInferred`, `.parentMarriage`,
`.siblingExists`, `.clusterIsSubject`, `.subjectSpouseMarriage`,
`.parentCandidates`, …); `HypothesisVerdict` is
`.supported / .contradicted / .inconclusive`. The v26
`research_hypotheses` table persists them with upsert-on-identityKey
semantics and a `user_rejected` flag. The `HypothesisEngine`
(`Services/Research/HypothesisEngine.swift`) hosts three thin
exhaustive central switches (`generate` / `grade` / `deficitQuery`),
each dispatching to a `HypothesisEngine+<Kind>.swift` extension; there
is no central `runAll` orchestrator (Decision 7.10) — the pipeline
calls per-kind flows directly.

**Load-bearing design contracts that survive as invariants (not
build narrative):**

- **Closed enum + three switches.** Adding a kind = add the case + a
  clause to each central switch + an extension file. Compile-time
  exhaustiveness catches "forgot to handle the new kind."
- **`isDeterministicallySupported`** (`verdict == .supported &&
  !isModelAssisted`) is the gate every promotion / auto-accept path
  uses — never a bare `verdict == .supported`. Preserves
  deterministic-wins: model output never writes facts.
- **Asymmetric verdict space.** `.parentInferred` / `.parentMarriage`
  treat absence of evidence as `.inconclusive`, never `.contradicted`
  (the record may sit outside the searched window). UI must not assume
  "absence of `.supported`" implies `.contradicted`.
- **`ResearchHypothesis` ≠ `Workbench.Hypothesis`.** The latter is
  user-authored free-form prose on the workbench surface; the former
  is machine-generated, regenerated each run, on the research surface.
  A `.supported` `ResearchHypothesis` may be *promoted* into a
  `Workbench.Hypothesis` by user action only — the sole crossing.

The build narrative (the `runAll` orchestrator that was proposed then
retired, the four-phase migration mechanics, the projection-equality
eval criteria, `v26` DDL) is in git.

---

## 5. Task-by-task

### 5.1 T11 — Hypothesis type + persistence

**Shipped 2026-05-19, `fe1c2b5`.** Type + kind enum + verdict enum +
transition record, v26 migration, `ProjectDatabase` load/upsert/reject
helpers, `ResearchResult.hypotheses` field. See §4.

### 5.2 T12 — HypothesisEngine: generate, test, grade

**Shipped 2026-05-19, `cb8b05b`.** Sibling, parent-inferred, and
parent-marriage generators + graders + deficit queries, dispatched
per-kind from the pipeline (Decision 7.10). The `.parentInferred` ↔
`.parentMarriage` cross-referencing design (two kinds, reconciled by
`reconcileParentMarriages` — a pure deterministic idempotent join that
appends the marriage record ID and a given-name sentence onto each
parent hypothesis) shipped as designed; the legacy `proposedSiblings`
and `proposedRelatives` fields are deleted. Migration mechanics (the
4-phase bisectable sequence per sub-project) and the marriage-
enrichment coupling design pass are in git.

### 5.3 T7 — Hypothesis-guided second pass

**Shipped (documented partial gate).** `researchSecondPass(firstResult:
state:)` selects `.inconclusive` hypotheses with a non-nil
`deficitQuery(for:atLevel:state:)`, dispatches the returned query,
appends evidence, increments `attempts`, re-grades, re-runs
`reconcileParentMarriages`, recomputes clusters. Runs at most once per
`research(...)` call; deficit queries respect the existing storm
guards. The two-condition stall gate (§7.4) ships with condition (b)
only — condition (a), dispatcher strictness-ladder instrumentation,
doesn't exist yet (documented in code). The "≥30% of stalled profiles
gain ≥1 new `.supported` hypothesis" uplift target is unmeasured
pending the eval harness (§5.8). Every deficit query is a
deterministic rewrite of its grader's inputs — MLX doesn't decide
where to look when the rules know.

### 5.4 T8 — MLX query strategist (Level 2)

**Shipped 2026-05-26 (slices 13a/13b/13c).** A between-iteration
Level-2 query strategist: `ResearchInterpreter.suggestNextFocusedQuery`
(MLX-backed) fires when an iteration produced 0 new records OR no
confirmed facts, returns a `FocusedQuery` (single-source, single-
record-type, required `rationale`), dispatched via
`SearchDispatcher.dispatchOne(focused:cache:)`. MLX chooses *what* to
ask; deterministic code owns *what's true* — records from a focused
query are **not** marked `isModelAssisted` (the source and scorer are
deterministic; only the decision to dispatch was MLX-influenced, which
`searchHistory` preserves for audit). Falls through gracefully when
MLX is unavailable/unparseable/`give_up`. Local MLX (not Claude API)
per Decision 7.7 — the App Store privacy posture is the binding
constraint. Full determinism table + prompt shape + fallback behaviour
in git.

**Forward — T8a hypothesis-level fallback (deferred).** The original
post-T7-exhausted-ladder MLX fallback (`suggestForWeakHypothesis`) is
still valuable when T7's deficit ladder exhausts on specific kinds.
Reserved for a future slice; the entry point adds alongside the
shipped `suggestNextFocusedQuery` without changing existing wiring.
Gated on the §7.5 `DeficitQueryResult` contract narrowing (below).

### 5.5 T9 — MLX free-text disambiguation pass

**Status: Paper-only. Not built.**

> **Superseded by `DOSSIER_SPEC.md`.** The narrow θ-threshold T9
> described here (a confidence-gated MLX tie-break wired into the
> `.subjectIdentity` grader) is subsumed by the DOSSIER investigation
> dossier + bounded adversarial challenge, which builds the shared
> grounded-prose / confidence-vocabulary machinery and a broader
> adversarial-selection pass. Build DOSSIER instead of this narrow T9
> if DOSSIER is greenlit; the design below is retained as the
> minimal-scope fallback and for its threshold-policy discipline.

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

**Status: Paper-only. Not built.** ⚠ Likely superseded in part by the
onboarding wizard + Getting Started that shipped 2026-07-21 — reconcile
scope before scheduling; may be closed.

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

**Status: Partial.** The Python-side scaffold shipped (commits
`516da79` → `99da91a`): §5.8.5 GEDCOM citation matcher (Python
`eval/citation_matcher.py` + Swift
`Services/Research/CitationMatcher.swift`, kept in sync), §5.8.6 runner
(`eval/run_harness.py`, `--backend python|mock`), §5.8.2 certified
subset (12 corpus subjects under `eval/certified/*.yaml`), and §5.8.3
per-kind verdict-agreement metric.

**Forward — the Swift/MCP backend (§5.8.8).** The remaining major
investment: a `--backend swift-mcp` that drives the actual Swift
product via `FieldResearcherMCP`. Today the harness measures the
*Python reference* implementation (per CLAUDE.md), not the Swift
product. This is the **first** of the pipeline tail — §8.1 names the
3-profile structural tier as "ship next"; it unblocks every validation
target (T7 uplift, T8 uplift, T9 user-agreement rate, T31 ladder
retune). Also unshipped: precision/recall in the strict §5.8.3 sense
(small follow-up on the existing per-kind data).

**Reframe (2026-05-22):** the harness is a *validation* prerequisite,
not a *build* prerequisite. T7 shipped without it, against unit tests,
and works. The harness is what would let us *defend* T7's "≥30% of
stalled profiles gain ≥1 new `.supported` hypothesis" target, T8
uplift, T9 user-agreement, T31 retuning.

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
`CitationMatcher` — does this mapping. (Shipped — see the status note
above.)

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
  behaviour change in the deterministic core. (A new
  `research_sessions` table backs persisted `ResearchState`.)
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

**Shipped (illustrates §5.2 / §4).** The concrete post-loop trace for
Kathleen Wheeldon (Bakewell, est. 1922–1924) — `.subjectIdentity`
`.supported`; two `.parentInferred` (Wheeldon-male, Keyworth-female)
`.supported` from the FreeBMD birth's MMN; `.parentMarriage`
(Keyworth×Wheeldon, 1893…1924) `.supported` from the George Wheeldon ×
Florence Keyworth 1921 Q4 marriage; reconciliation folding the given
names onto the parent hypotheses; `.siblingExists` skipped because the
parents exist only as hypotheses, not linked `relationships` rows — is
in git. Its enduring lesson: the sibling-discovery gap is **structural,
not algorithmic** (`.siblingExists` requires parents-linked → user
acceptance → the run-then-review-then-rerun loop), which either a
lifted gate or an auto-promote chain (§14) would close.

### 5.14 `.subjectSpouseMarriage` — pre-iteration hypothesis for thin placeholders

**Shipped** (`HypothesisEngine+SubjectSpouseMarriage.swift`, wired into
`ResearchPipeline.swift` as `runSubjectSpouseMarriageFlow` — the
pre-iteration analogue of `runParentHypothesisFlow`, with the
storm-guard short-circuit; git touches it through `e6e4a31`). All five
slices (detection/probe/match, write-back, UX, tests, the §14.3.4
carve-out) landed.

**What it does — the load-bearing contract (design detail in git):**
For a thin placeholder subject (recorded surname, no given name, a
`profileID`, ≥1 linked child carrying a usable MMN anchor), the
**marriage index is the anchor, not the birth index**. The subject's
own birth record is invisible until the given name is known; the
subject's *marriage* is reachable via the surname pair (subject surname
× child MMN) and carries the given name. `runSubjectSpouseMarriageFlow`
runs **before** the iteration loop (refining a thin subject *after* the
loop is too late), builds `(groom, bride)` BMD role-labelled pairs per
linked child (payload is `(groomSurname, brideSurname, childYearWindow)`
— handles all three name-storage conventions), dispatches groom-side +
bride-side, reunites via `MarriageEnrichmentEngine.match`, resolves the
subject's gender via a four-rule precedence ladder (explicit >
surname-pattern > topology > refuse, recorded in `reasoning`), and on a
`.unique` match writes back both `state.subject.givenName` (so the loop
sees a rich subject) and a firewall-respecting `pending_facts` row.
Fully deterministic (`isModelAssisted: false`).

**§14.3.4 auto-approval carve-out (shipped).** A `firstName` recovered
through this path auto-approves iff all of: (i) `.supported`
`.subjectSpouseMarriage`; (ii) the underlying match was `.unique`;
(iii) matched marriage source tier ≥ `.transcription` (a relaxation of
§14.3.1 for this BMD-shaped recovery, treating the BMD reference-tuple
agreement between groom/bride sides as structural convergence within
the source); (iv) subject `firstName` empty pre-recovery (recovery, not
correction). The carve-out is narrow by construction — it does not
generalise to any other `firstName` write. The multi-child /
disagreeing-MMN / remarriage reconciliation cases, the gender ladder
edge-case table, and the slice plan are in git.

### 5.15 `.parentCandidates` — user-seeded hypotheses (Epic 13)

**Shipped 2026-07-11 (Epic 13, slices 1–5):** slice 1 `a57fd70`, slice
2 `6d8ff6b`, slices 3–4 `0cff9a7`, slice-5 acceptance tests; decisions
`ab94695`.

Makes a user's hunch ("I think George Wheeldon's parents were Bob &
Sue") a first-class `ResearchHypothesis` that steers targeted probes
through the standard verdict lifecycle **without the hunch touching the
tree**. The enduring doctrine (a hunch is a *search directive*, never
data):

1. **Invisible to the tree.** A seeded hypothesis creates no profile,
   edge, field, or citation; nothing reaches the tree until real
   records survive the normal accept path (Part I §13.2).
2. **Biases WHERE, never WHAT.** The hunch adds focused queries;
   scoring, verdicts, clustering, convergence, auto-promote untouched.
   `isModelAssisted: false` on the deterministic paths.
3. **Distinct from family testimony.** "Aunt Vera wrote…" is *evidence*
   (a citable source, entering through the review queue with a tier); a
   hunch is *not evidence* and never acquires a tier. The two must not
   share a pipe.
4. **Refutable, and refutation is remembered.** Standard verdict
   lifecycle with `attempts`, history, persisted user-rejection;
   rejection memory (Part I §18.7) is honoured.

**Shipped shape (detail in git):** a specific typed
`.parentCandidates(fatherGiven?, fatherSurname?, motherGiven?,
motherMaidenSurname?, marriageWindow)` kind plus an orthogonal
`origin: .engine | .user` provenance field on every hypothesis (E1 —
not a generic `.userSeeded`). Intake mirrors the sanctioned
`research_run_requests` pattern: `submit_hypothesis` MCP tool +
Workbench "Add a hunch" form write a v32 `user_hypothesis_seeds`
staging table; the app-side watcher materialises queued seeds into
`research_hypotheses` rows (E2 — the engine keeps sole ownership of its
table). A T7 stall-gate carve-out gives `origin == .user` rows one
unconditional level-1 dispatch (E4 — a user directive isn't
speculation); later levels ride the normal gate. `.supported` requires
the full linkage chain (marriage match + subject linkage via MMN or
census household), not mere couple attestation (E5 — prevents the
hunch's own confirmation bias inflating verdicts). Probes ride existing
machinery (parent-marriage index / MMN linkage / census household);
pending facts face the **unmodified** §14.3 gates (a hunch needs no
carve-out — contrast §5.14). Not folded into T9 (E3 — deterministic,
independently shippable, on shipped rails). The natural-language intake
(phase c) is the only genuine T9-adjacency and is out of scope; it will
adopt this seeds table + `origin` unchanged.

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
│       b. (T8a — paper-only: MLX fallback when ladder exhausted)         │
│    9. score / dedup / append to state                                   │
│   10. re-grade each hypothesis; append VerdictTransition on change      │
│   11. HypothesisEngine.reconcileParentMarriages                         │
│                                                                          │
│  PASS 3 (T9 — paper-only: MLX tie-break for residual ambiguity;         │
│           superseded by DOSSIER_SPEC)                                    │
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

## 7. Decisions made — validated (see git for full rationale)

The substantive design choices from the 2026-05-19 walk-through (plus
7.10, recorded after the framework landed) are all **validated in the
shipped code** and collapsed here to a one-line status each. The full
resolution + rationale for each is in the pre-thinning git revision of
this spec.

- **7.1 `HypothesisKind` shape** — closed Swift enum + per-kind
  extension files; three thin central switches. **Validated** across
  `.siblingExists` / `.parentInferred` / `.parentMarriage` (and later
  kinds); compile-time exhaustiveness caught a forgotten-kind bug.
- **7.2 Migration of `proposedSiblings`** — hard 4-phase migration.
  **Validated**; legacy field deleted.
- **7.3 Fold `proposedRelatives` in too (T12-parent)** — same 4-phase
  pattern, sequenced after sibling. **Validated**; field deleted.
- **7.4 Stall-detection contract for T7** — two-condition gate.
  **Partially validated**: shipped with condition (b) only; condition
  (a) (dispatcher instrumentation) deferred, documented in code. This
  is a live forward residue.
- **7.6 Eval harness scope** — 3-profile starter, growing.
  **Unvalidated** (component not built — the Swift backend is the §5.8
  forward item).
- **7.7 Local MLX vs Claude API for T8/T9** — local MLX first (App
  Store posture is the binding constraint). **Partly load-bearing**:
  T8 shipped on MLX; T9 paper-only. API escalation is expected, not a
  contingency — the harness produces the evidence to defend it.
- **7.8 MLX nondeterminism representation** — orthogonal
  `isModelAssisted: Bool`, gated via `isDeterministicallySupported`.
  **Validated** (present on the shipped type).
- **7.9 Cluster-aware scoring** — **deferred** (gates G1; not a V2
  prerequisite).
- **7.10 Per-kind dispatch, no centralised `runAll`** — pipeline calls
  per-kind flows directly; the central file hosts only the switches +
  reconciliation. **Validated by absence** — three kinds shipped, no
  orchestrator needed.

### 7.5 Deficit-query contract narrowing (T8 prerequisite — forward)

**Resolution**: central switch dispatching to per-kind extension
methods; signature `deficitQuery(for hypothesis:atLevel:state:) ->
RecordQuery?`; each kind defines its own ladder, `nil` at any level =
ceiling reached = exhausted.

**Partially validated**: per-kind ladders work for `.siblingExists`
and `.parentMarriage`. But the shipped code uses `[RecordQuery]`
(returning `[]` for exhaustion / no-ladder) rather than `RecordQuery?`
— `[]` ⇔ `nil` semantically, but `.parentInferred` returns `[]` at
every level *by design* (the main pipeline's widening ladder is the
right escalation), which conflates "no ladder" with "exhausted."

**Open — resolve before T8a starts.** T8a (§5.4) treats exhaustion as
the trigger for MLX fallback, and cannot distinguish "no ladder,
escalate via pipeline widening" from "ladder walked off the end,
escalate via MLX." Narrow the contract to a three-state return:

```swift
enum DeficitQueryResult {
    case query(RecordQuery)   // a focused query at this level
    case exhausted            // ladder ceiling reached — T8 fires
    case noLadder             // no per-kind ladder — pipeline widens
}
```

`.parentInferred` returns `.noLadder` at every level; `.siblingExists`
and `.parentMarriage` return `.query(...)` at levels 1–N, then
`.exhausted`. T8a fires only on `.exhausted`. Size: S. Do before T8a.

---

## 8. Build order

Engine foundation is shipped; the forward tail sequences behind it.

```
[✓ shipped] T11 → T12-sibling → T12-parent (design pass + reconciliation)
[✓ shipped] T7 (looser one-condition gate; uplift target unvalidated)
[✓ shipped] T8 Level-2 MLX strategist
[✓ shipped] §5.14 .subjectSpouseMarriage; §5.15 Epic 13 .parentCandidates

FORWARD TAIL (not built):
  §5.8.8 Eval harness Swift/MCP backend  ── FIRST; unblocks every validation target
   ├─→ corpus 10–12 → validates T7 uplift
   └─→ corpus 20–30 → validates T8a / T9 / T31
  §5.9 Pipeline incrementality refactor  ── prerequisite for §5.10 / §5.11
   ├─→ §5.10 Research button collapse + auto-escalation UX
   └─→ §5.11 Hypothesis investigation as user action
  §7.5 DeficitQueryResult 3-state narrowing  ── T8a prerequisite
   └─→ T8a hypothesis-level MLX fallback (suggestForWeakHypothesis)
  T9 MLX disambiguation (superseded by DOSSIER_SPEC)
  T31 ladder retuning (defined as the harness applied)
  T23 Sample Tree tour (paper-only UX; may be closed by 2026-07-21 onboarding)
  §5.12 Design passes (paper-only UX)
  §14.B.2–.6 MCP auto-approval Phase 2 (bulk tool, transaction kinds, reversibility,
             audit surfaces, user toggle)
  §10.3 per-source discrepancy tolerances (low-priority tail)
  G1 cross-profile dedup + G7 subtle merge (post-V2 future epic; G1 gated on 7.9)
```

### 8.1 Recommended pragmatic sequencing

1. **Minimal harness (§5.8.1 row 1 — 3-profile structural-plumbing
   tier via §5.8.8 Swift backend).** Smallest unit that gives T7 a
   defensible number and unblocks all later validation. Ship next.
2. **§5.9 Pipeline incrementality refactor.** Pure refactor;
   byte-identical output behind a more flexible API. Prerequisite for
   §5.10 and §5.11.
3. **§5.10 (Research button collapse) and §5.11 (Hypothesis
   investigation) in parallel.** Both depend on §5.9 only.
4. **T8a / T9 / T31 as parallel tracks once the harness reaches the
   20–30-profile certified corpus.** None depends on the others; each
   gates on harness data. T8a also gates on the §7.5 `DeficitQueryResult`
   narrowing.
5. **T23 + §5.12 design passes — any time.** UX surfaces with no
   pipeline dependencies.

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

1. **Escape-valve threshold for Local→API escalation (T8a, T9)**. The
   eval harness will give us per-task miss-rate numbers; the
   threshold at which we file an "escalate to Claude API" task is
   TBD pending those numbers.
2. **Hypothesis kinds we haven't yet enumerated.** §4's closed enum
   lists the kinds we need today. Future kinds (death-in-district,
   occupation-trajectory, address-change-event) slot in via the same
   three-switch + extension-file pattern.
3. **`history` array growth policy.** Append-only on **verdict
   change** (skip identity-grade no-change events) is the recommended
   starting policy; revisit and add compaction-above-N if the harness
   shows unbounded growth on the certified corpus.

---

## 11. Net summary

The architectural pivot — from bespoke "research question → bespoke
engine" to a generalisable `ResearchHypothesis` framework, plus the
user-facing reframe exposing it as a single Research button with
auto-escalation and per-hypothesis investigation — has landed its
engine foundation:

- **Engine foundation (shipped)**: T11, T12 (sibling + parent), T7
  (deterministic stall-recovery, looser gate), T8 (Level-2 MLX
  strategist), §5.14 `.subjectSpouseMarriage`, §5.15 Epic 13
  `.parentCandidates`.

The **forward tail** is: the eval-harness Swift/MCP backend (§5.8.8 —
the load-bearing validation prerequisite for T7/T8a/T9/T31); the
§5.9 incrementality refactor and the §5.10/§5.11 user-facing reframe it
unlocks; the §7.5 `DeficitQueryResult` narrowing + T8a fallback; T9 MLX
disambiguation (superseded by `DOSSIER_SPEC.md`); T31 ladder retuning;
T23 tour (possibly closed by the 2026-07-21 onboarding); the §5.12
design passes; §14.B.2–.6 auto-approval Phase 2; §10.3 per-source
tolerances; and the post-V2 G1/G7 epic.

Invariants preserved through V2: deterministic-wins (rules grade,
model never overrules); Evidence Firewall (hypothesis verdicts don't
write to Profile or Relationship); Apply contract (overwrite-safe
fill-nil-only). Re-runnability is preserved for
**deterministically-graded hypotheses only** —
`isModelAssisted == true` hypotheses may vary between runs;
consumers gate via `isDeterministicallySupported`.

---

*End of specification.*
