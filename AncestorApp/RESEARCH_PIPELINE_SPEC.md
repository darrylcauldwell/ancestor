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
    let narrative: String               // one-paragraph summary of this life
}
```

**Confidence model:** the single-tier `ClusterConfidence` enum (Weak / Moderate /
Strong / Ambiguous) described in earlier drafts of this spec was retired by
`RESEARCH_CONFIDENCE_SPEC.md` (committed 2026-05-15). The replacement is a
three-axis model — **match quality**, **sourcing strength**, **inference
depth** — derived on demand from a cluster's records rather than stored as a
single combined tier. See `RESEARCH_CONFIDENCE_SPEC.md` for the canonical
definitions, UI contract, and acceptance criteria. Callers in this spec that
referenced `cluster.confidence` should be read as accessing
`cluster.evidenceConfidence(sourceInfoMap:)` instead.

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

---

## 21. Source-surfaced images (media capture from external sources)

**Status:** Proposed. No code yet — none of the seven shipping source plugins captures any image data, even when the upstream response carries it.

**Catalyst:** The 2026-05 fix to `FindAGraveSource.swift` that mines years from inscription/bio free text exposed a larger gap. The memorial-detail HTML carries `<img id="memPhoto">` and a photo-gallery section that `parseMemorialDetail` (lines ~248-331) never touches. Headstone photos with carved dates are some of the strongest direct evidence a free source produces — and we throw them away on every fetch.

The user framing, verbatim: *"Some sources return images relating to members of tree, I don't think we capture these presently but we should and store them linked to profile."*

Treat this section as the seed for a dedicated **`AncestorApp/SOURCE_IMAGES_SPEC.md`** if it grows past the first cut described in §21.6 — much of the data-model and UI surface deserves its own document. For now it lives here because the question is fundamentally about the research pipeline: *what does a source return, where does it land, and how does it count as evidence?*

There is an earlier, more ambitious treatment in `AncestorApp/archive/SOURCE_INTEGRATION_SPEC.md` §14 (Image Management). That section predates the current product and proposes a separate `ResearchImage` table and a per-project `Images/` filesystem layout. It is preserved as a reference for shape but is **not the current plan** — see §21.4 for why the existing `attachments` table is the better starting point.

### 21.1 Source-by-source inventory

Audit of the seven shipping source plugins under `Ancestor Research/Services/Sources/`. For each: does the upstream response carry image references? Does the parser surface them? File:line cites the point at which an image-bearing payload is parsed and the image fields are dropped.

| Source | Image-bearing payload | What the parser does today | Cite |
|---|---|---|---|
| **Find a Grave** | Headstone photo (`<img id="memPhoto">`), photo gallery (portrait, additional cemetery shots, military emblems), volunteer-uploaded | Drops them entirely — `parseMemorialDetail` extracts inscription/bio/cemetery/plot but never queries any `<img>` tag or photo-gallery div. `BurialRecord` (RecordTypes.swift:78) has no image field. | `FindAGraveSource.swift:248-331` |
| **CWGC** | Cemetery photographs and (for many casualties) a headstone or memorial-panel photo on the casualty-details page; downloadable certificate PDF | Drops them — `parseCSV` (the only ingest path) consumes the CSV export which is text-only. The detail-page HTML at `cwgc.org/find-records/.../casualty-details/{id}/` carries the imagery and is never fetched. | `CWGCSource.swift:142-213` (parseCSV is text-only); detail HTML is never touched |
| **FamilySearch** | Image waypoints (digitised microfilm scans) referenced from `sourceDescriptions[].links[]`, plus a `RectangleRegion` source-reference qualifier (FAMILYSEARCH_SOURCE_SPEC §5.5) marking *which row on the page* this persona occupies. Also Memories (user-uploaded portraits, certificates, family photos attached to FamilySearch tree persons) | The current parser decodes a narrow subset of GEDCOMx. `GxRoot` (FamilySearchSource.swift:750-754) decodes `persons`, `relationships`, `sourceDescriptions` but **not** `links`. `GxSourceDescription` (FamilySearchSource.swift:825-830) decodes `about/titles/coverage` but not links. There is no Memories endpoint integration. | `FamilySearchSource.swift:746-754, 825-830` — `links: [...]` field absent on decoded structs |
| **Wirksworth** | Pedigree pages occasionally embed scanned images of original pedigree-book pages (HTML `<img>` tags); some pages include parish-register photos | Drops them — the parser is text-only (`parsePedigreePage` walks `<PRE>` and narrative HTML; `<img>` tags don't have a code path) | `WirksworthSource.swift:108+, 145+` |
| **FreeBMD** | None directly (index only). But the index entries carry GRO reference fields (volume / page) that *point to* a registry image obtainable separately. | Parser captures volume/page in `rawFields` but does not synthesise a GRO image link. | `FreeBMDSource.swift` — no image fields in `BirthRecord`/`DeathRecord`/`MarriageRecord` (RecordTypes.swift:26-61) |
| **FreeCen** | None directly (transcription only). But each entry carries piece/folio/page from the underlying TNA census, which is the address of a TNA digitised page image. | Parser captures piece/folio/page/schedule/house_number/address in `rawFields` (FreeCenSource.swift:351) but does not link to the TNA image. | `FreeCenSource.swift:351` |
| **FreeREG** | None — transcription only. Some parish-register transcriptions reference originals at FamilySearch (cross-source link). | No image handling. | `FreeREGSource.swift` |
| **Probate** | Modern grants page sometimes links to a will-document PDF (post-1996 digital grants); older calendar entries have no image. The Nuxeo JSON response may carry a document URL. | Parser does not extract any URL beyond the grant text. | `ProbateSource.swift` |

**Direct-evidence sources where we drop images today:** Find a Grave, CWGC, FamilySearch, Wirksworth.

**Index sources where we have a reference but no synthesised image URL:** FreeBMD (GRO volume/page), FreeCen (TNA piece/folio/page).

**Transcription-only, no image:** FreeREG.

**Modern-records source, image rare:** Probate.

### 21.2 What's already in the data model

The repo already has an `attachments` table (migration `v10_attachments_goals`, `ProjectDatabase.swift:486-512`) and an `Attachment` model (`Models/Attachment.swift`). It was originally scoped to **user-uploaded** media per DESIGN.md §5.15 — photos and documents the user drags onto a profile, life event, or field source.

Shape today:

```swift
struct Attachment {
    let id: UUID
    var filename: String
    var mediaType: AttachmentType         // .photo / .document / .transcription
    var caption: String?
    var dateTaken: Date?
    var locationTaken: String?
    let relativePath: String              // relative to project media dir on disk
    let attachedTo: AttachmentTarget      // .profile(id) / .lifeEvent(id) / .fieldSource(entityID, field)
    let addedAt: Date
}
```

The `AttachmentTarget` union (`Attachment.swift:44-68`) already supports targeting a profile, a life event, or a specific `(entityID, field)` field-source row. That's a near-fit for source-surfaced images — a headstone photo from Find a Grave logically attaches to the burial life event *and* corroborates the death-date field source.

**What's missing for source-surfaced media:**

1. **Provenance fields.** No `sourceID`, no `sourceRecordID`, no `originalURL`. We can't tell a user-uploaded photo from one we downloaded from cwgc.org. This is load-bearing for §21.5 (trust + evidence weight).
2. **Subtype.** The current `AttachmentType` enum has only `photo / document / transcription`. For source-surfaced media we need to distinguish headstone / portrait / certificate / document scan / cemetery / pedigree (the categories the archived `SOURCE_INTEGRATION_SPEC §14.2` already enumerated; we should adopt that list).
3. **URL-only vs blob-cached.** No `fetchStatus` to indicate "URL recorded, file not downloaded yet" vs "downloaded and on disk at `relativePath`."
4. **Source-record link.** No FK to `source_records.id` — we can't trace a photo back to the search hit that surfaced it.

There is **no existing media table other than `attachments`.** Schema is at v26 (`ProjectDatabase.swift:780`); the CLAUDE.md schema summary that lists v1-v5 is stale and should be updated.

### 21.3 Open question: extend `attachments` vs new `source_media` table

Two viable shapes. Pick one before implementation; both have real costs.

**Option A — extend `attachments` with provenance columns.** Add `source_id`, `source_record_id`, `original_url`, `fetch_status`, and refine `media_type` to the six-category subtype list. Keep one table, one query path, one inspector UI section. The cost is mixing user-curated media (which the user "owns") with discovered media (which we surfaced and the user may not even know about yet). A user clicking "delete photo" on something they uploaded behaves differently from clicking it on something the pipeline pulled in.

**Option B — new `source_media` table** parallel to `attachments`. Discovered images live there until the user "accepts" them, at which point they're either promoted into `attachments` (and the source-media row marked accepted) or remain in source-media as evidence-only. The cost is duplication: two queries to render a profile's image strip, two delete paths, two export rules.

Recommendation, not decision: **Option B** mirrors the existing Evidence Firewall pattern (§13) — `pending_facts` for proposed facts is separate from the `field_sources` table for accepted ones. Source-surfaced media is to user-curated media as `pending_facts` is to `field_sources`. The user "accepting" a Find a Grave headstone photo via TreeDiffView is the analogue of accepting a date — it crosses the firewall.

Defer the final call to the implementer; both paths leave room to switch later. What is **not** deferrable is recording provenance the moment a parser sees an image URL.

### 21.4 Proposed data-model additions (Option B sketch)

```swift
/// An image (or PDF) surfaced by a source plugin during research, attached
/// to the profile the surfacing search was about. Lives behind the
/// Evidence Firewall: pipeline writes, user accepts in TreeDiffView.
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

`RecordCommon.rawFields` is the wrong home (string-only, no schema, lost on re-parse). The parsers should populate a new optional `discoveredMedia: [SourceMediaURL]` on `RecordCommon` (or per-typed-record where it makes sense) and the persistence layer is responsible for writing rows into `source_media` keyed off `source_records.id`. Keeping `discoveredMedia` on the typed record (not just `rawFields`) means tests can assert on it and the scorer can read it.

### 21.5 Open question: do images count toward the 4-gate scorer / evidence directness?

Today's `EvidenceDirectness` ladder (`Models/Research/EvidenceDirectness.swift`) is `.primary / .independentTranscription / .derivative / .communityEdited`. A Find a Grave memorial is `.derivative` because the volunteer transcribed dates from a headstone they did not necessarily photograph. **But a Find a Grave memorial with a headstone photo carrying the carved dates collapses that gap** — the user (or, post-MLX, the local model) can read the dates off the stone themselves. The transcription stops being a chain-of-custody risk because the photo is the primary record.

Three positions, all defensible:

1. **Images don't affect scoring.** They're decoration / verification aid. The transcription is what enters the pipeline; the photo is what the user looks at when reviewing.
2. **Images upgrade directness, deterministically.** A Find a Grave record with an attached headstone photo of the actual gravestone gets re-tiered from `.derivative` to `.primary` for the death-date field specifically. (Birth date and name still derivative — the volunteer transcribed those from the stone.)
3. **Images are an MLX-task.** The local model OCRs/reads the headstone photo, emits its own structured facts, those go through `pending_facts` as an independent source. The Find a Grave transcription stays derivative; the local-model extraction becomes a fresh primary-tier signal that converges with it.

Recommendation, not decision: **(3) is the only one that respects the deterministic sandwich** (§2.3). Position (2) would let the *presence* of an image dictate scoring, which makes the scorer dependent on a network fetch having succeeded — non-deterministic. Position (3) treats the image as fresh data, lets the convergence engine decide, and keeps the scorer pure.

This is an open question because position (3) implies wiring images into the MLX pipeline (vision-capable model? Tesseract pre-pass? defer until DeepSeek-R1 ships a vision variant?), and that's a separate spec. For the first cut, **adopt (1)**: capture and display, no scoring impact. Revisit when the local-vision story exists.

### 21.6 First-cut scope (one focused session)

**Goal:** Source-surfaced images flow into a persistent table, are visible on the profile inspector, and survive across sessions. No download-by-default; no scoring impact; no GEDCOM export.

**In scope:**

- Migration `v27_source_media` adding the table from §21.4.
- `SourceMediaCandidate` model + read/write in a new `ProjectDatabase+SourceMedia.swift`.
- `RecordCommon` (or per-record-type) gains optional `discoveredMedia: [SourceMediaURL]`.
- **Find a Grave first** (highest-yield, lowest-risk). `parseMemorialDetail` extracts:
  - Hero photo from `<img id="memPhoto" src="...">` → kind `.headstone` if visible carving / dates / inscription text suggests gravestone, else `.portrait`. Without a vision model the parser can't reliably classify; default to `.headstone` for the hero photo on a memorial page (it's the gravestone shot 80%+ of the time) and `.portrait` for any additional photos in the gallery. Mark this as a "known imperfect classifier" comment in code.
  - Up to N gallery photos (cap at 20 per memorial; observed memorials rarely exceed this and an unbounded loop on hostile HTML is a footgun).
- **CWGC second.** Extend the source to fetch the casualty-details HTML page (already linked from `casualty_id`) and extract the headstone/memorial photograph plus the certificate PDF URL.
- **FamilySearch third.** Decode `links[]` on `GxSourceDescription` (FamilySearchSource.swift:825-830) and capture the image-waypoint URL + the `RectangleRegion` qualifier from FAMILYSEARCH_SOURCE_SPEC §5.5 alongside it. The waypoint URL plus the rectangle is what enables the "deep-link to the exact row on the scanned page" UX from FAMILYSEARCH_SOURCE_SPEC §8.4.
- URL-only persistence by default. **No automatic download.** A "Download" affordance on each media row in the inspector triggers a fetch with the same rate-limit + auth contract as the parent source.
- Inspector UI: a collapsed-by-default "Source-discovered images (N)" disclosure under the existing Sources section on the profile detail view. Tapping a row opens the URL in the system browser; tapping "Download" fetches and re-renders inline.

**Out of scope for first cut:**

- Wirksworth pedigree-page image extraction (low yield, parser changes risky).
- FreeBMD GRO image-link synthesis (depends on GRO scheme; not a free image).
- FreeCen TNA image-link synthesis (same).
- Probate will-PDF (depends on Nuxeo response shape we haven't probed).
- Memories endpoint integration on FamilySearch (Tier 1 roadmap per FAMILYSEARCH_SOURCE_SPEC §13).
- Image-driven evidence promotion (§21.5 position 2 or 3).
- GEDCOM `OBJE` export — needs decision on whether to embed paths or copy files alongside the `.ged`.
- Vision-model OCR of headstones.
- Copyright/redistribution surfacing in shared exports (will need a confirm-on-export check per archived §14.8).
- Background eviction of cached blobs to manage disk.

### 21.7 Storage strategy: URL-only vs blob-cached

Both are needed, and the tradeoffs argue for "URL recorded on discovery, blob cached on demand" — the `fetchStatus` field in §21.4 encodes the lifecycle.

Why URL is not enough:

- **Find a Grave memorials get deleted.** Volunteers occasionally remove memorials; their image CDN URLs 404 from that point on. If we recorded the URL in 2026 and only fetch it in 2030 when the user reviews the profile, we may have lost the evidence. Cache early.
- **FamilySearch image waypoints require an authenticated session.** A URL alone is useless without the right cookies, and cookies expire every 1-2 hours (FAMILYSEARCH_SOURCE_SPEC §11.2). If we don't cache at discovery time, fetching later may require a re-auth interaction we can't always provide.

Why URL-only is enough as the default:

- **Disk usage at scale.** A tree of 5k profiles, each with 2-3 discovered images at ~1 MB average, is ~10-15 GB. Most users will never look at most of these.
- **Bandwidth and politeness.** Auto-downloading on every research run multiplies our footprint on volunteer sites by an order of magnitude. Find a Grave already rate-limits us at 500 ms; CWGC and FamilySearch likewise. Image downloads should be opt-in.

**Proposed policy:**

- On parse, always write a `source_media` row with `fetchStatus = .urlOnly` and the URL.
- **Auto-cache** when *any* of: the source is Find a Grave (volunteer deletion risk); the source requires auth and we have a valid session right now (FamilySearch — fetch while we can); the image is small (`<200KB` heuristic, from `Content-Length` HEAD) so cost is negligible.
- **Manual cache** ("Download" button) for everything else.
- **Settings toggle**: "Cache all source-discovered images automatically" (default off) for power users who want the offline archive.

This is the same pattern as the existing `page_cache` (migration v5, `ProjectDatabase.swift:260+`) — speculative caching of source HTML for re-parse. Source media is the binary analogue.

### 21.8 Trust + provenance

Every `source_media` row carries `sourceID` and `sourceRecordID`. The trust tier of the media is inherited from the source — there is no LLM-driven "this looks like a real headstone" judgement (cf. §2.1 invariant: source trust is URL-derived). A Find a Grave photo is `.community`-tier evidence by virtue of being from Find a Grave, regardless of how authoritative the image *looks*.

When the user accepts a `source_media` row into permanent `attachments` (via the §21.3 Option B promote path), the new `Attachment` row carries `sourceID` and `originalURL` columns (added to the existing table) so the provenance chain is preserved indefinitely. The user can later see "this photo came from Find a Grave memorial #12345 on 2026-05-20" even after the upstream URL 404s.

### 21.9 Cross-references

- **FAMILYSEARCH_SOURCE_SPEC §5.5** — image-pixel-region anchors via `RectangleRegion`. The first-cut work in §21.6 must capture both the image URL from `sourceDescriptions[].links[]` *and* the rectangle qualifier in `rawFields["sourceQualifier"]` together; they're only useful as a pair. The FS spec captures the rectangle as a future-UX concern; this spec is what turns it into stored media.
- **FAMILYSEARCH_SOURCE_SPEC §8.4** — "Image-availability badge" — was scoped as a UI affordance over an unfetched URL. Once the work in §21.6 lands, that badge graduates to "View / Download" with the rectangle highlight overlay.
- **FAMILYSEARCH_SOURCE_SPEC §13** (Tier-1 roadmap) — Memories read endpoint. User-uploaded portraits and family photos attached to FS tree persons. Out of scope for §21.6 first cut but is the obvious second step on the FamilySearch side.
- **DESIGN.md §5.15** — user-uploaded attachments. The Option B promote path (§21.3) is the bridge between this spec's discovered media and DESIGN's user-curated attachments.
- **`AncestorApp/archive/SOURCE_INTEGRATION_SPEC.md` §14** — earlier, more comprehensive image-management spec from before the product was hardened. Specifically §14.4 (`ResearchImage` model), §14.5 (Find a Grave URL extraction), §14.7 (GEDCOM `OBJE` export), §14.8 (copyright per source) are worth re-reading when this work starts.
- **Evidence Firewall, §13 of this spec** — `source_media` writes go through the firewall (`created_by_transaction_id`, user-accepts-to-promote pattern). Don't let parsers write directly to `attachments`.

---

## 22. Cross-source enrichment — the FamilySearch → Find a Grave bridge

**Status:** First cut shipped 2026-05-20. Spec records the pattern for future cross-source bridges.

### 22.1 The problem this solves

FamilySearch's `/service/search/hr/v2/personas` endpoint acts as an aggregator across many underlying databases — civil registration, censuses, parish registers, and importantly **Find a Grave memorials**. When a query surfaces a FAG-hosted memorial, the GEDCOMx response carries:

- The deceased's name and the burial place
- An `ExtRecordId` field containing the FAG memorial number
- A `sourceDescriptions[0].titles[0].value` of "Find a Grave Index" (or similar)
- **No `Birth`, `Death`, or `Burial` fact with a date.** FS's index of FAG carries the structured persona but not the inscribed dates.

That last point is load-bearing. A FAG memorial whose inscription says "1919 — 2017" is one of the strongest free-source pieces of death-date evidence available — but the FS aggregator does not surface those dates. Without intervention the record stalls as a lead, the 4-gate scorer can't promote it (no year axis to match against), and the next-iteration `refineSubject` (§ pipeline iteration loop) never gets a death year to propagate to the other 7 sources.

Concrete case: Ernest Victor Cauldwell's research run found his FAG memorial via FS, with name + Wirksworth + nothing else. Probate for the same person carrying "ERNEST VICTOR CAULDWELL, ADMINISTRATION 2017-02-14" was already in evidence — scored `impossible` because the subject had no death year to converge against. Two pieces of evidence one fact-confirmation apart, and the pipeline couldn't close the loop.

### 22.2 The bridge

In the parser (`FamilySearchSource.swift`):

- For any persona whose collection title matches `Find a Grave`, extract the FAG memorial id from `rawFields["field.ExtRecordId.original"]` (or `.interpreted`, or unmarked variant). Strip non-digit prefixes defensively.
- Populate the resulting `BurialRecord.memorialID` so the pipeline can route on it.

In the pipeline (`ResearchPipeline.swift`):

- Between dispatch and score, run `enrichFagBridge(records:existingIDs:)`. For every `FamilySearch`-sourced burial record where `memorialID` is set but `deathYear` is nil and the FAG-detail id is not already in evidence, call `FindAGraveSource.fetchDetail(recordID: "findagrave_\(memorialID)")`.
- **Append the FAG-detail record alongside the original FS persona**, do not replace. Both score independently; the scorer's convergence engine reunites them in clustering. Replacing would silently downgrade the FS persona's trust tier (FS is `.transcription`, FAG is `.community`), which is a scorer call the bridge has no business making.

The FAG detail parser already mines the inscription / bio for year ranges (`FindAGraveSource.extractYearsFromMemorialText`, landed earlier in this session). So once the bridge places the record in FAG's pipeline, the year extraction is automatic.

### 22.3 Why the bridge belongs in the pipeline, not in the source

Two reasons:

1. **The source should stay independent.** `FamilySearchSource` calling `FindAGraveSource` couples two source plugins that are otherwise free to evolve independently. The pipeline is the right level for cross-source orchestration — it already orchestrates dispatch, scoring, clustering, hypothesis generation.
2. **The bridge needs the pipeline's state.** Skipping memorials already seen in a prior iteration (the `existingIDs` argument) requires knowing what records the pipeline has accumulated so far. A source plugin doesn't see that.

### 22.4 First-cut scope and what's deferred

**In scope:**

- FS-to-FAG bridge described above.
- One follow-up fetch per FS burial persona per run. Rate-limited via the existing FAG 500ms-per-request gate.
- Deduplication across iterations of the main pipeline loop.

**Out of scope for first cut:**

- **Generalised bridge framework.** This is one hand-rolled case. If we add a second (e.g. FreeBMD → GRO image-link synthesis, or CWGC → detail-page image fetch), generalise then — premature now.
- **Bridge from non-FS sources to FAG.** FAG hits can also come directly from `FindAGraveSource.search`; those already go through `fetchDetail` via the search→detail pattern. Only the FS aggregator needed bridging.
- **MLX-driven decision to bridge.** The bridge is deterministic — collection-title match + missing year. No model judgement involved.

### 22.5 Convergence behaviour after bridging

When the bridge fires, the pipeline accumulates:

- **Record A**: FS burial persona, sourceID=familysearch, memorialID=N, deathYear=nil. Tier `.transcription`.
- **Record B**: FAG burial detail, sourceID=findagrave, memorialID=N, deathYear=Y (from inscription mining). Tier `.community`.

Both records share the same memorial ID. The scorer's convergence engine treats two records pointing to the same memorial as independent attestations — A confirms the *existence* of the memorial via FS, B confirms the *content* of the memorial via FAG. They converge on:

- Name (both have it)
- Place (both have it — FS as `place.original` on the burial fact, FAG as `burialLocation`)
- Death year (only B has it; A's scoring against the now-refined subject improves)

The subject-refinement step (`refineSubject` in `ResearchPipeline.swift`) then folds the death year into the subject for the *next* iteration. Downstream sources get a tighter query: FreeBMD death index narrows to year=Y, Probate likewise, FreeREG parish-burial likewise. This is the cross-source propagation the pipeline was designed for — the bridge unblocks it for the FAG case.

### 22.6 Open questions

- **Does FAG `fetchDetail` actually return a record when given a memorial id we found via FS?** The FAG memorial url scheme is stable (`/memorial/<id>`), so this should work — but FS's `ExtRecordId` might encode the id in a non-obvious form on some collections. First-run telemetry will tell us; the bridge fails closed (keeps the FS record alone) if the detail fetch returns no results.
- **Should the bridge attempt to fetch even when `deathYear` is present?** Today we only bridge when the year is missing. But the FAG detail also has inscription text and a headstone photo (per §21) that we never see otherwise. Tradeoff: extra rate-limit cost vs. richer evidence. Defer until §21's image capture work lands — then a bridge fetch picks up both at once.
- **What if FS has its own death year for the persona** (unlikely for FAG-sourced personas but possible)? In that case FS already attests the year via its own record and the bridge is moot; we keep the existing skip-when-year-present logic.

### 22.7 Cross-references

- **`FindAGraveSource.parseMemorialDetail`** — the inscription / bio year-mining the bridge depends on.
- **`refineSubject` in `ResearchPipeline.swift`** — the cross-source propagation mechanism the bridge unblocks.
- **§21 (this spec)** — Find a Grave image capture is the obvious next-step enrichment from a triggered bridge fetch.
- **`FAMILYSEARCH_SOURCE_SPEC.md` §5.0** — multi-persona parsing; the bridge keys off the per-persona `ExtRecordId` field captured into `rawFields`.
