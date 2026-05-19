# Research Pipeline — Specification

**Status:** Combined. Part I (current state) is descriptive; Part II (V2) is accepted, implementation pending.
**Supersedes:** the 2026-04-25 `RESEARCH_PIPELINE_SPEC.md` (historical design-intent doc).
**Folds in:** `archive/LLM_RESEARCH_OPTIONS.md` (decision-staging portfolio analysis; archived as the dated record).
**Date:** 2026-05-19 (post-T17 — sibling discovery shipped).

This document is in two parts. **Part I** is the as-built reference for the pipeline as it actually runs today. **Part II** is the accepted V2 design pivot — the architectural change that the seven remaining open tasks (T7, T8, T9, T11, T12, T23, T31) collectively implement.

Internal `§X` references within each Part are scoped to that Part. Cross-Part references use "Part I §X" / "Part II §X".

---

# Part I — Current state (as-built)

This Part describes the pipeline as **built**. It is the baseline against which Part II proposes change. Where this conflicts with the 2026-04-25 `RESEARCH_PIPELINE_SPEC.md`, the code wins.

## 1. What this is, and is not

**Is:** a behavioural inventory — what the code does today, with file:line refs, constants, thresholds, and the design rationales pinned in code comments. Read this when you need to know "does the pipeline already do X?" before adding a new subsystem.

**Is not:** a design-intent doc. The original `RESEARCH_PIPELINE_SPEC.md` (2026-04-25) covers that. Several names there (`StrategyAdvisor`, `LeadInvestigator`, `BiographyDrafter`) never shipped under those names; the actually-shipped LLM components are `ResearchInterpreter` and `NarrativeAssembler`.

**Is not:** a tutorial. The user-facing flow is documented elsewhere; this is the engine side.

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

**The deterministic-probabilistic-deterministic sandwich.** All decisions about whether a record matches, whether two records corroborate, whether a discrepancy is severe, and whether a fact is committed are made by rules. The local reasoning model (MLX) is restricted to between-iteration suggestions about *where to look next* and post-hoc *prose comparison* of already-graded clusters. It cannot override the scorer.

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

The model **cannot** classify records, decide convergence, or pick winners. Its output is "advice for the next iteration" or "prose for the user" — never a decision.

### 3.3 The deterministic-wins rule

When the model and the deterministic engine disagree, deterministic wins. Convergence can upgrade a discrepancy severity but never downgrade it. There is no path by which model output writes a Profile field or a Relationship.

---

## 4. The RecordScorer — four gates and a verdict

`RecordScorer.classify(record:subject:searchType:)` is the **only** way a `SourceRecord` becomes a `ScoredRecord`. Each call runs four gates and rolls them up into a verdict.

### 4.1 The gates

| Gate | Checks | Outcomes | Failure mode |
|---|---|---|---|
| **Name** | Surname similarity ≥0.7 AND given-name similarity ≥0.7. Middle-name guard: when subject has a middle name, record must agree (initial or substring). | `pass` / `fail` | Name `fail` always becomes `.impossible` — wrong person |
| **Date** | Record's year fits subject's birth window `[birthLow − tol, birthHigh + tol]`. Hard rules: died before born, married before born, age >110 at death, age <16 at marriage. | `pass` / `softFail` / `fail` / `impossible` | `impossible` short-circuits the entire roll-up to `.impossible` |
| **Geography** | Record district matches subject home district / Chapman code. Foreign-country tokens hard-fail. | `pass` / `softFail` / `fail` / `skip` | Mode-dependent: `.all` mode demotes failure to `.lead`; other modes treat it as `.impossible` |
| **Family context** (bonus) | Census household contains a known spouse/child, OR marriage record's spouse matches a known spouse profile. | `pass` / `softFail` / `skip` | `softFail` only — never decisive |

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

A record is a `.fact` only if every gate cleanly passes. Any softFail (typically geography "unknown district" or family context "spouse not present in household") drops it to `.lead`. Records become `.impossible` when name fails outright, or when date is mathematically incompatible (cannot have died in 1920 if married in 1925).

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

- **Middle-name guard** (May 2026): five same-name Jennifer Holmes 1947–49 births previously all passed because no middle-name comparison happened. Now `RecordScorer.middleNameMatches` rejects when subject has a middle name and record middle content disagrees. (T15.)
- **Birth-year window is a range, not a point** (T4): the date gate uses `[birthYearFrom, birthYearTo]` ± tolerance, not just `birthYearFrom`. Cluster verdict re-grades wide-window facts to `.lead`-equivalent when corroboration is thin.

---

## 5. The pipeline lifecycle

`ResearchPipeline.research(subject:config:)` is one async call that returns a `ResearchResult`. Internally it runs **N iterations** (mode-dependent maximum) followed by a single **post-loop** phase.

### 5.1 The iteration loop

For each iteration 1…`maxIterations`:

1. **Dispatch.** `SearchDispatcher.dispatch(subject:recordTypes:scope:mode:)` fans out to every applicable source and returns `[SourceRecord]`. The dispatcher honours the strictness ladder (§9) and scope-widening rules.
2. **Score.** Each raw record goes through `RecordScorer.classify` → `[ScoredRecord]`.
3. **Dedup.** Records already collected in prior iterations are filtered out before append. This catches the "same record re-fetched at every iteration" problem (T30) — historically, narrow scopes would silently double or triple count.
4. **Household extraction.** From census `.fact` records: pull `household` members and dedup by uppercase name against `state.householdMembers`.
5. **Discrepancy detection.** For each new `.fact` record, compare its key fields (birth year, death year) against existing subject data. Severity comes from `DiscrepancySeverityTable.severity(sourceTier:absDelta:convergence:)` — see §10.
6. **Subject refinement.** Confirmed facts feed back into the subject: a confirmed birth year tightens `birthYearFrom`/`birthYearTo`, a confirmed death year does the same. Census age + census year imply a birth year when none is known.
7. **Parent inference.** `ParentInferenceEngine.infer` runs against *facts + leads* (not just facts — see §6.4). Output: `[ProposedRelative]`, deduplicated by stable ID across iterations. Evidence records accumulate per proposal.
8. **Marriage enrichment.** First iteration where proposals exist: `MarriageEnrichmentEngine.match` joins groom-side and bride-side BMD queries by reference tuple to fill in parent given names. Gated on either both parents linked OR subject identity resolved (search-storm guard, §11.2). Once attempted, never re-run within a pipeline call.
9. **Reasoning suggestion.** Between iterations only: `ResearchInterpreter.suggestNextSearch` may propose adding a record type to `state.activeRecordTypes`. The deterministic dispatch still decides what runs next.
10. **Stopping checks** (any one breaks):
    - confirmedFacts ≥ `config.maxFacts`
    - mode `.verify` AND at least one confirmed fact (verify stops as soon as anything corroborates)
    - dispatch returned zero records
    - **stable-point**: iteration >1 AND no new records since last iteration (catches the "narrowing search returns the same set forever" loop)

### 5.2 The post-loop phase (one-shot)

After the iteration loop exits:

1. **Clustering.** `ClusteringEngine.cluster(records:sourceInfoMap:homeChapmanCode:)` runs the 5-step algorithm (§7). Marriage-enrichment records are filtered out of the cluster input — they describe the parents' marriage, not a candidate life of the subject, and surface under `ProposedRelative.evidence` instead.
2. **Sibling discovery** (T17). `findSiblings(state:)` gates on subject identity resolved + both parents linked. If both gates clear, it dispatches **one focused FreeBMD query** (surname-only, single district, ±20-year window) and runs `SiblingInferenceEngine.inferSiblings`. Returns `[]` otherwise.
3. **Result assembly.** A `ResearchResult` carries: `confirmedFacts`, `leads`, `allScoredRecords`, `clusters`, `discrepancies`, `householdMembers`, `searchHistory`, `proposedRelatives`, `proposedSiblings`.

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

The pipeline produces three kinds of inferred output beyond the raw scored records: **parents**, **enriched parent given names**, and **siblings**. Each runs as a pure function over the current `ResearchState`.

### 6.1 ParentInferenceEngine

**Input:** `state.confirmedFacts + state.leads` (not just facts — the `mothersMaidenName` field is a direct index transcription, so its reliability doesn't depend on geography/family-context gates).
**Output:** `[ProposedRelative]` — one mother proposal per distinct MMN, one father proposal sharing the subject's surname.

Algorithm (per record):

1. Filter to birth records with a non-empty `mothersMaidenName`.
2. Skip if record's source trust tier is below `.transcription` (community-only sources are too unreliable).
3. Compute parent birth window: `[subjectBirth − 45, subjectBirth − 18]` (parents 18–45 at child's birth).
4. Mother proposal: surname = MMN, gender = female, stable ID = `stableID(.parentOf(subjectID), .female, MMN)`.
5. Father proposal: surname = subject's surname, gender = male, stable ID likewise.
6. If a proposal with that stable ID already exists, append the new record to its `evidence`; do not create a duplicate.

The stable ID is the key invariant: re-running research must produce the same proposal IDs so rejection state persists.

### 6.2 MarriageEnrichmentEngine

**Input:** the `(mother proposal, father proposal)` pairs that share a `subjectID`, plus two FreeBMD marriage queries' results (groom-side and bride-side).
**Output:** one of three outcomes:

| Outcome | Trigger | Effect |
|---|---|---|
| `.unique(fatherGiven, motherGiven, fatherEv, motherEv)` | Exactly one reference key `(year, quarter, district, vol, page)` matches between sides | Fill given names where present; either side may be nil (one-sided enrichment is a valid partial win) |
| `.ambiguous(candidates)` | ≥2 reference keys match | Show all candidates in UI; user picks during accept |
| `.none` | No reference key matches | Proposal stays surname-only |

The reference-tuple match is the join mechanism. The BMD index writes each marriage twice (once under each party); matching by `(year, quarter, district, vol, page)` reunites the pair.

Spouse-surname guard (T19): groom-side entries whose `spouseSurname` ≠ the expected bride surname are rejected outright, even though they matched the source's filter. Closes an observed FreeBMD filter leakage where `s_surname=Wheeldon` returned unrelated marriages.

### 6.3 SiblingInferenceEngine (T17)

**Input:** the subject's resolved birth record + a pool of candidate birth records (one focused FreeBMD query) + both parent profile IDs + the snapshot.
**Output:** `[SiblingProposal]` — birth records matching the subject on:

- Same surname
- Same mother's maiden name
- Same registration district
- `|year − subject.birthYear| ≤ 20` (typical fertility span)
- Not the subject themselves
- Not already a known child of either parent in the snapshot

The engine is strict by design. A confidence-of-result mechanism doesn't exist; the contract is "if all keys agree, this is a sibling."

### 6.4 Why parent inference accepts leads but sibling inference doesn't

The `mothersMaidenName` field is a direct transcription from the BMD index — present regardless of whether geography or family-context gates pass. So leads carry trustworthy MMN data even though their geography didn't match. Sibling inference, by contrast, **depends on** the subject's resolved district; if the subject isn't pinned via `SubjectIdentityResolver`, the sibling engine returns `[]` (no key to filter by).

---

## 7. ClusteringEngine — the 5-step algorithm

Records become candidate lives via a five-step algorithm. Design principle (`ClusteringEngine.swift:7`): **when in doubt, split**. Over-splitting is recoverable (the UI shows merge candidates and lets the user accept the merge). Over-merging writes wrong facts that are hard to undo.

### 7.1 Step-by-step

1. **Seed.** Each distinct birth (by year OR district) seeds one cluster, lifespan `[birthYear, birthYear + 110]`. If there are no birth records, seed one cluster from the earliest record, lifespan `[earliest − 80, latest + 5]`.
2. **Assign.** For each unassigned record (chronological order), score against every existing cluster via
   ```
   score = 0.4 × dateCompatibility
         + 0.3 × locationConsistency
         + 0.3 × householdConfirmation
   ```
   Assign to the best-scoring cluster if `score ≥ 0.4`; otherwise create a new cluster.
3. **Split** (iterated until fixed point). A cluster is split when it contains any of:
   - ≥2 distinct birth records → keep oldest, split newer into a fresh cluster
   - ≥2 distinct death records → same
   - census-implied birth years differing by >5 years → split records above the midpoint
   - ≥2 distinct marriage spouses → peel one spouse group per iteration (so 4 spouses → 4 clusters)
4. **Merge candidates.** Identify clusters that **might** be the same person (one has only births, another only deaths, dates compatible, locations overlap). Set `mergeCandidate` pointers; **never auto-merge**.
5. (removed in Change 5) `scoreConfidence` — callers now derive `EvidenceConfidence` on demand via `LifeCluster.evidenceConfidence(sourceInfoMap:)`.

### 7.2 Assignment score components

| Component | Weight | Value table |
|---|---|---|
| Date compatibility | 0.4 | 1.0 inside lifespan; 0.5 within ±5 of either boundary; 0.0 otherwise |
| Location consistency | 0.3 | 1.0 same district; 0.7 same county; 0.3 same region; 0.0 non-local |
| Household confirmation | 0.3 | 1.0 census member is a known spouse/child by name; 0.5 surname match in family relation; 0.0 otherwise |

### 7.3 Why splitting matters

Real-world example: when a surname-only variant tier returned 80+ "Wheeldon" births across 50 years and several districts, the seed step produced one cluster per distinct birth-year-or-district, and the assignment step then refused to merge them across the 0.4 threshold. The result was many small candidate cards instead of one mega-cluster with contradictory facts — the user picks the right one rather than the algorithm guessing wrong.

---

## 8. ConvergenceEngine and source independence

`ConvergenceEngine.score(records:sourceInfoMap:)` answers a single question: how many **independent lineages** of evidence does the cluster contain, and at what trust level?

### 8.1 SourceLineage

Two records share a lineage if they share a `SourceLineage` value — defined per source. Two FreeBMD entries from different districts are still **one** lineage. FreeBMD + FamilySearch are **two** lineages. Three derivative sources that all transcribe the same official record are still **three** lineages but are capped by directness (§8.3).

### 8.2 ConvergenceLevel mapping

```
≥3 lineages                                 → .confirmed
2 lineages AND summed trust score ≥4         → .probable
2 lineages, lower trust                      → .possible
1 lineage, ≥2 records                        → .possible
otherwise                                    → .singleSource
```

The summed trust score uses `SourceTrustTier.rawValue` per record (community=1, transcription=2, primary=3 — approximate). Two transcription-tier sources = score 4 = clears `.probable`.

### 8.3 Directness caps

Convergence can never exceed what the underlying directness supports:

- All records `derivative` → cap at `.possible`
- No `.primary` records → cap at `.probable`

This is asymmetric: convergence can upgrade severity (or quality) but cannot downgrade. A single Wikipedia-citing-everything source can't get promoted to `.confirmed` no matter how many lineages.

### 8.4 SourcingStrength (UI-facing)

`SourcingStrength(sourceCount, independentLineageCount, topTrustTier)` — used by `LifeCluster.evidenceConfidence` and the three-axis `ConfidenceBadgeView`. `isCrossReferenced` is true when `independentLineageCount >= 2`.

---

## 9. Identity resolution

Two collaborating pieces: a generator that proposes likely districts, and a resolver that decides whether the subject's identity is pinned.

### 9.1 GeographicHypothesisGenerator

Walks the family graph and accumulates weight at each candidate district from six signals, each year-decayed:

| Signal | Weight | Rationale |
|---|---|---|
| Subject's own birth location | 1.0 | Direct answer |
| Subject's own marriage location | 0.75 | Strong transitive |
| Children's birth locations | 0.55 | Parents at child's registration |
| Siblings' birth locations | 0.65 | Same parents → usually same district |
| Parents' marriage location | 0.50 | Weaker — marriage may predate residence |
| Spouse's birth location | 0.35 | Assortative mating; confounded |

Year decay: `decay(signalYear, eventYear) = 0.5 ^ (|Δt| / 25)`. Half-life 25 years.

When a parish maps to multiple districts (boundary changes — Wirksworth is in both Bakewell and Belper RDs at different periods), the signal's weight is **split** across the districts: corroborating signals from another source still elect the right one.

Output: `[GeographicHypothesis]` sorted by descending weight, weights clamped to `[0, 1]`.

### 9.2 SubjectIdentityResolver

```
SubjectIdentityResolver.resolve(candidateBirthFacts:, hypotheses:) → SubjectIdentityResolution
```

Three outcomes:

- `.resolved(birthRecordID, districtName)` — exactly one candidate after applying the strongest hypothesis (weight ≥0.25); safe for downstream auto-promote.
- `.ambiguous(candidateIDs, reason)` — ≥2 candidates remain plausible; defer to human review.
- `.unresolved(reason)` — no candidates, or no usable geographic signal.

The 0.25 threshold is intentionally low: parish-to-district splits divide weight, so a single signal at full weight (1.0) still clears the gate after splits.

### 9.3 Why this matters

Resolved identity is the precondition for:

- **Auto-promote** (`AUTOMATION_AUTO_ACCEPT` automation path only — see §12)
- **Marriage enrichment** (when both parents aren't yet linked)
- **Sibling discovery** (always)

Closes the **Colin-Holmes failure** (May 2026): when there are multiple same-name birth records and no district anchor on the subject's profile, the older scorer treated them all as candidate facts and downstream inference silently picked the first one. The resolver now raises this case as `.ambiguous` so the pipeline defers rather than guesses wrong.

---

## 10. Discrepancy detection

When a `.fact` record's key field (birth year, death year) differs from the existing tree value, the pipeline raises a `ResearchDiscrepancy`. Severity comes from a deterministic table.

### 10.1 The severity table

`DiscrepancySeverityTable.severity(sourceTier:absDelta:convergence:)` → `(severity, reasoning)`.

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

A single FamilySearch hit at Δ=4 is a `.conflict`. The same finding cross-referenced by `.confirmed` independent sources stays `.conflict` (already ≥ the upgrade floor) — it doesn't reach `.correction` until convergence promotes the cluster verdict to a higher tier.

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

`SearchDispatcher.dispatch(subject:recordTypes:scope:mode:)` is the gateway to every source. Sources are dumb pipes; the dispatcher decides what to ask.

### 11.1 Strictness ladder by mode

| Mode | Ladder | Semantics |
|---|---|---|
| `.verify` | `[.strict]` | One tight pass. Stop early on first fact. |
| `.extend` | `[.strict, .loose]` | Strict first; broaden if empty. |
| `.discover` | `[.loose, .variant]` | Skip strict; start at loose. |
| `.all` | `[.strict, .loose, .variant]` | Run every tier; dedupe afterward. |

Empty-then-broaden: within `.extend` and `.discover`, stop at the first tier with non-empty results. `.all` always runs the full ladder.

### 11.2 Storm guards

The variant tier expands to all surname-variants × every district × every record type. Without bounds, surname-only queries (e.g. "Cauldwell" with no given name) detonate into thousands of unrelated records. Two guards:

1. **Variant-tier storm guard** (T38, `SearchDispatcher.swift:189–199`): skip variant tier when **all** queries are surname-only AND the year window spans >5 years. Narrow probes (known 1880 birth) stay bounded and useful.
2. **Phonetic-disable for surname-only** (T37): surname-only `.loose` queries downgrade to `.strict` so the source doesn't enable Phonetic (which has the same explosion shape).

### 11.3 Scope widening

Scope is a separate axis from strictness:

| Scope | What it widens to |
|---|---|
| `.parish` | (FreeBMD: no parish endpoint, returns no queries) |
| `.district` | Subject's home district only |
| `.county` | All districts in subject's Chapman code (DBY today) |
| `.adjacent` | County + neighbouring Chapman codes |
| `.national` | Full FreeBMD district catalogue, year-filtered to plausible coverage |

FreeBMD is district-coded; FreeCen and FreeREG are Chapman-coded; CWGC is military-only with eligible war years; FindAGrave / Probate / Wirksworth take a single query without scope branching.

### 11.4 Marriage enrichment's secondary dispatch

Marriage enrichment runs its own focused queries — not via the strictness ladder, but a single direct call per district (groom-side and bride-side) targeting the same district set as the main pipeline's scope. The gating policy (T29) prevents enrichment from triggering one query per candidate MMN: it only runs pairs whose surnames match either the linked parents OR the resolved-subject's birth record.

### 11.5 Sibling discovery's tertiary dispatch

`findSiblings` issues one query: surname-only, the subject's resolved birth district, year window `subject.birthYear ± 20`. No fan-out, no strictness ladder. Gated on both parents linked + identity resolved.

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

This is the cluster-level grading that decides whether the pipeline considers a candidate strong enough to auto-promote.

### 12.2 Auto-promote gate

`AUTOMATION_AUTO_ACCEPT` is a build flag that is **off in release**. When defined (test automation only):

```
RunRequestWatcher → request.autoAccept == "confirmed"
  → autoAcceptStronglySupportedProposals(
      clusters where hypothesisVerdict == .stronglySupported,
      identity resolved (precondition T14)
    )
```

Today there is **no user-facing auto-promote**. Strongly-supported clusters surface in the UI with the "Apply" button enabled, but the user clicks it; nothing writes implicitly. The flag exists so end-to-end tests can drive a run from request → application without UI interaction.

### 12.3 The cluster Apply button

Per-cluster Apply (cluster-level decision):

- `.confirmed` match quality → "Apply" button shown
- `.possible` match quality + a marriage record with `familyContext` gate passing (known spouse) → "Apply" button shown (T36 case)
- otherwise → "Save as lead" or "Discard"

Per-record decisions (T35) override the cluster gate per record: user-accepted records always apply, user-discarded records always skip, regardless of the gate predicate.

---

## 13. Evidence Firewall and the Apply contract

### 13.1 The firewall

Anything outside the Swift process (MCP tools, MLX-extracted facts, future external integrations) writes to **two tables only**: `pending_facts` and `leads`. They never touch `profiles`, `relationships`, or `life_events` directly. Promotion from `pending_facts` to actual fields goes through scorer → hallucination checks → human review.

Inside the Swift process, the same discipline holds: LLM output (currently `ResearchInterpreter.suggestNextSearch` and `compareCandidates`) does not write anything. Suggestions modify `state.activeRecordTypes`; prose lands in the cluster review sheet as advisory text.

### 13.2 The Apply contract

When the user clicks Apply on a cluster:

1. Iterate the cluster's records.
2. For each, determine effective decision:
   - user-accepted (per-record) → force apply
   - user-discarded (per-record) → force skip
   - else: apply iff `wouldApply(record)` (verdict `.fact` OR known-spouse marriage)
3. **Overwrite-safe**: every write checks "is the target field currently nil?" — Profile fields, marriage dates on relationships, birth/death locations. Existing data is **never** overwritten.
4. Records that apply add a citation; records that skip stay in the cluster as evidence history but don't write to fields.

The "fill nil only" rule is load-bearing. It's why the user can re-run research as many times as they like without losing data: every confirmed fact is additive.

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
| `pending_facts` (v4) | Outside-the-firewall candidate facts | Not pipeline; MCP / external |
| `leads` (v3) | Saved-as-lead candidates with full subject snapshot | Save-as-lead actions |
| `research_runs` (v2) | Run record per pipeline call | Pipeline entry / exit |
| `record_rejections` (v2) | Stable IDs of dismissed proposals / records | Reject proposed-relative; reject sibling |
| `negative_searches` (v2) | "Searched X, found nothing" | After each dispatcher pass |
| `hypotheses` (v7) | **Workbench** tentative claims (user-authored) | Workbench UI; not pipeline-generated |
| `focus_sets` / `open_questions` / `workbench_notes` (v7) | Workbench surfaces | Workbench UI |

What **doesn't** persist between runs:

- `ResearchResult.clusters` — recomputed each run from `evidence_records`
- `ResearchResult.proposedRelatives` — recomputed; rejection state persists, accept creates real relationship rows
- `ResearchResult.proposedSiblings` — same
- `ResearchResult.householdMembers` — recomputed
- `ResearchState` itself — in-memory only

The deterministic re-runnability is the key invariant: same project + same code = same output. Random IDs (`UUID()`) appear only for *accepted* new profiles/relationships, not for ephemeral pipeline output.

---

## 15. What the pipeline does NOT do today (the negative space)

Important inventory for Part II to push against:

1. **Cross-profile dedup.** Each `research(subject:)` call is independent. Researching mother after researching self refetches the shared marriage record and treats it as a fresh hit instead of recognising it. `ConvergenceEngine` operates per-cluster, never across clusters that span profiles. (`archive/LLM_RESEARCH_OPTIONS.md` G1.)
2. **Stall-aware planning.** When the dispatcher returns empty at every tier, the pipeline gives up. There is no mechanism that says "try a different angle" — e.g. probe an adjacent district, try the spouse's surname for a marriage record, etc. (G2.)
3. **Adaptive strictness escalation.** The strictness ladder is per-mode-static. `.verify` is always `[.strict]`. Empty-results don't promote `.verify` to `.extend` automatically. (G3.)
4. **Cross-cluster contradiction resolution.** When clustering produces two clusters with different birth years, the pipeline labels them both `.contradicted` but doesn't ask which is more plausible given the rest of the tree. (G5.)
5. **Family-graph plausibility for solo candidates.** A FreeBMD lead with right name + right year + right district passes scoring without checking "is this birth year inside the known parents' fertility window?". (G6.)
6. **Subtle merge detection.** `DiffEngine` catches near-exact duplicates. `John Caudwell Ashbourne 1845` ≈ `Jon Cauldwell Wirksworth 1845` slips through. (G7.)
7. **Evaluation harness.** No way today to measure "did this change improve coverage?" against a held-out corpus. Every improvement is "ship and hope."
8. **Persisted research hypotheses.** Each `findSiblings` (T17, shipped), each `GeographicHypothesisGenerator` call, each `SubjectIdentityResolver` resolution is recomputed from scratch. None of these results is written to disk as a hypothesis against which a second pass could be graded; verdict transitions across runs are invisible to the user. (T11/T12 target.)
9. **Hypothesis-guided second pass.** No mechanism re-runs the pipeline with focused queries derived from the *result* of the first pass. (T7 target.)
10. **MLX as planner / disambiguator.** The model only suggests record types between iterations and writes prose for the user. It doesn't propose hypotheses, doesn't grade, doesn't propose specific next searches. (T8/T9 target.)

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

Each source returns `[SourceRecord]`. The scorer normalises across them via the `SourceRecord` enum's per-case fields. No source mutates pipeline state directly.

---

## 17. Glossary (the load-bearing names)

- **Verdict** — `RecordVerdict.fact | .lead | .impossible`. The scorer's per-record judgement.
- **Match quality** — `MatchQuality.confirmed | .possible | .wrong`. UI-side aggregation of verdicts within a cluster.
- **Convergence level** — `ConvergenceLevel.confirmed | .probable | .possible | .singleSource | .uncorroborated`. Cross-source agreement, lineage-aware.
- **Hypothesis verdict** — `HypothesisVerdict.stronglySupported | .supported | .weak | .contradicted`. Cluster-as-hypothesis grading. The auto-promote gate.
- **Discrepancy severity** — `.none | .note | .refinement | .conflict | .correction`. Severity of a source-vs-tree disagreement.
- **Trust tier** — `.primary | .transcription | .community`. Source authoritativeness.
- **Directness** — `.primary | .directTranscription | .derivative`. How many hops the data is from the original record.
- **Independent lineage** — Two records share a lineage if they come from the same source/origin. Independence comes from different lineages.
- **Resolved identity** — `SubjectIdentityResolution.resolved` — exactly one candidate birth record pinned.
- **Stable ID** — Deterministic ID for a proposal (parent / sibling) so re-runs upsert rather than duplicate.
- **Evidence Firewall** — The rule that external/AI-derived facts enter `pending_facts` / `leads`, never `profiles` / `relationships` directly.
- **Apply contract** — When user clicks Apply on a cluster: per-record decisions override the gate predicate; writes are overwrite-safe (fill nil only) with citations.

---

# Part II — Proposed future state (V2)

This Part is the next architectural turn for the research pipeline. It folds in the portfolio thinking from `archive/LLM_RESEARCH_OPTIONS.md` (the gap inventory and tier-per-gap analysis) and lays out how the seven remaining open tasks compose into a coherent change.

All design decisions called out in this Part were resolved on 2026-05-19 (see §7). Implementation begins with T11.

---

## 1. Why now

The pipeline as built (see Part I) ships strong deterministic primitives: a 4-gate scorer, 5-step clustering, lineage-aware convergence, an identity resolver, three inference engines. Five recent tasks (T17 sibling discovery, T13 subject identity, T10 geographic hypothesis, T6 auto-promote gate, T5 cluster-level hypothesis verdict) all share a shape: each one is a **purpose-built question** wired to bespoke generation + bespoke testing + bespoke acceptance.

That shape doesn't generalise. Adding the next testable question — "burial at this parish?", "death certificate in this registry?", "second marriage to a new spouse?" — currently means another bespoke engine, another bespoke result field on `ResearchResult`, another bespoke UI surface, another bespoke accept path. T11 + T12 want to retire that pattern.

In parallel, `archive/LLM_RESEARCH_OPTIONS.md` (2026-05-15) re-framed the LLM debate as a **portfolio of moves per gap**, not a wholesale "more LLM or not." The remaining tasks line up against the portfolio's recommendations: T7 / T11 / T12 are the deterministic backbone; T8 / T9 are the local-MLX bolt-ons that earn their place where the deterministic tier hits a wall. T23 (Sample Tree tour) and T31 (empirical retuning) sit outside the architectural pivot but get a short pass each.

---

## 2. The architectural thesis

> Replace the bespoke "question → engine → field on result" pattern with a uniform **ResearchHypothesis** lifecycle: generate, test, grade, persist, optionally act on, optionally promote.

Concretely:

- `ResearchHypothesis` becomes a first-class type, alongside `ScoredRecord`, `LifeCluster`, `ProposedRelative`, `SiblingProposal`.
- Each existing one-off is folded in as a *kind* of hypothesis with its own generator and grader. Sibling discovery becomes `kind: .siblingExists(...)`. Subject identity becomes `kind: .subjectIdentity(...)`. Marriage enrichment becomes a generator for `kind: .parentMarriage(...)`. New questions become new kinds without new fields on `ResearchResult`.
- A `HypothesisEngine` runs all generators against the current `ResearchState`, tests each hypothesis against available evidence, and grades each with a verdict (`.supported` / `.contradicted` / `.inconclusive`).
- Hypotheses persist (T11), keyed by `(profile_id, kind, deterministic_subject_hash)`, so re-runs **upsert** rather than re-create. Verdict transitions are observable across runs.
- A graded hypothesis can drive a focused second pass (T7) — e.g. a `.weak` cluster hypothesis spawns a targeted query designed to either upgrade it to `.supported` or push it to `.contradicted`. This is the deterministic version of "stall recovery."
- MLX enters only where deterministic generation can't reach: free-text disambiguation of ambiguous identity resolutions (T9) and next-search suggestion for hypothesis-weak verdicts the rules can't escalate (T8).

The deterministic-wins rule is preserved: MLX can propose a hypothesis or a next-search direction, but the grader and the scorer remain rule-based. No verdict comes from a model.

---

## 3. Gap inventory (folded from `archive/LLM_RESEARCH_OPTIONS.md`)

Seven coverage gaps observed against the current pipeline. Each carries a recommended tier (cheapest that closes it) and an evaluation metric.

| # | Gap | Cheapest tier | Eval metric |
|---|---|---|---|
| **G1** | Shared evidence not cross-applied across profiles. Researching self + then mother re-discovers shared marriage cert rather than propagating. | Deterministic | % of cluster-internal evidence that requires only one source fetch instead of N |
| **G2** | Stall on no-result. Source returns empty for configured query; pipeline gives up rather than try a different angle. | Deterministic first, MLX second | Held-out: out of N stalled profiles, how many additional `.fact` verdicts after deterministic stall recovery? After MLX planner on top? |
| **G3** | Phonetic / spelling variants not adaptively escalated. Strictness ladder exists but escalation is per-mode-static, not response-driven. | Deterministic | Variant-tier hit rate on held-out vs current static behaviour |
| **G4** | Ambiguous locations stall the cleanse step. "Newport" matches 3 counties; cleanse can't pick one from spouse/sibling context. | Deterministic + graph context first, MLX where graph context insufficient | Resolution rate on held-out "Newport"-shaped findings |
| **G5** | Cross-cluster contradiction unresolved. Cluster A says born 1850, cluster B says 1855; no mechanism asks which is more plausible. | MLX (planning-class) | Contradictions surfaced and resolved with user agreement, per tree |
| **G6** | Bare evidence not contextualised against family graph. A single FreeBMD lead passes scoring in isolation, never re-checked vs parents/siblings. | Deterministic for the check, MLX for the rationale prose | Coverage-rate change on held-out, with and without family-graph plausibility gate |
| **G7** | Subtle merge candidates missed. `John Caudwell Ashbourne 1845` ≈ `Jon Cauldwell Wirksworth 1845` slips past `DiffEngine`. | Mixed (deterministic for structural, MLX for subtle) | Precision/recall on labelled merge-candidate set |

Two more emerged during this session:

| # | Gap | Cheapest tier |
|---|---|---|
| **G8** | One-off hypothesis pattern doesn't generalise. Adding "burial at parish" or "second marriage" today requires bespoke engine + bespoke result field + bespoke UI. | Deterministic refactor (T11+T12) |
| **G9** | No persistence of hypothesis state across runs. Re-running research from scratch loses the prior session's verdict transitions; user has no way to see "this hypothesis was `.weak` last time, `.supported` now." | Deterministic + new SQL table (T11) |

---

## 4. The proposed framework

### 4.1 `ResearchHypothesis` (T11)

A persistent, deterministic, testable claim. Replaces the bespoke fields on `ResearchResult` (today: `proposedSiblings`, soon-to-be `proposedXYZ` for every new question).

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

**Important design choice — separate from `Workbench.Hypothesis`.** The existing `Hypothesis` type in `Models/Workbench/` is user-authored, free-form, and lives on the workbench surface. `ResearchHypothesis` is machine-generated, structured, regenerated each run, and lives on the research surface. They share a name root but not a table. A `.supported` `ResearchHypothesis` may be *promoted* into a `Workbench.Hypothesis` by user action — that's the only crossing.

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

Each `HypothesisKind` participates via **three thin central switches** in `HypothesisEngine.swift`, each of which dispatches to per-kind logic that lives in a `HypothesisEngine+<Kind>.swift` extension file (Decision 5). The central switches stay small and exhaustive; the per-kind logic stays adjacent (all three operations for `.siblingExists` live in `HypothesisEngine+SiblingExists.swift` and so on).

1. **`generate(for kind:state:snapshot:)`** — `(...) -> [ResearchHypothesis]`. Returns 0..N candidate hypotheses (typically deterministic: `.siblingExists` generates one per resolved subject birth where both parents are linked).
2. **`grade(_ hypothesis:state:snapshot:)`** — `(...) -> GradeResult`. Pure function over current evidence; returns `(verdict, supportingIDs, contradictingIDs, reasoning)`.
3. **`deficitQuery(for hypothesis:atLevel:state:)`** — `(...) -> RecordQuery?`. Per-kind expansiveness ladder: returns the focused query for the given level on this hypothesis, or `nil` when the level exceeds the kind's ladder ceiling. Callers pass `attempts + 1`; the call site (T7 stall-recovery or the user "investigate further" gesture) is what differs, not the function. `nil` is the exhaustion signal — no separate state flag needed.

Adding a kind = add the case to `HypothesisKind` + add a clause to each central switch + add an extension file with the kind's three operations as static methods. The compiler enforces completeness on the central switches.

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

…and progressively loses **both** bespoke proposal fields: `proposedSiblings` is removed by the final phase of T12-sibling (sibling proposals become `.siblingExists` hypotheses; see §5.2); `proposedRelatives` is removed by the final phase of T12-parent (parent proposals become `.parentInferred` / `.parentMarriage` hypotheses). Decision 3 commits to migrating both rather than leaving one as legacy.

### 4.3 Persistence (T11)

New SQL migration `v26_research_hypotheses`:

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

**Upsert semantics**: when `HypothesisEngine.runAll` produces a hypothesis whose stable ID already exists in the table, the row is updated (verdict, evidence, reasoning, history append, lastTestedAt) — not replaced. The `created_at` and `history` carry forward.

**User-rejection persists**. A hypothesis the user has explicitly dismissed (e.g. "this sibling isn't mine") flips `user_rejected = 1` and is filtered out of UI display on subsequent runs. (Same mechanism as today's `record_rejections`, just on hypothesis IDs.)

---

## 5. Task-by-task — how each remaining task fits

### 5.1 T11 — Hypothesis type + persistence

**What lands:**
- `Models/Research/ResearchHypothesis.swift` with the type + kind enum + verdict enum + transition record.
- `v8` migration creating `research_hypotheses`.
- `ProjectDatabase` extensions: `loadHypotheses(forProfile:)`, `upsertHypotheses(_:)`, `rejectHypothesis(_:)`.
- `ResearchResult.hypotheses: [ResearchHypothesis]` field (default `[]` so existing callers compile).

**What does NOT land in T11:**
- Generators or graders. T11 ships the type and table; T12 ships the engine that fills them.
- Migration of existing one-offs. The existing `proposedSiblings` field remains during the transition; the new `hypotheses` field sits beside it. Migration happens incrementally as each generator lands in T12.

**Eval criterion:** T11 is structural plumbing; success = unit tests on round-trip persistence + the table queryable from the MCP server (so external tooling can read hypothesis state).

---

### 5.2 T12 — HypothesisEngine: generate, test, grade

T12 splits into two sequenced sub-projects (Decision 3). Each sub-project is itself executed as a 4-phase migration (Decision 2). Total: 8 commits across T12, each individually bisectable, each behaviour-identical to the prior commit until the final phase deletes the legacy field.

#### T12-sibling — fold `.siblingExists` into the framework

**What lands across phases:**

| Phase | What changes |
|---|---|
| 1 | `Services/Research/HypothesisEngine.swift` with `runAll` entry point + central `generate` / `grade` / `deficitQuery` switches. `.siblingExists` case added with generator + grader + deficit-query clauses. `result.hypotheses` field populated. `result.proposedSiblings` still populated by the legacy `findSiblings()` path. Both fields verified identical via tests. |
| 2 | Flip source of truth: `proposedSiblings` becomes `result.hypotheses.filter { kind matches .siblingExists, isDeterministicallySupported }.map(toLegacyShape)`. Legacy `findSiblings()` deleted. Output verified identical to Phase 1 by tests. |
| 3 | UI swaps to read `result.hypotheses` directly. `proposedSiblings` field still exists but unused. View diff trivial. |
| 4 | Delete `proposedSiblings` field. Pure deletion. |

**Generator/grader contract for `.siblingExists`**: generator runs when `SubjectIdentityResolver` returns `.resolved` AND both parents linked; emits one hypothesis per `(district, mmn, yearWindow)`. Hypothesis ID = `sibling:\(profileID):\(district):\(mmn):\(yearWindowKey)`. Grader runs the focused FreeBMD query + existing inference rule:
- `.supported` if ≥1 candidate sibling found AND user hasn't rejected it
- `.contradicted` if query returned zero candidates
- `.inconclusive` if query hit a source error / scope mismatch / quota guard

Deficit query for `.inconclusive`: retry the same district with the next strictness tier (loose, if the first ran at strict).

#### T12-parent — fold `.parentInferred` and `.parentMarriage` into the framework

**Gate (resolved 2026-05-19, see §5.2.1):** the marriage-enrichment coupling question is closed — `.parentInferred` and `.parentMarriage` are two cross-referencing kinds with a deterministic reconciliation step in `HypothesisEngine.runAll`. Phase 1 contract reflects that decision.

**What lands across phases:**

| Phase | What changes |
|---|---|
| 1 | Both `.parentInferred(gender, surname)` and `.parentMarriage(motherSurname, fatherSurname, window)` kinds added together with their generate / grade / deficit-query clauses (separate extension files per Decision 5). `HypothesisEngine.reconcileParentMarriages` lands in the central engine and is called at the end of `runAll`. `result.hypotheses` carries both new kinds with the marriage evidence already cross-referenced onto the parent hypotheses. `result.proposedRelatives` still populated by the legacy `ParentInferenceEngine.infer` + `enrichParentsWithMarriage` paths. Both surfaces verified projection-equal via tests. |
| 2 | Flip source of truth: `proposedRelatives` becomes a derived projection from `result.hypotheses` (supported `.parentInferred`s, with marriage evidence already folded in by reconciliation). Legacy inference paths deleted. Output verified identical to Phase 1. |
| 3 | UI swaps to read `result.hypotheses` directly. The "Already linked" detection, "Apply" action, and marriage-enrichment cross-validation cards re-target the new source — see §5.2.1 for how each affordance maps onto the two kinds. Bigger view diff than T12-sibling Phase 3. |
| 4 | Delete `proposedRelatives` field. Pure deletion. |

**Why this ordering (T11 → T12-sibling → T12-parent):**

- T11 is structural — no dependencies, fastest to bake.
- T12-sibling is the smaller test of the framework. Sibling discovery was added recently (T17) so the existing UI is narrow and the surgery is contained.
- T12-parent is the deeper change — older, more deeply integrated, more UI affordances. Doing it after T12-sibling lets us stress the framework once before tackling the bigger lift, and lets us write the marriage-enrichment design pass with full context.

**Eval criterion (cross-phase regression):** for both sub-projects, the per-profile output after each phase exhibits **projection-equality on the legacy field's shape** to the prior phase's output on a 5–10 profile snapshot corpus. "Projection-equality" excludes timestamps (`createdAt`, `lastTestedAt`), JSON key ordering inside payloads, and `attempts` counter values — these are expected to differ across runs and don't constitute behaviour change. The on-disk persistence layer itself is tested separately via dedicated upsert / round-trip unit tests, not via the cross-phase regression.

Final phases gain the new transparency: `.contradicted` hypotheses now surface with reasoning rather than vanishing silently.

#### 5.2.1 Marriage-enrichment design pass — addendum

**Status:** Resolved 2026-05-19, ahead of T12-parent Phase 1. Closes §10.1.

**Question:** does `.parentInferred(gender, surname)` contain marriage-enrichment evidence **internally** (one kind whose grader both proposes a parent and runs the marriage dispatch), or do `.parentInferred` and `.parentMarriage(motherSurname, fatherSurname, window)` exist as **two cross-referencing kinds** (one engine reconciles them post-grading)?

**Decision:** **two cross-referencing kinds.** `.parentInferred` claims "this surname belongs to a parent." `.parentMarriage` claims "a BMD marriage joins these two surnames in the plausible window." The engine reconciles the two during `runAll`: a supported `.parentMarriage` writes a cross-reference back onto the matching mother + father `.parentInferred` hypotheses (their `supportingEvidence` gains the marriage record ID, their `reasoning` gains the "given name X from .parentMarriage:Y" sentence). The reconciliation is deterministic and idempotent.

**Why two kinds, not one bundled kind:**

1. **Per-kind deficit-query ladders diverge.** An inconclusive `.parentInferred` (no birth record carrying MMN found) needs the main pipeline's whole-profile widening ladder — broaden the BMD birth search. An inconclusive `.parentMarriage` (no marriage hit) needs §6.5's scope-first-then-strictness walk — widen the year window from ±30 to ±40, then try the next adjacent county. Different ladders mean different `deficitQuery*` clauses (Decision 5). A bundled kind would fold both ladders into one switch that has to discriminate by inspecting evidence — clumsy, and impossible to keep exhaustive at the compiler level.

2. **Verdicts have to be separately observable.** A user asking "why is this parent proposal weak?" deserves to see *which* underlying claim failed: parent not proposable from any birth record (no MMN), or proposable but no marriage found to disambiguate the given name. §5.11's "investigate this hypothesis" UI is the whole point of the framework; bundling collapses the two failure modes into one opaque verdict.

3. **Generator chaining matches the engine's pattern.** `.parentMarriage` naturally feeds off `.parentInferred` output: only when both mother and father parent-hypotheses are supported is there a (mother, father) pair worth marriage-searching. This is the same pattern `.siblingExists` already uses with respect to `.subjectIdentity` — chains compose cleanly through `state`. Bundling collapses the chain into one grader body, which is harder to follow, harder to test, and harder to retune (T31's per-kind ladder retuning has to fish out the sub-claim).

4. **Identity-key stability under upsert.** One marriage links two parents. With one bundled kind, the marriage's record ID is duplicated across mother's and father's `.parentInferred.supportingEvidence` lists; re-runs can't dedupe across them. With two kinds, the marriage is one `.parentMarriage` row keyed by `parentMarriage:\(subject):\(motherSurname)x\(fatherSurname):\(window)`, the parent rows store the cross-reference once, and Decision 1's upsert semantics keep the on-disk state consistent across runs.

5. **Symmetry with the rest of the framework.** Every other kind in §4.1's enum carries one self-contained claim. `.subjectIdentity` is identity, not identity-plus-household. `.siblingExists` is sibling-exists, not sibling-plus-marriage-of-parents. Bundling enrichment into `.parentInferred` would be the framework's only kind hosting a sub-claim — an inconsistency that propagates into how `runAll` orders work, how the UI explains verdicts, and how new kinds (which the framework is designed to absorb without architectural change — §10.3) negotiate the precedent.

**Mechanics of cross-referencing:**

- `HypothesisEngine.generate(for: .parentInferred, ...)` emits one `.parentInferred` per (subject birth record, parent gender) pair carrying MMN — mirroring today's `ParentInferenceEngine.infer`. Father side uses `subject.surname`; mother side uses the birth record's `mothersMaidenName`.
- `HypothesisEngine.grade(_:state:snapshot:)` for `.parentInferred` is purely BMD-birth-evidence: verdict `.supported` when ≥1 fact-or-lead birth record carries the MMN; `.contradicted` only when explicit no-parents context exists (foundling, abandoned-at-birth — out of V2 scope, will be `.inconclusive` in practice); `.inconclusive` if no birth record found.
- `HypothesisEngine.generate(for: .parentMarriage, ...)` walks supported `.parentInferred` pairs (same subject, opposite genders, surnames present) and emits one `.parentMarriage(motherSurname, fatherSurname, window)` per pair. Window is `subjectBirthYear − 30 ... subjectBirthYear + 1` (today's pipeline default — T31 may retune).
- `HypothesisEngine.grade(_:state:snapshot:)` for `.parentMarriage` runs `MarriageEnrichmentEngine.match` against state's marriage records (the orchestration appends them via the `.parentMarriage` deficit query, same pattern as `.siblingExists` Phase 2): `.unique` → `.supported` with `supportingEvidence = [marriageRecordID]` and reasoning citing the BMD reference tuple; `.ambiguous` → `.inconclusive` with `supportingEvidence = [allCandidateIDs]`; `.none` → `.contradicted`.
- **Reconciliation step:** after `runAll` grades every kind, a new function `HypothesisEngine.reconcileParentMarriages(hypotheses:state:)` walks `.supported` `.parentMarriage` hypotheses and, for each, finds the two `.parentInferred` hypotheses they cross-reference. It appends the marriage record ID(s) to each parent's `supportingEvidence` and a sentence ("given name '\(given)' from marriage '\(parentMarriage.id)'") to each parent's `reasoning`. The reconciliation is a pure join over the hypothesis list — no dispatch, no model — so `isModelAssisted` on the parent hypotheses stays `false` and `isDeterministicallySupported` is preserved. Cross-references are recomputed on every run from the current hypothesis set, so persistence is upsert-safe (the parents' `supportingEvidence` may change between runs but only deterministically, and the union of evidence IDs the upsert sees is monotonic over the rejection-free re-run path).
- **Ambiguous marriages** stay attached to the `.parentMarriage` hypothesis (as its `supportingEvidence`); the parent hypotheses inherit the union via reconciliation but don't redundantly carry `ambiguousMarriages`. The UI (§5.11) reads the marriage hypothesis to render the disambiguation affordance.

**Implementation impact on T12-parent phase table (§5.2):**

- **Phase 1**: both kinds land together in the same commit. Two extension files (`HypothesisEngine+ParentInferred.swift`, `HypothesisEngine+ParentMarriage.swift`); central switches gain two clauses each. `reconcileParentMarriages` lives in `HypothesisEngine.swift`. Legacy `ParentInferenceEngine.infer` + `enrichParentsWithMarriage` continue to populate `result.proposedRelatives`; both surfaces verified projection-equal via tests (same equality criterion as T12-sibling Phase 1).
- **Phase 2**: `result.proposedRelatives` becomes a projection of supported `.parentInferred` hypotheses (with reconciliation already having folded marriage evidence in). Legacy paths deleted. The projection helper signature mirrors `projectSiblingExistsToProposals(hypothesis:scoredRecords:snapshot:)` — `scoredRecords` for the evidence lookup, `snapshot` for the "already-linked" comparison.
- **Phase 3**: UI swap is heavier than T12-sibling Phase 3 because of three affordances: "Already linked" detection (joins parent hypothesis surname/gender against `snapshot.parentsOf(subjectID)`), "Apply" action (creates ghost profile + parent edge from the hypothesis), and the ambiguous-marriage disambiguation card (reads the `.parentMarriage` hypothesis). All three retarget to read `result.hypotheses` directly.
- **Phase 4**: pure deletion of `proposedRelatives`. The projection helper survives — sole caller is the ViewModel, same shape as T12-sibling Phase 4 outcome.

**What this does not address:**

- The §10.1 question is the *coupling* question — one kind vs two. The numeric details of the marriage year window (`±30`/`±40`/`+1` etc.) and the per-kind ladder ceiling are still subject to T31's empirical retune. They're recorded in §5.2.1 as the starting values, not as the canonical answers.
- `secondMarriage` (a future kind in §4.1) is intentionally not coupled to `.parentMarriage`. The two are independent claims about different windows in the subject's life.

---

### 5.3 T7 — Hypothesis-guided second pass

**What lands:**
- A second-pass entry point in `ResearchPipeline` that runs after the first pass completes: `researchSecondPass(firstResult:state:)`.
- The pass examines `firstResult.hypotheses` and selects those with `verdict == .inconclusive` and a non-nil result from `deficitQuery(for: h, atLevel: h.attempts + 1, state: s)` (per Decision 5 — `nil` at any level means the kind's ladder ceiling is reached).
- For each, dispatch the returned query, append new evidence to `state`, increment the hypothesis's `attempts`, re-run `HypothesisEngine.runAll`, recompute clusters. Per-kind examples of what level transitions look like:
  - `.subjectIdentity` inconclusive (≥2 candidates after geographic filter) → level N might query FreeCen 1881/1891/1901 in each candidate's district for the same household; whichever district produces a credible parents-and-subject household resolves it.
  - `.clusterIsSubject` weak (one cluster, one fact, no corroboration) → level N re-queries an adjacent district at the next strictness tier.
  - `.parentMarriage` inconclusive (no marriage hit) → level N widens the year window from ±30 to ±40, level N+1 tries the next adjacent county.

**Stall-detection contract (Decision 4)** — two-condition gate (the spec uses this phrase throughout):

T7 fires the second pass iff both conditions hold:

1. **Variant-exhaustion**: the dispatcher has walked the full strictness ladder for every applicable source in the first pass (no headroom in the existing tier mechanism), AND
2. **Deficit-eligible inconclusive hypothesis**: the first pass produced at least one `.inconclusive` hypothesis whose `deficitQuery(for: h, atLevel: h.attempts + 1, state: s)` returns non-nil.

The second pass runs **at most once** per `research(...)` call. Cost ceiling: roughly N additional focused queries where N = count of deficit-eligible inconclusive hypotheses (typically 1–3 in practice). Deficit queries respect the existing storm guards in `SearchDispatcher` (Part I §11.2) — they go through the dispatcher's normal path, not around it. A per-kind ladder that would trip a storm guard at level N causes the dispatcher to return empty for that level; the engine re-grades, increments `attempts`, and on next invocation the same hypothesis may request level N+1 (or be exhausted if no further levels exist).

Hypotheses where `deficitQuery(..., atLevel: attempts + 1, ...) == nil` are **exhausted** — the kind's ladder ceiling reached. The UI archives these (see §5.11) and they fall through to T8's MLX next-search fallback (§5.4) for one last try.

**Why deterministic and not MLX:** every kind's deficit query is a deterministic rewrite of its own grader's inputs. "Try the next adjacent district" is graph traversal; "widen the year window" is arithmetic. MLX shouldn't decide where to look when the rules know perfectly well.

**Eval criterion:** held-out corpus of profiles known to stall in first pass — measure fact uplift after T7's second pass. Target: ≥30% of stalled profiles gain at least one new `.supported` hypothesis.

---

### 5.4 T8 — MLX next-search suggestion for weak verdicts

**What lands:**
- An MLX prompt + a `ResearchInterpreter.suggestForWeakHypothesis(hypothesis:state:availableSources:)` entry point.
- Wired into T7's second pass: when T7 finds an inconclusive hypothesis that is **exhausted** at its kind's deficit-query ladder (`deficitQuery(..., atLevel: attempts + 1, ...) == nil`), T8 is the fallback. It asks the model "given this hypothesis and what we know, what would you search?"
- Output is restricted to `(sourceID, recordType, queryHints)` — structured, not free-form. The deterministic dispatcher still builds and runs the query.

**Relationship to the existing `suggestNextSearch` (Part I §5.1 step 9)**: these are different prompts at different lifecycle points and they coexist.

- `suggestNextSearch` runs **between iterations within Pass 1**, before any clustering. Question: "what record types should the next iteration add to `activeRecordTypes`?" Output: a record-type suggestion. Coarse, broad, advisory.
- `suggestForWeakHypothesis` runs **in Pass 2**, after clustering and hypothesis grading, on a specific exhausted-ladder hypothesis. Question: "this specific hypothesis is stuck; what one focused query might shift it?" Output: a concrete `(sourceID, recordType, queryHints)` triple. Fine-grained, hypothesis-specific.
- They cannot be merged because their inputs differ: the first has only an iterating subject and partial scoring; the second has a complete graded hypothesis with an exhausted ladder and full evidence. The prompts and the calling contexts are different enough that one function doing both would be a thin wrapper, not a real abstraction.

**Why local MLX, not Claude API (Decision 7)**:

`archive/LLM_RESEARCH_OPTIONS.md` §6 argued the Claude API has the latency/quality edge for planner-class tasks. We're shipping T8 on local MLX anyway because:

1. **App Store posture**. We stripped outbound AI calls in May 2026 (T18, T20) specifically to clean the privacy disclosure surface. Re-introducing them is non-trivial — new privacy disclosure, possibly a new review cycle, and re-tackling "what does your app send where?"
2. **Task shape differs from the portfolio doc's framing**. T8's calls are structured-output, tie-break/fallback, low-frequency. That's easier territory for a 7B-4bit model than the open-ended planning the portfolio doc was sceptical about.
3. **The escape valve is a measured fallback, not a permanent ceiling**. The eval harness (§5.8) will reveal whether MLX quality is genuinely insufficient. If it is, a future task escalates to API — at which point we tackle the App Store implications with eyes open, having data to defend the move.

Both `verdict` and `isModelAssisted = true` are set on hypotheses T8 influences (Decision 8). Downstream consumers use `isDeterministicallySupported` to gate auto-promote and similar deterministic-only paths.

**Eval criterion:** for the subset of stalled-and-T7-stuck profiles, measure fact uplift after T8 fires. Target: ≥10% of T7-stuck profiles gain at least one `.supported` hypothesis on the third pass. (Lower bar than T7 because T8 is the last resort.)

---

### 5.5 T9 — MLX free-text disambiguation pass

**What lands:**
- `ResearchInterpreter.disambiguateIdentity(candidates:state:)` entry point.
- Wired into the `.subjectIdentity` grader: when `SubjectIdentityResolver.resolve` returns `.ambiguous`, AND T7's deterministic deficit query also doesn't resolve it (e.g. census didn't disambiguate), AND the candidates have free-text fields the deterministic resolver can't compare (notes, occupations, partial addresses in raw record fields), T9 asks the model "given these candidates and what we know about the subject, which is most plausible?"
- Output is again structured: `(preferredCandidateID, confidence, reasoning)`. The resolver only acts on it when `confidence ≥ threshold` (see §5.5.1), and even then the hypothesis grading flags it as model-assisted.

**Why MLX is right here and not for grading:**

The grader's contract is "rules decide, model never overrules." T9 doesn't overrule — it operates only when the rules return `.ambiguous` (i.e. the rules have explicitly given up). The model is breaking ties, not making findings.

Tie-breaks that T9 settles set `isModelAssisted = true` on the resulting hypothesis (Decision 8). Auto-promote and other deterministic-only gates skip these via `isDeterministicallySupported`. The user-facing UI surfaces a model-assisted badge so the user knows to treat the verdict with appropriate scepticism.

Same App Store / local-vs-API rationale as T8 (Decision 7): MLX now, escape valve to API later if eval harness shows quality is insufficient.

**Eval criterion:** held-out corpus of profiles where `SubjectIdentityResolver` returns `.ambiguous`; measure resolution rate via T9, with user-agreement as the success signal. Target: ≥50% user-agreement on tie-breaks. Low target because tie-breaks are inherently hard.

#### 5.5.1 Threshold policy

The confidence threshold is load-bearing — set too high and T9 is a no-op; set too low and the model overrules the rules in disguise. The threshold must be set by rule, not by guess:

> The shipped threshold is the lowest value `θ` such that user-agreement rate on the eval-harness disambiguation corpus (per §5.8) at threshold `θ` is **≥ 75%**. Below 75%, the threshold is raised until either the rate clears or no remaining tie-breaks pass.

The specific numeric value of `θ` is TBD until the harness has corpus data. The setting rule is fixed now. Concretely this means:

- T9 can ship with the threshold pinned at "always reject" (no model output ever acted on) until the harness produces enough data to set `θ` defensibly. That's not a no-op ship — the prompt, the structured-output parsing, and the wiring are real work; only the gate value is deferred.
- A T9-influenced verdict that doesn't clear `θ` falls through to leaving the hypothesis at `.inconclusive`. The user still sees the candidates and can pick manually via the candidate-comparison UX (see §5.12).
- The threshold can be re-tuned as the corpus grows. Each re-tune ships with the per-threshold agreement-rate curve in the commit message.

---

### 5.6 T23 — Guided Sample Tree tour (out of band)

**Out of architectural scope, in scope for completeness.** A first-launch tour that walks the user through the Sample Tree's features (Tree / Audit / Research / Leads / Settings). Pure UX work. No pipeline impact.

**What lands:**
- An overlay coachmark sequence triggered when the user opens the Sample Tree from the welcome screen.
- ~5 steps: tree navigation, opening Audit, running Research on a sample subject, reviewing leads, finding Settings.
- "Skip tour" / "Don't show again" affordances.

**Build order independence:** T23 can ship at any time without touching anything in §5.1–5.5. Recommended to slot in between the V2 framework landing and the MLX work, when there's a stable target for the tour to walk against.

---

### 5.7 T31 — Empirical retuning of the expansiveness ladder

**Reshaped from the original framing.** The original T31 retuned per-mode iteration counts and fact caps for the four research modes (`.verify`, `.extend`, `.discover`, `.all`). After Section 4.3 of the spec walk-through, those modes collapse into a single auto-escalating expansiveness ladder (see §5.10). T31 now retunes:

1. The default level → (strictness, scope) mapping for whole-profile research (the user-facing four-level ladder in §5.10).
2. Each hypothesis kind's expansiveness ladder defined by its `deficitQuerySiblingExists` / `deficitQuerySubjectIdentity` / etc. function (which levels exist, what they query).
3. The satisfaction threshold (`StopPolicy.satisfied` cutoff) — how strong a verdict counts as "enough" to stop auto-escalating.

**What lands:**
- The eval harness from §5.8 used as the measurement instrument.
- A short experiment that runs the certified corpus through the framework, varying:
  - The level → (strictness, scope) mapping
  - Each kind's ladder ceiling
  - The satisfaction threshold
- Diagnostic output per hypothesis kind: at what level did this kind resolve? at what level did it exhaust? — this is the per-kind reporting from §5.8 (refinement 1), repurposed for tuning.
- Updated constants in whichever module(s) own the ladder mappings.

**Build order:** T31 depends on the eval harness (§5.8), the Research button collapse (§5.10) which introduces the user-facing ladder, and at least T11/T12 having stabilised so the hypothesis kinds aren't moving. Recommended order: eval harness → §5.10 ladder ships with default mappings (informed-guess, not measured) → T31 runs as a one-shot experiment and re-pins the mappings with data behind them.

---

### 5.8 Eval harness (prerequisite for T7 / T8 / T9 / T31)

Not a numbered task, but load-bearing infrastructure that ships before T7 / T8 / T9 / T31 can have defensible deltas. The portfolio doc (`archive/LLM_RESEARCH_OPTIONS.md` §9) sketched this; Decision 6 commits to its shape with three refinements; the spec walk-through review extended that with **tiered corpus targets**, a **two-corpus structure**, an **evidence reproduction rate** metric, a **GEDCOM citation matcher** sub-deliverable, and a **difficulty stratification rule** for corpus growth.

#### 5.8.1 Tiered corpus targets

Corpus size is gated by which decision the harness is asked to back. Three-profile numbers can't carry irreversible ship decisions; growing the corpus to fit the decision is a load-bearing rule.

| Stage | Corpus size | Decisions backed | Rationale |
|---|---|---|---|
| T11 / T12 ship | 3 profiles | Structural plumbing only | The byte-equality (projection-equality) regression between phases is the real safety net at this stage, not the harness. |
| T7 ships with a defensible delta | 10–12 profiles | First task with eval-harness-backed commit message; T7's "≥30% of stalled profiles gain ≥1 new `.supported` hypothesis" target needs n where 30% is materially different from noise. | At n=3 the discrete result is 0/3 → 3/3 with standard error ≈26%; not interpretable. |
| T8 / T9 escape-valve to API; T31 ladder retune | 20–30 profiles | Irreversible or shipping decisions (re-introducing outbound AI calls; pinning ladder constants). Confidence intervals must not straddle the decision threshold. | The App Store posture cost of escalating to API is real (per Decision 7); the number behind that decision has to be defensible. |

This is not a deferral — the corpus grows over time as the user encounters difficult cases worth canonicalising — but it is a **gate**: tasks at each stage cannot ship before the corpus reaches the appropriate size.

#### 5.8.2 Two-corpus structure

The user's GEDCOM contains ~300 profiles with citations on many, plus some known errors. You can't use the tree as ground truth for a system whose job is partly to correct the tree. The fix is to acknowledge two corpora doing different work:

| Corpus | Size | Cost | Used for |
|---|---|---|---|
| **Certified subset** | 20–30 profiles, manually verified | High (30 min — several hours per profile, depending on citation density) | Precision/recall, per-kind metrics, evidence reproduction rate. Drawn from the GEDCOM via stratified sampling across difficulty axes (see §5.8.4). |
| **Known-errors corpus** | Grows over time, append-only | Low (write down the correction as you find it) | Regression suite: "does V2 surface the errors I already know about?". A growing hit-rate on a list of known errors is a cleaner signal than precision/recall on a partly-wrong corpus. |
| **Full-regression set** | ~270 profiles, free | Zero | "Didn't break anything obvious" nightly check; runs V2 against all uncertified profiles and surfaces large deltas vs current pipeline output. No ground truth — just regression detection. |

#### 5.8.3 Metrics

- **Precision** (% of `.fact` verdicts matching ground truth) on the certified subset.
- **Recall** (% of ground-truth facts surfaced as `.fact`) on the certified subset.
- **Contradiction count** (per profile) on the certified subset.
- **Evidence reproduction rate** (new, refinement 3.3): for each certified profile, the fraction of its existing citations that V2's pipeline surfaces. Tests the *process*, not just the outcome. V2 finding the same fact via different evidence is genuine independent corroboration (a ConvergenceEngine win); V2 finding the same fact via fewer sources is a coverage gap.
- All four metrics reported **per hypothesis kind** (refinement 1) so each task's eval criterion maps onto its kind's `.supported / .contradicted / .inconclusive` distribution.

#### 5.8.4 Difficulty stratification

Corpus growth prioritises **hard cases over headcount**. Three easy canonical profiles plus seven straightforward ones leaves you with n=10 that doesn't stress the framework. The selection rule is:

> Every corpus addition must increase the corpus's coverage on at least one difficulty axis: known stallers (G2-shaped); known ambiguous-identity (T9's target); known multi-cluster contradictions (G5-shaped); known sparse-evidence subjects (single-lineage cases); foreign-record edge cases (`.all` mode). At all times the corpus must include at least one "should remain absent" hallucination guardrail subject.

When the corpus reaches each tier (3 → 10–12 → 20–30) the additions are explicitly chosen for stratification breadth, not for "ease of curation."

#### 5.8.5 GEDCOM citation matcher (sub-deliverable)

To compute evidence reproduction rate, GEDCOM citation strings (a mix of URLs, structured references, and free prose accumulated over years) must map to the pipeline's internal source records. A short matcher — likely 50–150 lines near `SourceTierRegistry`, or as a new `CitationMatcher` — does this mapping.

**Sub-task before implementation**: a small survey of GEDCOM citation cleanliness (20 random samples categorised into clean URL / structured text / free prose) determines whether the matcher is a half-session of clear regex/URL parsing, or a multi-session task requiring fuzzy text matching. Survey lands before the harness work begins.

#### 5.8.6 Runner

- A CLI scheme target (`swift run eval` or equivalent) invokes `ResearchPipeline.research(...)` against each profile in whichever corpus is selected.
- **Snapshot-based** (refinement 2): each profile evaluates against a frozen `FamilyGraphSnapshot` taken at eval-start, so running T11 / T12 doesn't drift the corpus as accepted relatives land back in the tree.
- Reporting: per-kind metrics for diagnosis, plus a **single headline number** (refinement 3) — "net `.supported` deterministic hypotheses across the certified corpus" — for commit-message deltas. Evidence reproduction rate prints as a secondary line.
- CI: optional; manual `swift run eval` is enough to start.

#### 5.8.7 Build order

Ships **before** T7 (so T7 has a measurable uplift number on landing — corpus at 10–12 profiles), **before** T8 / T9 (mandatory, corpus at 20–30 profiles), and **before** T31 (which is purely the harness applied to ladder constants — corpus at 20–30 profiles). The starter 3-profile corpus ships alongside the runner; the 10–12 and 20–30 milestones gate downstream tasks.

---

### 5.9 Pipeline incrementality refactor (new task)

**Why**: today `ResearchPipeline.research(subject:config:)` is a monolithic call — kicks off, runs to completion, returns one result. Section 4.2 of the spec walk-through identified that "research as a discrete event" doesn't match the actual user mental model (research is something the user guides, watches, and may want to pause / continue / redirect). The Research-button collapse in §5.10 depends on the pipeline being able to *yield between levels*; this refactor is the prerequisite.

**What lands**:

- `ResearchPipeline.research(...)` decomposes into a level-by-level state machine. Each level runs to completion, yields a `ResearchState`, and the caller decides whether to invoke the next level.
- `ResearchState` becomes persistable. Today it's in-memory only (Part I §5.3). Now it's serialisable and stored against the in-progress research session (probably a new `research_sessions` row keyed by profile + started-at).
- New entry points: `startResearch(subject:initialLevel:)` returns a session handle; `continueResearch(session:)` runs the next level and yields; `pauseResearch(session:)` persists state and exits; `resumeResearch(session:)` rehydrates and is ready to continue. No behaviour change in the deterministic core — same dispatcher, same scorer, same clustering, same hypothesis engine. Just chunked execution.
- Existing call sites (UI flows, MCP tools, test harness) migrate to the new entry points. The legacy monolithic `research(subject:config:)` survives as a convenience wrapper that runs every level eagerly — but underneath it uses the new state machine.

**Eval criterion**: byte-identical (modulo projection-equality as in §5.2) result between a single eager invocation of the legacy wrapper and a level-by-level invocation of the new entry points, across the certified corpus.

**Build order**: lands after T11 / T12-sibling / T12-parent stabilise (so the hypothesis-engine integration isn't moving while the pipeline core is being refactored). T31 retuning and §5.10 / §5.11 user-facing changes both depend on this landing first.

---

### 5.10 Research button collapse + auto-escalation UX (new task)

**Why**: today the user picks one of four research modes (`.verify`, `.extend`, `.discover`, `.all`) before they have any results — exactly the choice they can't make well because they don't know what the search will surface. The modes also bundle three independent knobs (strictness ladder, iteration count, fact cap) into one. Section 4.2 of the walk-through proposed collapsing this into a single Research button with auto-escalation up a four-level expansiveness ladder.

**What lands**:

- `ResearchMode` collapses to a `StopPolicy` enum with three cases: `.firstFact` (stop after one `.fact` lands; replaces `.verify`), `.satisfied` (stop when satisfaction threshold met; replaces `.extend` / `.discover`), `.exhaustive` (run every level; replaces `.all`). Existing modes map to stop policies during migration.
- A single Research button in the UI, replacing the mode picker. Power users can change the stop policy from settings; default is `.satisfied`.
- A **default four-level expansiveness ladder** for whole-profile research, mapping each level to a (strictness, scope) pair:

  | Level | Strictness | Scope | Cost | Purpose |
  |---|---|---|---|---|
  | 1 | strict | district | 1× | Cheapest; lands if existing data is right |
  | 2 | loose | district | ~2× | Same location, spelling tolerance |
  | 3 | loose | county | ~10× | Widen location, keep loose match |
  | 4 | variant | adjacent | ~30× | Exhausted: every variant, every nearby district |

  `.national` scope sits **outside** the default ladder as an explicit override for "still nothing, give me everything," avoiding the cost cliff between level 4 (~30×) and a hypothetical level 5 (~300×).

- **Per-kind override**: each `HypothesisKind` defines its own expansiveness ladder via `deficitQuery*` (Decision 5). `.subjectIdentity` walks scope first (until identity is resolved, strictness doesn't apply to a specific location). `.siblingExists` walks strictness first (district is already pinned). `.parentMarriage` walks scope first then strictness. The whole-profile ladder above is the default for the user-facing "search this profile" gesture; the per-kind ladders fire under T7's deficit-query path and the "investigate this hypothesis" gesture in §5.11.
- A **progress indicator** + interactive **continue** affordance between levels. After level 1 completes, the user sees results-so-far plus "Continue to level 2 (~2× cost, broader spelling tolerance)?". This is load-bearing UX — without interactive continue, the collapse is just "research takes longer," not a paradigm shift.
- The progress indicator must support **pause** and **resume**: the user can navigate away and come back, with state preserved per §5.9. The default model is pause-and-resume (not background continuation, which adds notifications surface area we haven't designed).

**Eval criterion**: harness-driven; the default ladder mapping is informed-guess at landing time and is later retuned in T31 with eval data behind it. The progress indicator and continue affordance are user-tested rather than harness-tested.

**Build order**: depends on §5.9 (pipeline incrementality) being in place. T31 retunes the default ladder mappings after this lands.

---

### 5.11 Hypothesis investigation as user action (new task)

**Why**: today's lead list grows large and overwhelming. Most leads sit unsifted because the volume exceeds practical triage. Leads have high consumption cost (sift one by one) and low individual value (most are wrong), so they accumulate as a dead-end output. Section 4.1 of the walk-through proposed surfacing lead-only clusters as user-facing `.clusterIsSubject` hypothesis cards with an "investigate further" action that runs focused research — the same machinery T7 uses for automatic stall-recovery, exposed as a user gesture.

**Architectural fit is essentially free**: `.clusterIsSubject` is already in the enumerated `HypothesisKind` cases (§4.1). `ClusteringEngine` already groups leads alongside facts. `deficitQuery(for:atLevel:state:)` (Decision 5) is the exact mechanism for "what focused query would settle this?". The new work is the user-facing entry point and a lifecycle state machine.

**What lands**:

- A `ResearchPipeline.investigateHypothesis(_:)` (or equivalent) entry point. Takes a hypothesis ID, dispatches the next deficit-query level, increments `attempts`, re-grades. Returns the updated hypothesis. Same as T7's per-hypothesis path, but driven by a UI gesture rather than the variant-exhaustion gate.
- **Hypothesis lifecycle state machine** layered over the existing `verdict` axis:
  - `active` — hypothesis is current; UI shows "investigate further" affordance.
  - `exhausted` — `deficitQuery(..., atLevel: attempts + 1, ...) == nil`; UI archives the hypothesis under a collapsible "exhausted" section per profile, still revivable.
  - `archived` — user-dismissed; UI hides unless explicitly recalled.
  - `re-promoted` — new evidence (typically from a re-run after new transcriptions land at a source) flips a previously-exhausted hypothesis back to active. Automatic; the user sees a "previously exhausted hypothesis revived" badge.
  - State is computed from `(verdict, attempts, exhausted-at-ceiling, user_rejected, recently-graded)`; not stored as a separate column.
- **UI surface in cluster review** (and a dedicated tab/section if cluster review can't carry the weight): hypothesis cards showing the cluster's candidate identity, current verdict, evidence, attempt-count + ladder level, "investigate further" / "archive" / "promote to ghost profile" actions.
- **Lookahead UX**: clicking "investigate further" first reveals what the next level would do ("Next attempt: search loose name match in adjacent Belper district, ~2× cost"). User confirms; query dispatches. Powered by `deficitQuery(...)`'s level lookahead (Decision 5, reason 2).

**Eval criterion**: held-out corpus of profiles with many lead-only clusters; measure (a) how many clusters the user investigates per session before/after this lands, (b) how many investigations resolve a hypothesis. No precision/recall here — this is a UX win, not a coverage win.

**Build order**: depends on T11 (hypothesis type), T12 (engine + persisted `.clusterIsSubject` hypotheses), T7 (deficit-query machinery), §5.9 (pipeline incrementality — `investigateHypothesis` is a level dispatch on an existing session). Recommended slot: after T7 lands.

---

### 5.12 Design passes needed (UX surfaces requiring their own specs)

Five user-facing surfaces emerged from the spec walk-through that are either underspecified in this V2 relative to their importance, or that fall out of the §5.10 / §5.11 reframe. Each deserves its own design pass; the notes here flag the issue, not the design.

#### 5.12.1 Discrepancy review surface

Part I §10 describes discrepancy detection in real depth — severity table, convergence-upgrade rule, per-source tolerances — but the spec doesn't describe **where the user sees discrepancies** or what they do with them. This is one of the most directly actionable outputs of the pipeline ("the record says 1898, your tree says 1899") and risks being buried inside cluster review.

Likely shape: a dedicated review queue, sortable by severity, with triage actions ("the record is right" / "the tree is right" / "needs more research"). The `DiscrepancySeverityTable` already provides the sort key.

#### 5.12.2 Candidate-comparison UX (the Colin-Holmes case)

Part I §9.3 calls out the failure mode `SubjectIdentityResolver` fixes — but the fix is deferring to user choice. When `.resolve` returns `.ambiguous`, the user picks. Today's affordance is `ResearchInterpreter.compareCandidates` — a paragraph of MLX prose. For a decision that cascades into wrong parents, wrong siblings, and wrong lines of descent, prose alone is thin.

Likely shape: a structured side-by-side — both candidates' records, family contexts, geographic signals, evidence strength, with differences highlighted. MLX prose is one element on the page, not the whole page. This is one of the highest-stakes UX moments in the pipeline and the place where T9 (§5.5) falls back to user choice when its threshold isn't met.

#### 5.12.3 Search transparency — "why didn't we find X?"

Users know things the system didn't find. "My ancestor married in Manchester, why isn't that here?" Today the answer is in `searchHistory` and `negative_searches` (Part I §14) but not surfaced. Making it user-visible turns a black box into a collaborator: which sources were queried, with what parameters, at what scope, returning what counts. Combined with the four-level ladder (§5.10), the user can see "we ran levels 1–3, level 3 was district X loose match, found 0" and either escalate manually or correct an upstream assumption.

#### 5.12.4 Verdict transitions across runs

§4.1's `VerdictTransition` history field is genuinely powerful and currently invisible. A "since last run" diff at the top of the research result — "3 new `.supported` hypotheses, 1 dropped from `.supported` to `.inconclusive` (new contradicting evidence), 2 hypotheses now have more lineages" — is the answer to "why bother re-running?" The data is being stored; the UX is a delta-view affordance.

#### 5.12.5 Confidence badge dimensionality

The `SourcingStrength` three-axis badge (Part I §8.4) currently shows source count, lineage count, and top trust tier. With the hypothesis framework, there are now potentially five dimensions of confidence on a single finding: verdict, `isModelAssisted`, source count, lineage count, top trust tier. That's too much for a glance. Likely shape: a primary indicator (verdict + model-assisted state) with the source-strength axes as a secondary, on-hover detail.

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

Persistence: research_hypotheses (v26) — upserted across runs, with attempts column tracking expansiveness ladder progress.
             research_sessions (new in §5.9) — persisted ResearchState for pause/resume.
             record_rejections (v2) — extended to reject by hypothesis ID.
             evidence_records (v4) — unchanged.
```

The diagram describes the **engine** lifecycle. User-facing surfaces sit above it: the single Research button + auto-escalation (§5.10) drives Pass 1 level-by-level via §5.9's incremental entry points; hypothesis investigation cards (§5.11) drive Pass 2's deficit queries on user gesture. Both go through the same engine paths shown here — they're not separate code paths.

**Key invariants preserved**:

- Deterministic-wins. Graders are rules; MLX (T8/T9) only enters when rules return `.inconclusive` / `.ambiguous`.
- Evidence Firewall. Hypothesis verdicts don't write to Profile or Relationship; user accept actions still go through `acceptProposedRelative` / `acceptSiblingProposal` paths.
- Apply contract. Overwrite-safe fill-nil-only.
- **Re-runnability is preserved for deterministically-graded hypotheses only.** For any hypothesis whose `isModelAssisted == true`, the verdict (and any field derived from it — `isDeterministicallySupported`, auto-promote eligibility, downstream UI badges) **may differ between runs of the same project on the same code**. The `isModelAssisted` flag is the visible annotation; every consumer gates accordingly via `isDeterministicallySupported`. The deterministic subset of hypotheses retains the "same project + same code = same output" guarantee.

---

## 7. Decisions made

Eight substantive design choices resolved during the 2026-05-19 spec walk-through, plus one carry-over from the original spec draft. Each is now load-bearing for the corresponding task. Section numbers match the walk-through order so inline "Decision N" references throughout the spec resolve to "§7.N".

### 7.1 — `HypothesisKind` shape and per-kind code organisation

**Resolution**: **closed Swift enum with associated values, with per-kind logic decomposed into extension files**. The three central switches in `HypothesisEngine.swift` stay thin entry points — each switch dispatches to per-kind static methods defined in a `HypothesisEngine+<Kind>.swift` extension. All three operations for a given kind (`generate*`, `grade*`, `deficitQuery*`) live adjacent in one file. This keeps compile-time exhaustiveness on the central switches (the original reason for closed-enum) while preserving per-kind colocation as the kind set grows.

```swift
// HypothesisEngine.swift — entry points + thin central switches (stable, ~150 lines)
enum HypothesisEngine {
    static func generate(for kind: HypothesisKind, state: ResearchState, snapshot: ...) -> [ResearchHypothesis] {
        switch kind {
        case .siblingExists:   return generateSiblingExists(state: state, ...)
        case .subjectIdentity: return generateSubjectIdentity(...)
        // ... compiler enforces every case
        }
    }
    // grade and deficitQuery follow the same pattern
}

// HypothesisEngine+SiblingExists.swift — all three operations for one kind, contiguous
extension HypothesisEngine {
    static func generateSiblingExists(...) -> [ResearchHypothesis] { ... }
    static func gradeSiblingExists(...) -> GradeResult { ... }
    static func deficitQuerySiblingExists(for: ResearchHypothesis, atLevel: Int, state: ...) -> RecordQuery? { ... }
}
```

Rejected alternative (protocol-based, open kinds): more open but worse for persistence (type-erased payloads) and loses compile-time exhaustiveness on the central dispatch.

Rejected alternative (all three switches and all per-kind logic in one `HypothesisEngine.swift`): at six kinds the file is ~600 lines; at the spec's enumerated kinds plus future ones (death-in-district, occupation-trajectory, etc.) it climbs to 1500–2000 lines with three parallel switches that must stay aligned per kind. The colocation argument that motivated closed-enum is better served by extension-per-kind files, which place each kind's three operations adjacent rather than scattered across three sections of a god-file. Drift risk (generator assumptions diverging from grader assumptions) goes down. Decomposition is cheap now (T11/T12 scaffold the structure from scratch), expensive later.

### 7.2 — Migration of `proposedSiblings` (T12-sibling)

**Resolution**: **hard migration executed as four bisectable phases** — Phase 1 in-place duplicate (new framework runs alongside legacy `findSiblings()`, outputs verified identical), Phase 2 flip source of truth (legacy field becomes a projection of `result.hypotheses`, original engine deleted), Phase 3 swap UI to read `result.hypotheses` directly, Phase 4 delete `proposedSiblings` field.

Rejected alternative (soft migration, leave legacy field indefinitely): "we'll evaluate later if it's worth removing" typically becomes "we never get around to it," leaving the framework permanently asymmetric.

Full phase-by-phase contract in §5.2 (T12-sibling).

### 7.3 — Fold `proposedRelatives` into the framework too (T12-parent)

**Resolution**: **yes, with the same four-phase pattern as T12-sibling, sequenced after it.** The argument for folding it: consistency. The earlier argument against (UI complexity) is solved by the phasing — Phase 3 absorbs the UI surgery in one bisectable commit, Phase 4 deletes the legacy field.

A short **marriage-enrichment design pass** sat between T12-sibling Phase 4 and T12-parent Phase 1 to resolve whether `.parentInferred` and `.parentMarriage` are one bundled hypothesis or two cross-referencing kinds (residual question §10.1). Resolved 2026-05-19: two cross-referencing kinds — see §5.2.1.

Rejected alternative (defer to follow-up task): leaves the framework asymmetric for an unbounded period, and re-builds context cost when we eventually do it.

### 7.4 — Stall-detection contract for T7

**Resolution**: T7's second pass fires when **both** (a) the dispatcher has walked the full strictness ladder for every applicable source AND (b) ≥1 `.inconclusive` hypothesis has a non-nil `deficitQuery`.

Rejected alternatives: zero-new-facts iteration (fires too often, wastes source quota on cases where the rules haven't tried everything yet); confidence-floor stall (adds extra knobs to tune per mode, when the existing verdict axis is the better signal); variant-exhaustion alone (fires even when there's nothing concrete to retry).

The two-condition gate requires every kind to declare a deficit query — costed in T11 anyway, so no new cost.

### 7.5 — Deficit query declaration style and ladder shape

**Resolution**: **central switch in `HypothesisEngine`** dispatching to per-kind extension methods (per Decision 1's revised organisation). Signature: `deficitQuery(for hypothesis:atLevel:state:) -> RecordQuery?`. Each kind defines its own expansiveness ladder; `nil` at any level = the kind's ceiling reached = hypothesis exhausted (the exhaustion signal, not a separate state flag).

Why level-parameterised, not state-driven:

1. **Pure function consistency.** `generate` and `grade` are pure. Reading `attempts` inside `deficitQuery` would make it the odd one out.
2. **Lookahead.** Callers can preview the next attempt's query without committing — drives "next attempt will widen scope to county — continue?" in the user-facing investigation UX (§5.11). State-driven would have to commit to compute.
3. **Per-kind ladder length falls out.** `.siblingExists` might have 4 levels, `.subjectIdentity` might have 6 (scope-walking has more granularity), `.parentMarriage` might have 3. Each kind's switch handles whatever levels are meaningful and returns `nil` above its ceiling. No global "max levels" constant; no per-kind metadata.

The `attempts` field on `ResearchHypothesis` is the caller's bookmark. T7's stall-recovery and the user's "investigate further" gesture both compute `nextLevel = attempts + 1`, call `deficitQuery(for: h, atLevel: nextLevel, state: s)`, dispatch the result if non-nil, re-grade, increment `attempts`. Same mechanism, two entry points.

Rejected alternative (state-driven, no level parameter): conflates "what's the next query?" with "where are we?". Loses lookahead.

Rejected alternative (per-kind handler structs in separate files): co-locates three pieces nicely per kind but loses the central exhaustive switch. Extension-per-kind in §7.1 captures the colocation benefit without the dispatch cost.

Rejected alternative (discovered, via reflection): magical, fragile, not seriously considered.

### 7.6 — Eval harness scope and rollout

**Resolution**: commit to the `archive/LLM_RESEARCH_OPTIONS.md` §9 spec with **three refinements**, executed as a **3-profile starter corpus that grows over time**:

1. Per-hypothesis-kind reporting (not per-gap-class) — matches the framework's natural unit.
2. Snapshot-based evaluation — each profile evaluates against a frozen `FamilyGraphSnapshot` taken at eval-start, so accepted relatives from prior runs don't drift the corpus.
3. Single headline number — "net `.supported` deterministic hypotheses across the corpus" — for commit-message deltas, in addition to per-kind diagnostics.

Full spec in §5.8.

### 7.7 — Local MLX vs Claude API for T8 / T9

**Resolution**: **local MLX for T8 and T9** as initial path. Escape-valve to API in a future task if the eval harness shows MLX is leaving findings on the table (threshold quantified when harness data exists).

Rejected alternative (Claude API directly): re-introducing outbound AI calls would partially undo the App Store posture work shipped in May 2026 (T18, T20). Worth doing only with data to defend the move — which the eval harness provides.

### 7.8 — MLX nondeterminism representation

**Resolution**: **orthogonal `isModelAssisted: Bool` field** on `ResearchHypothesis`, not a new verdict case. Auto-promote and similar deterministic-only gates use the `isDeterministicallySupported` helper (= `verdict == .supported && !isModelAssisted`).

Rejected alternative (new `.modelSupported` verdict case): conflates verdict and provenance, which are orthogonal axes. Would also force inventing `.modelContradicted` and `.modelInconclusive` to be consistent, doubling the verdict enum to capture what is really one bit of metadata.

Mitigation for the flag's mild error-prone-ness: every consumer uses `isDeterministicallySupported` (or an analogous helper), never bare `verdict ==` comparisons for promotion decisions.

### 7.9 — Cluster-aware scoring (out of V2 scope)

**Resolution**: deferred. Important (gates the G1 cross-profile dedup task in `archive/LLM_RESEARCH_OPTIONS.md` §8) but neither in the current task list nor a prerequisite for any V2 task. Tracked here so it isn't lost.

---

## 8. Build order

Strict dependencies (post-decisions, including the §5.9 / §5.10 / §5.11 reframe additions):

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

Recommended session-by-session sequence (engine work first, then UX reframe, then MLX bolt-ons):

**Engine foundation**

1. **T11** (~1–2 sessions). `ResearchHypothesis` type with `attempts` field, `v8` migration including `attempts` column, persistence helpers, central-switch scaffolding in `HypothesisEngine.swift` plus the first `HypothesisEngine+<Kind>.swift` extension file, MCP read-only exposure. Unit-test round-trip.
2. **T12-sibling** (~2–3 sessions). Four bisectable commits (Phase 1–4) folding `.siblingExists` in. Cross-phase regression asserts projection-equality (§5.2 wording, not byte-equality).
3. **T12-parent design pass** (~½ session, doc only — **completed 2026-05-19, see §5.2.1**). Spec addendum resolved the marriage-enrichment coupling: two cross-referencing `.parentInferred` + `.parentMarriage` kinds reconciled by a deterministic post-grading step in `HypothesisEngine.runAll`.
4. **T12-parent** (~3–4 sessions). Four bisectable commits folding parents + marriage enrichment in per the design pass. T12-parent Phase 3 (UI re-targeting: "Already linked" + Apply + marriage-enrichment cross-validation cards) is the **biggest schedule risk** in this sequence — the parent UI has the most affordances. Budget conservatively.

**Measurement infrastructure**

5. **Eval harness runner + 3-profile starter corpus** (~1–2 sessions). §5.8 runner, snapshot-based eval, per-kind reporting, headline number, evidence reproduction rate (requires GEDCOM citation matcher — see step 5a). The starter corpus ships here; growth to 10–12 and 20–30 profiles happens between later steps as a side task.
   - **5a.** *(half-session or multi-session, depending)* GEDCOM citation cleanliness survey (20 random samples) and citation matcher implementation (§5.8.5).

**UX reframe foundation**

6. **§5.9 Pipeline incrementality refactor** (~2–3 sessions). Level-by-level state machine, persistable `ResearchState`, `startResearch` / `continueResearch` / `pauseResearch` / `resumeResearch` entry points. Legacy monolithic `research(...)` wraps the new path. Cross-implementation regression on certified corpus.

**Deterministic stall-recovery + auto-escalation**

7. **T7** (~2 sessions). Second-pass loop via `deficitQuery(for: h, atLevel: h.attempts + 1, state: s)`. First task with eval-harness-backed delta in its commit message. *Requires corpus at 10–12 profiles before this commit lands.*

**User-facing reframe**

8. **§5.10 Research button collapse + auto-escalation UX** (~2–3 sessions). `ResearchMode` → `StopPolicy` migration; single Research button; default four-level expansiveness ladder; progress indicator + interactive continue; pause-and-resume.
9. **§5.11 Hypothesis investigation as user action** (~2–3 sessions). `investigateHypothesis(_:)` entry point; lifecycle state machine (active / exhausted / archived / re-promoted); cluster cards in cluster review; lookahead UX on "investigate further."

**MLX bolt-ons**

10. **T8** (~2 sessions). MLX fallback for exhausted-ladder hypotheses. Sets `isModelAssisted = true`. *Requires corpus at 20–30 profiles.*
11. **T9** (~2 sessions). MLX tie-break for residual `.subjectIdentity` ambiguity. Sets `isModelAssisted = true`. Ships with threshold pinned at "always reject" until corpus gives `θ` per §5.5.1. *Requires corpus at 20–30 profiles.*

**Tuning + parallel UX work**

12. **T31** (~1 session). One-shot retuning experiment using the harness; re-pins the §5.10 default ladder mapping and per-kind ladders. *Requires corpus at 20–30 profiles and §5.10 landed.*
13. **T23 + §5.12 design passes** — slot in parallel to the engine sequence above where they fit. T23 (Sample Tree tour) and the five §5.12 design passes (discrepancy review, candidate comparison, search transparency, verdict transitions, confidence badge consolidation) are independent of each other and of the main engine pipeline; each is ~1–3 sessions on its own.

Estimated total: **24–32 sessions** (up from the original V2 estimate of 16–21, reflecting the reframe additions). The engine foundation (steps 1–7) is the original V2 scope at ~12–16 sessions; the UX reframe (steps 8–9, 13) plus extended MLX work and corpus growth adds ~12–16 sessions. Each task commit-message carries the appropriate eval delta (projection-equality for T11 / T12; corpus-based for T7 onwards).

---

## 9. What this V2 does NOT do

Holdovers, explicitly out of scope:

- **G1 (cross-profile dedup).** Important, called out in §3, but not in the current task list. Future task.
- **G7 (subtle merge detection).** Same.
- **MLX as primary grader.** No. Graders stay rule-based. MLX only enters when rules return inconclusive/ambiguous.
- **Per-source autotuning.** Today's per-source strictness configs (T37, T38) are static and stay static. Adaptive tuning is a future task.
- **Cluster-aware scoring.** §7.9 flagged. Out of V2 scope.
- **Workbench.Hypothesis ↔ ResearchHypothesis automatic crossover.** A `.supported` ResearchHypothesis can be promoted to a Workbench.Hypothesis by user action only — no automatic flow.

---

## 10. Residual questions deferred to implementation time

Small, well-bounded questions that don't require resolution before T11 starts. Each will surface naturally during the task that gates it and is captured here so it isn't lost.

1. **Marriage-enrichment coupling** (gated T12-parent Phase 1). Should `.parentInferred` contain enrichment evidence internally, or do `.parentInferred` and `.parentMarriage` exist as two cross-referencing kinds with the engine reconciling them? **Resolved 2026-05-19, ahead of T12-parent Phase 1 — see §5.2.1.** Outcome: two cross-referencing kinds with a deterministic reconciliation step in `HypothesisEngine.runAll`.

2. **Escape-valve threshold for Local→API escalation (T8, T9)**. The eval harness will give us per-task miss-rate numbers; the threshold at which we file an "escalate to Claude API" task is TBD pending those numbers.

3. **Hypothesis kinds we haven't yet enumerated.** §4.1's enum lists the kinds we know we need (`subjectIdentity`, `parentMarriage`, `siblingExists`, `clusterIsSubject`, `burialAtParish`, `secondMarriage`). The framework is designed to absorb new kinds without architectural change. Future kinds (death-in-district, occupation-trajectory, address-change-event) are out of V2 scope but slot in via the same three-switch + extension-file pattern when their task lands.

4. **`history` array growth policy.** §4.1's `history: [VerdictTransition]` grows on every re-grading. After 100 re-runs of a stable subject the array is 100 entries. Decision needed before T11 ships: append-only on **verdict change** (skip identity-grade no-change events) is the recommended starting policy; revisit and add compaction-above-N if the harness shows unbounded growth on the certified corpus.

Note: the T9 threshold policy was upgraded out of this list — it's now §5.5.1 because the setting rule (not just the numeric value) is load-bearing for T9 to ship at all.

---

## 11. Net summary

This Part is the architectural pivot from bespoke "research question → bespoke engine" to a generalisable `ResearchHypothesis` framework, **plus** the user-facing reframe that exposes the framework as a single Research button with auto-escalation and per-hypothesis investigation. The seven existing tasks compose around it:

- **Engine foundation**: T11, T12 (sibling + parent sub-projects).
- **Deterministic stall-recovery**: T7.
- **MLX bolt-ons** (gated on eval-harness data): T8, T9.
- **Independent**: T23 (Sample Tree tour), T31 (now ladder retuning, not mode retuning).

Plus three new task slots from the §5.10–5.11 reframe:

- **Pipeline incrementality** (§5.9) — prerequisite for the user-facing reframe.
- **Research button collapse + four-level expansiveness ladder** (§5.10).
- **Hypothesis investigation as user action** (§5.11).

And five UX design passes (§5.12) running in parallel where they fit: discrepancy review, candidate comparison, search transparency, verdict transitions across runs, confidence badge consolidation.

The eval harness (§5.8) is the load-bearing prerequisite for T7 / T8 / T9 / T31. Corpus size gates downstream tasks: 3 profiles → ships with T11/T12; 10–12 → required before T7; 20–30 → required before T8 / T9 / T31.

Eight design decisions resolved on 2026-05-19 (see §7) close the holistic-alignment gate that prompted this spec. Implementation begins with T11.

Invariants preserved through V2: deterministic-wins (rules grade, model never overrules); Evidence Firewall (hypothesis verdicts don't write to Profile or Relationship); Apply contract (overwrite-safe fill-nil-only). Re-runnability is preserved for **deterministically-graded hypotheses only** — `isModelAssisted == true` hypotheses may vary between runs; consumers gate via `isDeterministicallySupported`.

---

*End of specification.*
