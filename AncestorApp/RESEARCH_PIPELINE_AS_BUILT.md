# Research Pipeline — As-Built Specification

**Status:** Reference (descriptive, not prescriptive)
**Scope:** Everything the deterministic research pipeline does today, end-to-end, as it actually runs in shipped code
**Supersedes for "what shipped":** the 2026-04-25 `RESEARCH_PIPELINE_SPEC.md` (which remains the historical design-intent doc)
**Companion:** `RESEARCH_PIPELINE_V2_SPEC.md` (proposes the next architectural pivot)
**Date:** 2026-05-19 (post-T17 — sibling discovery shipped)

This document describes the pipeline as **built**. It is the baseline against which the V2 spec proposes change. Where this conflicts with the 2026-04-25 spec, the code wins.

---

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

Important inventory for the V2 spec to push against:

1. **Cross-profile dedup.** Each `research(subject:)` call is independent. Researching mother after researching self refetches the shared marriage record and treats it as a fresh hit instead of recognising it. `ConvergenceEngine` operates per-cluster, never across clusters that span profiles. (`LLM_RESEARCH_OPTIONS.md` G1.)
2. **Stall-aware planning.** When the dispatcher returns empty at every tier, the pipeline gives up. There is no mechanism that says "try a different angle" — e.g. probe an adjacent district, try the spouse's surname for a marriage record, etc. (G2.)
3. **Adaptive strictness escalation.** The strictness ladder is per-mode-static. `.verify` is always `[.strict]`. Empty-results don't promote `.verify` to `.extend` automatically. (G3.)
4. **Cross-cluster contradiction resolution.** When clustering produces two clusters with different birth years, the pipeline labels them both `.contradicted` but doesn't ask which is more plausible given the rest of the tree. (G5.)
5. **Family-graph plausibility for solo candidates.** A FreeBMD lead with right name + right year + right district passes scoring without checking "is this birth year inside the known parents' fertility window?". (G6.)
6. **Subtle merge detection.** `DiffEngine` catches near-exact duplicates. `John Caudwell Ashbourne 1845` ≈ `Jon Cauldwell Wirksworth 1845` slips through. (G7.)
7. **Evaluation harness.** No way today to measure "did this change improve coverage?" against a held-out corpus. Every improvement is "ship and hope."
8. **Persisted research hypotheses.** Each `findSiblings`, each `GeographicHypothesisGenerator` call, each `SubjectIdentityResolver` resolution is recomputed from scratch. None of these are written to disk as hypotheses against which a second pass could be graded. (T11/T12 target.)
9. **Hypothesis-guided second pass.** No mechanism re-runs the pipeline with focused queries derived from the *result* of the first pass. (T7 target.)
10. **MLX as planner / disambiguator.** The model only suggests record types between iterations and writes prose for the user. It doesn't propose hypotheses, doesn't grade, doesn't propose specific next searches. (T8/T9 target.)

This is the surface against which the V2 spec proposes.

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

*End of as-built. Next: the V2 spec proposes how T7 / T8 / T9 / T11 / T12 / T23 / T31 reshape this.*
