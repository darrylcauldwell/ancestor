import Testing
import Foundation
@testable import Ancestor_Research

/// Acceptance tests for RESEARCH_AXES_SPEC.md Change 6 —
/// dispatcher empty-then-broaden flow + activity bus strictness.
@MainActor
struct EmptyThenBroadenTests {

    // MARK: - Strictness ladder per mode (§3.1)

    @Test func ladderVerifyIsStrictOnly() {
        #expect(SearchDispatcher.strictnessLadder(for: .verify) == [.strict])
    }

    @Test func ladderExtendIsStrictThenLoose() {
        #expect(SearchDispatcher.strictnessLadder(for: .extend) == [.strict, .loose])
    }

    @Test func ladderDiscoverSkipsStrict() {
        #expect(SearchDispatcher.strictnessLadder(for: .discover) == [.loose, .variant])
    }

    @Test func ladderAllRunsEveryTier() {
        #expect(SearchDispatcher.strictnessLadder(for: .all) == [.strict, .loose, .variant])
    }

    // MARK: - AC6.1 — verify issues only .strict queries

    @Test func ac6_1_verifyIssuesOnlyStrictTier() async {
        let stub = TierRecordingSource(emptyAt: [])
        let dispatcher = makeDispatcher(stub: stub)
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .verify
        )
        let calls = await stub.tierCalls
        #expect(calls == [.strict], "verify should call only .strict tier; got \(calls)")
    }

    // MARK: - AC6.2 — extend re-issues at .loose for empty sources

    @Test func ac6_2_extendBroadensOnEmpty() async {
        let stub = TierRecordingSource(emptyAt: [.strict])
        let dispatcher = makeDispatcher(stub: stub)
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .extend
        )
        let calls = await stub.tierCalls
        #expect(calls == [.strict, .loose],
                "extend should walk .strict then .loose on empty; got \(calls)")
    }

    @Test func ac6_2_extendStopsEarlyWhenStrictReturnsResults() async {
        let stub = TierRecordingSource(emptyAt: [], resultsPerTier: 1)
        let dispatcher = makeDispatcher(stub: stub)
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .extend
        )
        let calls = await stub.tierCalls
        #expect(calls == [.strict],
                "extend should stop at .strict when it returns results; got \(calls)")
    }

    // MARK: - Discarded records do not satisfy the ladder's stop condition

    /// Owner dogfood 2026-08-22. Harriet Holmes is a Holmes who married a
    /// Holmes, so her `.strict` census probe is guaranteed to return namesakes.
    /// It returned one, the ladder stopped, and the tiers that would have found
    /// her real census never ran. She had already DISCARDED that namesake — she
    /// told the app it was the wrong woman, and the app went on using it as the
    /// reason not to look further.
    @Test func discardedStrictHitDoesNotStopTheLadder() async {
        let stub = TierRecordingSource(emptyAt: [], resultsPerTier: 1)
        var dispatcher = makeDispatcher(stub: stub)
        dispatcher.discardedSourceRecordIDs = ["stub-strict-0"]
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .extend
        )
        let calls = await stub.tierCalls
        #expect(calls == [.strict, .loose],
                "a discarded hit is not a find — the ladder must broaden; got \(calls)")
    }

    /// The mirror: an UNREVIEWED hit still stops the ladder. This change must
    /// not turn every run into a full-ladder walk.
    @Test func undiscardedHitStillStopsTheLadder() async {
        let stub = TierRecordingSource(emptyAt: [], resultsPerTier: 1)
        var dispatcher = makeDispatcher(stub: stub)
        dispatcher.discardedSourceRecordIDs = ["some-other-record"]
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .extend
        )
        let calls = await stub.tierCalls
        #expect(calls == [.strict], "an unreviewed hit still satisfies the stop; got \(calls)")
    }

    /// Partial discard: one of two hits rejected still leaves a plausible find,
    /// so the ladder stops. Only a tier with NOTHING left broadens.
    @Test func partiallyDiscardedTierStillStopsTheLadder() async {
        let stub = TierRecordingSource(emptyAt: [], resultsPerTier: 2)
        var dispatcher = makeDispatcher(stub: stub)
        dispatcher.discardedSourceRecordIDs = ["stub-strict-0"]      // stub-strict-1 survives
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .extend
        )
        let calls = await stub.tierCalls
        #expect(calls == [.strict], "one surviving candidate is still a find; got \(calls)")
    }

    /// Discards accumulate down the ladder: reject the strict hit AND the loose
    /// hit and `discover`/`all`-style walking continues to `.variant`. This is
    /// the property that makes review work FEED the search rather than narrow
    /// it — every dismissal widens the next run.
    @Test func discardsAtEveryTierWalkTheWholeLadder() async {
        let stub = TierRecordingSource(emptyAt: [], resultsPerTier: 1)
        var dispatcher = makeDispatcher(stub: stub)
        dispatcher.discardedSourceRecordIDs = ["stub-strict-0", "stub-loose-0"]
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .discover                       // ladder = [.loose, .variant]
        )
        let calls = await stub.tierCalls
        #expect(calls == [.loose, .variant],
                "a discarded loose hit must not stop discover; got \(calls)")
    }

    /// The honesty envelope is unchanged in the other direction: the default
    /// (no discards known) behaves exactly as before.
    @Test func emptyDiscardSetPreservesLegacyBehaviour() async {
        let stub = TierRecordingSource(emptyAt: [], resultsPerTier: 1)
        let dispatcher = makeDispatcher(stub: stub)          // discards default to []
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .extend
        )
        let calls = await stub.tierCalls
        #expect(calls == [.strict])
    }

    // MARK: - A skipped query must not veto broadening

    /// Owner dogfood 2026-08-22, and the actual reason Harriet Holmes's census
    /// was unreachable for a whole session. The dispatcher fans census years
    /// from `ScoringRules.censusYears` (…1911, 1921); FreeCen holds only
    /// 1841–1911. Every subject whose census window reached 1921 therefore
    /// carried ONE out-of-coverage query, which maps to `.skipped` — and one
    /// skipped outcome made the entire tier read as inconclusive, breaking the
    /// ladder at `.strict` even after the discard fix had correctly decided to
    /// broaden. A deliberate non-search carries no information; it must not
    /// veto the queries that did answer.
    @Test func aSkippedQueryDoesNotBlockBroadening() {
        let clean = Self.outcomeEntry(SearchOutcome(resultCount: 0))
        let skipped = Self.outcomeEntry(
            SearchOutcome(resultCount: 0, availability: .skipped(reason: "outside coverage: 1921")))
        #expect(clean.outcome.isConclusive)
        #expect(!skipped.outcome.isConclusive, "a skip is not a clean answer")
        #expect(skipped.outcome.wasSkipped)
        #expect(!clean.outcome.wasSkipped)

        // The ladder's own predicate: skipped rows are excluded, the rest must
        // all be clean, and at least one must have actually answered.
        let tier = [clean, skipped]
        let answered = tier.filter { !$0.outcome.wasSkipped }
        #expect(!answered.isEmpty && answered.allSatisfy { $0.outcome.isConclusive },
                "six clean empties + one out-of-coverage year must still broaden")
    }

    /// The case the 2026-07-30 `.skipped` mapping was written for is preserved:
    /// when EVERY query was skipped, nothing was searched and there is nothing
    /// to broaden into (the Probate 1922–1995 subject).
    @Test func aFullySkippedTierStillStops() {
        let skipped = Self.outcomeEntry(
            SearchOutcome(resultCount: 0, availability: .skipped(reason: "outside coverage")))
        let tier = [skipped, skipped]
        let answered = tier.filter { !$0.outcome.wasSkipped }
        #expect(answered.isEmpty)
        #expect(!(!answered.isEmpty && answered.allSatisfy { $0.outcome.isConclusive }),
                "nothing was searched — do not broaden")
    }

    /// A genuine failure still stops the ladder. The honesty envelope is
    /// unchanged: an errored tier must not be laundered into "searched
    /// everything, found nothing".
    @Test func anErroredQueryStillBlocksBroadening() {
        let clean = Self.outcomeEntry(SearchOutcome(resultCount: 0))
        let errored = Self.outcomeEntry(
            SearchOutcome(resultCount: 0, availability: .error(reason: "HTTP 500")))
        let tier = [clean, errored]
        let answered = tier.filter { !$0.outcome.wasSkipped }
        #expect(!answered.isEmpty)
        #expect(!answered.allSatisfy { $0.outcome.isConclusive },
                "an error is not a skip — it must still stop the ladder")
    }

    // MARK: - AC6.3 — discover skips .strict, escalates to .variant on empty

    @Test func ac6_3_discoverStartsAtLoose() async {
        let stub = TierRecordingSource(emptyAt: [], resultsPerTier: 1)
        let dispatcher = makeDispatcher(stub: stub)
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .discover
        )
        let calls = await stub.tierCalls
        #expect(calls == [.loose],
                "discover should start at .loose; got \(calls)")
    }

    @Test func ac6_3_discoverEscalatesToVariantOnEmpty() async {
        let stub = TierRecordingSource(emptyAt: [.loose])
        let dispatcher = makeDispatcher(stub: stub)
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .discover
        )
        let calls = await stub.tierCalls
        #expect(calls == [.loose, .variant],
                "discover should escalate to .variant when .loose is empty; got \(calls)")
    }

    // MARK: - AC6.4 — all parallel-fans every tier, dedupes

    @Test func ac6_4_allRunsEveryTierEvenWithResults() async {
        let stub = TierRecordingSource(emptyAt: [], resultsPerTier: 1)
        let dispatcher = makeDispatcher(stub: stub)
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .all
        )
        let calls = await stub.tierCalls
        #expect(calls == [.strict, .loose, .variant],
                "all should run every tier even when results are non-empty; got \(calls)")
    }

    @Test func ac6_4_allDedupesAcrossTiersByRecordID() async {
        // Stub returns the same single record at every tier — outer dedupe
        // collapses them by (sourceID, recordID).
        let stub = TierRecordingSource(emptyAt: [], resultsPerTier: 1, identicalResults: true)
        let dispatcher = makeDispatcher(stub: stub)
        let combined = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .all
        )
        #expect(combined.count == 1, "all should dedupe identical records across tiers; got \(combined.count)")
    }

    // MARK: - Activity bus carries strictness on every event

    @Test func dispatcherWalksMultipleTiersForExtendMode() async {
        // Verified at the dispatcher contract: the stub receives queries at
        // both .strict and .loose tiers when extend escalates on empty.
        // The ResearchActivityBus publication itself (events carrying
        // strictness) is guaranteed structurally — every source's publish
        // call site passes `strictness: query.strictness` (verified by the
        // type system and source-side audit done in Change 6). Subscribing
        // to the singleton bus from a parallel-running test suite is too
        // flaky to test directly.
        let stub = TierRecordingSource(emptyAt: [])
        let dispatcher = makeDispatcher(stub: stub)
        _ = await dispatcher.dispatch(
            subject: makeSubject(),
            recordTypes: [.death],
            scope: .county,
            mode: .extend
        )
        let tiers = Set(await stub.tierCalls)
        #expect(tiers.contains(.strict))
        #expect(tiers.contains(.loose))
    }

    // MARK: - AC6.5 — motivating end-to-end (network-gated)

    @Test(.disabled("Network-gated; enable manually to verify against live CWGC."))
    func ac6_5_williamCauldwellDiscoverFindsCWGCVariants() async {
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        bootstrapSources(registry: registry)
        let dispatcher = SearchDispatcher(registry: registry)
        let subject = ResearchSubject(
            profileID: nil,
            surname: "Cauldwell", givenName: "William",
            birthYearFrom: 1882, birthYearTo: 1882,
            deathYearFrom: 1914, deathYearTo: 1918,
            gender: .male, region: nil,
            mode: .discover,
            familyContext: nil,
            homeChapmanCode: "DBY"
        )
        let records = await dispatcher.dispatch(
            subject: subject,
            recordTypes: [.death],
            scope: .national,
            mode: .discover
        )
        let variantHits = records.compactMap { record -> String? in
            guard case .military(let r) = record else { return nil }
            let upper = (r.common.surname ?? "").uppercased()
            return (upper.contains("CALDWELL") || upper.contains("CAUDWELL")) ? upper : nil
        }
        #expect(variantHits.count >= 2,
                "discover-mode William Cauldwell should surface ≥2 CALDWELL/CAUDWELL CWGC matches; got \(variantHits.count)")
    }

    // MARK: - FT-04 — county→national scope escalation

    @Test func escalatePredicate_firesOnConclusiveCleanEmpty() {
        // FreeBMD, county scope, extend mode, zero records, every outcome a
        // conclusive clean empty → escalate.
        let outcomes = [Self.outcomeEntry(.init(resultCount: 0))]
        #expect(SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .county, mode: .extend,
            records: [], outcomes: outcomes, surname: "Cauldwell"))
    }

    @Test func escalatePredicate_doesNotFireOnError() {
        // T1-01 honesty envelope: an errored empty is not a clean empty.
        let outcomes = [Self.outcomeEntry(.init(resultCount: 0, availability: .error(reason: "boom")))]
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .county, mode: .extend,
            records: [], outcomes: outcomes, surname: "Cauldwell"))
    }

    @Test func escalatePredicate_doesNotFireOnTruncated() {
        // A truncated page-1 answer is not a trustworthy empty either.
        let outcomes = [Self.outcomeEntry(.init(resultCount: 0, totalAvailable: 999, truncated: true))]
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .county, mode: .extend,
            records: [], outcomes: outcomes, surname: "Cauldwell"))
    }

    @Test func escalatePredicate_doesNotFireOnThrottled() {
        let outcomes = [Self.outcomeEntry(.init(resultCount: 0, availability: .throttled))]
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .county, mode: .extend,
            records: [], outcomes: outcomes, surname: "Cauldwell"))
    }

    @Test func escalatePredicate_doesNotFireWhenAnyRecordsFound() {
        // Non-empty county result — no need to escalate.
        let rec = SourceRecord.death(DeathRecord(common: RecordCommon(id: "x", sourceID: "freebmd", rawFields: [:])))
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .county, mode: .extend,
            records: [rec], outcomes: [Self.outcomeEntry(.init(resultCount: 1))], surname: "Cauldwell"))
    }

    @Test func escalatePredicate_onlyFreeBMD() {
        // CWGC/FAG/Probate are inherently national — no district-vs-national
        // escalation. Only FreeBMD escalates.
        let outcomes = [Self.outcomeEntry(.init(resultCount: 0), sourceID: "cwgc")]
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: TierRecordingSource(emptyAt: [.strict], sourceID: "cwgc"),
            scope: .county, mode: .extend, records: [], outcomes: outcomes, surname: "Cauldwell"))
    }

    @Test func escalatePredicate_notAtNationalOrParish() {
        let clean = [Self.outcomeEntry(.init(resultCount: 0))]
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .national, mode: .extend,
            records: [], outcomes: clean, surname: "Cauldwell"))
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .parish, mode: .extend,
            records: [], outcomes: clean, surname: "Cauldwell"))
    }

    @Test func escalatePredicate_notInAllMode() {
        // .all runs the full ladder by contract, not as a reaction to
        // emptiness — escalation would double its national fan-out.
        let clean = [Self.outcomeEntry(.init(resultCount: 0))]
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .county, mode: .all,
            records: [], outcomes: clean, surname: "Cauldwell"))
    }

    @Test func escalatePredicate_notOnEmptyOutcomes() {
        // No axes ran → nothing to escalate from.
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .county, mode: .extend,
            records: [], outcomes: [], surname: "Cauldwell"))
    }

    @Test func escalatePredicate_doesNotFireForCommonSurname() {
        // Owner report 2026-08-05: a clean-empty county search on a COMMON
        // surname (Thompson) must NOT auto-escalate to a national FreeBMD
        // scrape — that national query is what tripped the volunteer source's
        // throttle. An uncommon surname (Cauldwell) with the same inputs still
        // escalates (bounded national query, cross-county recall worth it).
        let clean = [Self.outcomeEntry(.init(resultCount: 0))]
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .county, mode: .extend,
            records: [], outcomes: clean, surname: "Thompson"))
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .county, mode: .extend,
            records: [], outcomes: clean, surname: "Holmes"))
        // Missing surname can't be vouched rare → also stays put.
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .county, mode: .extend,
            records: [], outcomes: clean, surname: nil))
        // The rare-surname control still escalates.
        #expect(SearchDispatcher.shouldEscalateScope(
            source: ScopeRecordingFreeBMD(), scope: .county, mode: .extend,
            records: [], outcomes: clean, surname: "Cauldwell"))
    }

    @Test func dispatch_escalatesToNationalOnCountyCleanEmpty() async {
        // End-to-end at the dispatcher: a FreeBMD-shaped source that returns
        // a conclusive clean empty at county scope is re-walked at national
        // scope (districtid="" → both geo axes nil).
        let stub = ScopeRecordingFreeBMD(emptyEverywhere: true)
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(stub)
        let dispatcher = SearchDispatcher(registry: registry)
        _ = await dispatcher.dispatch(
            subject: makeSubject(), recordTypes: [.death],
            scope: .county, mode: .extend
        )
        let sawNational = await stub.sawNationalQuery
        #expect(sawNational, "county clean-empty must escalate to a national districtid=\"\" query")
    }

    @Test func dispatch_doesNotEscalateWhenCountyErrors() async {
        // An errored county answer must NOT escalate (honesty envelope).
        let stub = ScopeRecordingFreeBMD(emptyEverywhere: true, errorEverywhere: true)
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(stub)
        let dispatcher = SearchDispatcher(registry: registry)
        _ = await dispatcher.dispatch(
            subject: makeSubject(), recordTypes: [.death],
            scope: .county, mode: .extend
        )
        let sawNational = await stub.sawNationalQuery
        #expect(!sawNational, "an errored county answer must not trigger national escalation")
    }

    // MARK: - T1-12 — CWGC dispatched once per run even with two targets

    @Test func cwgcDispatchedOnceWhenDeathAndBurialBothActive() async {
        // Two record-type targets (.death, .burial) that build wire-
        // identical CWGC queries must collapse to a single dispatch — no
        // duplicate HTTP request racing past the per-run cache.
        let cwgc = CountingCWGC()
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(cwgc)
        let dispatcher = SearchDispatcher(registry: registry)
        _ = await dispatcher.dispatch(
            subject: makeMilitarySubject(),
            recordTypes: [.death, .burial],
            scope: .county, mode: .verify
        )
        let count = await cwgc.searchCount
        #expect(count == 1, "CWGC must dispatch exactly once for wire-identical .death/.burial targets; got \(count)")
    }

    // MARK: - Helpers

    private static func outcomeEntry(_ outcome: SearchOutcome, sourceID: String = "freebmd") -> SearchOutcomeEntry {
        SearchOutcomeEntry(
            sourceID: sourceID, recordType: .death, strictness: .strict,
            queryKey: "k", outcome: outcome
        )
    }

    private func makeMilitarySubject() -> ResearchSubject {
        // Birth 1895 → WW1-eligible, so buildQueries' cwgc case emits a query.
        ResearchSubject(
            profileID: nil,
            surname: "Cauldwell", givenName: "William",
            birthYearFrom: 1895, birthYearTo: 1895,
            deathYearFrom: 1916, deathYearTo: 1916,
            gender: .male, region: nil,
            mode: .verify, familyContext: nil,
            homeChapmanCode: "DBY"
        )
    }

    private func makeDispatcher(stub: TierRecordingSource) -> SearchDispatcher {
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(stub)
        return SearchDispatcher(registry: registry)
    }

    private func makeSubject() -> ResearchSubject {
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

}

/// Stub source that records the strictness of each `search(...)` call and
/// returns configurable empty/non-empty results per tier.
actor TierRecordingSource: RecordSource {
    nonisolated let sourceID: String
    nonisolated let scopeHandling: ScopeHandling = .inherentlyNational(reason: "test double")
    nonisolated let displayName = "Tier Recorder"
    nonisolated let recordTypes: Set<RecordType> = [.death]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "test")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(level: .open, summary: "test stub")

    let emptyAt: Set<SearchStrictness>
    let resultsPerTier: Int
    let identicalResults: Bool

    private(set) var tierCalls: [SearchStrictness] = []

    init(emptyAt: Set<SearchStrictness>, resultsPerTier: Int = 0, identicalResults: Bool = false, sourceID: String = "tier-recorder") {
        self.sourceID = sourceID
        self.emptyAt = emptyAt
        self.resultsPerTier = resultsPerTier
        self.identicalResults = identicalResults
    }

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        tierCalls.append(query.strictness)
        let count = emptyAt.contains(query.strictness) ? 0 : resultsPerTier
        guard count > 0 else { return .results([]) }
        let records = (0..<count).map { i -> SourceRecord in
            let id = identicalResults ? "fixed-id" : "stub-\(query.strictness.rawValue)-\(i)"
            let common = RecordCommon(
                id: id,
                sourceID: sourceID,
                name: "Stub \(i)",
                surname: query.surname,
                givenName: query.givenName,
                detailURL: nil,
                rawFields: [:]
            )
            return .military(MilitaryRecord(
                common: common,
                rank: nil, regiment: nil, unit: nil, serviceNumber: nil,
                dateOfDeath: nil, deathYear: nil, age: nil,
                cemetery: nil, graveRef: nil, additionalInfo: nil
            ))
        }
        return .results(records)
    }
}

/// FT-04 stub — a FreeBMD-shaped source (`sourceID == "freebmd"`, so the
/// dispatcher's freebmd `buildQueries` branch and the FT-04 escalation
/// predicate both treat it as FreeBMD) that records whether a national
/// query (both geo axes nil → districtid="") ever reached it, and returns
/// configurable empty/error envelopes.
actor ScopeRecordingFreeBMD: RecordSource {
    nonisolated let sourceID = "freebmd"
    nonisolated let scopeHandling: ScopeHandling = .scoped
    nonisolated let displayName = "FreeBMD (test)"
    nonisolated let recordTypes: Set<RecordType> = [.birth, .death, .marriage]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1837...1992
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "test")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(level: .open, summary: "test stub")

    let emptyEverywhere: Bool
    let errorEverywhere: Bool
    private(set) var sawNationalQuery = false

    init(emptyEverywhere: Bool = true, errorEverywhere: Bool = false) {
        self.emptyEverywhere = emptyEverywhere
        self.errorEverywhere = errorEverywhere
    }

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        await searchWithOutcome(query).result
    }

    func searchWithOutcome(_ query: RecordQuery) async -> SourceSearchEnvelope {
        if case .freeBMD(let p) = query.sourceParams,
           (p.districtCode ?? "").isEmpty, (p.countyCode ?? "").isEmpty {
            sawNationalQuery = true
        }
        if errorEverywhere {
            return SourceSearchEnvelope(
                result: .unavailable(reason: "test error"),
                outcome: SearchOutcome(resultCount: 0, availability: .error(reason: "test error"))
            )
        }
        if emptyEverywhere {
            return SourceSearchEnvelope(
                result: .results([]),
                outcome: SearchOutcome(resultCount: 0)
            )
        }
        return SourceSearchEnvelope(result: .results([]), outcome: SearchOutcome(resultCount: 0))
    }
}

/// T1-12 stub — a CWGC-shaped source that declares BOTH `.death` and
/// `.burial` (the pre-fix condition) and counts every `search` call. The
/// dispatcher's target dedupe must collapse the two wire-identical targets
/// so this counts exactly one.
actor CountingCWGC: RecordSource {
    nonisolated let sourceID = "cwgc"
    nonisolated let scopeHandling: ScopeHandling = .inherentlyNational(reason: "test double")
    nonisolated let displayName = "CWGC (test)"
    nonisolated let recordTypes: Set<RecordType> = [.death, .burial]
    nonisolated let coverageYearRange: ClosedRange<Int>? = 1914...1947
    nonisolated let coverageRegions: Set<Region> = [.commonwealthMilitary]
    nonisolated let dataLineage: SourceLineage = .primaryRecord
    nonisolated let trustTier: SourceTrustTier = .primary
    nonisolated let evidenceDirectness: EvidenceDirectness = .primary
    nonisolated let tosStatus = SourceToSStatus(level: .open, summary: "test stub")

    private(set) var searchCount = 0

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        searchCount += 1
        return .results([])
    }
}
