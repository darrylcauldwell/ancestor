# Research Pipeline — Specification

**Status:** Accepted  
**Scope:** Source plugins, research pipeline, discrepancy detection, convergence scoring, local LLM integration  
**Supersedes:** INVESTIGATOR_SPEC.md, SOURCE_PLUGIN_SPEC.md (for architecture and types)  
**References:** SOURCE_INTEGRATION_SPEC.md (source field documentation, Python port gaps, image management)  
**Date:** 2026-04-25  

This is the **governing spec** for the research pipeline. It combines architectural decisions with concrete Swift types. Where it conflicts with earlier specs, this document takes precedence.

---

## 1. Purpose and scope

Post-MVP research pipeline as an extension of the MVP architecture, not a replacement. The MVP delivers GEDCOM/WikiTree/audit. This spec adds: external source plugins, evidence scoring, a deterministic-probabilistic-deterministic research pipeline, discrepancy detection unified with audit, and local LLM inference via MLX.

**Unifying principle:** Decisions about facts are always deterministic and always user-approved. The LLM only suggests where to look next.

**Runtime decision:** Swift-only. The Python codebase is a reference implementation for porting — never a runtime dependency. Single signed Mac binary, no IPC, no two-process debugging.

---

## 2. Decision rights — deterministic vs probabilistic

### 2.1 Always deterministic (LLM never decides these)

| Decision | Mechanism | Component |
|---|---|---|
| Whether a source record matches a person | 4-gate scorer (name/date/geography/type) | `RecordScorer` |
| Whether a record contradicts the tree | Discrepancy rules (range arithmetic) | `DiscrepancyEngine` |
| Whether the existing tree is internally consistent | Audit rules | Unified rule registry |
| Whether two sources corroborate | Convergence rules (with source independence) | `ConvergenceEngine` |
| Whether a fact is committed to the tree | User approval in TreeDiffView | UI only |
| What date ranges are compatible | `GenealogicalDate` arithmetic | Existing |
| What counts as the same person | Duplicate detection rules | Existing audit rule |

### 2.2 Always probabilistic (only the LLM can do these)

| Decision | Why deterministic can't | Component |
|---|---|---|
| Which source to search next given partial evidence | Open-ended reasoning across many possibilities | `StrategyAdvisor` |
| What relationship a household member implies | Multi-step inference (mother-in-law → maiden name) | `LeadInvestigator` |
| Drafting biographical narrative from facts | Language generation | `BiographyDrafter` |

### 2.3 Rule: when the LLM and the deterministic engine disagree, deterministic wins

The LLM can suggest, never overrule. Convergence can upgrade discrepancy severity but never downgrade it.

---

## 3. Foundation types

```swift
enum RecordType: String, Codable, Sendable, CaseIterable {
    case birth, death, marriage, census, burial, probate
    case christening, baptism, other
}

enum Region: Hashable, Codable, Sendable {
    case englandAndWales
    case scotland
    case ireland
    case commonwealthMilitary
    case county(String)
    case parish(String, county: String)
}

enum SourceLineage: Hashable, Codable, Sendable {
    case independentTranscription(of: String)   // FreeBMD → "GRO-indexes"
    case communityEdited                        // FamilySearch, Find a Grave
    case primaryRecord                          // CWGC official
    case derivedFrom(Set<String>)
}

enum SourceTrustTier: Int, Codable, Sendable, Comparable {
    case community = 1       // FamilySearch user submissions, Find a Grave
    case transcription = 2   // FreeBMD, FreeCen, FreeREG
    case primary = 3         // CWGC, official registers

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum SourceReadiness: Sendable, Equatable {
    case ready
    case needsAuth(message: String)
    case unavailable(reason: String)
}
```

---

## 4. Source plugin protocol

```swift
protocol RecordSource: Sendable {
    nonisolated var sourceID: String { get }
    nonisolated var displayName: String { get }
    nonisolated var recordTypes: Set<RecordType> { get }
    nonisolated var coverageYearRange: ClosedRange<Int>? { get }
    nonisolated var coverageRegions: Set<Region> { get }
    nonisolated var dataLineage: SourceLineage { get }
    nonisolated var trustTier: SourceTrustTier { get }

    var readiness: SourceReadiness { get async }
    func search(_ query: RecordQuery) async -> SourceQueryResult
}

protocol DetailFetchingSource: RecordSource {
    func fetchDetail(recordID: String) async -> SourceQueryResult
}

protocol AuthenticatingSource: RecordSource {
    func setCredentials(_ credentials: SourceCredentials) async
    func clearCredentials() async
}

enum SourceCredentials: Sendable {
    case cookie(String)
    case oauth(token: String, refresh: String?)
}

enum SourceQueryResult: Sendable {
    case results([SourceRecord])
    case unavailable(reason: String)
    case throttled(retryAfter: Duration)
    case outsideCoverage(reason: String)

    var records: [SourceRecord] {
        if case .results(let r) = self { return r } else { return [] }
    }
}
```

**Stateless sources are structs** (CWGC, Probate, Find a Grave, Wirksworth). **Stateful sources are actors** (FreeBMD, FreeCen, FreeREG — CSRF sessions). The protocol requires `Sendable`, not `Actor`.

---

## 5. Typed query parameters

```swift
struct RecordQuery: Sendable {
    let surname: String
    let givenName: String?
    let recordType: RecordType
    let yearRange: ClosedRange<Int>?
    let region: Region?
    let gender: Gender?
    let sourceParams: SourceQueryParams
}

enum SourceQueryParams: Sendable {
    case freeBMD(FreeBMDParams)
    case freeCen(FreeCenParams)
    case findAGrave(FindAGraveParams)
    case cwgc(CWGCParams)
    case probate(ProbateParams)
    case wirksworth(WirksworthParams)
    case freeREG(FreeREGParams)
    case familySearch(FamilySearchParams)
    case generic
}

struct FreeBMDParams: Sendable {
    let districtCode: String?
    let wildcardSurname: Bool
    let motherSurname: String?
    let spouseSurname: String?
}

struct FreeCenParams: Sendable {
    let chapmanCode: String?
    let censusYear: Int?
    let birthYearRange: ClosedRange<Int>?
}

struct FindAGraveParams: Sendable {
    let yearRangeWidth: Int
    let cemetery: String?
}

struct CWGCParams: Sendable {
    let conflict: String?
    let regiment: String?
}

struct ProbateParams: Sendable {
    let courtType: String?
}

struct WirksworthParams: Sendable {
    let parishHint: String?
}

struct FreeREGParams: Sendable {
    let registerType: String?
    let parish: String?
}

struct FamilySearchParams: Sendable {
    let collectionID: String?
    let fatherSurname: String?
    let motherSurname: String?
}
```

---

## 6. HTTP client with injection

```swift
protocol HTTPClient: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> Data
    func postForm(url: URL, body: [String: String], headers: [String: String]) async throws -> Data
}

enum HTTPError: Error {
    case status(code: Int, body: Data?)
    case unauthorized
    case throttled
    case timeout
    case transport(Error)

    var isThrottled: Bool {
        if case .throttled = self { return true }
        if case .status(let code, _) = self, code == 429 { return true }
        return false
    }
}

actor SourceHTTPClient: HTTPClient {
    static let shared = SourceHTTPClient()
    private let urlSession: URLSession
    private var rateLimits: [String: RateLimiter] = [:]

    func get(url: URL, headers: [String: String]) async throws -> Data {
        try await throttled(host: url.host ?? "") {
            var request = URLRequest(url: url)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            return try await self.execute(request)
        }
    }

    func postForm(url: URL, body: [String: String], headers: [String: String]) async throws -> Data {
        try await throttled(host: url.host ?? "") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            request.httpBody = self.encodeForm(body)
            return try await self.execute(request)
        }
    }

    private func execute(_ request: URLRequest) async throws -> Data { ... }
    private func throttled<T>(host: String, _ work: () async throws -> T) async throws -> T { ... }
    private func encodeForm(_ body: [String: String]) -> Data { ... }
}

#if DEBUG
struct FixtureHTTPClient: HTTPClient {
    let fixtures: [URL: Data]
    func get(url: URL, headers: [String: String]) async throws -> Data {
        guard let data = fixtures[url] else { throw HTTPError.status(code: 404, body: nil) }
        return data
    }
    func postForm(url: URL, body: [String: String], headers: [String: String]) async throws -> Data {
        guard let data = fixtures[url] else { throw HTTPError.status(code: 404, body: nil) }
        return data
    }
}
#endif
```

---

## 7. Source registry

```swift
@MainActor @Observable
final class SourceRegistry {
    private(set) var sources: [String: any RecordSource] = [:]
    @AppStorage("disabledSources") private var disabledSourceIDsRaw: String = ""

    func register(_ source: any RecordSource) { sources[source.sourceID] = source }
    func source(for id: String) -> (any RecordSource)? { sources[id] }

    func enabledSources(for recordType: RecordType, region: Region?) -> [any RecordSource] {
        sources.values.filter { source in
            !disabledSourceIDs.contains(source.sourceID)
            && source.recordTypes.contains(recordType)
            && (region == nil || source.coverageRegions.contains(region!))
        }
    }

    func sourcesByLineage() -> [SourceLineage: [any RecordSource]] {
        Dictionary(grouping: sources.values, by: \.dataLineage)
    }
}
```

`sourcesByLineage()` is what convergence scoring needs — agreements between sources of different lineage are stronger evidence than same-lineage agreements.

---

## 8. Search dispatcher

The dispatcher decides which sources to query and constructs typed params for each. Sources are dumb pipes; the dispatcher knows source-specific patterns.

```swift
@MainActor
struct SearchDispatcher {
    let registry: SourceRegistry
    let regionConfig: RegionConfig

    func dispatch(subject: ResearchSubject, recordTypes: Set<RecordType>) async -> [SourceRecord] {
        await withTaskGroup(of: [SourceRecord].self) { group in
            for (source, query) in queriesFor(subject: subject, recordTypes: recordTypes) {
                group.addTask { await source.search(query).records }
            }
            var combined: [SourceRecord] = []
            for await batch in group { combined.append(contentsOf: batch) }
            return deduplicate(combined)
        }
    }

    private func queriesFor(subject: ResearchSubject, recordTypes: Set<RecordType>) -> [(any RecordSource, RecordQuery)] {
        var pairs: [(any RecordSource, RecordQuery)] = []
        for recordType in recordTypes {
            for source in registry.enabledSources(for: recordType, region: subject.region) {
                pairs.append(contentsOf: buildQueries(source: source, subject: subject, recordType: recordType).map { (source, $0) })
            }
        }
        return pairs
    }

    private func buildQueries(source: any RecordSource, subject: ResearchSubject, recordType: RecordType) -> [RecordQuery] {
        switch source.sourceID {
        case "freebmd":
            // Multi-district: one query per configured district
            return regionConfig.districts.map { (_, code) in
                RecordQuery(surname: subject.surname, givenName: subject.givenName, recordType: recordType,
                           yearRange: subject.yearRange(for: recordType), region: subject.region, gender: subject.gender,
                           sourceParams: .freeBMD(FreeBMDParams(districtCode: code, wildcardSurname: false,
                                                                 motherSurname: subject.knownMotherMaidenName, spouseSurname: nil)))
            }
        case "familysearch":
            // 5-subquery: birth, death, marriage, census, broad sweep
            return buildFamilySearchQueries(subject: subject)
        case "freecen":
            // Per applicable census year
            return censusYearsApplicable(to: subject).map { year in
                RecordQuery(surname: subject.surname, givenName: subject.givenName, recordType: .census,
                           yearRange: year...year, region: subject.region, gender: subject.gender,
                           sourceParams: .freeCen(FreeCenParams(chapmanCode: regionConfig.chapmanCode, censusYear: year, birthYearRange: subject.birthYearRange)))
            }
        default:
            return [RecordQuery(surname: subject.surname, givenName: subject.givenName, recordType: recordType,
                               yearRange: subject.yearRange(for: recordType), region: subject.region, gender: subject.gender,
                               sourceParams: .generic)]
        }
    }
}
```

---

## 9. Record scorer (4-gate classifier)

```swift
struct RecordScorer {
    let snapshot: FamilyGraphSnapshot

    func score(_ record: SourceRecord, against subject: ResearchSubject) -> ScoredRecord {
        let gates = GateResults(
            name: nameGate(record, subject),
            date: dateGate(record, subject),
            geography: geographyGate(record, subject),
            type: typeGate(record, subject)
        )
        let verdict: RecordVerdict = {
            if gates.name == .fail || gates.date == .fail { return .impossible }
            if gates.allPassed { return .fact }
            return .lead
        }()
        return ScoredRecord(record: record, gates: gates, verdict: verdict)
    }
}

struct GateResults: Sendable {
    let name, date, geography, type: GateResult
    var allPassed: Bool { name == .pass && date == .pass && geography != .fail && type != .fail }
}

enum GateResult: Sendable, Equatable { case pass, fail, softFail }
enum RecordVerdict: String, Sendable, Codable { case fact, lead, impossible }
```

Gates use range arithmetic via `GenealogicalDate`. `softFail` for geography/type doesn't disqualify — a Derbyshire person registered in Nottinghamshire is a lead, not impossible.

Name similarity uses the genealogy-specific scoring from Python (AU/A swap=0.95, nicknames=0.85, containment=0.8) — NOT raw Levenshtein.

---

## 10. Unified rule registry (audit + discrepancy + corroboration)

One protocol, three trigger contexts. The audit engine and discrepancy detector share infrastructure.

```swift
protocol DataQualityRule: Sendable {
    var id: String { get }
    var displayName: String { get }
    var severity: RuleSeverity { get }
    var triggerContexts: Set<RuleTriggerContext> { get }

    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult]
    func evaluate(record: SourceRecord, profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult]
    func evaluate(field: ProfileField, sources: [FieldSource], profile: Profile) -> [RuleResult]
}

extension DataQualityRule {
    func evaluate(profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] { [] }
    func evaluate(record: SourceRecord, profile: Profile, snapshot: FamilyGraphSnapshot) -> [RuleResult] { [] }
    func evaluate(field: ProfileField, sources: [FieldSource], profile: Profile) -> [RuleResult] { [] }
}

enum RuleTriggerContext: Sendable, Hashable {
    case existingTree       // audit
    case newRecord          // discrepancy detection
    case multipleSourceMerge // corroboration / merge policy
}

enum RuleSeverity: String, Sendable, Codable, Comparable {
    case info, warning, error
    private var rank: Int { switch self { case .info: 0; case .warning: 1; case .error: 2 } }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

struct RuleResult: Sendable, Identifiable {
    let id = UUID()
    let ruleID: String
    let profileID: String
    let field: ProfileField?
    let severity: RuleSeverity
    let context: RuleTriggerContext
    let message: String
    let evidence: [Evidence]
}
```

A single `BirthBeforeDeathRule` can: audit the existing tree, detect contradictions from new source records, AND flag conflicts during multi-source merge. One rule definition, three uses, no drift.

---

## 11. Convergence engine (source independence)

```swift
struct ConvergenceEngine {
    let registry: SourceRegistry

    func score(value: ConvergenceValue, supportedBy records: [SourceRecord]) -> ConvergenceLevel {
        let lineageGroups = Dictionary(grouping: records) { registry.sources[$0.common.sourceID]?.dataLineage }
        let independentCount = lineageGroups.keys.count
        let trustScore = records.reduce(0.0) { $0 + Double(registry.sources[$1.common.sourceID]?.trustTier.rawValue ?? 1) }

        switch (independentCount, trustScore) {
        case (let n, _) where n >= 3: return .confirmed
        case (2, let s) where s >= 4: return .probable
        case (2, _): return .possible
        case (1, _): return .singleSource
        default: return .uncorroborated
        }
    }
}

enum ConvergenceLevel: String, Sendable, Codable, Comparable {
    case uncorroborated, singleSource, possible, probable, confirmed
    private var rank: Int { switch self { case .uncorroborated: 0; case .singleSource: 1; case .possible: 2; case .probable: 3; case .confirmed: 4 } }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}
```

Two FreeBMD entries from different districts = one lineage. FreeBMD + FamilySearch = two lineages.

---

## 12. Discrepancy severity with source trust

```swift
struct DiscrepancySeverityTable {
    static func severity(sourceTier: SourceTrustTier, absDelta: Int, convergence: ConvergenceLevel) -> DiscrepancySeverity {
        let base: DiscrepancySeverity = {
            switch (sourceTier, absDelta) {
            case (.primary, 0): return .none
            case (.primary, 1...2): return .refinement
            case (.primary, _): return .correction
            case (.transcription, 0...1): return .none
            case (.transcription, 2...3): return .refinement
            case (.transcription, _): return .conflict
            case (.community, 0...2): return .note
            case (.community, _): return .conflict
            }
        }()
        // Convergence can upgrade but never downgrade
        switch convergence {
        case .confirmed: return max(base, .correction)
        case .probable: return max(base, .conflict)
        default: return base
        }
    }
}

enum DiscrepancySeverity: String, Sendable, Codable, Comparable {
    case none, note, refinement, conflict, correction
    private var rank: Int { switch self { case .none: 0; case .note: 1; case .refinement: 2; case .conflict: 3; case .correction: 4 } }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}
```

---

## 13. Research pipeline

```swift
@MainActor
final class ResearchPipeline {
    let dispatcher: SearchDispatcher
    let scorer: RecordScorer
    let convergence: ConvergenceEngine
    let ruleRegistry: DataQualityRuleRegistry
    let strategyAdvisor: StrategyAdvisor?
    let snapshot: FamilyGraphSnapshot

    func research(subject: ResearchSubject, config: ResearchConfig) async -> ResearchResult {
        var state = ResearchState(subject: subject)

        for iteration in 1...config.maxIterations {
            // DETERMINISTIC: dispatch and score
            let records = await dispatcher.dispatch(subject: state.subject, recordTypes: state.activeRecordTypes)
            let scored = records.map { scorer.score($0, against: state.subject) }

            // DETERMINISTIC: discrepancy detection
            let discrepancies = ruleRegistry.evaluateNewRecord(scored.filter { $0.verdict != .impossible },
                                                                profile: state.profile, snapshot: snapshot)

            // DETERMINISTIC: convergence scoring and promotion
            let convergent = convergence.scoreAll(scoredRecords: scored)
            state.applyConvergencePromotions(convergent)

            // DETERMINISTIC: refine subject from confirmed facts
            state.subject = state.subject.refined(with: state.confirmedFacts)

            // STOPPING CONDITIONS
            if state.confirmedFacts.count >= config.maxFacts { break }
            if iteration >= config.maxIterations { break }

            // PROBABILISTIC (optional): LLM strategy advice
            if let advisor = strategyAdvisor, config.useLLM {
                let strategy = await advisor.suggestNextSearch(state: state)
                if let validated = strategy.validated() {
                    state.activeRecordTypes = validated.recordTypes
                }
            }
        }

        return ResearchResult(confirmedFacts: state.confirmedFacts, leads: state.leads,
                              discrepancies: state.discrepancies, allScoredRecords: state.allScoredRecords)
    }
}

struct ResearchConfig: Sendable {
    let maxIterations: Int
    let maxFacts: Int
    let useLLM: Bool

    static let perProfile = ResearchConfig(maxIterations: 4, maxFacts: 50, useLLM: true)
    static let wholeTree = ResearchConfig(maxIterations: 2, maxFacts: 20, useLLM: false)
    static let deterministicOnly = ResearchConfig(maxIterations: 4, maxFacts: 50, useLLM: false)
}
```

The LLM is called once per iteration, only between iterations, only to suggest the next search direction — never to rule on any specific record.

---

## 14. Local LLM service (MLX)

```swift
actor LocalInferenceService {
    static let shared = LocalInferenceService()
    private var model: LLMModel?
    private var loadTask: Task<LLMModel, Error>?

    func ensureLoaded() async throws -> LLMModel {
        if let model { return model }
        if let existing = loadTask { return try await existing.value }
        let task = Task<LLMModel, Error> { try await LLMModel.load(modelID: modelID) }
        loadTask = task
        defer { loadTask = nil }
        let loaded = try await task.value
        model = loaded
        return loaded
    }

    func reason(systemPrompt: String, userPrompt: String) async throws -> String {
        let model = try await ensureLoaded()
        return try await model.generate(messages: [.system(systemPrompt), .user(userPrompt)],
                                        maxTokens: 2048, temperature: 0.3)
    }

    static func loadPrompt(named name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Prompts")
            .flatMap { try? String(contentsOf: $0) } ?? ""
    }
}
```

The strategy advisor wraps the inference service with defensive parsing:

```swift
struct StrategyAdvisor {
    let inference: LocalInferenceService

    func suggestNextSearch(state: ResearchState) async -> SearchStrategy {
        let response = try? await inference.reason(
            systemPrompt: LocalInferenceService.loadPrompt(named: "strategy_system"),
            userPrompt: renderState(state)
        )
        return SearchStrategy.parse(response ?? "") ?? .fallback(state: state)
    }
}

struct SearchStrategy: Sendable {
    let recordTypes: Set<RecordType>
    let reasoning: String

    static func parse(_ raw: String) -> SearchStrategy? {
        // Defensive JSON extraction: find first {, last }, parse between
        // Validate record types against known set
        // Reject malformed input
        ...
    }

    func validated() -> SearchStrategy? { recordTypes.isEmpty ? nil : self }
    static func fallback(state: ResearchState) -> SearchStrategy {
        SearchStrategy(recordTypes: state.activeRecordTypes, reasoning: "Fallback: continue current strategy")
    }
}
```

Prompts are bundled as `.txt` resource files in `Resources/Prompts/`.

---

## 15. Implementation order

Build bottom-up. R1-R8 deliver a deterministic-only pipeline — a useful product without the LLM.

| Phase | Component | Depends on |
|---|---|---|
| **R1** | Source plugin foundation: `RecordSource` protocol, `SourceQueryResult`, `SourceRegistry`, `HTTPClient` injection, fixture-based test harness | MVP complete |
| **R2** | Two stateless sources: `CWGCSource`, `FindAGraveSource` with fixture tests | R1 |
| **R3** | Stateful source: `FreeBMDSource` with CSRF tokens, multi-district dispatcher | R1, R2 |
| **R4** | Record scorer: 4 gates, `ScoredRecord`, `RecordVerdict`, exhaustive tests | R3 |
| **R5** | Unified rule registry: `DataQualityRule` protocol, port 18 audit rules, add `newRecord` and `multipleSourceMerge` triggers | R4, MVP audit |
| **R6** | Discrepancy engine: severity table, trust tiers | R5 |
| **R7** | Convergence engine: independence-aware scoring | R5, R6 |
| **R8** | Pipeline (deterministic only): dispatch → score → discrepancy → convergence → refine loop | R6, R7 |
| **R9** | Local LLM service: MLX integration, model loading, prompt resources | None (parallel) |
| **R10** | Strategy advisor: LLM wrapper with validated suggestions | R8, R9 |
| **R11** | Pipeline (full sandwich): add strategy advisor, learned date propagation | R10 |
| **R12** | Per-profile research UI: progress view, TreeDiffView extensions | R11 |
| **R13** | Whole-tree orchestrator: priority queue, batch research, review queue | R12 |
| **R14** | Remaining sources: FreeCen, Probate, Wirksworth, FreeREG, FamilySearch | R8 |
| **R15** | Narrative & biography: drafter, narrative assembly, audit-triggered research | R11 |

---

## 16. SQLite schema additions

```sql
CREATE TABLE source_records (
    id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL,
    record_type TEXT NOT NULL,
    profile_id TEXT,
    raw_fields_json TEXT NOT NULL,
    parsed_json TEXT NOT NULL,
    discovered_at TIMESTAMP NOT NULL,
    created_by_transaction_id TEXT NOT NULL
);

CREATE TABLE scored_records (
    id TEXT PRIMARY KEY,
    source_record_id TEXT NOT NULL,
    profile_id TEXT NOT NULL,
    name_gate TEXT NOT NULL,
    date_gate TEXT NOT NULL,
    geography_gate TEXT NOT NULL,
    type_gate TEXT NOT NULL,
    verdict TEXT NOT NULL,
    scored_at TIMESTAMP NOT NULL
);

CREATE TABLE research_discrepancies (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    field TEXT NOT NULL,
    existing_value TEXT NOT NULL,
    source_value TEXT NOT NULL,
    source_id TEXT NOT NULL,
    record_id TEXT NOT NULL,
    severity TEXT NOT NULL,
    reasoning TEXT NOT NULL,
    detected_at TIMESTAMP NOT NULL,
    resolution_status TEXT NOT NULL DEFAULT 'open',
    created_by_transaction_id TEXT NOT NULL
);

CREATE TABLE leads (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    category TEXT NOT NULL,
    summary TEXT NOT NULL,
    priority REAL NOT NULL,
    status TEXT NOT NULL DEFAULT 'open',
    evidence_json TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL,
    created_by_transaction_id TEXT NOT NULL
);

CREATE TABLE pending_facts (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    fact_kind TEXT NOT NULL,
    value_json TEXT NOT NULL,
    sources_json TEXT NOT NULL,
    proposed_at TIMESTAMP NOT NULL,
    review_status TEXT NOT NULL DEFAULT 'pending',
    created_by_transaction_id TEXT NOT NULL
);
```

All tables support undo via `created_by_transaction_id`.

---

## 17. File layout

```
Models/Research/          — RecordType, Region, SourceLineage, SourceTrustTier, SourceReadiness,
                           DataQualityRule, DataQualityRuleRegistry, ResearchFact, ResearchDiscrepancy,
                           Lead, ConvergenceLevel, DiscrepancySeverity, ScoredRecord, SourceRecord

Services/Research/        — RecordSource, RecordQuery, SourceQueryResult, HTTPClient, SourceHTTPClient,
                           FixtureHTTPClient, SourceRegistry, SearchDispatcher, RecordScorer,
                           ScoringRules, ConvergenceEngine, DiscrepancyEngine, DiscrepancySeverityTable,
                           ResearchSubject, ResearchState, ResearchPipeline, LocalInferenceService,
                           StrategyAdvisor, TreeResearchOrchestrator
                    Rules/ — One file per DataQualityRule (BirthBeforeDeathRule, etc.)

Services/Sources/         — SourceBootstrap, CWGCSource, FreeBMDSource, FreeCenSource, FindAGraveSource,
                           ProbateSource, WirksworthSource, FreeREGSource, FamilySearchSource

Views/Research/           — ResearchProgressView, TreeResearchConfigView, ReviewQueueView,
                           DiscrepancyDetailView, LeadListView

Resources/Prompts/        — strategy_system.txt, investigation_system.txt, ancestor_extension_system.txt

Tests/ResearchTests/      — Fixtures/ (recorded HTTP responses), per-source tests, scorer tests,
                           convergence tests, discrepancy tests, pipeline tests, determinism boundary tests
```

---

## 18. Testing strategy

**Source tests:** fixture-based. Recorded HTTP responses replayed against parsers. Fixtures in repo.

**Pipeline tests:** mock sources returning canned records. Tests dispatcher/scorer/discrepancy/convergence integration without network.

**Rule tests:** every rule tested in all three trigger contexts it claims to support.

**LLM tests:** parser tests with canned responses. Validator tests with malformed strategies.

**Determinism boundary tests:**
```swift
@Test func llmCannotPromoteImpossibleRecord() async throws { ... }
@Test func llmCannotDowngradeDiscrepancySeverity() async throws { ... }
```

These are the regression suite for "decisions about facts are always deterministic."

---

## 19. Risks

1. **MLX runtime maturity.** R9 is independent of R1-R8 — MLX issues don't block the deterministic pipeline.
2. **Source ToS compliance.** Each source plugin includes ToS status in its header comment.
3. **Fixture rot.** Quarterly fixture refresh task.
4. **LLM hallucination escaping the validator.** Defensive parsing — assume hostile input.
5. **Pipeline complexity.** R8's deterministic-only milestone is a stable product. R11 builds on a proven base.

---

## 20. Product-Level Design Requirements

This section addresses how the pipeline's output becomes trustworthy genealogical research. The backend (§3–§14) produces candidates. This section defines how candidates become trusted knowledge.

### 20.1 The Real Problem: Plausible Wrong Matches

The 4-gate scorer rejects impossible records. But the dangerous records are plausible ones for the wrong person. 47 Thomas Lands born in Derbyshire 1830–1840 all pass the gates. Presenting 30 "facts" for the user to sort through is not research assistance — it's data dumping.

**The solution is cluster-based presentation, not record-by-record review.**

### 20.2 Life Clustering

Before presenting results to the user, the pipeline groups records that appear to describe the same person's life:

```swift
struct LifeCluster: Identifiable, Sendable {
    let id: UUID
    let candidateName: String
    let birthYearEstimate: Int?
    let records: [ScoredRecord]
    let convergenceLevel: ConvergenceLevel
    let confidence: ClusterConfidence
    let narrative: String               // one-paragraph summary of this life
}

enum ClusterConfidence: String, Sendable {
    case strong     // multiple independent sources, consistent dates, household confirms
    case moderate   // some corroboration, minor gaps
    case weak       // single source or contradictions within the cluster
    case ambiguous  // could be this person or someone else with the same name
}
```

**Clustering algorithm:**
1. Group records by (surname, given name, ±5 year birth range, same district/parish)
2. Within each group, check for contradictions (two birth records with different mothers → split into two clusters)
3. Check for household confirmation (census record lists the right spouse/children → strong signal)
4. Score each cluster's internal consistency

**User sees:** "We found 3 candidate Thomas Lands. Here's what we know about each:" — not 30 individual records.

**User action:** Accept a cluster as "this is my Thomas Land" → all records in the cluster become facts. Reject → all become impossible for this profile. "Not sure" → records become leads.

### 20.3 Three Research Modes

A generic "Research" button doesn't communicate what the user should expect. Three modes with different expectations:

| Mode | Goal | Precision/Recall | Stops when | Success looks like |
|------|------|-------------------|------------|-------------------|
| **Verify** | Confirm what's already in the tree | High precision, low recall | All known facts corroborated or contradicted | "3 facts confirmed, 1 discrepancy found" |
| **Extend** | Find missing facts (death date, marriage) | Medium | Missing fields filled or exhausted | "Found death date, found marriage record" |
| **Discover** | Find this person from scratch (ghost node) | Low precision, high recall | Candidate clusters identified | "Found 3 candidate matches, review needed" |

```swift
enum ResearchMode: String, Sendable {
    case verify     // confirm existing data
    case extend     // fill known gaps
    case discover   // find from scratch (ghost nodes)
}

extension ResearchConfig {
    static func forMode(_ mode: ResearchMode) -> ResearchConfig {
        switch mode {
        case .verify:  return ResearchConfig(maxIterations: 2, maxFacts: 20, useLLM: false)
        case .extend:  return ResearchConfig(maxIterations: 4, maxFacts: 50, useLLM: true)
        case .discover: return ResearchConfig(maxIterations: 4, maxFacts: 100, useLLM: true)
        }
    }
}
```

**A verify run that finds nothing is a success** — "we couldn't disprove your data."
**A discover run that finds nothing is a failure** that needs reporting.

### 20.4 Evidence Type (Beyond Source Independence)

Source independence is necessary but not sufficient. The convergence engine needs a second axis — evidence directness:

```swift
enum EvidenceDirectness: Int, Sendable, Comparable {
    case primary = 3        // original record (parish register, death certificate)
    case directTranscription = 2  // transcript by someone who saw the primary (FreeBMD, FreeREG)
    case derivative = 1     // compiled/summarised without seeing the primary (most FamilySearch user submissions, Find a Grave bios)

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
```

Three derivative sources agreeing is weaker than one direct transcription. The convergence engine incorporates this:

```swift
extension ConvergenceEngine {
    func adjustedScore(
        baseLevel: ConvergenceLevel,
        records: [SourceRecord]
    ) -> ConvergenceLevel {
        let directnessScores = records.compactMap { record -> EvidenceDirectness? in
            registry.sources[record.common.sourceID]?.evidenceDirectness
        }
        let hasDirectOrPrimary = directnessScores.contains { $0 >= .directTranscription }

        // If all supporting evidence is derivative, cap at .possible
        if !hasDirectOrPrimary && baseLevel > .possible {
            return .possible
        }
        return baseLevel
    }
}
```

**Add `evidenceDirectness` to the `RecordSource` protocol:**

```swift
protocol RecordSource: Sendable {
    // ... existing properties ...
    nonisolated var evidenceDirectness: EvidenceDirectness { get }
}
```

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

### 20.5 Discrepancy Threshold Justification

The severity table's thresholds must be named and justified, not arbitrary constants:

| Source type | Tolerance | Justification |
|------------|-----------|---------------|
| FreeBMD birth ±2 years | Registration quarter vs actual birth date. A December birth registered in January appears as the following year. | 
| FreeCen census age ±3 years | Self-reported by household head, often rounded. Victorian adults frequently misstated age. 1841 census deliberately rounded adults to nearest 5. |
| FreeBMD death age ±1 year | Age at death recorded by informant (usually family). More reliable than census age. |
| Find a Grave dates ±2 years | Volunteer-transcribed from headstones which may be weathered. Sometimes from obituaries with errors. |
| CWGC dates ±0 | Official military records. If CWGC says 14 July 1918, it's 14 July 1918. |

**Make these configurable per source** in `RegionConfig` or a source-specific config:

```swift
struct SourceTolerances: Codable, Sendable {
    let birthYearTolerance: Int
    let deathYearTolerance: Int
    let censusAgeTolerance: Int
    let marriageYearTolerance: Int
}
```

### 20.6 Review Friction Levels

Not all results need the same level of user attention. Stage by friction:

| Category | Default action | User effort | Example |
|----------|---------------|-------------|---------|
| **Refinements** | Auto-stage for acceptance (one-click confirm-all) | Minimal — glance and confirm | "1834" → "15 Mar 1834" |
| **Confirmations** | Grouped for batch review | Low — scan and accept | Two sources agree on death year 1902 |
| **Corrections** | Individual review required | Medium — compare old vs new | Three sources say 1905, tree says 1902 |
| **Conflicts** | Must resolve before commit | High — evaluate evidence | FreeBMD says Belper, census says Ashbourne |
| **Discoveries** | Separate "new findings" section | High — evaluate if relevant | Census reveals unknown sibling |

```swift
enum ReviewFriction: Int, Sendable, Comparable {
    case autoStage = 0      // refinements — confirm-all button
    case batchReview = 1    // confirmations — scan and accept
    case individualReview = 2 // corrections — compare carefully
    case mustResolve = 3    // conflicts — can't proceed without decision
    case newFinding = 4     // discoveries — separate section

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
```

The review queue sorts by friction level descending — hard decisions first, easy confirmations last. Bulk actions: "Accept all refinements" (friction 0), "Accept all confirmations" (friction 1).

### 20.7 Rejection Memory

When a user rejects a record for a profile, that rejection is sticky:

```swift
struct RecordRejection: Codable, Sendable {
    let profileID: String
    let sourceRecordID: String      // the specific record rejected
    let rejectedAt: Date
    let reason: String?             // optional user note
}
```

Stored in SQLite. Before presenting results, the pipeline filters out previously rejected records. This prevents the same wrong Thomas Land from appearing every time the user researches.

**Equivalence learning:** When the user accepts "Robert" = "Bob" during review, store in a user equivalences table:

```swift
struct NameEquivalence: Codable, Sendable {
    let nameA: String
    let nameB: String
    let addedAt: Date
}
```

The name gate checks user equivalences in addition to the hardcoded nickname table. The system learns from every review session.

### 20.8 Household Members as First-Class Discoveries

Household members are the most valuable output of census research. They reveal ancestors, siblings, and in-laws the user didn't know existed. They must be surfaced as first-class discoveries, not buried in `ResearchState.householdMembers`.

```swift
struct Discovery: Identifiable, Sendable {
    let id: UUID
    let type: DiscoveryType
    let description: String
    let evidence: [ScoredRecord]
    let suggestedAction: String
    let profileID: String           // which profile this was discovered through
}

enum DiscoveryType: String, Sendable {
    case newAncestor        // "Census shows father Isaac Land, age 43"
    case maidenName         // "Mother-in-law Martha Barker → wife's maiden name is Barker"
    case unknownSibling     // "Census shows brother James Land, not in tree"
    case unknownChild       // "Census shows daughter Mary, not in tree"
    case spouseIdentified   // "Marriage record identifies spouse as Hannah Barker"
    case occupationRevealed // "1861 census: lead miner"
    case addressFound       // "1881 census: High Street, Wirksworth"
}
```

The research result includes a `discoveries` array alongside facts, leads, and discrepancies. The UI has a dedicated "Discoveries" section showing what the system found that the user wasn't explicitly looking for.

### 20.9 LLM Rebalancing

The LLM's current role (strategy advice between iterations) is the easier half of the problem. The harder half — where the LLM earns its compute budget — is interpretation within iterations:

| Task | Current assignment | Better assignment |
|------|-------------------|-------------------|
| "Which source to search next" | LLM (StrategyAdvisor) | **Deterministic** — decision tree based on what's missing |
| "Are these records the same person?" | Not assigned | **LLM** — cluster identification |
| "Is this discrepancy a wrong person or a wrong tree?" | Deterministic (severity table) | **LLM** — disambiguation with context |
| "What does this household relationship imply?" | LLM (mentioned but not wired) | **LLM** — relationship inference |
| "What to research about this profile" | Deterministic (gaps view) | **Deterministic** — keep as-is |

**Phase R10 should wire the LLM for cluster interpretation and disambiguation, not just strategy advice.** The `StrategyAdvisor` becomes a `ResearchInterpreter` with three capabilities:

```swift
struct ResearchInterpreter {
    let inference: LocalInferenceService

    /// Cluster: group records into candidate lives
    func identifyClusters(records: [ScoredRecord], subject: ResearchSubject) async -> [LifeCluster]

    /// Disambiguate: is this discrepancy a wrong person or a wrong tree?
    func disambiguate(discrepancy: ResearchDiscrepancy, context: ResearchState) async -> DisambiguationResult

    /// Suggest: what to search next (existing capability, moved from StrategyAdvisor)
    func suggestNextSearch(state: ResearchState) async -> SearchStrategy
}

enum DisambiguationResult: Sendable {
    case wrongPerson(reasoning: String)     // this record is for a different person
    case wrongTree(reasoning: String)       // the tree's existing value is probably wrong
    case unclear(reasoning: String)         // can't determine — needs more evidence
}
```

### 20.10 Per-Profile Research as the Primary Mode

Whole-tree research is a power-user batch mode. The primary product is per-profile research, beautifully done, with output the user can confidently act on in 5 minutes.

**The MVP of the research pipeline is:**
1. User selects one profile
2. Pipeline runs verify or extend mode
3. Results clustered into candidate lives
4. User reviews one cluster, accepts or rejects
5. Accepted facts flow through MergeEngine → tree updates
6. Total time: 2-3 minutes research, 2-3 minutes review

If this doesn't work well, whole-tree mode won't save it. Build this first, make it excellent, then add batch modes.
