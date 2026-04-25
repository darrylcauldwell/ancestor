# Implementation Plan

**Date:** 2026-04-25 (v4 — genealogical method additions)  
**Governing spec:** RESEARCH_PIPELINE_SPEC.md  
**Spec authority:** The spec is a build artifact, not a frozen plan. End of each phase: review the spec for drift, update if needed. When building reveals the spec is wrong, update the spec to match what was built.  

---

## 1. Where We Are Today

55 Swift files, 9,802 lines. The app works: tree view with ghost nodes, 3 source plugins (Find a Grave, FreeBMD, FreeCen), Source Explorer for manual searching, 18 audit rules, gaps view, GEDCOM/WikiTree integration, SQLite persistence with undo.

What's not built: research pipeline, convergence, discrepancy detection, unified rules, life clustering, leads, LLM, narrative, whole-tree research.

---

## 2. What We're Building

A user selects a profile. The app searches sources, groups results into candidate lives, and presents "here are 2 candidate matches — which is yours?" The user confirms in under 5 minutes. Facts flow into the tree. Ghost nodes become real.

---

## 3. Critical Path to Primary Product

**7 phases to the primary product. Phase 6 is what ships.**

```
Phase 0  →  Phase 1  →  Phase 2  →  Phase 3  →  Phase 4  →  Phase 5  →  Phase 6
Foundation   +1 source   Unified     Convergence  Dispatcher   Clustering   THE PRIMARY
(4 steps)    + harness   rules       + discrepancy + pipeline               PRODUCT
```

Everything after Phase 6 is enhancement, built after the primary product is validated.

**Validation gate:** Phase 7+ begins after I've used Phase 6 on 5 different profiles from the 71-profile tree and the workflow is comfortable for at least 3 of them. "Comfortable" means: under 5 minutes, clusters make sense, accepted facts appear correctly in the tree.

---

## 4. Genealogical Method — What Makes This Research, Not Search

The pipeline doesn't just find records. It performs genealogical research to a professional standard. The Genealogical Proof Standard (GPS) — the formal standard used by the Board for Certification of Genealogists — has five criteria:

| GPS Criterion | Pipeline mechanism | Phase |
|---|---|---|
| 1. Reasonably exhaustive search | Negative evidence tracking + search frontier display | 4, 6 |
| 2. Complete and accurate citations | Citation renderer per source, Evidence Explained format | 6 |
| 3. Analysis and correlation | 4-gate scorer + convergence engine + field-level evidence type | 3, 4 |
| 4. Resolution of conflicting evidence | Discrepancy engine + conflict resolution UI | 3, 6 |
| 5. Soundly reasoned conclusion | Evidence summary per fact (reasoning trail) | 7, 11 |

Every profile carries a GPS score — a 0/5 indicator of how many criteria are met:

```
Thomas Land (b. 1834 Belper)
GPS: 4/5
✓ Exhaustive search (5 of 6 applicable sources searched)
✓ Complete citations (all facts cited, accessed within 6 months)
✓ Analysis and correlation (3 independent primary sources corroborate birth)
✗ Conflicting evidence (1 unresolved discrepancy: death year)
✓ Soundly reasoned (evidence summary available)
```

This is radically different from Ancestry's "leaf icon" or FamilySearch's "hint count." It tells the user whether their research meets professional standards, not just whether records exist.

### 4.1 Negative Evidence

"Searched and found nothing" is evidence when the search was comprehensive.

```swift
struct NegativeSearch: Sendable, Codable {
    let sourceID: String
    let recordType: RecordType
    let searchedAt: Date
    let scope: SearchScope
    let resultCount: Int            // 0 for negative
}

struct SearchScope: Sendable, Codable {
    let surname: String
    let givenName: String?
    let yearRange: ClosedRange<Int>
    let regions: [Region]
    let exactMatch: Bool
}
```

**Freshness:** Negative evidence has a shelf life. FreeBMD adds entries monthly. A negative search from 18 months ago may be stale. The strategiser checks `searchedAt` and suggests re-running stale negative searches.

**Scope must be exact.** "Searched FreeBMD" is meaningless. "Searched FreeBMD, surname=Land, given=Thomas, all Derbyshire districts, 1880-1920, exact match" is meaningful.

**Affects discrepancy severity.** If the tree says death 1885 in Belper and an exhaustive FreeBMD search for deaths in Belper 1880-1890 finds nothing, that's a stronger discrepancy signal than if no death search was conducted.

**User-facing:** The search frontier shows which sources have been searched and which haven't:
```
Sources searched: FreeBMD ✓  FreeCen ✓  CWGC (n/a — pre-1914)
Sources unsearched: Probate  Wirksworth
Adjacent regions unsearched: Nottinghamshire  Staffordshire
```

### 4.2 Source Citations

Every fact that reaches the tree carries a proper citation following Evidence Explained format.

```swift
protocol CitationRenderer: Sendable {
    func render(record: SourceRecord) -> Citation
}

struct Citation: Sendable, Codable {
    let full: String        // "FreeBMD, Births, Belper registration district,
                            //  March quarter 1834, volume 7b, page 213,
                            //  General Register Office, England & Wales"
    let short: String       // "FreeBMD Births 1834 Belper, vol 7b p213"
    let url: String?        // permanent link if available
    let accessedAt: Date
}
```

**Citations are rendered, not stored.** A `CitationRenderer` per source takes raw record fields and produces the citation string. Cached for display, regenerable from the record at any time.

**Multi-source citations for corroborated facts:**
```
Birth: 1834
  FreeREG baptism 6 April 1834, Belper [primary]
  FreeBMD birth, Belper March quarter 1834 [secondary — registration only]
  FreeCen 1841 census, age 7, Belper [secondary — implied from age]
```

**GEDCOM export with proper citations** via SOUR records with TITL, AUTH, PUBL, PAGE, DATA fields. A tree exported from this app and imported into Family Historian or RootsMagic shows the citations in their native UI.

**Every source plugin must include a `CitationRenderer`.** A source without one is incomplete.

### 4.3 Field-Level Evidence Type

The same record can be primary evidence for one field and secondary for another. A death certificate is primary evidence of death date but secondary evidence of birth date.

```swift
enum FieldEvidenceType: String, Codable, Sendable {
    case primary        // recorded contemporaneously by someone with direct knowledge
    case secondary      // recorded later or by someone reporting indirect knowledge
    case derivative     // copied from another source
}
```

**Per-source × per-field mapping:**

| Source | birthDate | deathDate | birthLocation | deathLocation |
|--------|-----------|-----------|---------------|---------------|
| FreeBMD birth | secondary (registration ≠ birth) | — | primary (registration district) | — |
| FreeBMD death | secondary (from informant) | primary (registration) | — | primary (registration district) |
| FreeCen census | secondary (implied from age) | — | primary (asked directly) | — |
| CWGC | secondary (calculated from age) | primary (official record) | — | primary (where died) |
| FreeREG baptism | primary (recorded at event) | — | primary (parish of baptism) | — |
| Find a Grave | secondary (volunteer-entered) | secondary (volunteer-entered) | — | secondary (cemetery location) |

**Convergence weights by evidence type:** Two sources agreeing as primary evidence is stronger than two agreeing as secondary. Three secondary sources agreeing is weaker than one primary + one secondary.

```swift
extension ConvergenceEngine {
    func adjustForEvidenceType(
        baseLevel: ConvergenceLevel,
        evidenceTypes: [FieldEvidenceType]
    ) -> ConvergenceLevel {
        let hasPrimary = evidenceTypes.contains(.primary)
        let allDerivative = evidenceTypes.allSatisfy { $0 == .derivative }

        if allDerivative && baseLevel > .possible { return .possible }
        if !hasPrimary && baseLevel > .probable { return .probable }
        return baseLevel
    }
}
```

### 4.4 GPS Scoring

```swift
struct GPSScore: Sendable, Codable {
    let exhaustiveSearch: GPSCriterion
    let completeCitations: GPSCriterion
    let analysisAndCorrelation: GPSCriterion
    let conflictResolution: GPSCriterion
    let soundlyReasoned: GPSCriterion

    var score: Int { [exhaustiveSearch, completeCitations, analysisAndCorrelation,
                      conflictResolution, soundlyReasoned].filter(\.met).count }
    var maximum: Int { 5 }
}

struct GPSCriterion: Sendable, Codable {
    let met: Bool
    let detail: String
}

extension GPSScore {
    static func compute(
        profile: Profile,
        snapshot: FamilyGraphSnapshot,
        negativeSearches: [NegativeSearch],
        citations: [Citation],
        convergenceResults: [ConvergenceValue: ConvergenceLevel],
        discrepancies: [ResearchDiscrepancy],
        narrativeExists: Bool
    ) -> GPSScore {
        // 1. Exhaustive search: % of applicable sources searched
        let applicableSources = SourceAvailability.applicableSources(for: profile)
        let searchedSources = negativeSearches.map(\.sourceID) // includes positive searches too
        let searchCoverage = Double(Set(searchedSources).intersection(applicableSources).count) / Double(applicableSources.count)
        let exhaustive = GPSCriterion(
            met: searchCoverage >= 0.75,
            detail: "\(Int(searchCoverage * 100))% of applicable sources searched"
        )

        // 2. Complete citations: every committed fact has a citation
        let factsWithCitations = citations.count
        let totalFacts = profile.sources.values.flatMap { $0 }.count
        let citationComplete = GPSCriterion(
            met: totalFacts > 0 && factsWithCitations >= totalFacts,
            detail: "\(factsWithCitations)/\(totalFacts) facts cited"
        )

        // 3. Analysis: at least one corroborated fact
        let hasCorroboration = convergenceResults.values.contains { $0 >= .probable }
        let analysis = GPSCriterion(
            met: hasCorroboration,
            detail: hasCorroboration ? "Corroborated by independent sources" : "No independent corroboration"
        )

        // 4. Conflicts resolved: zero unresolved discrepancies
        let unresolvedCount = discrepancies.filter { $0.severity >= .conflict }.count
        let conflictsResolved = GPSCriterion(
            met: unresolvedCount == 0,
            detail: unresolvedCount == 0 ? "No unresolved conflicts" : "\(unresolvedCount) unresolved"
        )

        // 5. Soundly reasoned: evidence summary or narrative exists
        let reasoned = GPSCriterion(
            met: narrativeExists,
            detail: narrativeExists ? "Evidence summary available" : "No evidence summary"
        )

        return GPSScore(
            exhaustiveSearch: exhaustive,
            completeCitations: citationComplete,
            analysisAndCorrelation: analysis,
            conflictResolution: conflictsResolved,
            soundlyReasoned: reasoned
        )
    }
}
```

**GPS score displayed in the tree view** alongside the completeness score. Completeness is "how much data do we have?" GPS is "how well-researched is this data?"

---

## 5. The Phases

### Phase 0: Align Foundations (minimum to unblock)

Only the type changes that block subsequent phases.

| Step | Work | Why now |
|------|------|---------|
| 0.1 | **`RecordSource` from `Actor` to `Sendable`.** `FindAGraveSource` becomes struct. FreeBMD/FreeCen remain actors. | Blocks Phase 1 source shape |
| 0.2 | **Add `SourceLineage`, `SourceTrustTier`, `EvidenceDirectness`** to each source + protocol. | Blocks Phase 3 convergence |
| 0.3 | **Replace search return with `SourceQueryResult` enum.** | Blocks Phase 4 dispatcher |
| 0.4 | **Add `softFail` gate result.** Geography and type gates use `softFail`. | Blocks Phase 4 scorer |

**NOT in Phase 0:** Test harness (Phase 1), typed `SourceQueryParams` (Phase 4), `HTTPClient` injection (Phase 1), per-source tolerances (Phase 3).

**Milestone:** App works as before. Foundation types match the governing spec.

---

### Phase 1: One More Source + Test Harness

| Step | Work |
|------|------|
| 1.1 | **Build standalone test harness** (Swift Package). Capture fixtures from Python. |
| 1.2 | **Validate existing 3 sources** against Python output. Default: Swift matches Python in fields; can deviate in interpretation if the deviation is an improvement. Document deviations. |
| 1.3 | **Build `CWGCSource`** as struct. Primary trust tier. CSV parsing, next-of-kin extraction. |
| 1.4 | **Add `HTTPClient` protocol.** Inject into all 4 sources. `FixtureHTTPClient` for tests. |
| 1.5 | Register CWGC in `SourceBootstrap`. Verify in Source Explorer. |

**NOT in Phase 1:** Probate, Wirksworth, FreeREG, FamilySearch. FamilySearch specifically deferred until OAuth is available — cookie-paste is not shippable.

**Milestone:** 4 sources working, all fixture-validated. Test harness operational.

---

### Phase 2: Unified Rule Registry

| Step | Work |
|------|------|
| 2.1 | `DataQualityRule` protocol with three trigger contexts. Default no-op implementations. |
| 2.2 | `DataQualityRuleRegistry` with `registerBuiltins()`. |
| 2.3 | Port all 18 audit rules. Each gets `existingTree` context. Add `newRecord` to: birthBeforeDeath, parentAgeGap, lifespan, marriageAge, noMarriageAfterDeath. |
| 2.4 | Refactor `AuditEngine` to use registry. **Regression test: audit results unchanged.** |
| 2.5 | Refactor audit UI to use `RuleResult`. |

**Milestone:** Audit works exactly as before. Rules extensible to `newRecord` and `multipleSourceMerge`.

---

### Phase 3: Convergence + Discrepancy Engines

| Step | Work |
|------|------|
| 3.1 | `ConvergenceEngine` with `SourceLineage` grouping and trust-weighted scoring. |
| 3.2 | `EvidenceDirectness` cap: all-derivative evidence capped at `.possible`. |
| 3.2a | **Field-level `FieldEvidenceType` (primary/secondary/derivative).** Per-source × per-field mapping table. Convergence engine weights by evidence type: two primary > two secondary > three derivative. |
| 3.3 | `DiscrepancySeverityTable` with per-source thresholds. Each threshold justified: |
| | FreeBMD birth ±2 (registration quarter shift). Census age ±3 (self-reported, 1841 rounded). FreeBMD death age ±1 (informant-reported). CWGC ±0 (official). Find a Grave ±2 (volunteer-transcribed, weathered headstones). |
| 3.4 | `DiscrepancyEngine` using rule registry in `newRecord` context. Convergence upgrades severity but never downgrades. |
| 3.5 | `SourceTolerances` per source, configurable in `RegionConfig`. |
| 3.6 | Tests against fixture data. FreeBMD + FreeBMD = 1 lineage. FreeBMD + CWGC = 2. 3 derivative ≤ `.possible`. Primary disagreeing by >2 = correction. |

**Note:** Phase 4 will exercise these engines with real pipeline data. Budget 50% of Phase 5 time for revisiting this phase when integration reveals issues.

**Milestone:** Convergence and discrepancy scoring work against fixture data.

---

### Phase 4: Search Dispatcher + Pipeline

| Step | Work |
|------|------|
| 4.1 | Replace `additionalParams` with typed `SourceQueryParams`. Update all 4 sources + Source Explorer. |
| 4.2 | `SearchDispatcher` with source-specific query building. |
| 4.3 | Multi-district iteration for FreeBMD. |
| 4.4 | Unsearchable person detection (birth > 1930 → skip). |
| 4.5 | Nil-surname handling for ghost mothers. |
| 4.6 | `QueryCache` for intra-run deduplication. |
| 4.6a | **Negative evidence tracking.** `NegativeSearch` with structured `SearchScope` stored alongside positive results. Dispatcher records every search executed with its exact parameters. Negative searches affect discrepancy severity and feed the search frontier display. |
| 4.6b | **Context-aware dispatch (stretch goal).** Occupation signals constrain geography (framework knitter → Belper/Heanor villages). Military indicators boost CWGC priority. Deferred to Phase 4 stretch if time allows; safe to land later. |
| 4.7 | `ResearchSubject` with factory methods. Include `ResearchMode`: |
| | **Verify:** 2 iterations, stops early if all known facts corroborated, narrow search ranges. |
| | **Extend:** 4 iterations, standard ranges, runs until gaps filled or exhausted. |
| | **Discover:** 4 iterations, broader search ranges (±10 year birth, all districts), accepts more leads (lower threshold). Specific numbers tuned during Phase 6. |
| 4.8 | `ResearchState` with single `scoredRecords` array, computed partitions. |
| 4.9 | `ResearchPipeline` — iteration loop: dispatch → score → discrepancy → convergence → refine. |
| 4.10 | Learned date propagation: `ResearchSubject.refined(with:)`. |
| 4.11 | Stable-point detection + `Task.checkCancellation()`. |
| 4.12 | Household member extraction from census results. |
| 4.13 | **Source eligibility tracking.** Dispatcher records WHY each source was or wasn't queried: "CWGC: not searched (subject pre-1914, no military indicator)" vs "FreeBMD: searched, 3 results." Surfaced in Phase 6 progress view. |
| 4.14 | Pipeline test against fixture data. |

**Milestone:** Working deterministic pipeline with research modes affecting behaviour.

---

### Phase 5: Life Clustering

The highest-risk phase. Determines whether the product is useful or a record dump.

#### 5.1 Design Principle

**When in doubt, split.** The user can merge two clusters they recognise as the same person. They cannot easily un-merge two different people incorrectly combined. Over-splitting produces more candidate cards; over-merging produces wrong facts. Over-splitting is the safer failure mode for genealogy.

#### 5.2 Clustering Algorithm

```
Input: [ScoredRecord] (all non-impossible records for one search subject)
Output: [LifeCluster]

Step 1: SEED clusters from birth/baptism records
  - Each distinct birth (different year OR different district) seeds a new cluster
  - If no birth records, seed from the earliest record of any type
  - Cluster lifespan model:
    - With birth record: birth_year to (birth_year + 110)
    - Without birth record: (earliest_record_year - 80) to (latest_record_year + 5)

Step 2: ASSIGN remaining records to clusters (chronological order)
  For each unassigned record:
    Score against each cluster:

      score = date_compatibility × 0.4
            + location_consistency × 0.3
            + household_confirmation × 0.3

    where:
      date_compatibility:
        1.0  if record.year ∈ cluster.lifespan
        0.5  if record.year within ±5 of lifespan boundary
        0.0  otherwise

      location_consistency:
        1.0  if record.district == any cluster record's district
        0.7  if record.district is adjacent (same county)
        0.3  if record.district is in the same region
        0.0  if record.district is non-local

      household_confirmation:
        1.0  if census household lists a person matching cluster's known spouse/child
        0.5  if census household contains the same surname in a family relationship
        0.0  if no household data or no match

    Assign to the cluster with the highest score IF score ≥ 0.4
    If no cluster scores ≥ 0.4, create a new cluster

Step 3: SPLIT clusters with internal contradictions
  - Two birth/baptism records in the same cluster → split (keep the older, seed a new cluster from the newer)
  - Two death/burial records → split
  - Census records with age-implied birth years differing by >5 → split
  - After splitting, re-run Step 2 for unassigned records

Step 4: MERGE candidates (flag, don't auto-merge)
  - Two clusters where one has a birth and the other has a death with compatible dates and overlapping location → flag as "possible merge" for user review
  - Do NOT auto-merge. The user sees both clusters with a "These might be the same person" note.
  - Rationale: the "when in doubt, split" principle means merge is always a user decision.

Step 5: SCORE cluster confidence
  Strong: 3+ records from 2+ independent lineages, household confirmation, no contradictions, covers birth-to-death span
  Moderate: 2+ records, some corroboration, minor gaps in life coverage
  Weak: single source, or only records from derivative sources
  Ambiguous: contradictions within the cluster, or could plausibly be a different person
```

#### 5.3 Cluster Confidence Derivation

Cluster confidence derives from convergence levels of its records:

| Convergence of records | + Internal consistency | = Cluster confidence |
|----------------------|----------------------|---------------------|
| confirmed/probable | No contradictions | Strong |
| possible | No contradictions | Moderate |
| singleSource | Any | Weak |
| Any | Has contradictions | Ambiguous |
| uncorroborated | Any | Weak |

#### 5.4 Handling Missing Data

| Situation | Approach |
|-----------|----------|
| Record has no birth year | Use record's own date as anchor. `date_compatibility` scores against cluster lifespan bounds. |
| Record has no location | `location_consistency` = 0.5 (neutral). Doesn't penalise or boost. |
| Only one record for a surname | Single-record cluster, confidence = Weak. |
| All records are leads (no facts) | Cluster by date proximity. All clusters = Ambiguous. |
| No birth records exist | Seed from earliest record. Lifespan = (earliest - 80) to (latest + 5). |

#### 5.5 Phase 5 Evaluation Set

Build 5-10 hand-curated test cases with known ground truth:

| Test case | Input | Expected clusters | Tests |
|-----------|-------|-------------------|-------|
| Thomas Land, b.1834, Wirksworth | 30 records across 3 real people | 3 clusters, strongest for b.1834 | Multi-cluster separation |
| Unique surname (Cauldwell) | 5 records, all same person | 1 cluster, Strong confidence | Simple case |
| Common surname (Smith), Belper | 50+ records, 5+ real people | 5+ clusters, most Weak/Ambiguous | Over-splitting preferred |
| Person with no birth record | Census + death only | 1 cluster anchored on census | Missing-data handling |
| Person with contradicting census ages | 1841 age=30, 1851 age=45 | Split into 2 clusters | Contradiction detection |

**This evaluation set is reused in Phase 7 to measure LLM enhancement.** Precision and recall measured against ground truth for both deterministic and LLM-enhanced clustering.

#### 5.6 Tests

| Test | Expected |
|------|----------|
| 30 records, 3 distinct birth years → 3 clusters | Pass |
| Census with wife Hannah → assigned to cluster containing marriage to Hannah | Pass |
| Two births in same cluster → split | Pass |
| Single record, no corroboration → Weak confidence | Pass |
| All Find a Grave (derivative) → convergence capped at possible | Pass |
| Score formula: district match + date match + household match = 1.0 | Pass |
| Score formula: no district + no date + no household = 0.0, new cluster created | Pass |

**Phase 3 backflow expected.** Convergence/discrepancy engines will need adjustment when real clustering data reveals edge cases. This is the plan, not a surprise.

**Milestone:** Pipeline output is clusters, not raw records. Deterministic clustering produces reasonable groupings for the evaluation set.

---

### Phase 6: The Primary Product

Per-profile research with clustering, review, persistence, and memory. Everything needed for a complete workflow.

#### UI

| Step | Work |
|------|------|
| 6.1 | `ResearchProgressView` — live source status cards, iteration progress, counts. **5-minute clock visible in dev builds.** Source eligibility reasons shown: "CWGC: not searched (pre-1914)" vs "FreeBMD: 3 results". |
| 6.2 | "Research" button on profile popover and Gaps view. |
| 6.3 | Research mode selector (verify/extend/discover). Each mode explains what success looks like: "Verify: we'll check your existing data against sources. Finding nothing means your data checks out." |
| 6.4 | Cluster review view — candidate lives with evidence, accept/reject/investigate per cluster. |
| 6.5 | Wire: accepted cluster → `ResearchUpdate` → `MergeEngine` → `TreeDiffView` → tree update. |

#### Review Friction Tiers

| Tier | What | Default action | UI pattern |
|------|------|---------------|-----------|
| **Refinements** | Source adds precision ("1834" → "15 Mar 1834") | **Committed with undo.** Applied immediately. Undo button in research history reverses in one click. User glances at the list, undoes any they disagree with. | List with checkmarks, "Undo" per item |
| **Confirmations** | Two sources agree on a value already in the tree | **Batched.** Presented as a list with "Accept all N confirmations" button. Each can be individually rejected. | Batch list with bulk accept |
| **Corrections** | Source disagrees with tree, evidence is strong | **Individual review.** Each shown with old value → new value + source justification. Accept or reject per item. | Side-by-side comparison card |
| **Conflicts** | Sources disagree with each other or with tree, unclear which is right | **Must resolve.** Cannot commit research results until each conflict has a decision: accept source A, accept source B, or defer. | Modal resolution UI (existing ConflictResolutionView pattern) |

Exit criterion visible: "3 corrections reviewed, 2 remaining. 8 refinements applied. 1 conflict to resolve."

#### Discoveries

| Step | Work |
|------|------|
| 6.6 | "Discoveries" section — first-class findings the user didn't ask for. Each is a `Discovery` with type (newAncestor, maidenName, unknownSibling, spouseIdentified, etc.), description, evidence, and suggested action. |
| 6.7 | Household members surfaced as discoveries, not buried in research state. "Census reveals brother James Land, not in your tree." |

#### Memory

| Step | Work |
|------|------|
| 6.8 | **Rejection memory.** Rejected record IDs stored per profile in SQLite. Filtered before presentation. Tested across app restart. |
| 6.9 | **Name equivalence learning.** When user accepts "Robert" = "Bob" during review, stored in per-project equivalences table. Name gate checks user equivalences alongside hardcoded nicknames. Per-project default; "promote to global" deferred. |

#### Citations + GPS

| Step | Work |
|------|------|
| 6.10 | **`CitationRenderer` per source.** Evidence Explained format for all 4 MVP sources. `Citation` struct with full, short, url, accessedAt. Rendered from raw record fields, cached for display. |
| 6.11 | **Multi-source citation display.** Corroborated facts show all supporting citations with field-level evidence type badges (primary/secondary/derivative). |
| 6.12 | **GPS score per profile.** 5-criterion display in the inspector sidebar alongside completeness score. Completeness = "how much data?" GPS = "how well-researched?" |
| 6.13 | **Search frontier display.** Which sources have been searched (with dates), which haven't, which are not applicable. Stale searches (>6 months) flagged. |

#### Persistence

| Step | Work |
|------|------|
| 6.14 | SQLite tables: source_records, scored_records, research_discrepancies, pending_facts, record_rejections, name_equivalences, negative_searches. GRDB migration for existing projects. |
| 6.15 | Research state persists per profile — clusters, scores, discrepancies, negative searches survive app restart. |
| 6.16 | Research history — previous runs visible per profile with results. |

#### Validation

| Step | Work |
|------|------|
| 6.17 | **End-to-end on the 71-profile tree.** Research 5 different profiles. Measure wall-clock time. Each under 5 minutes including review. |
| 6.18 | **Speed note:** 5 minutes assumes reasonable source latency. With slow sources, the progress view shows live status, never a hung app. If total time exceeds 10 minutes, that's a Phase 6 problem to fix now. |
| 6.19 | Run the Phase 5 evaluation set through the full pipeline. Verify clusters match ground truth. |
| 6.20 | **GPS validation.** After researching 5 profiles, each should have GPS ≥ 3/5. If not, the research workflow isn't meeting the professional standard — fix before shipping. |

**Milestone: THE PRIMARY PRODUCT.** User selects a profile → pipeline searches 4 sources → results clustered into candidate lives → user reviews clusters with friction-appropriate UI → accepted facts flow into tree → ghost nodes become real. Results persist. Rejections remembered. Under 5 minutes.

---

## 5. After Phase 6

**Order is decided, not flexible.** Rationale for each:

| Phase | What | Why this order |
|-------|------|---------------|
| **7** | **Local LLM** | Clustering quality is the #1 product risk. LLM-enhanced clustering is load-bearing if deterministic clustering is rough. Ship this first to improve the core product. |
| **8** | **More sources** (Probate, Wirksworth, FreeREG) | More sources = richer evidence = better clusters. After the pipeline proves itself with 4 sources, add breadth. FamilySearch only when OAuth is resolved. |
| **9** | **Lead management** | Leads need rich source data to be useful. With 7 sources, leads will surface meaningful people to investigate. |
| **10** | **Minimal whole-tree** | Loop per-profile pipeline over selected profiles. Minimal new UI — same cluster review, one profile at a time. |
| **11** | **Narrative + images** | Life story assembly from confirmed facts. Images from Find a Grave and CWGC. Polish, not infrastructure. |
| **12** | **Whole-tree polish** | Bulk-review UI, friction sorting, resume. Only if Phase 10's minimal version proves insufficient. |

### Phase 7: Local LLM

| Step | Work |
|------|------|
| 7.1 | `LocalInferenceService` with MLX Swift. Hugging Face model browser + download. |
| 7.2 | Model selector in Settings with hardware-adaptive guidance. |
| 7.3 | `ResearchInterpreter` with three capabilities: cluster enhancement, disambiguation ("wrong person vs wrong tree"), strategy suggestion. |
| 7.4 | Wire into pipeline as optional enhancement. Deterministic fallback when unavailable. |
| 7.5 | Determinism boundary tests. |
| 7.6 | **Evidence summary per fact (reasoning trail).** LLM generates a per-fact written argument: "Birth year 1834 is established by FreeREG baptism 6 April 1834, corroborated by 1841 census age 7 and 1851 census age 17, all in Belper." This is GPS criterion 5 — the soundly reasoned conclusion. Deterministic template fallback when LLM unavailable. |
| 7.7 | **Measure:** Run Phase 5 evaluation set with LLM-enhanced clustering. Compare precision/recall against deterministic baseline. If LLM clustering is not measurably better on ≥3 of 5 test cases, the LLM integration needs rethinking before shipping. |

### Phase 8: More Sources

Each built in the test harness, validated against Python output, then integrated. **Each source must include a `CitationRenderer` and a `FieldEvidenceMap`.** A source without both is incomplete.

| Source | Notes |
|--------|-------|
| Probate | Nuxeo JSON API, stateless struct |
| Wirksworth | HTML parsing, implement parish search stub |
| FreeREG | CSRF, structured detail returns per record type |
| FamilySearch | **Only when OAuth is available** |

### Phase 9: Lead Management

| Step | Work |
|------|------|
| 9.1 | `Lead` model, `LeadStore` actor, GRDB persistence |
| 9.2 | Lead creation from scored leads + household discoveries |
| 9.3 | Investigation loop (re-run pipeline with lead as subject) |
| 9.4 | Ghost resolution: promoted lead → rekey other leads, dismiss competitors |
| 9.5 | Lead list + detail views |

### Phase 10: Minimal Whole-Tree

| Step | Work |
|------|------|
| 10.1 | "Research all" button → loops per-profile pipeline over priority-sorted queue |
| 10.2 | Stop conditions: max profiles, time limit, no-new-facts streak |
| 10.3 | Same per-profile cluster review, one at a time. No new bulk UI. |
| 10.4 | Sidebar progress indicator. Cancel/resume. |

### Phase 11: Narrative + Images + GEDCOM Citations

| Step | Work |
|------|------|
| 11.1 | `NarrativeAssembler` + `BiographyDrafter` |
| 11.2 | Profile timeline view |
| 11.3 | Image discovery, download, storage, gallery |
| 11.4 | **GEDCOM export with proper citations.** SOUR records with TITL, AUTH, PUBL, PAGE, DATA fields. A tree exported and imported into RootsMagic or Family Historian shows citations in their native UI. |
| 11.5 | **Evidence summary export.** Per-fact reasoning trail included in GEDCOM notes or as a separate research report document. |

### Phase 12: Whole-Tree Polish (if needed)

Only if Phase 10 minimal proves insufficient: bulk-review, friction sorting, resume persistence.

---

## 6. What Ships When

| After Phase | What the user gets |
|------------|-------------------|
| **0** | Same app, aligned foundations |
| **1** | CWGC in Source Explorer, all sources fixture-validated |
| **2** | Audit on unified rules (same UX) |
| **3** | Infrastructure (no visible change) |
| **4** | Infrastructure (no visible change) |
| **5** | Infrastructure (no visible change) |
| **6** | **THE PRODUCT:** per-profile research, clusters, 5 minutes, persistent |
| **7** | LLM-enhanced clustering |
| **8** | 7 sources (8 with FamilySearch if OAuth resolved) |
| **9** | Lead tracking and ghost resolution |
| **10** | Batch research (minimal) |
| **11** | Life narratives and images |

---

## 7. What We Don't Build

- **Python runtime.** Swift-only.
- **FamilySearch** until OAuth available.
- **WikiTree write automation.** Separate spec.
- **Region configuration UI.** Hardcoded Derbyshire. Personal research tool.
- **Mobile/iPad.** macOS only.
- **Sophisticated whole-tree review** until minimal proves insufficient.

---

## 8. Success Criteria

| # | Criterion | Measurement |
|---|-----------|------------|
| 1 | One profile researched in under 5 minutes | Wall-clock from "Research" to tree update |
| 2 | Results as candidate lives, not raw records | Cluster count < 5 for common Derbyshire surname |
| 3 | Discrepancies with justified severity | Each severity traceable to source + threshold + evidence type |
| 4 | One-click accept flows facts into tree | Ghost node becomes real profile |
| 5 | Rejected records never reappear | Tested across app restart |
| 6 | Works without LLM | Deterministic clusters pass evaluation set |
| 7 | LLM measurably improves clustering | ≥3 of 5 evaluation cases better with LLM |
| 8 | Results survive restart | Close/reopen — previous research visible |
| 9 | Every committed fact has a complete citation | Usable in academic contexts / Evidence Explained format |
| 10 | Every researched profile has a GPS score | All 5 criteria assessable, GPS ≥ 3/5 after research |
| 11 | Negative evidence tracked and visible | Search frontier shows searched/unsearched/stale per profile |
| 12 | Field-level evidence type distinguishes primary/secondary/derivative | Visible in citation display per fact |

---

## 9. Risks

| Risk | Mitigation |
|------|-----------|
| **Clustering quality** | Phase 5 is the most detailed phase. Evaluation set with ground truth. "When in doubt, split." Phase 7 LLM enhancement is load-bearing if deterministic is rough — acknowledged. |
| **Pipeline speed** | 5-minute clock in dev builds from Phase 6.1. Speed depends on source latency (not controlled). Progress view, never a hung app. |
| **Phase 3 backflow** | 50% of Phase 5 time budgeted for revisiting convergence/discrepancy engines. Expected. |
| **MLX maturity** | Phase 7 independent of 0-6. MLX issues don't block primary product. |
| **Source fragility** | Fixture tests catch regressions. Source eligibility shown in progress view. |
| **FamilySearch OAuth** | Deferred entirely. Product works with 4-7 other sources. |
