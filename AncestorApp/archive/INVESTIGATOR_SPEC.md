# Investigator Pipeline — Swift Port Specification

**Status:** Proposed (v5 — final, ready to build)  
**Scope:** New Services, Models, and Views for research automation  
**Date:** 2026-04-25  

**Porting principle:** Port from Python faithfully first. Copy exact algorithms, thresholds, gate logic, and date range calculations. Maximisation opportunities (§10) are a second pass after the faithful port is working and validated against the same data the Python code runs on.

---

## 1. What the Python Investigator Does Today

The Python research agent is a closed-loop pipeline that takes a person (name + birth year + gender + location) and systematically searches 8 external genealogical sources, scores every result through 4 deterministic gates, uses an optional local LLM to suggest follow-up searches, and produces confirmed facts, leads for further investigation, and household member discoveries.

### 1.1 The Pipeline (3 Phases)

```
Phase 1: SEARCH
  Person → Search Plan → 8 Source Adapters → Raw Results

Phase 2: SCORE
  Raw Results → 4 Gate Checks (Name, Date, Geography, Family) → fact / lead / impossible

Phase 3: STRATEGISE
  Scored Results → Pattern Analysis (deterministic) or LLM → New Search Suggestions → Loop
```

The loop runs up to 4 iterations. Each iteration may discover new facts that refine subsequent searches (e.g., confirming a death year narrows probate search range).

**Termination:** The Python pipeline stops when (a) max iterations reached, or (b) the strategiser returns no new search suggestions (all `searchKey` values are already in the `searched` set). The Swift port must implement both — iteration cap AND stable-point detection. Stable-point detection: if the new `suggestedSearches` have all their `searchKey` values present in `searchHistory`, stop.

### 1.2 The 8 Sources

| Source | Python module | Data provided | Access method | Auth | Maturity |
|--------|-------------|---------------|---------------|------|----------|
| **FreeBMD** | `sources/freebmd.py` | Birth/death/marriage registrations 1837+ | POST form + session cookie | None | Production |
| **FreeCen** | `sources/freecen.py` | Census records 1841-1921 + household detail | POST form + CSRF | None | Production |
| **FamilySearch** | `sources/familysearch.py` | Multi-source historical records | JSON API | Cookie (manual, expires ~2hrs) | Production but fragile |
| **CWGC** | `sources/cwgc.py` | WWI/WWII war dead | CSV export endpoint | None | Production |
| **Find a Grave** | `sources/findagrave.py` | Burial memorials (230M+ records) | Internal JSON API + HTML scrape | None | Production |
| **Probate** | `sources/probate.py` | Wills & grants (~1996+ digital, soldier wills) | Nuxeo JSON API | None | Production |
| **FreeREG** | `sources/freereg_search.py` | Parish registers (baptisms, marriages, burials pre-1900) | POST form + CSRF | None | Experimental |
| **Wirksworth** | `sources/wirksworth.py` | Derbyshire pedigrees + 104K parish records | HTML scraping | None | Production |

### 1.3 The 4 Scoring Gates

Every search result passes through 4 sequential gates:

| Gate | What it checks | Pass threshold | Fail verdict |
|------|---------------|---------------|--------------|
| **NAME** | Surname + given name similarity | ≥ 0.7 score (0.0–1.0 range; handles spelling variants, nicknames) | `impossible` (wrong person) |
| **DATE** | Record year vs birth/death year, age calculations | Within tolerance (±2 for birth, ±2 for census age) | `lead` or `impossible` depending on severity |
| **GEOGRAPHY** | District/county matching | Is in primary region (per `RegionConfig`) or unknown | `lead` (non-local) |
| **FAMILY** | Household members match known family | Any expected family member found | `lead` (bonus gate, doesn't cause impossible) |

**Verdicts:** All gates pass → `fact`. Name fails → `impossible`. Other gate fails → `lead`.

### 1.4 The Deterministic Strategiser

After scoring, 12 pattern detections suggest follow-up searches:

1. **Maiden name detection** — mother-in-law's surname differs from head → search marriage under maiden name
2. **Missing children from later census** — child disappeared between census years → death/marriage/military
3. **Child gap analysis** — >3 year gap between children → infant death search
4. **Military eligibility** — male born 1880-1927 → CWGC search
5. **Marriage alternatives** — no result found → suggest different parish, non-conformist, spelling variant
6. **Death search** — not yet searched → FreeBMD death with year range
7. **Birth search** — not yet searched → FreeBMD birth ±2 years
8. **Census gaps** — missing census years in plausible range → FreeCen search
9. **Burial search** — not yet searched → Find a Grave
10. **Probate search** — death year known → probate ±5 years
11. **Parish registers** — pre-1837 birth → FreeREG search
12. **Wirksworth** — Derbyshire surname → wirksworth.org.uk pedigrees

### 1.5 Lead Management

Results that score as `lead` (not fact, not impossible) become managed leads:

- **Categories:** birth, death, marriage, census, identity, relationship, ancestor_extension, data_quality
- **Priority scoring:** direct ancestor +10, has free actions +3, multiple sources +2, common surname -3, pre-1837 -2
- **Status lifecycle:** open → investigating → confirmed/dismissed
- **Evidence accumulation:** each investigation iteration adds evidence with source + record summary + gate reasons
- **Cluster investigation:** leads grouped by family (shared household) for efficient LLM analysis

### 1.6 Data Flow

```
Search Results → Scorer → Facts + Leads
                              ↓        ↓
                     ResearchState   LeadStore (SQLite)
                              ↓        ↓
                     MergeEngine    Lead investigation
                              ↓        ↓
                     TreeDiffView   Promote → MergeEngine → TreeDiffView
                              ↓
                     User accepts → Snapshot updated → Tree re-renders
```

### 1.7 Python FamilySearch Cookie Behaviour

When FamilySearch cookies expire mid-run, the Python code catches the HTTP error and returns an empty result list for that source. The pipeline continues with other sources. The user sees "FamilySearch: 0 results" in the search history and can re-run with fresh cookies later.

The Swift port matches this: FamilySearch failure is a **graceful degradation**, not a pipeline abort. The source returns an empty result set with a logged warning. The user is notified in the research progress UI: "FamilySearch unavailable — refresh cookies in Settings to include."

---

## 2. Current Swift Architecture

### 2.1 What We Have

| Layer | Swift component | What it does |
|-------|----------------|-------------|
| **Data model** | `Profile`, `FamilyGraphSnapshot`, `Relationship` | Immutable family graph with completeness, traversal, caching |
| **Source provenance** | `FieldSource`, `SourceOrigin` | Every field tracks all sources that support it |
| **Merge engine** | `MergeEngine` | Multi-source conflict resolution with dispute tracking |
| **Diff engine** | `DiffEngine` | Compare old vs new snapshot, visual diff before committing |
| **Audit engine** | `AuditEngine` + 18 rules | Deterministic validation with error/warning/info tiers |
| **WikiTree client** | `WikiTreeClient` (actor) | API read + web session management |
| **Persistence** | `ProjectDatabase` (GRDB/SQLite) | Transactional storage with undo/time-travel |
| **UI** | Tree view, audit, gaps, settings | Full navigation + inspection + gap analysis |

### 2.2 What Maps Directly

| Python concept | Swift equivalent | Status |
|---------------|-----------------|--------|
| Corpus (local twin) | `FamilyGraphSnapshot` | Done |
| Source provenance | `SourceOrigin` | Done — `.freebmd`, `.freecen`, `.familysearch`, `.cwgc` etc. |
| WikiTree integration | `WikiTreeClient` | Done |
| Fact review | `TreeDiffView` + `ConflictResolutionView` | Done |

### 2.3 Shared Scoring Primitives

Both `AuditEngine` (validates existing data) and `RecordScorer` (triages candidate data) consume the same scoring primitives. They are NOT derived from each other — different inputs, different outputs, different triggers.

```
ScoringRules (shared primitives)
    ├── consumed by AuditEngine (Profile → AuditResult)
    └── consumed by RecordScorer (SourceRecord + ResearchSubject → ScoredRecord)
```

`ScoringRules` is the single source of truth for: name similarity, nickname equivalents, date tolerances, geography validation, military eligibility, census years, civil registration dates. Both engines import it. When nickname equivalents are updated, both engines pick up the change.

### 2.4 What Needs Building

| Component | Python source | Swift work needed |
|-----------|-------------|------------------|
| **Scoring primitives** | `rules.py` | `ScoringRules` — shared by AuditEngine and RecordScorer |
| **Record scorer** | `scorer.py` | `RecordScorer` — 4-gate classification |
| **Source protocol** | 8 separate modules | `RecordSource` protocol + 8 conforming actors |
| **Search dispatcher** | `discover.py` | `SearchDispatcher` service |
| **Strategiser** | `analyser.py` | `ResearchStrategiser` (configurable, 12 patterns) |
| **Lead model** | `leads.py` | `Lead` + `LeadEvidence` + `LeadStore` |
| **Research pipeline** | `pipeline.py` | `ResearchPipeline` orchestrator |
| **Research state** | `record.py` | `ResearchState` per person |
| **Investigation loop** | `investigator.py` | `LeadInvestigator` service |
| **Local LLM** | `agent/llm.py` (MLX) | `LocalInferenceService` (MLX Swift) |
| **Research trace** | (new) | `ResearchTrace` — full audit trail of every decision |
| **Research UI** | CLI only | ResearchView, LeadListView, source explorer |

---

## 3. Pluggable Source Architecture

### 3.1 RecordSource Protocol

```swift
/// A genealogical record source that can be searched.
protocol RecordSource: Actor {
    /// Unique identifier (e.g., "freebmd", "familysearch").
    var sourceID: String { get }

    /// Human-readable name (e.g., "FreeBMD", "FamilySearch").
    var displayName: String { get }

    /// What record types this source provides.
    var recordTypes: Set<RecordType> { get }

    /// Year range this source covers (nil = unbounded).
    var coverageYearRange: ClosedRange<Int>? { get }

    /// Current readiness state.
    var readiness: SourceReadiness { get }

    /// Search for records matching the given query.
    func search(_ query: RecordQuery) async throws -> [SourceRecord]
}

/// Sources that can fetch full detail for a specific record.
protocol DetailFetchingSource: RecordSource {
    func fetchDetail(recordID: String) async throws -> SourceRecord?
}

enum SourceReadiness: Sendable {
    case ready
    case needsAuth(message: String)     // "Paste FamilySearch cookies in Settings"
    case unavailable(reason: String)    // "Model requires 16GB unified memory"
}
```

Sources that can't fetch detail (FreeBMD, Wirksworth) don't conform to `DetailFetchingSource`. No dummy implementations.

### 3.2 Record Types — Enum with Associated Values

Each record type carries only the fields that apply to it. No flat struct with 30 optional fields.

```swift
/// What kind of record to search for.
enum RecordType: String, Codable, Sendable {
    case birth, death, marriage, census, burial, military, probate
    case baptism, christening, parish, pedigree
}

/// A record returned from a source — typed by record kind.
enum SourceRecord: Identifiable, Sendable {
    case birth(BirthRecord)
    case death(DeathRecord)
    case marriage(MarriageRecord)
    case census(CensusRecord)
    case burial(BurialRecord)
    case military(MilitaryRecord)
    case probate(ProbateRecord)
    case parish(ParishRecord)
    case pedigree(PedigreeRecord)

    /// Shared fields accessible on all variants.
    var id: String { common.id }
    var sourceID: String { common.sourceID }
    var name: String? { common.name }
    var surname: String? { common.surname }
    var givenName: String? { common.givenName }
    var detailURL: String? { common.detailURL }
    var rawFields: [String: String] { common.rawFields }

    /// Extract common fields from any variant.
    var common: RecordCommon {
        switch self {
        case .birth(let r): r.common
        case .death(let r): r.common
        case .marriage(let r): r.common
        case .census(let r): r.common
        case .burial(let r): r.common
        case .military(let r): r.common
        case .probate(let r): r.common
        case .parish(let r): r.common
        case .pedigree(let r): r.common
        }
    }
}

/// Fields shared by all record types.
struct RecordCommon: Sendable {
    let id: String
    let sourceID: String
    let name: String?
    let surname: String?
    let givenName: String?
    let detailURL: String?
    let rawFields: [String: String]
}

// Type-specific records carry only their relevant fields:

struct BirthRecord: Sendable {
    let common: RecordCommon
    let birthYear: Int?
    let birthDate: String?
    let birthPlace: String?
    let quarter: String?            // FreeBMD: "Mar"/"Jun"/"Sep"/"Dec"
    let district: String?
    let volume: String?
    let page: String?
    let mothersMaidenName: String?  // FreeBMD: from Sep 1911
}

struct DeathRecord: Sendable {
    let common: RecordCommon
    let deathYear: Int?
    let deathDate: String?
    let deathPlace: String?
    let age: Int?
    let quarter: String?
    let district: String?
    let volume: String?
    let page: String?
    let spouseSurname: String?      // FreeBMD: from Sep 1912
}

struct MarriageRecord: Sendable {
    let common: RecordCommon
    let marriageYear: Int?
    let marriageDate: String?
    let marriagePlace: String?
    let quarter: String?
    let district: String?
    let volume: String?
    let page: String?
    let spouseName: String?
}

struct CensusRecord: Sendable {
    let common: RecordCommon
    let censusYear: Int
    let age: Int?
    let birthYear: Int?
    let birthPlace: String?
    let birthCounty: String?
    let relationship: String?       // "Head", "Wife", "Son", etc.
    let occupation: String?
    let address: String?
    let parish: String?
    let district: String?
    let household: [HouseholdMember]?
}

struct BurialRecord: Sendable {
    let common: RecordCommon
    let deathDate: String?
    let deathYear: Int?
    let birthDate: String?
    let birthYear: Int?
    let burialLocation: String?
    let cemetery: String?
    let memorialID: Int?
    let inscription: String?
    let bio: String?
    let isVeteran: Bool
}

struct MilitaryRecord: Sendable {
    let common: RecordCommon
    let rank: String?
    let regiment: String?
    let unit: String?
    let serviceNumber: String?
    let dateOfDeath: String?
    let deathYear: Int?
    let age: Int?
    let cemetery: String?
    let graveRef: String?
    let additionalInfo: String?     // Often names parents/spouse
}

struct ProbateRecord: Sendable {
    let common: RecordCommon
    let deathDate: String?
    let deathYear: Int?
    let probateDate: String?
    let birthDate: String?
    let ageAtDeath: Int?
    let address: String?
    let grantType: String?          // "PROBATE"/"ADMINISTRATION"
    let registry: String?
    let probateNumber: String?
    let regimentNumber: Int?        // Soldier wills
}

struct ParishRecord: Sendable {
    let common: RecordCommon
    let eventType: String?          // "baptism"/"marriage"/"burial"
    let eventDate: String?
    let eventYear: Int?
    let parish: String?
    let county: String?
    let fatherName: String?         // Christenings often name parents
    let motherName: String?
}

struct PedigreeRecord: Sendable {
    let common: RecordCommon
    let birthYear: Int?
    let deathYear: Int?
    let spouse: String?
    let marriageYear: Int?
    let occupation: String?
    let location: String?
    let generation: Int?
}

struct HouseholdMember: Codable, Sendable {
    let name: String
    let relationship: String
    let age: Int?
    let birthYear: Int?
    let birthPlace: String?
    let occupation: String?
    let sex: String?
}
```

The scorer switches on the `SourceRecord` case and extracts type-specific fields. Adding a new source with a new record type adds one case — existing code gets exhaustiveness checking.

### 3.3 Search Query

```swift
/// Search parameters — source adapters extract what they need.
struct RecordQuery: Sendable {
    let surname: String
    let givenName: String
    let birthYear: Int?
    let deathYear: Int?
    let gender: Gender?
    let location: String?
    let recordType: RecordType
    let yearFrom: Int?
    let yearTo: Int?
    let additionalParams: [String: String]  // source-specific (district codes, etc.)
}
```

**Note on `additionalParams`:** This is a known limitation — an untyped escape hatch for source-specific parameters (FreeBMD district codes, FreeCen Chapman codes, FamilySearch collection IDs). Acceptable for v1 because the Python reference uses the same pattern. Future enhancement: source-specific query builders with compile-time safety (e.g., `FreeBMDQuery.births(district: .bakewell)`). Not in this spec.

### 3.4 Source Registry

```swift
/// Central registry of all available sources.
@MainActor @Observable
final class SourceRegistry {
    private(set) var sources: [any RecordSource] = []
    private var disabledSourceIDs: Set<String> = []     // user-toggled in Settings

    func register(_ source: any RecordSource)
    func setEnabled(sourceID: String, enabled: Bool)
    func source(for id: String) -> (any RecordSource)?
    func sources(for recordType: RecordType) -> [any RecordSource]  // excludes disabled
    func readySources() -> [any RecordSource]                        // ready AND enabled
    func allSources() -> [any RecordSource]                          // including disabled, for Settings UI
}
```

### 3.5 HTTP Layer

```swift
/// HTTP client with retry logic for source adapters.
actor SourceHTTPClient {
    /// GET with retries on 500/502/503 and network errors.
    func get(url: URL, headers: [String: String] = [:],
             timeout: TimeInterval = 20, retries: Int = 3) async throws -> Data

    /// POST form data with retries.
    func postForm(url: URL, fields: [String: String],
                  headers: [String: String] = [:],
                  timeout: TimeInterval = 20, retries: Int = 3) async throws -> Data

    /// Rate-limited request (per-source delay).
    func rateLimited(sourceID: String, delay: Duration = .milliseconds(300),
                     operation: () async throws -> Data) async throws -> Data
}
```

Retry: 3 attempts, exponential backoff (1s, 2s, 4s), retry on HTTP 500/502/503 and network errors. Matches Python's `_http.py` exactly.

### 3.6 Query Cache (Intra-Run Deduplication)

```swift
/// Per-pipeline-run cache preventing duplicate queries to the same source.
/// Keyed by searchKey (source + record type + normalised params).
/// Discarded at pipeline end — not a persistent cache.
actor QueryCache {
    private var cache: [String: [SourceRecord]] = [:]

    func get(_ key: String) -> [SourceRecord]?
    func set(_ key: String, results: [SourceRecord])
    func contains(_ key: String) -> Bool
}
```

The dispatcher checks the cache before issuing a query. If the same search was already executed in this pipeline run, the cached results are returned without hitting the source.

---

## 4. Scoring Engine

### 4.1 ScoringRules — Shared Primitives

```swift
/// Shared scoring primitives consumed by both AuditEngine and RecordScorer.
/// Single source of truth for thresholds, tolerances, and reference data.
nonisolated struct ScoringRules {
    // Tolerances
    static let censusAgeTolerance = 2
    static let birthYearTolerance = 2
    static let deathAgeTolerance = 1

    // Date boundaries
    static let civilRegistrationStart = 1837
    static let mothersMaidenNameStart = 1911
    static let spouseSurnameStart = 1912
    static let freebmdBakewellCutoff = 1941
    static let censusYears = [1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911, 1921]
    static let ww1Eligibility = 1880...1900
    static let ww2Eligibility = 1900...1927

    /// Name similarity score (0.0–1.0).
    /// Handles spelling variants (Caldwell/Cauldwell), nicknames, single-char typos.
    /// Port the full nickname resolution function from Python, not just the lookup table.
    static func nameSimilarity(_ a: String, _ b: String) -> Double { ... }

    static func validateRecord(year: Int, birthYear: Int?, deathYear: Int?,
                               recordType: RecordType) -> ValidationResult { ... }
    static func militaryEligible(birthYear: Int, gender: Gender) -> [String] { ... }
    static func childGapSuggestsDeath(birthYears: [Int], threshold: Int = 3) -> [(Int, Int)] { ... }
    static func maidenNameFromMotherInLaw(household: [HouseholdMember],
                                          headSurname: String) -> String? { ... }
    static func isDerbyshireDistrict(_ district: String) -> Bool { ... }
    static func isNonLocal(_ district: String) -> String? { ... }
}
```

### 4.2 RecordScorer

```swift
/// Scores a source record against a known person through 4 gates.
nonisolated struct RecordScorer {
    static func classify(
        record: SourceRecord,
        subject: ResearchSubject,
        searchType: RecordType
    ) -> ScoredRecord
}
```

`ResearchSubject`, `FamilyContext`, and `KnownRelative` are defined in §8.1.

```swift
struct ScoredRecord: Identifiable, Sendable {
    let id: String
    let record: SourceRecord
    let verdict: RecordVerdict
    let gates: [GateResult]
    let summary: String
}

enum RecordVerdict: String, Codable, Sendable {
    case fact, lead, impossible
}

struct GateResult: Sendable {
    let gate: ScoringGate
    let outcome: GateOutcome
    let reason: String
}

enum ScoringGate: String, Sendable { case name, date, geography, familyContext }
enum GateOutcome: String, Sendable { case pass, fail, impossible, skip }
```
```

### 4.3 Dispatcher Handling of nil-Surname Subjects

When `ResearchSubject.surname` is `nil` (ghost mothers), the dispatcher adjusts its search plan:

| Search type | Surname required? | nil-surname behaviour |
|------------|-------------------|----------------------|
| FreeBMD birth/death | Yes | **Skip** — can't search FreeBMD without a surname |
| FreeBMD marriage | Yes, but... | **Search by known spouse's surname** if `familyContext.knownSpouse` exists. The marriage record carries both names. |
| FreeCen census | No | **Search by household** — use known child's name + estimated year. Census shows full household including wife's name. |
| Find a Grave | Preferred but optional | **Search by location + year range only** if surname nil. Broader results, more leads. |
| FamilySearch | Preferred but optional | **Search by given name + location + year** if available. Broad, but FamilySearch handles partial queries. |
| CWGC | Yes | **Skip** — military records require surname. |
| Probate | Yes | **Skip** — probate requires surname. |
| Wirksworth | Yes | **Skip** — pedigree lookup by surname. |
| FreeREG | Yes | **Skip** — parish register search requires surname. |

**Key insight:** For ghost mothers, the most productive searches are census (reveals her by household) and marriage (reveals maiden name). The strategiser's maiden-name-from-mother-in-law pattern (#1) can then discover her maiden name from census household data, enabling birth/death searches in subsequent iterations.

---

## 5. Research Strategiser

```swift
/// 12 deterministic pattern detections. Configurable with region data.
struct ResearchStrategiser {
    let config: RegionConfig  // district mappings, parish lists, etc.

    func analyse(state: ResearchState) -> ResearchStrategy
}

struct RegionConfig: Sendable {
    let county: String
    let chapmanCode: String
    let districts: [String: String]         // name → FreeBMD code
    let districtParishes: [String: [String]] // district → parishes
    let nonLocalDistricts: [String: String]  // district → location
}

struct ResearchStrategy: Sendable {
    let insights: [String]
    let suggestedSearches: [SearchSuggestion]
    let questions: [String]
}

struct SearchSuggestion: Sendable {
    let description: String
    let sourceID: String
    let recordType: RecordType
    let query: RecordQuery
    let reasoning: String
    let searchKey: String
}
```

The 12 pattern detections from Python's `analyser.py` become 12 private methods, each returning `[SearchSuggestion]`. `RegionConfig` is injected at init — different regions (Derbyshire, Lancashire, etc.) provide different district mappings without changing the detection logic.

**RegionConfig sourcing (v1):** Derbyshire config is bundled with the app as a JSON resource file (`Regions/derbyshire.json`). The Python `config.yaml` district mappings, parish lists, and non-local districts are ported to this JSON verbatim. The project stores which region it uses (currently always Derbyshire). Multi-region selection is future work — for v1, the config is loaded at project open and passed to the strategiser.

**Cross-region subjects:** If a person was born in Derbyshire but died in Lancashire, the strategiser uses the project's primary region config. Geography gate results for non-local records are `lead` (not `impossible`) — the user sees them and can judge. Region-aware source selection (e.g., querying Lancashire-specific sources) is a maximisation opportunity, not a v1 requirement.

---

## 6. Research Pipeline

### 6.1 Pipeline Orchestrator

```swift
/// Closed-loop research pipeline for a single person.
actor ResearchPipeline {
    private let sources: SourceRegistry
    private let scorer: RecordScorer.Type
    private let strategiser: ResearchStrategiser
    private let queryCache: QueryCache

    func research(
        subject: ResearchSubject,
        snapshot: FamilyGraphSnapshot,
        maxIterations: Int = 4
    ) async -> ResearchResult
}

struct ResearchResult: Sendable {
    let state: ResearchState
    let trace: ResearchTrace
}
```

**Termination:** The pipeline stops when:
1. `maxIterations` reached, OR
2. **Stable point:** all `searchKey` values in the new `suggestedSearches` are already in `searchHistory` — no new searches to run.

**Cancellation:** The pipeline checks `Task.checkCancellation()` between iterations and between source queries within an iteration. If the user closes the research view or the Task is cancelled, the pipeline returns its current `ResearchState` (partial results are still useful) and logs a `TraceEntry.cancelled(iteration:)` entry.

**Rate limiting:** Each source has its own per-source serial queue in `SourceHTTPClient` (not one global queue — FreeBMD waiting doesn't block FamilySearch). Sources run in parallel, each with 300ms delay between its own requests. Wall-clock time for a full iteration is bounded by the slowest source's request count: ~20 queries for the busiest source at 300ms = ~6 seconds per iteration. The query cache (§3.6) eliminates duplicate queries across iterations, so later iterations are faster.

### 6.2 Research State

```swift
/// Accumulating state for one person's research session.
/// Records are stored in a single array; verdict determines partition.
struct ResearchState: Codable, Sendable {
    let subjectID: String
    var subject: ResearchSubject
    var scoredRecords: [ScoredRecord]       // all scored results
    var householdMembers: [HouseholdMember]
    var searchHistory: [SearchAttempt]
    var strategy: ResearchStrategy?
    var corpusMatch: String?                // matched profile ID
    var discrepancies: [String]

    // Computed partitions — single source of truth is scoredRecords + verdict
    var confirmedFacts: [ScoredRecord] { scoredRecords.filter { $0.verdict == .fact } }
    var leads: [ScoredRecord] { scoredRecords.filter { $0.verdict == .lead } }
    var rejectedRecords: [ScoredRecord] { scoredRecords.filter { $0.verdict == .impossible } }
}

struct SearchAttempt: Codable, Sendable {
    let sourceID: String
    let recordType: RecordType
    let searchKey: String
    let resultCount: Int
    let timestamp: Date
}
```

**Single array design:** Records live in `scoredRecords`. The verdict field determines the partition. No possibility of a record being in the wrong bucket. If a user manually rejects a lead, we change the verdict to `.impossible` on the record — no array shuffling.

### 6.3 Research Trace

```swift
/// Full audit trail of every decision the pipeline made.
/// Persisted alongside ResearchState for debugging and user transparency.
struct ResearchTrace: Codable, Sendable {
    var entries: [TraceEntry]
}

enum TraceEntry: Codable, Sendable {
    case searchIssued(sourceID: String, query: RecordQuery, timestamp: Date)
    case resultReceived(sourceID: String, resultCount: Int, timestamp: Date)
    case gateVerdict(recordID: String, gate: ScoringGate, outcome: GateOutcome, reason: String)
    case strategyDecision(iteration: Int, suggestedCount: Int, insights: [String])
    case stablePointReached(iteration: Int)
    case sourceUnavailable(sourceID: String, reason: String)
    case leadCreated(leadID: String, category: String)
    case factConfirmed(recordID: String, summary: String)
}
```

Every search, every score, every strategy decision is logged. When the user asks "why was this lead dismissed?" the trace provides the answer.

**Persistence:** Traces are stored in a SQLite table within `ProjectDatabase`, keyed by `subjectID` + session timestamp. Retention: the 5 most recent research sessions per subject are kept in full. Older sessions are summarised (search counts, fact/lead/impossible counts only) and the per-entry log is pruned. Traces are NOT included in GEDCOM export or project sharing — they're local debug/audit data.

**Rendering:** The trace view groups entries by iteration, then by source within each iteration. Each gate verdict is shown inline with its record. Progressive disclosure: collapsed by default, expand an iteration to see its searches and scores. Not a flat `ForEach` — that's unreadable at 200+ entries.

---

## 7. Lead Management

### 7.1 Lead Model

```swift
struct Lead: Identifiable, Codable, Sendable {
    let id: UUID                            // stable, collision-free
    let leadKey: String                     // "{name}_{category}_{year}" for dedup lookup
    let subjectID: String                   // profile ID (real or ghost)
    let subjectName: String
    var subjectBirthYear: Int?

    var category: LeadCategory
    var summary: String
    var uncertaintyReasons: [String]
    var evidence: [LeadEvidence]
    var nextActions: [LeadAction]

    var priority: Int
    var status: LeadStatus

    let openedAt: Date
    var updatedAt: Date
    var history: [LeadEvent]

    var isDirectAncestor: Bool
    var corroboratingSources: Int
}
```

**ID is UUID.** The `leadKey` is for deduplication (matching existing leads when new candidates arrive). ID is stable — it never changes when the lead's year or name refines.

**`subjectID` for ghost nodes:** When a ghost node triggers research, the `subjectID` uses the ghost ID scheme: `"@ghost:father:\(childProfileID)"`, `"@ghost:mother:\(childProfileID)"`, or `"@ghost:unknown:\(childProfileID)"`. When the ghost becomes a real profile (after fact promotion through MergeEngine), `GhostResolved` fires and the lead's `subjectID` is rekeyed to the new profile's real ID (see §7.4).

### 7.2 Lead Store

```swift
/// Persistent lead management backed by SQLite via GRDB.
/// Actor (not MainActor) — pipeline writes from background, UI reads on main.
actor LeadStore {
    func add(_ lead: Lead) async
    func get(_ id: UUID) async -> Lead?
    func addEvidence(_ leadID: UUID, _ evidence: LeadEvidence) async
    func promote(_ leadID: UUID) async -> [ResearchUpdate]
    func dismiss(_ leadID: UUID, reason: String) async
    func byPriority(status: LeadStatus) async -> [Lead]
    func openCount() async -> Int
    func cluster() async -> [LeadCluster]
}
```

**Actor, not MainActor.** The pipeline creates leads from a background actor. Making `LeadStore` a plain `actor` avoids main-thread hops during batch lead creation.

**UI binding pattern:** A `@MainActor @Observable` `LeadViewModel` maintains a main-thread projection of derived counts and the currently-visible lead list. The `LeadStore` actor pushes updates to this projection after writes:

```swift
@MainActor @Observable
final class LeadViewModel {
    private(set) var openCount: Int = 0
    private(set) var leads: [Lead] = []
    private(set) var clusters: [LeadCluster] = []

    func refresh(from store: LeadStore) async {
        openCount = await store.openCount()
        leads = await store.byPriority(status: .open)
        clusters = await store.cluster()
    }
}
```

**Automatic refresh via AsyncStream:** `LeadStore` exposes `var changes: AsyncStream<Void>` that emits after every mutation (add, promote, dismiss, addEvidence). `LeadViewModel` subscribes on init and calls `refresh()` on each event. Callers of mutation methods don't need to remember to refresh — it's automatic.

```swift
// In LeadViewModel.init:
Task {
    for await _ in store.changes {
        await refresh(from: store)
    }
}
```

Sidebar badges read `openCount` directly — no actor hop per render.

### 7.3 Research Updates — Typed, Ordered, Atomic

Lead promotion and research results produce typed updates, not a flat list of field writes. MergeEngine processes them in dependency order.

```swift
/// A discrete change produced by research — profile creation, field update, or relationship.
enum ResearchUpdate: Sendable {
    /// Create a new profile (e.g., discovered ancestor).
    /// ID format: "research_<UUID>" — guaranteed unique, never collides with WikiTree/GEDCOM IDs.
    /// When later matched to a WikiTree profile, MergeEngine emits ProfileRekeyed and updates all references.
    case createProfile(
        id: String,
        firstName: String?, lastName: String?,
        gender: Gender?,
        fields: [ProfileField: String],
        sources: [ProfileField: FieldSource]
    )
    /// Update a field on an existing profile.
    case updateField(
        profileID: String,
        field: ProfileField,
        value: String,
        source: FieldSource
    )
    /// Create a relationship between two profiles.
    case createRelationship(
        fromID: String, toID: String,
        type: RelationshipType,
        role: ParentRole?,
        source: FieldSource
    )
}
```

**Processing order:** MergeEngine applies `createProfile` first, then `createRelationship`, then `updateField`. This ensures a relationship referencing a newly-created profile doesn't fail because the profile doesn't exist yet.

**Promotion path:**

```
LeadStore.promote(leadID)
    → produces [ResearchUpdate]  (ordered: creates → relationships → updates)
    → MergeEngine.applyResearch(updates, to: snapshot)
    → produces new snapshot (or disputes if conflicts)
    → TreeDiffView shows changes for user review
    → User accepts → ProjectStore commits transaction
    → Snapshot updated → Tree re-renders
    → GhostResolution: if update resolved a ghost, rekey leads (see §7.4)
```

This is the same conflict/dispute pipeline as WikiTree refresh data. No bypass.

### 7.4 Ghost Resolution — Lead Rekeying

When a `createProfile` + `createRelationship` resolves a ghost node (unknown parent becomes a real profile), leads referencing that ghost must be updated.

```swift
/// Emitted by MergeEngine when a research update resolves a ghost node.
struct GhostResolved: Sendable {
    let ghostSubjectID: String      // e.g., "@ghost:father:Smith-12345"
    let realProfileID: String       // the newly created profile's ID
    let resolvedByLeadID: UUID      // which lead was promoted
}
```

**LeadStore subscribes to ghost resolution events:**

1. Leads with `subjectID == ghostSubjectID` are rekeyed to `realProfileID`
2. Other leads for the **same ghost slot** (different candidates for the same unknown parent) are auto-dismissed with reason `"Superseded by \(realProfileName)"`
3. The dismissed leads' evidence is preserved for audit trail

**Ghost subject ID scheme:** `"@ghost:father:\(childProfileID)"`, `"@ghost:mother:\(childProfileID)"`, or `"@ghost:unknown:\(childProfileID)"`. The `@ghost:` prefix is guaranteed to never collide with real profile IDs (WikiTree = `Surname-NNN`, GEDCOM = `@I123@`, research-created = `research_<UUID>`).

### 7.5 Future: Generalised Entity Rekeying

Ghost resolution (§7.4) is one instance of a general pattern: an entity's ID changes and all references must update. The same pattern will apply when a research-created profile (`research_<UUID>`) is later matched to a WikiTree profile (`Surname-NNN`).

**For v1:** Only `GhostResolved` is implemented. Generalising to a broader `EntityRekeyed` event (covering WikiTree matching, profile merging, etc.) is future work — when the WikiTree matching flow is built. Don't generalise prematurely.

### 7.6 Subject Resolution from Lead

UI components need to navigate from a lead to its subject. The subject ID may be a real profile, a ghost, or orphaned.

```swift
enum SubjectReference: Sendable {
    case profile(Profile)
    case ghost(childID: String, role: GhostRole)
    case orphan(reason: String)
}

extension LeadStore {
    func resolveSubject(_ subjectID: String, snapshot: FamilyGraphSnapshot) -> SubjectReference {
        // Real profile?
        if let profile = snapshot.profiles[subjectID] {
            return .profile(profile)
        }
        // Ghost?
        if subjectID.hasPrefix("@ghost:") {
            let parts = subjectID.split(separator: ":")
            if parts.count == 3 {
                let role: GhostRole = parts[1] == "father" ? .father : parts[1] == "mother" ? .mother : .unknown
                let childID = String(parts[2])
                return .ghost(childID: childID, role: role)
            }
        }
        return .orphan(reason: "Subject ID '\(subjectID)' not found in snapshot or ghost scheme")
    }
}
```

---

## 8. Subject Construction + Tree Integration

### 8.1 Shared Types

**GhostRole** is defined once in a shared location, consumed by both the layout spec (TreeLayout) and this spec:

```swift
/// Defined in Models/GhostRole.swift — shared across layout and research.
enum GhostRole: String, Codable, Sendable {
    case father, mother, unknown
}
```

TreeLayout's `NodeKind.ghost(parentOf:role:)` uses this enum. `ResearchSubject.forGhostParent()` uses it. One definition, no string-sniffing.

**KnownRelative** replaces labeled tuples in FamilyContext:

```swift
struct KnownRelative: Codable, Sendable {
    let name: String
    let birthYear: Int?
}
```

**FamilyContext:**

```swift
struct FamilyContext: Codable, Sendable {
    let knownParents: [KnownRelative]
    let knownSpouse: KnownRelative?
    let knownChildren: [KnownRelative]
}
```

**ResearchSubject carries split name fields** (not `displayName`):

```swift
struct ResearchSubject: Codable, Sendable {
    let surname: String?            // for source surname filters (nil for ghost mothers)
    let givenName: String?          // for source given-name filters
    let birthYear: Int?
    let deathYear: Int?
    let gender: Gender?
    let birthLocation: String?
    let familyContext: FamilyContext?

    /// Display name for UI (convenience).
    var displayName: String {
        [givenName, surname].compactMap { $0 }.joined(separator: " ")
    }
}
```

Sources use `surname` for their surname filter and `givenName` for given-name filter. No parsing of a combined `name` string.

### 8.2 Building a ResearchSubject

Three factory methods. The logic lives here, not in ad-hoc code at call sites.

```swift
extension ResearchSubject {
    /// Build from an existing profile (research to fill gaps).
    static func fromProfile(_ profile: Profile, snapshot: FamilyGraphSnapshot) -> ResearchSubject {
        let parents = snapshot.parentsOf(profile.id)
        let spouse = snapshot.spousesOf(profile.id).first
        let children = snapshot.childrenOf(profile.id)
        return ResearchSubject(
            surname: profile.lastName,
            givenName: profile.firstName,
            birthYear: profile.birthDate?.bestYear,
            deathYear: profile.deathDate?.bestYear,
            gender: profile.gender,
            birthLocation: profile.birthLocation,
            familyContext: FamilyContext(
                knownParents: parents.map { KnownRelative(name: $0.displayName, birthYear: $0.birthDate?.bestYear) },
                knownSpouse: spouse.map { KnownRelative(name: $0.displayName, birthYear: $0.birthDate?.bestYear) },
                knownChildren: children.map { KnownRelative(name: $0.displayName, birthYear: $0.birthDate?.bestYear) }
            )
        )
    }

    /// Build from a ghost node (ancestor extension).
    /// CRITICAL: ghost fathers and ghost mothers have different search strategies.
    static func forGhostParent(
        childProfile: Profile,
        ghostRole: GhostRole,
        snapshot: FamilyGraphSnapshot
    ) -> ResearchSubject {
        let childBirthYear = childProfile.birthDate?.bestYear
        let estimatedBirthYear = childBirthYear.map { $0 - 30 }
        let otherParent = snapshot.parentsOf(childProfile.id).first

        switch ghostRole {
        case .father:
            // Father shares child's surname. Search by surname + location.
            return ResearchSubject(
                surname: childProfile.lastName,
                givenName: nil,             // unknown — sources search surname only
                birthYear: estimatedBirthYear,
                deathYear: nil,
                gender: .male,
                birthLocation: childProfile.birthLocation,
                familyContext: FamilyContext(
                    knownParents: [],
                    knownSpouse: otherParent.map { KnownRelative(name: $0.displayName, birthYear: $0.birthDate?.bestYear) },
                    knownChildren: [KnownRelative(name: childProfile.displayName, birthYear: childBirthYear)]
                )
            )

        case .mother:
            // Mother's maiden name is UNKNOWN. Her birth surname differs from child's.
            // Strategy: search MARRIAGE records (which carry both married and maiden names)
            // and CENSUS records (which show her in the household).
            // Do NOT search birth/baptism by child's surname — that's her married name, not birth name.
            // If maiden name is known (from mother-in-law detection or other evidence),
            // the pipeline will pick it up via the strategiser's maiden-name pattern (#1).
            return ResearchSubject(
                surname: nil,               // maiden name unknown — can't search by surname
                givenName: nil,             // unknown
                birthYear: estimatedBirthYear,
                deathYear: nil,
                gender: .female,
                birthLocation: childProfile.birthLocation,
                familyContext: FamilyContext(
                    knownParents: [],
                    knownSpouse: otherParent.map { KnownRelative(name: $0.displayName, birthYear: $0.birthDate?.bestYear) },
                    knownChildren: [KnownRelative(name: childProfile.displayName, birthYear: childBirthYear)]
                )
            )
            // knownSpouse is the OTHER parent (the father, if known).
            // This enables the §4.3 dispatcher to search marriage records
            // by the spouse's (father's) surname — the marriage record will
            // carry both his surname and her maiden name.

        case .unknown:
            // Unknown role — search broadly by child's surname, no gender constraint.
            return ResearchSubject(
                surname: childProfile.lastName,
                givenName: nil,
                birthYear: estimatedBirthYear,
                deathYear: nil,
                gender: nil,
                birthLocation: childProfile.birthLocation,
                familyContext: FamilyContext(
                    knownParents: [],
                    knownSpouse: otherParent.map { KnownRelative(name: $0.displayName, birthYear: $0.birthDate?.bestYear) },
                    knownChildren: [KnownRelative(name: childProfile.displayName, birthYear: childBirthYear)]
                )
            )
        }
    }

    /// Build from manual user input (ad-hoc research).
    static func fromUserInput(
        surname: String?, givenName: String?,
        birthYear: Int?, deathYear: Int?,
        gender: Gender?, location: String?
    ) -> ResearchSubject {
        ResearchSubject(
            surname: surname, givenName: givenName,
            birthYear: birthYear, deathYear: deathYear,
            gender: gender, birthLocation: location, familyContext: nil
        )
    }
}
```

**Ghost mother search strategy:**
- `surname` is `nil` — sources that require a surname will skip or broaden
- The search dispatcher skips birth/baptism searches for nil-surname subjects
- Census searches work (FreeCen searches by household, not individual surname)
- Marriage searches work (the marriage record carries both maiden and married names)
- The strategiser's maiden-name-from-mother-in-law pattern (#1) may discover the maiden name from census household data, enabling birth searches in subsequent iterations
- Find a Grave works (search by location + date range, no surname required)

**Ghost father search strategy:**
- `surname` is child's `lastName` — direct FreeBMD/census/burial search
- Standard pipeline, same as researching a known person with missing details

**Ghost unknown-role search strategy:**
- Same as father (surname from child) but no gender constraint — broader results, more leads

### 8.3 Ghost Parent Heuristics + Search vs Scorer Tolerance

| Heuristic | Value | Rationale |
|-----------|-------|-----------|
| Estimated birth year | child birth year - 30 | Midpoint of typical parent age range (20-40) |
| Search year range | ±10 years from estimate | Captures parents aged 20-40 at child's birth |
| Father surname | child's lastName | Patronymic — child inherits father's surname |
| Mother surname | nil (unknown) | Maiden name differs from married/child name |
| Location | child's birthLocation | Parents likely lived where child was born |
| Gender | from ghostRole | father → male, mother → female, unknown → nil |

**Search range vs scorer tolerance:** The search casts a wide net (±10 years) to find candidates. The scorer's date gate is narrow (±2 years from estimated birth year). Most candidates inside the search range but outside ±2 years will score as `lead`, not `fact`. This is intentional — the wide search finds plausible candidates, the narrow scorer separates strong matches from ones needing more evidence. The user adjudicates leads via evidence review.

**Edge case — nil surname father:** If a child profile has no `lastName` (foundling, uncertain identity), the father ghost gets `surname: nil`, which triggers the same nil-surname dispatcher path as ghost mothers (§4.3). This is correct — without a surname, all searches broaden. Rare but handled.

### 8.4 End-to-End Flow

1. **User launches research** — from Gaps view ("Research this person") or Source Explorer ("Full pipeline")
2. **Subject constructed** — via `ResearchSubject.fromProfile()` or `.fromUserInput()`
3. **Pipeline runs** — searches, scores, strategises, loops
4. **User reviews results** — confirmed facts shown in TreeDiffView as `[ResearchUpdate]`:
   - `createProfile`: "Create new profile: Isaac Land, born ~1798, Wirksworth"
   - `createRelationship`: "Isaac Land is father of Thomas Land"
   - `updateField`: "Add death date 1875 to Isaac Land"
5. **User accepts** → MergeEngine processes updates → snapshot rebuilds → tree re-renders
6. **Ghost becomes real** — if a ghost was resolved, `GhostResolved` event fires, leads are rekeyed

**For v1:** Research is launched manually from Gaps view or Source Explorer. Ghost node click → research launch is future work (PEDIGREE_NAV_SPEC §6.3 + research-workflow spec). The midway state is "researcher-as-power-user" — they manually select who to research. This is intentional and the user story is honest about it.

---

## 9. Local LLM Integration (Optional)

```swift
actor LocalInferenceService {
    private var model: (any MLXModel)?

    var readiness: SourceReadiness {
        if model != nil { return .ready }
        // Check available memory
        let availableGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        if availableGB < 16 {
            return .unavailable(reason: "Requires 16GB unified memory (have \(availableGB)GB)")
        }
        return .unavailable(reason: "Model not loaded — tap Load Model in Settings")
    }

    func loadModel(modelID: String) async throws { ... }
    func ask(systemPrompt: String, userPrompt: String, maxTokens: Int = 2000) async throws -> String?
    func askJSON<T: Decodable>(systemPrompt: String, userPrompt: String,
                                type: T.Type, retries: Int = 2) async throws -> T?
}
```

Model ID is configurable (not hardcoded). Users with less RAM choose a smaller model; users with M3 Max choose bigger. Settings panel shows available models and memory requirements.

**Fallback:** If `readiness != .ready`, the pipeline uses `ResearchStrategiser` (deterministic). Every code path works without the LLM.

---

## 10. Source Maximisation Opportunities (Second Pass)

**These are NOT part of the faithful Python port.** They are enhancements to pursue AFTER the port is working and validated.

| Source | What Python extracts | What's also available | Enhancement |
|--------|---------------------|----------------------|-------------|
| **FamilySearch** | Birth/death/marriage/census basic fields | Christening records naming parents, relationship data in GEDCOMx, collection-specific queries | Dedicated christening search for ancestor extension |
| **Find a Grave** | Name, dates, cemetery, bio, inscription | Family links (linked memorials for spouse/parents/children) | Extract structured family relationships |
| **CWGC** | Casualty search + detail page | Certificate PDF with next-of-kin (parents, spouse, address) | Parse certificate data |
| **Probate** | Search by name/date | Full grant text naming executors, beneficiaries, addresses | Extract family members from grant text |
| **FreeCen** | Top 5 household details | All matching households | Remove cap, fetch all detail |

---

## 11. Implementation Phases

**Strategy: vertical slice first, then widen.** Don't build all 8 sources then the pipeline. Build foundation + 3 high-value sources + a basic pipeline + minimal UI = a working end-to-end research tool. Then add remaining sources, leads, and LLM as parallel work.

FreeBMD + FreeCen + Find a Grave cover most British research from 1837 onward: civil registration, census with households, and burials. That's enough for a useful pipeline.

### Phase 1: Foundation + ScoringRules

| Step | Work |
|------|------|
| 1.1 | `ScoringRules` — port `rules.py` faithfully (name similarity with full nickname resolution, date validation, geography, military eligibility, census tolerances). **Refactor AuditEngine to consume ScoringRules** for shared logic (name similarity, date validation). Regression test: audit results unchanged. |
| 1.2 | `RecordSource` protocol, `DetailFetchingSource`, `SourceRecord` enum, `RecordQuery`, `HouseholdMember`, all typed record structs, `SourceReadiness` |
| 1.3 | `SourceHTTPClient` actor — port `_http.py` retry logic (per-source serial queues, not global) |
| 1.4 | `RecordScorer` — 4-gate classification, port `scorer.py` |
| 1.5 | `SourceRegistry`, `QueryCache` |
| 1.6 | `RegionConfig` with bundled `Regions/derbyshire.json` (ported from Python `config.yaml`) |

**Test:** Score mock records against mock subjects, verify verdicts match Python output.

### Phase 2: First 3 Sources + Source Explorer

| Step | Work |
|------|------|
| 2.1 | `FreeBMDSource` — POST form, JS array parsing, district codes |
| 2.2 | `FreeCenSource` — CSRF token flow, search + household detail |
| 2.3 | `FindAGraveSource` — JSON search + HTML detail scrape |
| 2.4 | **Source Explorer UI** — sidebar tab with form (name, birth year, death year, source picker). Shows raw scored results per source. Validates sources end-to-end. |

**Test:** Search each source for Thomas Land (b. 1834) and verify results match Python output.

### Phase 3: Vertical Slice — Working Pipeline

| Step | Work |
|------|------|
| 3.1 | `ResearchState`, `ResearchTrace` models |
| 3.2 | `SearchDispatcher` — translates search plan to source queries via registry |
| 3.3 | `ResearchStrategiser` — 12 pattern detections with `RegionConfig` |
| 3.4 | `ResearchPipeline` — closed-loop orchestrator with stable-point detection |
| 3.5 | `ResearchSubject` factory methods (`.fromProfile()`, `.fromUserInput()`) |
| 3.6 | `ResearchUpdate` enum (createProfile, updateField, createRelationship) |
| 3.7 | Integration: extend `MergeEngine` with `applyResearch([ResearchUpdate], to: FamilyGraphSnapshot)` — new method that processes createProfile → createRelationship → updateField in order. Pipeline results flow through this → `TreeDiffView` |
| 3.8 | **Research launch from Gaps view** — "Research" button on incomplete profiles |
| 3.9 | **Research progress view** — live search status, scoring results as they arrive |

**Milestone: facts work end-to-end.** User selects an incomplete profile in Gaps → pipeline searches FreeBMD + FreeCen + Find a Grave → scores results → user reviews confirmed facts in TreeDiffView → accepts → tree updates. This is user-visible value with 3 sources. **Leads are not in this phase** — results scored as `lead` are visible in the research progress view but there is no lead store, investigation loop, or lead management UI yet. That comes in Phase 6.

### Phase 4: Remaining No-Auth Sources

| Step | Work |
|------|------|
| 4.1 | `CWGCSource` — CSV export, casualty detail HTML |
| 4.2 | `ProbateSource` — Nuxeo JSON API, pagination |
| 4.3 | `WirksworthSource` — HTML scraping, two parsing modes |
| 4.4 | `FreeREGSource` — CSRF token, dynamic form discovery (experimental) |

### Phase 5: FamilySearch (Cookie-Auth)

| Step | Work |
|------|------|
| 5.1 | `FamilySearchSource` — cookie management, JSON API, GEDCOMx parsing |
| 5.2 | Cookie management UI in Settings — paste/refresh cookies, show expiry status |
| 5.3 | Graceful degradation — FamilySearch failure returns empty results with warning, pipeline continues |

### Phase 6: Lead Management

| Step | Work |
|------|------|
| 6.1 | `Lead`, `LeadEvidence`, `LeadAction` models (UUID ID, leadKey dedup) |
| 6.2 | `LeadStore` actor with GRDB persistence |
| 6.3 | Lead creation from candidates (port `create_leads_from_candidates`) |
| 6.4 | `LeadInvestigator` — investigation loop with evidence scoring |
| 6.5 | Lead clustering by family |
| 6.6 | Ghost resolution rekeying (§7.4) |
| 6.7 | **Lead list view** — prioritised leads with filters by category/status |
| 6.8 | **Lead detail view** — evidence timeline, next actions, promote/dismiss |

### Phase 7: Local LLM (Optional)

| Step | Work |
|------|------|
| 7.1 | `LocalInferenceService` — MLX Swift, configurable model, memory check |
| 7.2 | Port strategist + investigator system prompts (bundled as `.txt` resource files for iteration without rebuild) |
| 7.3 | Wire LLM as optional enhancement to deterministic strategiser |

### Phase 8: Polish

| Step | Work |
|------|------|
| 8.1 | Fact review improvements — group ResearchUpdates by profile in TreeDiffView |
| 8.2 | Research trace view — grouped by iteration → source → record, progressive disclosure |
| 8.3 | Source Explorer improvements — compare results across sources for same person |

---

## 12. What This Spec Does NOT Cover

- **Ghost node click → research launch** — ghosts are currently non-interactive (PEDIGREE_NAV_SPEC §6.3). Making them research triggers is the bridge to the research-workflow spec. The combined spec (this + ghost interaction) is what delivers the full workflow. The midway state (research via Gaps view) is "researcher-as-power-user" — intentional and functional.
- **WikiTree write automation** — Playwright-based profile editor. Separate spec.
- **Bio generation** — Python's `drafter.py`. Useful but separate from investigation.
- **Branch queueing** — Python's `branch.py` (auto-queue household members). Port after core pipeline works.
- **Multi-region configuration** — v1 is Derbyshire only (bundled JSON). Region selection UI is future.
- **Cookie automation for FamilySearch** — v1 requires manual cookie paste. Browser-extension-style auto-capture is a maximisation opportunity.

---

## 13. Key Porting Principles

1. **Port from Python faithfully.** Copy exact algorithms, thresholds, gate logic, date ranges. Do not reinvent.
2. **Maximise later.** §10 enhancements come AFTER the faithful port is validated against the same data.
3. **Sources are actors.** Each manages its own HTTP state in isolation. Per-source rate limiting, not global.
4. **ScoringRules is shared.** Both AuditEngine and RecordScorer consume it. Introduced in Phase 1.1 with AuditEngine refactor and regression test.
5. **Scoring is nonisolated.** Pure functions, no state, trivially testable.
6. **Pipeline is an actor.** Owns research state, coordinates sources and scorer.
7. **Leads persist to SQLite** via GRDB. LeadStore is a plain actor, not MainActor.
8. **LLM is always optional.** Deterministic strategiser is the primary path.
9. **Promoted leads flow through MergeEngine** as typed `ResearchUpdate` enums — createProfile → createRelationship → updateField ordering. Same conflict resolution as WikiTree data.
10. **Research trace logs everything.** Persisted per subject, retained for 5 sessions, pruned beyond.
11. **Vertical slice first.** Phase 3 delivers a working end-to-end pipeline with 3 sources. Remaining sources and leads are parallel widening work.
12. **LLM prompts are resource files.** Bundled `.txt` files, not inline strings. Iterate without rebuilding.
13. **Ghost resolution is explicit.** `GhostResolved` event rekeys leads and auto-dismisses competing candidates. Generalised rekeying (WikiTree matching) is future work — don't generalise prematurely.
14. **GhostRole is defined once.** In `Models/GhostRole.swift`, consumed by both TreeLayout and ResearchSubject.
15. **ResearchSubject uses split names.** `surname` + `givenName`, not a combined `name` string. Ghost mothers have `surname: nil`.

---

## 14. Known Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| **FamilySearch cookies expire every ~2 hours** | High — richest source, least reliable | Graceful degradation (§1.7). Pipeline continues without it. Cookie management UI (Phase 5.2). Long-term: cookie automation. |
| **MergeEngine integration for profile creation** | Medium — `ResearchUpdate.createProfile` is new capability | Typed enum with ordered processing (§7.3). Test with manual profile creation before pipeline integration. |
| **Ghost resolution fan-out** | Medium — multiple leads for same ghost slot | `GhostResolved` event with explicit lead rekeying and auto-dismiss (§7.4). |
| **Source fragility** | Medium — web scraping breaks when sites change | Per-source isolation means one source breaking doesn't affect others. Source Explorer (Phase 2.4) validates each source independently. |
| **Research-workflow spec coupling** | Low (intentional) — ghost click → research is separate | v1 user story is Gaps view launch, not ghost click. Functional without the second spec. |
| **LLM memory availability** | Low | `physicalMemory` check is a hard lower bound (reject <16GB). At load time, use `os_proc_available_memory()` for soft check with clear user error if insufficient. |
| **Ghost mother surname** | High if not handled | Ghost mothers search with `surname: nil`. Dispatcher skips surname-required searches. Census and marriage searches work without surname. Maiden name discovered via strategiser pattern #1 in later iterations. |
