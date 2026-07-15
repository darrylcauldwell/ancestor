import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-01 (CONNECTOR_AUDIT_2026-07.md §6.1, subsumes
/// FT-22/FT-23 §2.4) — the search-outcome honesty envelope. Blocks, API
/// errors, throttles, and page-1 truncation must never be recorded as
/// "searched, found nothing": the envelope propagates through
/// QueryCache and SearchDispatcher, the empty-then-broaden ladder must
/// not broaden on inconclusive emptiness, only clean negatives persist,
/// and GPS criterion-1 accounting excludes inconclusive-only sources.
struct SearchOutcomeEnvelopeTests {

    // MARK: - SourceQueryResult → SearchOutcome default mapping

    @Test func resultsMapToOkOutcome() {
        let outcome = SourceQueryResult.results([]).outcome
        #expect(outcome.availability == .ok)
        #expect(outcome.resultCount == 0)
        #expect(!outcome.truncated)
        #expect(outcome.isCleanNegative)
    }

    @Test func unavailableMapsToErrorNotCleanNegative() {
        let outcome = SourceQueryResult.unavailable(reason: "boom").outcome
        #expect(outcome.availability == .error(reason: "boom"))
        #expect(!outcome.isCleanNegative)
        #expect(!outcome.isConclusive)
    }

    @Test func throttledMapsToThrottled() {
        let outcome = SourceQueryResult.throttled(retryAfter: .seconds(60)).outcome
        #expect(outcome.availability == .throttled)
        #expect(!outcome.isCleanNegative)
    }

    @Test func requiresAuthMapsToRequiresAuth() {
        let outcome = SourceQueryResult.requiresAuth(message: "log in").outcome
        #expect(outcome.availability == .requiresAuth)
        #expect(!outcome.isCleanNegative)
    }

    @Test func outsideCoverageIsNotACleanNegative() {
        // Nothing was searched — must not read as evidence of absence.
        let outcome = SourceQueryResult.outsideCoverage(reason: "pre-1996").outcome
        #expect(!outcome.isCleanNegative)
        #expect(!outcome.isConclusive)
    }

    @Test func truncatedOkOutcomeIsNotConclusive() {
        let outcome = SearchOutcome(resultCount: 0, totalAvailable: 500, truncated: true)
        #expect(outcome.availability == .ok)
        #expect(!outcome.isConclusive)
        #expect(!outcome.isCleanNegative)
    }

    @Test func cleanNonEmptyOutcomeIsConclusiveButNotNegative() {
        let outcome = SearchOutcome(resultCount: 3)
        #expect(outcome.isConclusive)
        #expect(!outcome.isCleanNegative)
    }

    // MARK: - QueryCache envelope propagation

    @Test func errorOutcomeSurfacesAndIsNotCached() async {
        let cache = QueryCache()
        let source = ScriptedOutcomeSource(script: [
            .init(SourceQueryResult.unavailable(reason: "outage")),
            SourceSearchEnvelope(.results([])),
        ])
        let first = await QueryCache.wrappedSearchWithOutcome(
            source: source, query: Self.genericQuery(), cache: cache)
        #expect(first.records.isEmpty)
        #expect(first.outcome.availability == .error(reason: "outage"))

        let second = await QueryCache.wrappedSearchWithOutcome(
            source: source, query: Self.genericQuery(), cache: cache)
        let calls = await source.searchCalls
        #expect(calls == 2, "an error outcome must not be cached; got \(calls) source call(s)")
        #expect(second.outcome.isCleanNegative)
    }

    @Test func truncatedOutcomeIsPreservedOnCacheHit() async {
        let cache = QueryCache()
        let record = Self.stubRecord(id: "r1", sourceID: "scripted")
        let truncatedEnvelope = SourceSearchEnvelope(
            result: .results([record]),
            outcome: SearchOutcome(resultCount: 1, totalAvailable: 100, truncated: true)
        )
        let source = ScriptedOutcomeSource(script: [truncatedEnvelope])
        _ = await QueryCache.wrappedSearchWithOutcome(
            source: source, query: Self.genericQuery(), cache: cache)
        let hit = await QueryCache.wrappedSearchWithOutcome(
            source: source, query: Self.genericQuery(), cache: cache)
        let calls = await source.searchCalls
        #expect(calls == 1, "ok results should be served from cache; got \(calls) call(s)")
        #expect(hit.outcome.truncated, "a cache hit must not launder a truncated page into a complete answer")
        #expect(hit.outcome.totalAvailable == 100)
        #expect(hit.records.count == 1)
    }

    @Test func recordsOnlyConvenienceUnchangedForErrors() async {
        // Callers that ignore outcomes keep the existing contract:
        // failures collapse to [].
        let source = ScriptedOutcomeSource(script: [
            .init(SourceQueryResult.unavailable(reason: "outage")),
        ])
        let records = await QueryCache.wrappedSearch(
            source: source, query: Self.genericQuery(), cache: QueryCache())
        #expect(records.isEmpty)
    }

    // MARK: - Ladder must not broaden on inconclusive emptiness

    @MainActor
    @Test func ladderDoesNotBroadenWhenStrictTierErrored() async {
        let source = ScriptedOutcomeSource(script: [
            .init(SourceQueryResult.unavailable(reason: "blocked")),
        ])
        let dispatcher = Self.makeDispatcher(source: source)
        let (records, outcomes) = await dispatcher.dispatchWithOutcomes(
            subject: Self.makeSubject(), recordTypes: [.death],
            scope: .county, mode: .extend
        )
        let tiers = await source.tierCalls
        #expect(tiers == [.strict],
                "an errored strict tier must not broaden to .loose; got \(tiers)")
        #expect(records.isEmpty)
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.outcome.isConclusive == false)
    }

    @MainActor
    @Test func ladderDoesNotBroadenWhenStrictTierTruncatedEmpty() async {
        // FreeBMD's unsplittable overflow shape: zero parsed rows but the
        // source's own count says thousands exist. Broadening spelling
        // tiers on top of that would compound the lie.
        let source = ScriptedOutcomeSource(script: [
            SourceSearchEnvelope(
                result: .results([]),
                outcome: SearchOutcome(resultCount: 0, totalAvailable: 12345, truncated: true)
            ),
        ])
        let dispatcher = Self.makeDispatcher(source: source)
        let (_, outcomes) = await dispatcher.dispatchWithOutcomes(
            subject: Self.makeSubject(), recordTypes: [.death],
            scope: .county, mode: .extend
        )
        let tiers = await source.tierCalls
        #expect(tiers == [.strict],
                "a truncated-empty strict tier must not broaden to .loose; got \(tiers)")
        #expect(outcomes.first?.outcome.truncated == true)
    }

    @MainActor
    @Test func ladderStillBroadensOnCleanEmpty() async {
        // Regression guard on the honesty rule: PROVEN emptiness still
        // walks the ladder exactly as before.
        let source = ScriptedOutcomeSource(script: [
            SourceSearchEnvelope(.results([])),
            SourceSearchEnvelope(.results([])),
        ])
        let dispatcher = Self.makeDispatcher(source: source)
        _ = await dispatcher.dispatchWithOutcomes(
            subject: Self.makeSubject(), recordTypes: [.death],
            scope: .county, mode: .extend
        )
        let tiers = await source.tierCalls
        #expect(tiers == [.strict, .loose],
                "clean empty must still broaden; got \(tiers)")
    }

    @MainActor
    @Test func allModeRunsEveryTierDespiteErrors() async {
        // `.all` runs every tier by contract, not as a reaction to
        // emptiness — the honesty rule doesn't apply to it.
        let source = ScriptedOutcomeSource(script: [
            .init(SourceQueryResult.unavailable(reason: "outage")),
            SourceSearchEnvelope(.results([])),
            SourceSearchEnvelope(.results([])),
        ])
        let dispatcher = Self.makeDispatcher(source: source)
        _ = await dispatcher.dispatchWithOutcomes(
            subject: Self.makeSubject(), recordTypes: [.death],
            scope: .county, mode: .all
        )
        let tiers = await source.tierCalls
        #expect(tiers == [.strict, .loose, .variant],
                ".all mode should run every tier regardless of outcomes; got \(tiers)")
    }

    @MainActor
    @Test func dispatchRecordsOnlyConveniencePreserved() async {
        let record = Self.stubRecord(id: "r1", sourceID: "scripted")
        let source = ScriptedOutcomeSource(script: [
            SourceSearchEnvelope(.results([record])),
        ])
        let dispatcher = Self.makeDispatcher(source: source)
        let records = await dispatcher.dispatch(
            subject: Self.makeSubject(), recordTypes: [.death],
            scope: .county, mode: .extend
        )
        #expect(records.count == 1)
    }

    // MARK: - Genuine-negative aggregation (persistence gate)

    @Test func allCleanZeroPairBecomesNegative() {
        let outcomes = [
            Self.entry(source: "freebmd", type: .birth, outcome: SearchOutcome(resultCount: 0)),
            Self.entry(source: "freebmd", type: .birth, outcome: SearchOutcome(resultCount: 0)),
        ]
        let negatives = NegativeSearchAggregator.genuineNegatives(outcomes: outcomes, scoredRecords: [])
        #expect(negatives == [
            NegativeSearchAggregator.Negative(sourceID: "freebmd", recordType: .birth, queryCount: 2)
        ])
    }

    @Test func errorInPairSuppressesNegative() {
        let outcomes = [
            Self.entry(source: "freebmd", type: .birth, outcome: SearchOutcome(resultCount: 0)),
            Self.entry(source: "freebmd", type: .birth,
                       outcome: SearchOutcome(resultCount: 0, availability: .error(reason: "outage"))),
        ]
        let negatives = NegativeSearchAggregator.genuineNegatives(outcomes: outcomes, scoredRecords: [])
        #expect(negatives.isEmpty, "one errored query leaves the pair's emptiness unproven")
    }

    @Test func truncatedZeroSuppressesNegative() {
        let outcomes = [
            Self.entry(source: "freecen", type: .census,
                       outcome: SearchOutcome(resultCount: 0, totalAvailable: 40, truncated: true)),
        ]
        let negatives = NegativeSearchAggregator.genuineNegatives(outcomes: outcomes, scoredRecords: [])
        #expect(negatives.isEmpty)
    }

    @Test func nonZeroResultsAreNotANegative() {
        let outcomes = [
            Self.entry(source: "freebmd", type: .birth, outcome: SearchOutcome(resultCount: 2)),
        ]
        let negatives = NegativeSearchAggregator.genuineNegatives(outcomes: outcomes, scoredRecords: [])
        #expect(negatives.isEmpty)
    }

    @Test func scoredRecordFromAnotherFlowVetoesNegative() {
        // Main-loop queries were clean-zero, but a strategist/pivot
        // dispatch found a record for the same (source, type) — a record
        // in hand always vetoes the negative.
        let outcomes = [
            Self.entry(source: "freebmd", type: .birth, outcome: SearchOutcome(resultCount: 0)),
        ]
        let scored = [Self.scored(Self.stubRecord(id: "b1", sourceID: "freebmd"))]
        let negatives = NegativeSearchAggregator.genuineNegatives(outcomes: outcomes, scoredRecords: scored)
        #expect(negatives.isEmpty)
    }

    @Test func pairsAreIndependent() {
        let outcomes = [
            Self.entry(source: "freebmd", type: .birth, outcome: SearchOutcome(resultCount: 0)),
            Self.entry(source: "freebmd", type: .marriage,
                       outcome: SearchOutcome(resultCount: 0, availability: .throttled)),
        ]
        let negatives = NegativeSearchAggregator.genuineNegatives(outcomes: outcomes, scoredRecords: [])
        #expect(negatives == [
            NegativeSearchAggregator.Negative(sourceID: "freebmd", recordType: .birth, queryCount: 1)
        ], "the throttled marriage pair must not suppress the clean birth negative")
    }

    // MARK: - GPS criterion-1 accounting (searched-source seam)

    @Test func errorOnlySourceDoesNotCountAsSearched() {
        let result = Self.result(
            outcomes: [
                Self.entry(source: "freebmd", type: .birth, outcome: SearchOutcome(resultCount: 0)),
                Self.entry(source: "findagrave", type: .burial,
                           outcome: SearchOutcome(resultCount: 0, availability: .blocked(reason: "cloudflare"))),
            ]
        )
        #expect(GPSScorer.searchedSourceIDs(for: result) == ["freebmd"])
    }

    @Test func truncatedOnlySourceDoesNotCountAsSearched() {
        let result = Self.result(
            outcomes: [
                Self.entry(source: "probate", type: .probate,
                           outcome: SearchOutcome(resultCount: 50, totalAvailable: 3000, truncated: true)),
                Self.entry(source: "freebmd", type: .death, outcome: SearchOutcome(resultCount: 1)),
            ]
        )
        #expect(GPSScorer.searchedSourceIDs(for: result) == ["freebmd"],
                "a source whose every answer was page-1-truncated hasn't been exhaustively searched")
    }

    @Test func mixedSourceCountsWhenAnyQueryWasConclusive() {
        let result = Self.result(
            outcomes: [
                Self.entry(source: "probate", type: .probate,
                           outcome: SearchOutcome(resultCount: 50, totalAvailable: 3000, truncated: true)),
                Self.entry(source: "probate", type: .probate, outcome: SearchOutcome(resultCount: 0)),
            ]
        )
        #expect(GPSScorer.searchedSourceIDs(for: result) == ["probate"])
    }

    @Test func legacyResultsWithoutOutcomesFallBackToRecordAccounting() {
        let result = Self.result(
            scored: [Self.scored(Self.stubRecord(id: "r1", sourceID: "cwgc"))],
            outcomes: []
        )
        #expect(GPSScorer.searchedSourceIDs(for: result) == ["cwgc"])
    }

    @Test func strategistOnlySourceCountsViaItsRecords() {
        // dispatchOne / pivot flows don't produce outcome entries; a
        // record in hand proves the source answered.
        let result = Self.result(
            scored: [Self.scored(Self.stubRecord(id: "r1", sourceID: "wirksworth"))],
            outcomes: [
                Self.entry(source: "freebmd", type: .birth, outcome: SearchOutcome(resultCount: 0)),
            ]
        )
        #expect(GPSScorer.searchedSourceIDs(for: result) == ["freebmd", "wirksworth"])
    }

    // MARK: - Helpers

    private static func genericQuery(recordType: RecordType = .death) -> RecordQuery {
        RecordQuery(
            surname: "Cauldwell", givenName: "Robert",
            recordType: recordType,
            yearFrom: 1914, yearTo: 1918,
            gender: .male, region: .englandAndWales,
            sourceParams: .generic
        )
    }

    @MainActor
    private static func makeDispatcher(source: ScriptedOutcomeSource) -> SearchDispatcher {
        let registry = SourceRegistry()
        registry.register(source)
        return SearchDispatcher(registry: registry)
    }

    private static func makeSubject() -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: "Cauldwell", givenName: "Robert",
            birthYearFrom: 1880, birthYearTo: 1880,
            deathYearFrom: 1916, deathYearTo: 1918,
            gender: .male, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
    }

    private static func stubRecord(id: String, sourceID: String) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(
                id: id, sourceID: sourceID, name: "Stub",
                surname: "Cauldwell", givenName: "Robert",
                detailURL: nil, rawFields: [:]
            ),
            birthYear: 1880
        ))
    }

    private static func scored(_ record: SourceRecord) -> ScoredRecord {
        ScoredRecord(id: record.id, record: record, verdict: .lead, gates: [], summary: "test")
    }

    private static func entry(
        source: String,
        type: RecordType,
        outcome: SearchOutcome
    ) -> SearchOutcomeEntry {
        SearchOutcomeEntry(
            sourceID: source, recordType: type, strictness: .strict,
            queryKey: "\(source)|\(type.rawValue)|test", outcome: outcome
        )
    }

    private static func result(
        scored: [ScoredRecord] = [],
        outcomes: [SearchOutcomeEntry]
    ) -> ResearchResult {
        ResearchResult(
            confirmedFacts: [], leads: [],
            allScoredRecords: scored,
            clusters: [], discrepancies: [], householdMembers: [],
            searchHistory: [],
            searchOutcomes: outcomes
        )
    }
}

/// Stub source with a scripted sequence of envelopes — pops the next
/// envelope per `searchWithOutcome` call (repeats the last one when the
/// script runs out) and records the strictness tier of every call.
actor ScriptedOutcomeSource: RecordSource {
    nonisolated let sourceID: String = "scripted"
    nonisolated let scopeHandling: ScopeHandling = .inherentlyNational(reason: "test double")
    nonisolated let displayName = "Scripted Outcome Source"
    nonisolated let recordTypes: Set<RecordType> = [.death, .birth]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "test")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(level: .open, summary: "test stub")

    private var script: [SourceSearchEnvelope]
    private(set) var tierCalls: [SearchStrictness] = []
    private(set) var searchCalls = 0

    init(script: [SourceSearchEnvelope]) {
        self.script = script
    }

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        await searchWithOutcome(query).result
    }

    func searchWithOutcome(_ query: RecordQuery) async -> SourceSearchEnvelope {
        searchCalls += 1
        tierCalls.append(query.strictness)
        guard !script.isEmpty else {
            return SourceSearchEnvelope(.results([]))
        }
        return script.count == 1 ? script[0] : script.removeFirst()
    }
}
