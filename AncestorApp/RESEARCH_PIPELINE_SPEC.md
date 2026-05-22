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
synthesis subsystem), `AncestorApp/AUTO_APPROVAL_VIA_MCP_SPEC.md`
(auto-promote tail), `AncestorApp/FAMILYSEARCH_SOURCE_SPEC.md`
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
│    7. ParentInferenceEngine.infer  ──► [ProposedRelative]            │
│    8. (first time only) MarriageEnrichmentEngine.match               │
│    9. (between iterations) ResearchInterpreter.suggestNextSearch     │
│    10. stopping checks                                               │
│                                                                       │
│  post-loop (once):                                                   │
│    11. ClusteringEngine.cluster        ──► [LifeCluster]             │
│    12. findSiblings (identity-gated)   ──► [SiblingProposal]         │
│    13. assemble ResearchResult                                       │
└────────────────────────┬─────────────────────────────────────────────┘
                         │ ResearchResult (clusters, proposals, discrepancies)
                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│  ClusterReviewView — user reviews + decides                          │
│    • Cluster Apply / Discard / Save-as-lead                          │
│    • Per-record Apply / Discard overrides                            │
│    • Proposed Relatives accept/apply                                 │
│    • Proposed Siblings accept/reject                                 │
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
elif zero fails AND zero softFails:          → .fact
elif zero fails AND ≥1 softFail:             → .lead
else:                                        → .lead
```

A record is a `.fact` only if every gate cleanly passes. Any softFail
(typically geography "unknown district" or family context "spouse not
present in household") drops it to `.lead`. Records become
`.impossible` when name fails outright, or when date is mathematically
incompatible (cannot have died in 1920 if married in 1925).

### 4.3 Key thresholds (RecordScorer.swift)

| Constant | Value | Notes |
|---|---|---|
| Surname/given-name similarity floor | 0.7 | Both must clear independently |
| Census age tolerance | ±2 years | Birth year inferred from census age |
| BMD birth year tolerance | ±2 years | Registration quarter ≠ birth date |
| Marriage min age | 16 | Younger = impossible |
| Marriage max age | 70 | Older = impossible |
| Lifespan max | 110 years | Age at death cap |
| Foreign-country token list | `[canada, australia, usa, …]` | Hard-fails geography in non-`.all` modes |

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
7. **Parent inference.** `ParentInferenceEngine.infer` runs against
   *facts + leads* (not just facts — see §6.4). Output:
   `[ProposedRelative]`, deduplicated by stable ID across iterations.
   Evidence records accumulate per proposal.
8. **Marriage enrichment.** First iteration where proposals exist:
   `MarriageEnrichmentEngine.match` joins groom-side and bride-side
   BMD queries by reference tuple to fill in parent given names.
   Gated on either both parents linked OR subject identity resolved
   (search-storm guard, §11.2). Once attempted, never re-run within
   a pipeline call.
9. **Reasoning suggestion.** Between iterations only:
   `ResearchInterpreter.suggestNextSearch` may propose adding a
   record type to `state.activeRecordTypes`. The deterministic
   dispatch still decides what runs next.
10. **Stopping checks** (any one breaks):
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
   marriage, not a candidate life of the subject, and surface under
   `ProposedRelative.evidence` instead.
2. **Sibling discovery** (T17). `findSiblings(state:)` gates on
   subject identity resolved + both parents linked. If both gates
   clear, it dispatches **one focused FreeBMD query** (surname-only,
   single district, ±20-year window) and runs
   `SiblingInferenceEngine.inferSiblings`. Returns `[]` otherwise.
3. **Result assembly.** A `ResearchResult` carries: `confirmedFacts`,
   `leads`, `allScoredRecords`, `clusters`, `discrepancies`,
   `householdMembers`, `searchHistory`, `proposedRelatives`,
   `proposedSiblings`.

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
`ResearchState`.

### 6.1 ParentInferenceEngine

**Input:** `state.confirmedFacts + state.leads` (not just facts — the
`mothersMaidenName` field is a direct index transcription, so its
reliability doesn't depend on geography/family-context gates).
**Output:** `[ProposedRelative]` — one mother proposal per distinct
MMN, one father proposal sharing the subject's surname.

Algorithm (per record):

1. Filter to birth records with a non-empty `mothersMaidenName`.
2. Skip if record's source trust tier is below `.transcription`
   (community-only sources are too unreliable).
3. Compute parent birth window: `[subjectBirth − 45, subjectBirth − 18]`
   (parents 18–45 at child's birth).
4. Mother proposal: surname = MMN, gender = female, stable ID =
   `stableID(.parentOf(subjectID), .female, MMN)`.
5. Father proposal: surname = subject's surname, gender = male,
   stable ID likewise.
6. If a proposal with that stable ID already exists, append the new
   record to its `evidence`; do not create a duplicate.

The stable ID is the key invariant: re-running research must produce
the same proposal IDs so rejection state persists.

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
birth records (one focused FreeBMD query) + both parent profile IDs +
the snapshot.
**Output:** `[SiblingProposal]` — birth records matching the subject
on:

- Same surname
- Same mother's maiden name
- Same registration district
- `|year − subject.birthYear| ≤ 20` (typical fertility span)
- Not the subject themselves
- Not already a known child of either parent in the snapshot

The engine is strict by design. A confidence-of-result mechanism
doesn't exist; the contract is "if all keys agree, this is a sibling."

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
`ResearchDiscrepancy`. Severity comes from a deterministic table.

### 10.1 The severity table

`DiscrepancySeverityTable.severity(sourceTier:absDelta:convergence:)`
→ `(severity, reasoning)`.

Base severity by trust tier and delta (years):

| Tier | Δ = 0 | Δ = 1–2 | Δ = 3–5 | Δ > 5 |
|---|---|---|---|---|
| **Primary** (CWGC, official) | `.none` | `.refinement` | `.correction` | `.correction` |
| **Transcription** (FreeBMD, FreeCen, FreeREG) | `.none` | `.none` | `.refinement` | `.conflict` |
| **Community** (FamilySearch, Find a Grave) | `.note` | `.note` | `.conflict` | `.conflict` |

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

### 11.4 Marriage enrichment's secondary dispatch

Marriage enrichment runs its own focused queries — not via the
strictness ladder, but a single direct call per district (groom-side
and bride-side) targeting the same district set as the main
pipeline's scope. The gating policy (T29) prevents enrichment from
triggering one query per candidate MMN: it only runs pairs whose
surnames match either the linked parents OR the resolved-subject's
birth record.

### 11.5 Sibling discovery's tertiary dispatch

`findSiblings` issues one query: surname-only, the subject's
resolved birth district, year window `subject.birthYear ± 20`. No
fan-out, no strictness ladder. Gated on both parents linked +
identity resolved.

---

## 12. The cluster verdict and auto-promote

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

(See `AUTO_APPROVAL_VIA_MCP_SPEC.md` for the orthogonal pending-fact
auto-approval feature exposed through the MCP server — that operates
on `pending_facts` rows, not on cluster proposals.)

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

## 14. Persistence model

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

What **doesn't** persist between runs:

- `ResearchResult.clusters` — recomputed each run from
  `evidence_records`
- `ResearchResult.proposedRelatives` — recomputed; rejection state
  persists, accept creates real relationship rows
- `ResearchResult.proposedSiblings` — same
- `ResearchResult.householdMembers` — recomputed
- `ResearchState` itself — in-memory only

The deterministic re-runnability is the key invariant: same project +
same code = same output. Random IDs (`UUID()`) appear only for
*accepted* new profiles/relationships, not for ephemeral pipeline
output.

---

## 15. What the pipeline does NOT do today (the negative space)

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
8. **Persisted research hypotheses driving second passes.** Each
   `findSiblings` (T17, shipped), each
   `GeographicHypothesisGenerator` call, each
   `SubjectIdentityResolver` resolution is recomputed from scratch.
   The v26 `research_hypotheses` table exists (migration) but is not
   yet driving the pipeline. (T11/T12 target.)
9. **Hypothesis-guided second pass.** No mechanism re-runs the
   pipeline with focused queries derived from the *result* of the
   first pass. (T7 target.)
10. **MLX as planner / disambiguator.** The model only suggests
    record types between iterations and writes prose for the user. It
    doesn't propose hypotheses, doesn't grade, doesn't propose
    specific next searches. (T8/T9 target.)

This is the surface against which Part II proposes.

---

## 16. Source plugins — what's wired today

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

---

## 17. Product-level design requirements

Folded in from the 2026-04-25 design draft. These are the
user-facing problems the pipeline solves and the principles that
shape its outputs. Where the language describes future behaviour, see
Part II for the current roadmap.

### 17.1 The real problem: plausible wrong matches

The 4-gate scorer rejects impossible records. But the dangerous
records are plausible ones for the wrong person. 47 Thomas Lands
born in Derbyshire 1830–1840 all pass the gates. Presenting 30
"facts" for the user to sort through is not research assistance —
it's data dumping.

**The solution is cluster-based presentation, not record-by-record
review.**

### 17.2 Life clustering

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

### 17.3 Three research modes

A generic "Research" button doesn't communicate what the user should
expect. Three modes with different expectations:

| Mode | Goal | Precision/Recall | Stops when | Success looks like |
|------|------|-------------------|------------|-------------------|
| **Verify** | Confirm what's already in the tree | High precision, low recall | All known facts corroborated or contradicted | "3 facts confirmed, 1 discrepancy found" |
| **Extend** | Find missing facts (death date, marriage) | Medium | Missing fields filled or exhausted | "Found death date, found marriage record" |
| **Discover** | Find this person from scratch (ghost node) | Low precision, high recall | Candidate clusters identified | "Found 3 candidate matches, review needed" |

**A verify run that finds nothing is a success** — "we couldn't
disprove your data." **A discover run that finds nothing is a
failure** that needs reporting.

> **Note:** Part II §5.10 proposes collapsing these three modes into
> a single Research button with a four-level auto-escalation ladder
> (`StopPolicy.firstFact` / `.satisfied` / `.exhaustive`). The legacy
> mode names stay until that lands.

### 17.4 Evidence directness

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

### 17.5 Discrepancy threshold justification

The severity table's thresholds (§10) are not arbitrary constants;
each is named and justified:

| Source type | Tolerance | Justification |
|------------|-----------|---------------|
| FreeBMD birth ±2 years | Registration quarter vs actual birth date. A December birth registered in January appears as the following year. |
| FreeCen census age ±3 years | Self-reported by household head, often rounded. Victorian adults frequently misstated age. 1841 census deliberately rounded adults to nearest 5. |
| FreeBMD death age ±1 year | Age at death recorded by informant (usually family). More reliable than census age. |
| Find a Grave dates ±2 years | Volunteer-transcribed from headstones which may be weathered. Sometimes from obituaries with errors. |
| CWGC dates ±0 | Official military records. If CWGC says 14 July 1918, it's 14 July 1918. |

### 17.6 Review friction levels

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

### 17.7 Rejection memory

When a user rejects a record for a profile, that rejection is
sticky. Stored in `record_rejections`. Before presenting results,
the pipeline filters out previously rejected records. This prevents
the same wrong Thomas Land from appearing every time the user
researches.

**Equivalence learning:** When the user accepts "Robert" = "Bob"
during review, store in a user equivalences table (`name_equivalences`).
The name gate checks user equivalences in addition to the hardcoded
nickname table. The system learns from every review session.

### 17.8 Household members as first-class discoveries

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

### 17.9 Per-profile research as the primary mode

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

## 18. Source-surfaced images

**Status:** Proposed. No code yet — none of the seven shipping
source plugins captures any image data, even when the upstream
response carries it.

**Catalyst:** The 2026-05 fix to `FindAGraveSource.swift` that mines
years from inscription/bio free text exposed a larger gap. The
memorial-detail HTML carries `<img id="memPhoto">` and a
photo-gallery section that `parseMemorialDetail` (lines ~248–331)
never touches. Headstone photos with carved dates are some of the
strongest direct evidence a free source produces — and we throw them
away on every fetch.

User framing, verbatim: *"Some sources return images relating to
members of tree, I don't think we capture these presently but we
should and store them linked to profile."*

Treat this section as the seed for a dedicated
`AncestorApp/SOURCE_IMAGES_SPEC.md` if it grows past the first cut
described in §18.6 — much of the data-model and UI surface deserves
its own document. For now it lives here because the question is
fundamentally about the research pipeline: *what does a source
return, where does it land, and how does it count as evidence?*

### 18.1 Source-by-source inventory

| Source | Image-bearing payload | What the parser does today | Cite |
|---|---|---|---|
| **Find a Grave** | Headstone photo (`<img id="memPhoto">`), photo gallery (portrait, additional cemetery shots, military emblems), volunteer-uploaded | Drops them entirely — `parseMemorialDetail` extracts inscription/bio/cemetery/plot but never queries any `<img>` tag or photo-gallery div. `BurialRecord` (RecordTypes.swift:78) has no image field. | `FindAGraveSource.swift:248-331` |
| **CWGC** | Cemetery photographs and (for many casualties) a headstone or memorial-panel photo on the casualty-details page; downloadable certificate PDF | Drops them — `parseCSV` (the only ingest path) consumes the CSV export which is text-only. The detail-page HTML at `cwgc.org/find-records/.../casualty-details/{id}/` carries the imagery and is never fetched. | `CWGCSource.swift:142-213` (parseCSV is text-only); detail HTML is never touched |
| **FamilySearch** | Image waypoints (digitised microfilm scans) referenced from `sourceDescriptions[].links[]`, plus a `RectangleRegion` source-reference qualifier (FAMILYSEARCH_SOURCE_SPEC §5.5) marking *which row on the page* this persona occupies. Also Memories (user-uploaded portraits, certificates, family photos attached to FamilySearch tree persons). | Current parser decodes a narrow subset of GEDCOMx. `GxRoot` decodes `persons`, `relationships`, `sourceDescriptions` but **not** `links`. There is no Memories endpoint integration. | `FamilySearchSource.swift:746-754, 825-830` — `links: [...]` field absent on decoded structs |
| **Wirksworth** | Pedigree pages occasionally embed scanned images of original pedigree-book pages (HTML `<img>` tags); some pages include parish-register photos | Drops them — the parser is text-only | `WirksworthSource.swift:108+, 145+` |
| **FreeBMD** | None directly (index only). But the index entries carry GRO reference fields (volume / page) that *point to* a registry image obtainable separately. | Parser captures volume/page in `rawFields` but does not synthesise a GRO image link. | `FreeBMDSource.swift` — no image fields in `BirthRecord`/`DeathRecord`/`MarriageRecord` |
| **FreeCen** | None directly (transcription only). But each entry carries piece/folio/page from the underlying TNA census, which is the address of a TNA digitised page image. | Parser captures piece/folio/page/schedule/house_number/address in `rawFields` but does not link to the TNA image. | `FreeCenSource.swift:351` |
| **FreeREG** | None — transcription only. Some parish-register transcriptions reference originals at FamilySearch (cross-source link). | No image handling. | `FreeREGSource.swift` |
| **Probate** | Modern grants page sometimes links to a will-document PDF (post-1996 digital grants); older calendar entries have no image. The Nuxeo JSON response may carry a document URL. | Parser does not extract any URL beyond the grant text. | `ProbateSource.swift` |

**Direct-evidence sources where we drop images today:** Find a Grave,
CWGC, FamilySearch, Wirksworth.

**Index sources where we have a reference but no synthesised image
URL:** FreeBMD (GRO volume/page), FreeCen (TNA piece/folio/page).

**Transcription-only, no image:** FreeREG.

**Modern-records source, image rare:** Probate.

### 18.2 What's already in the data model

The repo already has an `attachments` table (migration
`v10_attachments_goals`, `ProjectDatabase.swift:486-512`) and an
`Attachment` model (`Models/Attachment.swift`). It was originally
scoped to **user-uploaded** media per DESIGN.md §5.15 — photos and
documents the user drags onto a profile, life event, or field source.

The `AttachmentTarget` union already supports targeting a profile, a
life event, or a specific `(entityID, field)` field-source row.
That's a near-fit for source-surfaced images — a headstone photo
from Find a Grave logically attaches to the burial life event *and*
corroborates the death-date field source.

**What's missing for source-surfaced media:**

1. **Provenance fields.** No `sourceID`, no `sourceRecordID`, no
   `originalURL`. We can't tell a user-uploaded photo from one we
   downloaded from cwgc.org. This is load-bearing for §18.5 (trust +
   evidence weight).
2. **Subtype.** The current `AttachmentType` enum has only `photo /
   document / transcription`. For source-surfaced media we need to
   distinguish headstone / portrait / certificate / document scan /
   cemetery / pedigree.
3. **URL-only vs blob-cached.** No `fetchStatus` to indicate "URL
   recorded, file not downloaded yet" vs "downloaded and on disk at
   `relativePath`."
4. **Source-record link.** No FK to `source_records.id` — we can't
   trace a photo back to the search hit that surfaced it.

### 18.3 Open question: extend `attachments` vs new `source_media` table

Two viable shapes. Pick one before implementation; both have real
costs.

**Option A — extend `attachments` with provenance columns.** Add
`source_id`, `source_record_id`, `original_url`, `fetch_status`, and
refine `media_type` to the six-category subtype list. Keep one
table, one query path, one inspector UI section. The cost is mixing
user-curated media (which the user "owns") with discovered media
(which we surfaced and the user may not even know about yet). A user
clicking "delete photo" on something they uploaded behaves
differently from clicking it on something the pipeline pulled in.

**Option B — new `source_media` table** parallel to `attachments`.
Discovered images live there until the user "accepts" them, at which
point they're either promoted into `attachments` (and the
source-media row marked accepted) or remain in source-media as
evidence-only. The cost is duplication: two queries to render a
profile's image strip, two delete paths, two export rules.

Recommendation, not decision: **Option B** mirrors the existing
Evidence Firewall pattern (§13) — `pending_facts` for proposed facts
is separate from the `field_sources` table for accepted ones.
Source-surfaced media is to user-curated media as `pending_facts` is
to `field_sources`. The user "accepting" a Find a Grave headstone
photo via TreeDiffView is the analogue of accepting a date — it
crosses the firewall.

What is **not** deferrable is recording provenance the moment a
parser sees an image URL.

### 18.4 Proposed data-model additions (Option B sketch)

```swift
/// An image (or PDF) surfaced by a source plugin during research,
/// attached to the profile the surfacing search was about. Lives
/// behind the Evidence Firewall: pipeline writes, user accepts in
/// TreeDiffView.
struct SourceMediaCandidate: Codable, Identifiable, Sendable {
    let id: UUID
    let profileID: String
    let sourceID: String                  // "findagrave", "cwgc", "familysearch", ...
    let sourceRecordID: String            // FK into source_records.id
    let mediaKind: SourceMediaKind
    let originalURL: String               // canonical, never null at insert
    let caption: String?                  // alt text or scraped figure caption
    let mimeTypeHint: String?             // "image/jpeg", "application/pdf"
    let fetchStatus: FetchStatus          // urlOnly / cached / failed(reason)
    let cachedRelativePath: String?       // populated when fetchStatus == .cached
    let cachedAt: Date?
    let cachedByteSize: Int64?
    let discoveredAt: Date
    let createdByTransactionID: String    // undo-tracked like every other firewall write
    var acceptedAt: Date?                 // user accepted into permanent attachments
    var promotedAttachmentID: UUID?       // FK into attachments.id when accepted
}

enum SourceMediaKind: String, Codable {
    case headstone, portrait, certificate, documentScan, cemetery, pedigree, other
}

enum FetchStatus: Codable {
    case urlOnly                          // we know the URL, file not on disk
    case cached                           // file is on disk at cachedRelativePath
    case failed(reason: String)           // tried to fetch, host returned error
}
```

Migration shape:

```sql
CREATE TABLE source_media (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    source_record_id TEXT NOT NULL,
    media_kind TEXT NOT NULL,
    original_url TEXT NOT NULL,
    caption TEXT,
    mime_type_hint TEXT,
    fetch_status TEXT NOT NULL DEFAULT 'urlOnly',
    cached_relative_path TEXT,
    cached_at DATETIME,
    cached_byte_size INTEGER,
    discovered_at DATETIME NOT NULL,
    created_by_transaction_id TEXT NOT NULL,
    accepted_at DATETIME,
    promoted_attachment_id TEXT,
    FOREIGN KEY (source_record_id) REFERENCES source_records(id),
    FOREIGN KEY (promoted_attachment_id) REFERENCES attachments(id)
);
CREATE INDEX idx_source_media_profile ON source_media (profile_id);
CREATE INDEX idx_source_media_record ON source_media (source_record_id);
```

`RecordCommon.rawFields` is the wrong home (string-only, no schema,
lost on re-parse). The parsers should populate a new optional
`discoveredMedia: [SourceMediaURL]` on `RecordCommon` (or per-typed
record where it makes sense) and the persistence layer is responsible
for writing rows into `source_media` keyed off `source_records.id`.
Keeping `discoveredMedia` on the typed record (not just `rawFields`)
means tests can assert on it and the scorer can read it.

### 18.5 Open question: do images count toward the 4-gate scorer / evidence directness?

Today's `EvidenceDirectness` ladder is `.primary /
.independentTranscription / .derivative / .communityEdited`. A Find
a Grave memorial is `.derivative` because the volunteer transcribed
dates from a headstone they did not necessarily photograph. **But a
Find a Grave memorial with a headstone photo carrying the carved
dates collapses that gap** — the user (or, post-MLX, the local
model) can read the dates off the stone themselves.

Three positions, all defensible:

1. **Images don't affect scoring.** They're decoration / verification
   aid.
2. **Images upgrade directness, deterministically.** A Find a Grave
   record with an attached headstone photo of the actual gravestone
   gets re-tiered from `.derivative` to `.primary` for the death-date
   field specifically.
3. **Images are an MLX-task.** The local model OCRs/reads the
   headstone photo, emits its own structured facts, those go through
   `pending_facts` as an independent source.

Recommendation, not decision: **(3) is the only one that respects the
deterministic sandwich** (§3.3). Position (2) would let the
*presence* of an image dictate scoring, which makes the scorer
dependent on a network fetch having succeeded — non-deterministic.
Position (3) treats the image as fresh data, lets the convergence
engine decide, and keeps the scorer pure.

For the first cut, **adopt (1)**: capture and display, no scoring
impact. Revisit when the local-vision story exists.

### 18.6 First-cut scope (one focused session)

**Goal:** Source-surfaced images flow into a persistent table, are
visible on the profile inspector, and survive across sessions. No
download-by-default; no scoring impact; no GEDCOM export.

**In scope:**

- Migration `v_source_media` adding the table from §18.4.
- `SourceMediaCandidate` model + read/write in a new
  `ProjectDatabase+SourceMedia.swift`.
- `RecordCommon` (or per-record-type) gains optional
  `discoveredMedia: [SourceMediaURL]`.
- **Find a Grave first** (highest-yield, lowest-risk).
  `parseMemorialDetail` extracts the hero photo and gallery (capped at
  20 per memorial).
- **CWGC second.** Extend the source to fetch the casualty-details
  HTML page and extract the headstone/memorial photograph plus the
  certificate PDF URL.
- **FamilySearch third.** Decode `links[]` on `GxSourceDescription`
  and capture the image-waypoint URL + the `RectangleRegion`
  qualifier alongside it.
- URL-only persistence by default. **No automatic download.** A
  "Download" affordance on each media row in the inspector triggers
  a fetch with the same rate-limit + auth contract as the parent
  source.
- Inspector UI: a collapsed-by-default "Source-discovered images (N)"
  disclosure under the existing Sources section on the profile detail
  view.

**Out of scope for first cut:**

- Wirksworth pedigree-page image extraction.
- FreeBMD GRO image-link synthesis.
- FreeCen TNA image-link synthesis.
- Probate will-PDF.
- Memories endpoint integration on FamilySearch.
- Image-driven evidence promotion (position 2 or 3).
- GEDCOM `OBJE` export.
- Vision-model OCR of headstones.
- Copyright/redistribution surfacing in shared exports.
- Background eviction of cached blobs to manage disk.

### 18.7 Storage strategy: URL-only vs blob-cached

Both are needed, and the tradeoffs argue for "URL recorded on
discovery, blob cached on demand" — the `fetchStatus` field in §18.4
encodes the lifecycle.

**Proposed policy:**

- On parse, always write a `source_media` row with `fetchStatus =
  .urlOnly` and the URL.
- **Auto-cache** when *any* of: the source is Find a Grave (volunteer
  deletion risk); the source requires auth and we have a valid
  session right now (FamilySearch — fetch while we can); the image is
  small (`<200KB` heuristic, from `Content-Length` HEAD).
- **Manual cache** ("Download" button) for everything else.
- **Settings toggle**: "Cache all source-discovered images
  automatically" (default off) for power users who want the offline
  archive.

This is the same pattern as the existing `page_cache` (migration v5)
— speculative caching of source HTML for re-parse. Source media is
the binary analogue.

### 18.8 Trust + provenance

Every `source_media` row carries `sourceID` and `sourceRecordID`. The
trust tier of the media is inherited from the source — there is no
LLM-driven "this looks like a real headstone" judgement (cf. §3.1
invariant: source trust is URL-derived). A Find a Grave photo is
`.community`-tier evidence by virtue of being from Find a Grave,
regardless of how authoritative the image *looks*.

When the user accepts a `source_media` row into permanent
`attachments` (via the §18.3 Option B promote path), the new
`Attachment` row carries `sourceID` and `originalURL` columns so the
provenance chain is preserved indefinitely.

---

## 19. Cross-source enrichment — FamilySearch → Find a Grave bridge

**Status:** First cut shipped 2026-05-20. Section records the
pattern for future cross-source bridges.

### 19.1 The problem this solves

FamilySearch's `/service/search/hr/v2/personas` endpoint acts as an
aggregator across many underlying databases — civil registration,
censuses, parish registers, and importantly **Find a Grave
memorials**. When a query surfaces a FAG-hosted memorial, the
GEDCOMx response carries:

- The deceased's name and the burial place
- An `ExtRecordId` field containing the FAG memorial number
- A `sourceDescriptions[0].titles[0].value` of "Find a Grave Index"
  (or similar)
- **No `Birth`, `Death`, or `Burial` fact with a date.** FS's index
  of FAG carries the structured persona but not the inscribed dates.

That last point is load-bearing. A FAG memorial whose inscription
says "1919 — 2017" is one of the strongest free-source pieces of
death-date evidence available — but the FS aggregator does not
surface those dates. Without intervention the record stalls as a
lead, the 4-gate scorer can't promote it (no year axis to match
against), and the next-iteration `refineSubject` never gets a death
year to propagate to the other 7 sources.

Concrete case: Ernest Victor Cauldwell's research run found his FAG
memorial via FS, with name + Wirksworth + nothing else. Probate for
the same person carrying "ERNEST VICTOR CAULDWELL, ADMINISTRATION
2017-02-14" was already in evidence — scored `impossible` because
the subject had no death year to converge against. Two pieces of
evidence one fact-confirmation apart, and the pipeline couldn't
close the loop.

### 19.2 The bridge

In the parser (`FamilySearchSource.swift`):

- For any persona whose collection title matches `Find a Grave`,
  extract the FAG memorial id from
  `rawFields["field.ExtRecordId.original"]` (or `.interpreted`, or
  unmarked variant). Strip non-digit prefixes defensively.
- Populate the resulting `BurialRecord.memorialID` so the pipeline
  can route on it.

In the pipeline (`ResearchPipeline.swift`):

- Between dispatch and score, run `enrichFagBridge(records:existingIDs:)`.
  For every `FamilySearch`-sourced burial record where `memorialID` is
  set but `deathYear` is nil and the FAG-detail id is not already in
  evidence, call `FindAGraveSource.fetchDetail(recordID: "findagrave_\(memorialID)")`.
- **Append the FAG-detail record alongside the original FS persona**,
  do not replace. Both score independently; the scorer's convergence
  engine reunites them in clustering. Replacing would silently
  downgrade the FS persona's trust tier (FS is `.transcription`, FAG
  is `.community`), which is a scorer call the bridge has no business
  making.

The FAG detail parser already mines the inscription / bio for year
ranges (`FindAGraveSource.extractYearsFromMemorialText`). So once the
bridge places the record in FAG's pipeline, the year extraction is
automatic.

### 19.3 Why the bridge belongs in the pipeline, not in the source

Two reasons:

1. **The source should stay independent.** `FamilySearchSource`
   calling `FindAGraveSource` couples two source plugins that are
   otherwise free to evolve independently. The pipeline is the right
   level for cross-source orchestration — it already orchestrates
   dispatch, scoring, clustering, hypothesis generation.
2. **The bridge needs the pipeline's state.** Skipping memorials
   already seen in a prior iteration (the `existingIDs` argument)
   requires knowing what records the pipeline has accumulated so
   far. A source plugin doesn't see that.

### 19.4 First-cut scope and what's deferred

**In scope:**

- FS-to-FAG bridge described above.
- One follow-up fetch per FS burial persona per run. Rate-limited
  via the existing FAG 500ms-per-request gate.
- Deduplication across iterations of the main pipeline loop.

**Out of scope for first cut:**

- **Generalised bridge framework.** This is one hand-rolled case. If
  we add a second (e.g. FreeBMD → GRO image-link synthesis, or CWGC
  → detail-page image fetch), generalise then — premature now.
- **Bridge from non-FS sources to FAG.** FAG hits can also come
  directly from `FindAGraveSource.search`; those already go through
  `fetchDetail` via the search→detail pattern. Only the FS aggregator
  needed bridging.
- **MLX-driven decision to bridge.** The bridge is deterministic —
  collection-title match + missing year. No model judgement involved.

### 19.5 Convergence behaviour after bridging

When the bridge fires, the pipeline accumulates:

- **Record A**: FS burial persona, sourceID=familysearch,
  memorialID=N, deathYear=nil. Tier `.transcription`.
- **Record B**: FAG burial detail, sourceID=findagrave, memorialID=N,
  deathYear=Y (from inscription mining). Tier `.community`.

Both records share the same memorial ID. The scorer's convergence
engine treats two records pointing to the same memorial as
independent attestations — A confirms the *existence* of the memorial
via FS, B confirms the *content* of the memorial via FAG. They
converge on:

- Name (both have it)
- Place (both have it — FS as `place.original` on the burial fact,
  FAG as `burialLocation`)
- Death year (only B has it; A's scoring against the now-refined
  subject improves)

The subject-refinement step (`refineSubject`) then folds the death
year into the subject for the *next* iteration. Downstream sources
get a tighter query: FreeBMD death index narrows to year=Y, Probate
likewise, FreeREG parish-burial likewise.

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
    case subjectIdentity(birthYearWindow: Range<Int>, districtHint: String?)
    case parentMarriage(motherSurname: String, fatherSurname: String, windowYears: Range<Int>)
    case siblingExists(district: String, mmn: String, yearWindow: Range<Int>)
    case clusterIsSubject(clusterID: UUID)       // T7's working hypothesis
    case burialAtParish(parish: String, yearWindow: Range<Int>)
    case secondMarriage(afterYear: Int)
    // ... extensible by adding cases here + the three central switches
}

enum HypothesisVerdict: String, Sendable {
    case supported       // evidence points to claim
    case contradicted    // evidence rules claim out
    case inconclusive    // not enough evidence to decide
}

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

```swift
@MainActor
enum HypothesisEngine {
    /// Run every registered generator against the current state.
    /// Each generator returns 0..N candidate hypotheses; the engine
    /// dedups by stable ID against persisted hypotheses, tests each
    /// fresh / refreshed hypothesis against available evidence, grades
    /// it, and returns the full set.
    static func runAll(
        state: ResearchState,
        snapshot: FamilyGraphSnapshot,
        persisted: [ResearchHypothesis]
    ) -> [ResearchHypothesis]
}
```

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

**Upsert semantics**: when `HypothesisEngine.runAll` produces a
hypothesis whose stable ID already exists in the table, the row is
updated (verdict, evidence, reasoning, history append, lastTestedAt)
— not replaced. The `created_at` and `history` carry forward.

**User-rejection persists**. A hypothesis the user has explicitly
dismissed (e.g. "this sibling isn't mine") flips `user_rejected = 1`
and is filtered out of UI display on subsequent runs.

---

## 5. Task-by-task — how each remaining task fits

### 5.1 T11 — Hypothesis type + persistence

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

T12 splits into two sequenced sub-projects (Decision 3). Each
sub-project is itself executed as a 4-phase migration (Decision 2).
Total: 8 commits across T12, each individually bisectable, each
behaviour-identical to the prior commit until the final phase
deletes the legacy field.

#### T12-sibling — fold `.siblingExists` into the framework

| Phase | What changes |
|---|---|
| 1 | `Services/Research/HypothesisEngine.swift` with `runAll` entry point + central `generate` / `grade` / `deficitQuery` switches. `.siblingExists` case added with generator + grader + deficit-query clauses. `result.hypotheses` field populated. `result.proposedSiblings` still populated by the legacy `findSiblings()` path. Both fields verified identical via tests. |
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
step in `HypothesisEngine.runAll`.

| Phase | What changes |
|---|---|
| 1 | Both `.parentInferred(gender, surname)` and `.parentMarriage(motherSurname, fatherSurname, window)` kinds added together with their generate / grade / deficit-query clauses (separate extension files per Decision 5). `HypothesisEngine.reconcileParentMarriages` lands in the central engine and is called at the end of `runAll`. `result.hypotheses` carries both new kinds with the marriage evidence already cross-referenced onto the parent hypotheses. `result.proposedRelatives` still populated by the legacy `ParentInferenceEngine.infer` + `enrichParentsWithMarriage` paths. Both surfaces verified projection-equal via tests. |
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
The engine reconciles the two during `runAll`: a supported
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
- **Reconciliation step:** after `runAll` grades every kind, a new
  function `HypothesisEngine.reconcileParentMarriages` walks
  `.supported` `.parentMarriage` hypotheses and, for each, finds the
  two `.parentInferred` hypotheses they cross-reference. It appends
  the marriage record ID(s) to each parent's `supportingEvidence` and
  a sentence ("given name 'X' from marriage 'Y'") to each parent's
  `reasoning`. The reconciliation is a pure join over the hypothesis
  list — no dispatch, no model — so `isModelAssisted` on the parent
  hypotheses stays `false` and `isDeterministicallySupported` is
  preserved.

### 5.3 T7 — Hypothesis-guided second pass

**What lands:**
- A second-pass entry point in `ResearchPipeline` that runs after
  the first pass completes: `researchSecondPass(firstResult:state:)`.
- The pass examines `firstResult.hypotheses` and selects those with
  `verdict == .inconclusive` and a non-nil result from
  `deficitQuery(for: h, atLevel: h.attempts + 1, state: s)` (per
  Decision 5 — `nil` at any level means the kind's ladder ceiling is
  reached).
- For each, dispatch the returned query, append new evidence to
  `state`, increment the hypothesis's `attempts`, re-run
  `HypothesisEngine.runAll`, recompute clusters.

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

### 5.4 T8 — MLX next-search suggestion for weak verdicts

**What lands:**
- An MLX prompt + a
  `ResearchInterpreter.suggestForWeakHypothesis(hypothesis:state:availableSources:)`
  entry point.
- Wired into T7's second pass: when T7 finds an inconclusive
  hypothesis that is **exhausted** at its kind's deficit-query ladder
  (`deficitQuery(..., atLevel: attempts + 1, ...) == nil`), T8 is
  the fallback. It asks the model "given this hypothesis and what we
  know, what would you search?"
- Output is restricted to `(sourceID, recordType, queryHints)` —
  structured, not free-form. The deterministic dispatcher still
  builds and runs the query.

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

> The shipped threshold is the lowest value `θ` such that
> user-agreement rate on the eval-harness disambiguation corpus (per
> §5.8) at threshold `θ` is **≥ 75%**. Below 75%, the threshold is
> raised until either the rate clears or no remaining tie-breaks
> pass.

The specific numeric value of `θ` is TBD until the harness has
corpus data. The setting rule is fixed now. T9 can ship with the
threshold pinned at "always reject" (no model output ever acted on)
until the harness produces enough data to set `θ` defensibly.

### 5.6 T23 — Guided Sample Tree tour (out of band)

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

### 5.8 Eval harness (prerequisite for T7 / T8 / T9 / T31)

Not a numbered task, but load-bearing infrastructure that ships
before T7 / T8 / T9 / T31 can have defensible deltas.

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

---

## 6. Holistic architecture (post-V2)

```
┌─────────────────────────────────────────────────────────────────────────┐
│  ResearchPipeline.research(subject:, config:)                           │
│                                                                          │
│  PASS 1 (deterministic iterative core, ~unchanged from today):          │
│    1. dispatch  →  score  →  dedup                                      │
│    2. extract household / detect discrepancies / refine subject         │
│    3. ParentInferenceEngine.infer                                       │
│    4. (first iteration with proposals) MarriageEnrichmentEngine.match   │
│    5. (between iterations) ResearchInterpreter.suggestNextSearch        │
│    6. stopping checks                                                   │
│                                                                          │
│  POST-PASS-1 (unchanged):                                               │
│    7. ClusteringEngine.cluster                                          │
│                                                                          │
│  NEW: HypothesisEngine.runAll(state, snapshot, persisted)               │
│    • Generators per kind (SubjectIdentity, ParentMarriage,              │
│      SiblingExists, ClusterIsSubject, ...)                              │
│    • Graders per kind (deterministic)                                   │
│    • Persistent upsert keyed on stable hypothesis ID                    │
│    • Return [ResearchHypothesis]                                        │
│                                                                          │
│  PASS 2 (T7: hypothesis-guided second pass, fires when                  │
│           strictness exhausted AND ≥1 inconclusive deficit hypothesis): │
│    8. For each inconclusive hypothesis with a deficit query:            │
│       a. dispatch deficit query                                         │
│       b. (T8 fallback if no deficit query) MLX next-search              │
│    9. score / dedup / append to state                                   │
│   10. HypothesisEngine.runAll again — re-test, re-grade                 │
│                                                                          │
│  PASS 3 (T9: MLX tie-break for residual ambiguity)                      │
│   11. For each ambiguous .subjectIdentity hypothesis the rules          │
│       couldn't settle:                                                  │
│       a. MLX disambiguate (structured output, threshold-gated)          │
│       b. annotate the hypothesis as model-assisted                      │
│                                                                          │
│  RESULT ASSEMBLY:                                                       │
│   12. clusters (recomputed if Pass 2 added evidence)                    │
│   13. hypotheses (all kinds, persisted)                                 │
│   14. legacy fields — during T12 transition only, derived as            │
│       projections of `hypotheses`. Deleted by final phase of each       │
│       T12 sub-project (proposedSiblings, then proposedRelatives).       │
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

Eight substantive design choices resolved during the 2026-05-19 spec
walk-through, plus one carry-over from the original spec draft. Each
is now load-bearing for the corresponding task.

### 7.1 — `HypothesisKind` shape and per-kind code organisation

**Resolution**: **closed Swift enum with associated values, with
per-kind logic decomposed into extension files**. The three central
switches in `HypothesisEngine.swift` stay thin entry points — each
switch dispatches to per-kind static methods defined in a
`HypothesisEngine+<Kind>.swift` extension. All three operations for a
given kind (`generate*`, `grade*`, `deficitQuery*`) live adjacent in
one file.

### 7.2 — Migration of `proposedSiblings` (T12-sibling)

**Resolution**: **hard migration executed as four bisectable phases**
— Phase 1 in-place duplicate, Phase 2 flip source of truth, Phase 3
swap UI to read `result.hypotheses` directly, Phase 4 delete
`proposedSiblings` field.

### 7.3 — Fold `proposedRelatives` into the framework too (T12-parent)

**Resolution**: **yes, with the same four-phase pattern as
T12-sibling, sequenced after it.**

### 7.4 — Stall-detection contract for T7

**Resolution**: T7's second pass fires when **both** (a) the
dispatcher has walked the full strictness ladder for every applicable
source AND (b) ≥1 `.inconclusive` hypothesis has a non-nil
`deficitQuery`.

### 7.5 — Deficit query declaration style and ladder shape

**Resolution**: **central switch in `HypothesisEngine`** dispatching
to per-kind extension methods (per Decision 1's revised
organisation). Signature: `deficitQuery(for hypothesis:atLevel:state:) -> RecordQuery?`.
Each kind defines its own expansiveness ladder; `nil` at any level =
the kind's ceiling reached = hypothesis exhausted.

### 7.6 — Eval harness scope and rollout

**Resolution**: commit to a 3-profile starter corpus that grows over
time, with three refinements: per-hypothesis-kind reporting,
snapshot-based evaluation, single headline number.

### 7.7 — Local MLX vs Claude API for T8 / T9

**Resolution**: **local MLX for T8 and T9** as initial path.
Escape-valve to API in a future task if the eval harness shows MLX is
leaving findings on the table.

### 7.8 — MLX nondeterminism representation

**Resolution**: **orthogonal `isModelAssisted: Bool` field** on
`ResearchHypothesis`, not a new verdict case. Auto-promote and
similar deterministic-only gates use the
`isDeterministicallySupported` helper.

### 7.9 — Cluster-aware scoring (out of V2 scope)

**Resolution**: deferred. Important (gates the G1 cross-profile
dedup task) but neither in the current task list nor a prerequisite
for any V2 task.

---

## 8. Build order

Strict dependencies (post-decisions):

```
T11 (type + v26 migration + persistence helpers)
 └─→ T12-sibling Phase 1–4 (.siblingExists folds in)
      └─→ T12-parent design-pass (marriage-enrichment coupling)
           └─→ T12-parent Phase 1–4 (.parentInferred + .parentMarriage fold in)
                ├─→ Eval harness runner + 3-profile starter corpus (§5.8)
                │    ├─→ §5.9 Pipeline incrementality refactor
                │    │    ├─→ T7 (second pass; deficit queries via level-dispatch)
                │    │    │    [requires corpus at 10–12 profiles]
                │    │    ├─→ §5.10 Research button collapse + auto-escalation UX
                │    │    └─→ §5.11 Hypothesis investigation as user action
                │    │         └─→ T8 (MLX next-search for exhausted-ladder)
                │    │              [requires corpus at 20–30 profiles]
                │    │              └─→ T9 (MLX disambiguation for residual ambiguity)
                │    │                   [requires corpus at 20–30 profiles]
                │    └─→ T31 (ladder retuning, one-shot experiment)
                │         [requires corpus at 20–30 profiles + §5.10 landed]
                ├─→ T23 (Sample Tree tour, any time post-T12)
                └─→ §5.12 Design passes (each its own deliverable, parallel)
```

Estimated total: **24–32 sessions**. The engine foundation (T11
through T7) is ~12–16 sessions; the UX reframe (§5.10–§5.11) plus
extended MLX work and corpus growth adds ~12–16 sessions.

---

## 9. What this V2 does NOT do

Holdovers, explicitly out of scope:

- **G1 (cross-profile dedup).** Important, but not in the current
  task list. Future task.
- **G7 (subtle merge detection).** Same.
- **MLX as primary grader.** No. Graders stay rule-based. MLX only
  enters when rules return inconclusive/ambiguous.
- **Per-source autotuning.** Today's per-source strictness configs
  (T37, T38) are static and stay static.
- **Cluster-aware scoring.** §7.9 flagged.
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
