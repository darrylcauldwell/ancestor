import Testing
import Foundation
@testable import Ancestor_Research

/// SOURCE_WEIGHTING_SPEC Change 1 — the scope contract.
///
/// SCOPE_AUDIT_2026-07 established that the Scope picker's behaviour was
/// undeclared and untested for five of eight sources. These pins freeze the
/// audited per-scope query shapes so nothing drifts silently while the
/// staged-dispatch build (Changes 2–5) restructures this surface. Where a
/// later Change deliberately alters a shape (FS in Change 4, FreeREG
/// umbrella expansion in Change 3), the pin here is updated IN that change —
/// that is the point: shape changes must be visible in a diff.
@MainActor
struct ScopeContractTests {

    private let allScopes: [ResearchScope] = [.parish, .district, .county, .adjacent, .national]

    private func makeDispatcher() -> SearchDispatcher {
        let registry = SourceRegistry()
        bootstrapSources(registry: registry)
        return SearchDispatcher(registry: registry)
    }

    private func makeSubject(homeChapmanCode: String = "DBY") -> ResearchSubject {
        ResearchSubject(
            profileID: nil,
            surname: "Cauldwell",
            givenName: "Robert",
            birthYearFrom: 1880,
            birthYearTo: 1880,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: .male,
            region: nil,
            mode: .extend,
            familyContext: nil,
            homeChapmanCode: homeChapmanCode
        )
    }

    /// Wire-identity fingerprint of a (source, recordType, scope) query set.
    private func keys(
        _ source: any RecordSource, _ recordType: RecordType, _ scope: ResearchScope,
        dispatcher: SearchDispatcher, subject: ResearchSubject
    ) -> Set<String> {
        Set(dispatcher.buildQueriesForTest(
            source: source, subject: subject, recordType: recordType, scope: scope
        ).map { QueryCache.cacheKey(sourceID: source.sourceID, query: $0) })
    }

    // MARK: - Declarations match the audit

    @Test func everySourceDeclaresItsAuditedScopeHandling() {
        #expect(FreeBMDSource().scopeHandling == .scoped)
        #expect(FreeCenSource().scopeHandling == .scoped)
        #expect(FreeREGSource().scopeHandling == .scoped)
        if case .inherentlyNational = CWGCSource().scopeHandling {} else {
            Issue.record("CWGC must declare .inherentlyNational")
        }
        if case .anchorPinned = FindAGraveSource().scopeHandling {} else {
            Issue.record("FindAGrave must declare .anchorPinned — its county pin never lifts")
        }
        if case .inherentlyNational = ProbateSource().scopeHandling {} else {
            Issue.record("Probate must declare .inherentlyNational")
        }
    }

    // The three FamilySearch scope tests (declares-scoped, scope-steers-axis-
    // level, never-scope-skips) were removed with the FS records plugin (owner
    // pivot 2026-07-21 — FS is no longer a data source). The generic scope
    // contract stays covered by the free-source tests below; the FS dispatch
    // STAGE (DispatchStage.familySearch) is still exercised via scripted mock
    // sources in DispatchStagingTests / StagedPipelineTests.

    // MARK: - Scoped sources: per-scope shapes (audit verdict table)

    @Test func freeBMDPerScopeShape() {
        let dispatcher = makeDispatcher()
        let subject = makeSubject()
        let source = FreeBMDSource()

        // parish → deliberate zero queries (no parish endpoint)
        #expect(keys(source, .birth, .parish, dispatcher: dispatcher, subject: subject).isEmpty)
        // district → transitional widen: byte-identical to county
        let district = keys(source, .birth, .district, dispatcher: dispatcher, subject: subject)
        let county = keys(source, .birth, .county, dispatcher: dispatcher, subject: subject)
        #expect(district == county)
        // county → exactly one county-level query (FT-01 gate ON default)
        #expect(county.count == 1)
        // adjacent → home + neighbours, umbrella-expanded + deduped: 9 for DBY
        let adjacent = keys(source, .birth, .adjacent, dispatcher: dispatcher, subject: subject)
        #expect(adjacent.count == 9, "DBY + 7 neighbours with YKS→WRY/NRY/ERY expansion, deduped → 9; got \(adjacent.count)")
        #expect(adjacent.isSuperset(of: county), "adjacent must include the county query")
        // national → exactly one all-districts query
        #expect(keys(source, .birth, .national, dispatcher: dispatcher, subject: subject).count == 1)
    }

    @Test func freeCenWideningAndAxisSwapShape() {
        let dispatcher = makeDispatcher()
        let subject = makeSubject()
        let source = FreeCenSource()

        // parish/district widen to county — byte-identical query sets
        let parish = keys(source, .census, .parish, dispatcher: dispatcher, subject: subject)
        let district = keys(source, .census, .district, dispatcher: dispatcher, subject: subject)
        let county = keys(source, .census, .county, dispatcher: dispatcher, subject: subject)
        #expect(parish == county && district == county)
        #expect(!county.isEmpty)
        // FT-11 axis swap: adjacent ≡ national for a home-known subject
        // (one birth-county query per census year, no residence filter)
        let adjacent = keys(source, .census, .adjacent, dispatcher: dispatcher, subject: subject)
        let national = keys(source, .census, .national, dispatcher: dispatcher, subject: subject)
        #expect(adjacent == national)
        #expect(adjacent != county, "adjacent swaps to the birth axis — not the county residence shape")
    }

    @Test func freeREGPerScopeFanOut() {
        let dispatcher = makeDispatcher()
        let subject = makeSubject()
        let source = FreeREGSource()

        // parish/district/county → single home-chapman query set
        let parish = keys(source, .parish, .parish, dispatcher: dispatcher, subject: subject)
        let county = keys(source, .parish, .county, dispatcher: dispatcher, subject: subject)
        #expect(parish == county)
        #expect(county.count == 1)
        // adjacent → home + neighbours, umbrella-expanded + deduped like
        // FreeBMD (Change 3): DBY + 7 neighbours with YKS → WRY/NRY/ERY
        // and WRY deduped → 9
        let adjacent = keys(source, .parish, .adjacent, dispatcher: dispatcher, subject: subject)
        #expect(adjacent.count == 9, "umbrella-expanded adjacency → 9; got \(adjacent.count)")
        // national → full England & Wales fan-out, strictly wider
        let national = keys(source, .parish, .national, dispatcher: dispatcher, subject: subject)
        #expect(national.count > adjacent.count)
        #expect(national.count == 56, "englandAndWales() chapman codes → 56 per audit; got \(national.count)")
    }

    // MARK: - Scope-invariant sources: invariance pinned at every level

    @Test func declaredScopeInvariantSourcesAreInvariantAtEveryLevel() {
        let dispatcher = makeDispatcher()
        let subject = makeSubject()
        let cases: [(any RecordSource, RecordType)] = [
            (CWGCSource(), .death),
            (FindAGraveSource(), .burial),
            (ProbateSource(), .probate),
        ]
        for (source, recordType) in cases {
            let baseline = keys(source, recordType, .parish, dispatcher: dispatcher, subject: subject)
            #expect(!baseline.isEmpty, "\(source.sourceID) should build queries at parish scope (it ignores scope)")
            for scope in allScopes {
                let set = keys(source, recordType, scope, dispatcher: dispatcher, subject: subject)
                #expect(set == baseline,
                        "\(source.sourceID) is declared scope-invariant; \(scope) diverged from parish")
            }
        }
    }

    // MARK: - The generic branch refuses undeclared scoped sources

    @Test func scopedSourceWithoutDedicatedBranchIsRefused() {
        let dispatcher = makeDispatcher()
        let subject = makeSubject()
        // A source that CLAIMS .scoped but has no scope-aware branch in
        // buildQueries must get zero queries (loud log), never silently
        // inherit the generic unscoped shape.
        let impostor = ScopedImpostorSource()
        let built = dispatcher.buildQueriesForTest(
            source: impostor, subject: subject, recordType: .probate, scope: .county)
        #expect(built.isEmpty, "generic branch must refuse a .scoped source, got \(built.count) queries")
    }
}

/// SOURCE_WEIGHTING_SPEC Change 2 — visible skips. An anchor-less subject
/// at a bounded scope (or FreeBMD at parish) must produce ZERO dead queries
/// and ONE synthetic `.skipped` outcome per (source, recordType) — never
/// silence, never an error, never a persistable negative.
@MainActor
struct ScopeSkipVisibilityTests {

    private func makeDispatcher(sources: [any RecordSource]) -> SearchDispatcher {
        let registry = SourceRegistry()
        for source in sources { registry.register(source) }
        return SearchDispatcher(registry: registry)
    }

    private func makeSubject(homeChapmanCode: String) -> ResearchSubject {
        ResearchSubject(
            profileID: nil, surname: "Cauldwell", givenName: "Robert",
            birthYearFrom: 1880, birthYearTo: 1880,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil, mode: .extend,
            familyContext: nil, homeChapmanCode: homeChapmanCode
        )
    }

    @Test func skipOutcomeIsNeitherConclusiveNorPersistableNegative() {
        let outcome = SearchOutcome.scopeSkip(reason: "no anchor")
        #expect(!outcome.isConclusive)
        #expect(!outcome.isCleanNegative)
        let entry = SearchOutcomeEntry(
            sourceID: "freebmd", recordType: .birth, strictness: .strict,
            queryKey: "scope-skip|freebmd|birth|county", outcome: outcome)
        #expect(NegativeSearchAggregator.genuineNegatives(outcomes: [entry], scoredRecords: []).isEmpty,
                "a skip must never persist as negative evidence")
    }

    @Test func skipReasonsFollowTheContract() {
        let anchored = makeSubject(homeChapmanCode: "DBY")
        let anchorless = makeSubject(homeChapmanCode: "")
        // FreeBMD parish: deliberate no-endpoint skip, even when anchored.
        #expect(SearchDispatcher.scopeSkipReason(source: FreeBMDSource(), subject: anchored, scope: .parish) != nil)
        // Anchor-less at bounded scopes → skip; national never skips.
        for source in [FreeBMDSource() as any RecordSource, FreeCenSource(), FreeREGSource()] {
            #expect(SearchDispatcher.scopeSkipReason(source: source, subject: anchorless, scope: .county) != nil,
                    "\(source.sourceID) must skip an anchor-less subject at county scope")
            #expect(SearchDispatcher.scopeSkipReason(source: source, subject: anchorless, scope: .adjacent) != nil)
            #expect(SearchDispatcher.scopeSkipReason(source: source, subject: anchorless, scope: .national) == nil,
                    "national scope needs no anchor")
        }
        // Anchored subjects at workable scopes never skip.
        #expect(SearchDispatcher.scopeSkipReason(source: FreeBMDSource(), subject: anchored, scope: .county) == nil)
        // Non-scoped sources are never scope-skipped.
        #expect(SearchDispatcher.scopeSkipReason(source: CWGCSource(), subject: anchorless, scope: .county) == nil)
    }

    @Test func anchorlessSubjectBuildsZeroDeadQueriesBelowNational() {
        let dispatcher = makeDispatcher(sources: [FreeBMDSource(), FreeCenSource(), FreeREGSource()])
        let anchorless = makeSubject(homeChapmanCode: "")
        let cases: [(any RecordSource, RecordType)] = [
            (FreeBMDSource(), .birth), (FreeCenSource(), .census), (FreeREGSource(), .parish),
        ]
        for (source, recordType) in cases {
            for scope in [ResearchScope.parish, .district, .county, .adjacent] {
                let queries = dispatcher.buildQueriesForTest(
                    source: source, subject: anchorless, recordType: recordType, scope: scope)
                #expect(queries.isEmpty,
                        "\(source.sourceID) at \(scope) with no anchor built \(queries.count) dead queries")
            }
            // National still fans out for census/parish sweeps; FreeBMD
            // national is its one all-districts query.
            let national = dispatcher.buildQueriesForTest(
                source: source, subject: anchorless, recordType: recordType, scope: .national)
            #expect(!national.isEmpty, "\(source.sourceID) national must still work without an anchor")
        }
    }

    @Test func dispatchEmitsVisibleSkipEntriesWithoutTouchingTheWire() async {
        // Registry contains ONLY FreeBMD; parish scope → zero queries →
        // one skip entry, no HTTP possible (nothing was built to send).
        let dispatcher = makeDispatcher(sources: [FreeBMDSource()])
        let anchored = makeSubject(homeChapmanCode: "DBY")
        let (records, outcomes) = await dispatcher.dispatchWithOutcomes(
            subject: anchored, recordTypes: [.birth], scope: .parish)
        #expect(records.isEmpty)
        let skips = outcomes.filter {
            if case .skipped = $0.outcome.availability { return true } else { return false }
        }
        #expect(skips.count == 1, "expected exactly one visible skip entry, got \(outcomes.count) outcomes")
        #expect(skips.first?.sourceID == "freebmd")
    }

    @Test func skipNeverTriggersScopeEscalation() {
        let entry = SearchOutcomeEntry(
            sourceID: "freebmd", recordType: .birth, strictness: .strict,
            queryKey: "scope-skip|freebmd|birth|county",
            outcome: .scopeSkip(reason: "no anchor"))
        #expect(!SearchDispatcher.shouldEscalateScope(
            source: FreeBMDSource(), scope: .county, mode: .extend,
            records: [], outcomes: [entry]),
            "a skip is not a conclusive clean-empty — FT-04 must not fire national from it")
    }
}

/// SOURCE_WEIGHTING_SPEC Change 5 (stage model) — the ladder is bounded by
/// the user's scope, stage membership derives from declared ScopeHandling,
/// and a staged dispatch fires only that stage's sources.
@MainActor
struct DispatchStagingTests {

    @Test func ladderIsBoundedByUserScope() {
        #expect(DispatchStage.ladder(for: .parish) == [.localFree, .familySearch])
        #expect(DispatchStage.ladder(for: .district) == [.localFree, .familySearch])
        #expect(DispatchStage.ladder(for: .county) == [.localFree, .familySearch])
        #expect(DispatchStage.ladder(for: .adjacent) == [.localFree, .adjacentFree, .familySearch])
        #expect(DispatchStage.ladder(for: .national) ==
                [.localFree, .adjacentFree, .nationalFree, .familySearch])
    }

    @Test func effectiveScopeNeverExceedsTheUserBound() {
        #expect(DispatchStage.localFree.effectiveScope(userScope: .parish) == .parish)
        #expect(DispatchStage.localFree.effectiveScope(userScope: .national) == .county)
        #expect(DispatchStage.adjacentFree.effectiveScope(userScope: .national) == .adjacent)
        #expect(DispatchStage.familySearch.effectiveScope(userScope: .county) == .county)
        #expect(DispatchStage.familySearch.effectiveScope(userScope: .national) == .national)
    }

    @Test func stageMembershipDerivesFromDeclarations() {
        #expect(DispatchStage.localFree.includes(FreeBMDSource()))
        #expect(DispatchStage.localFree.includes(CWGCSource()),
                "scope-invariant free specialists fire in the first stage")
        #expect(DispatchStage.adjacentFree.includes(FreeREGSource()))
        #expect(!DispatchStage.adjacentFree.includes(ProbateSource()),
                "widening stages are the chapman trio only")
        // The familySearch-stage membership asserts moved out with the FS
        // plugin; the stage's behaviour is still pinned by the scripted-source
        // DispatchStagingTests / StagedPipelineTests below.
        #expect(!DispatchStage.familySearch.includes(FreeBMDSource()))
    }

    @Test func stagedDispatchExcludesNonStageSources() async {
        // Only FreeBMD registered; at the FS stage it is not a target —
        // nothing fires, nothing touches the wire.
        let registry = SourceRegistry()
        registry.register(FreeBMDSource())
        let dispatcher = SearchDispatcher(registry: registry)
        let subject = ResearchSubject(
            profileID: nil, surname: "Cauldwell", givenName: "Robert",
            birthYearFrom: 1880, birthYearTo: 1880,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil, mode: .extend,
            familyContext: nil, homeChapmanCode: "DBY")
        let (records, outcomes) = await dispatcher.dispatchWithOutcomes(
            subject: subject, recordTypes: [.birth], scope: .national, stage: .familySearch)
        #expect(records.isEmpty && outcomes.isEmpty)
    }
}

/// SOURCE_WEIGHTING_SPEC Change 5 (pipeline integration), revised 2026-07-25
/// (moves 1+2) — FamilySearch is the terminal stage and is ALWAYS reached for
/// any record type the free tier found a candidate for: a single candidate for
/// corroboration, competing candidates for the tie-break. Free geographic
/// widening still happens only on a genuine miss (no candidate at all).
@MainActor
struct StagedPipelineTests {

    private func makeSubject() -> ResearchSubject {
        ResearchSubject(
            profileID: nil, surname: "Cauldwell", givenName: "Robert",
            birthYearFrom: 1880, birthYearTo: 1880,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: .county("Derbyshire"), mode: .extend,
            familyContext: nil, homeChapmanCode: "DBY")
    }

    private func matchingBirth() -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(id: "b-match", sourceID: "freebmd",
                                 name: "Robert Cauldwell", surname: "Cauldwell",
                                 givenName: "Robert", detailURL: nil, rawFields: [:]),
            birthYear: 1880, birthDate: "1880", birthPlace: nil,
            quarter: "Jun", district: "Belper", volume: "7b", page: "3",
            mothersMaidenName: nil))
    }

    private func run(freeResults: [SourceRecord], fs: StagedScriptedSource)
    async -> ResearchResult {
        let registry = SourceRegistry()
        registry.register(StagedScriptedSource(
            sourceID: "freebmd", displayName: "FreeBMD (test)", results: freeResults))
        registry.register(fs)
        let pipeline = ResearchPipeline(
            dispatcher: SearchDispatcher(registry: registry),
            snapshot: .empty, sourceInfoMap: [:])
        return await pipeline.research(
            subject: makeSubject(),
            config: ResearchConfig(maxIterations: 3, maxFacts: 50, mode: .extend,
                                   scope: .county))
    }

    // Moves 1+2: even when the free tier hands back a single clean candidate,
    // FamilySearch is STILL reached — for corroboration — and its record is
    // captured. (Old on-miss contract: FS was skipped and a visible skip
    // recorded. That inversion is the whole point of the change.)
    @Test func freeTierAnswerStillReachesFamilySearchForCorroboration() async {
        let fsCorroboration = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "b-fs-corrob", sourceID: "familysearch",
                                 name: "Robert Cauldwell", surname: "Cauldwell",
                                 givenName: "Robert", detailURL: nil, rawFields: [:]),
            birthYear: 1880, birthDate: "1880", birthPlace: nil,
            quarter: nil, district: "Belper", volume: nil, page: nil,
            mothersMaidenName: nil))
        let fs = StagedScriptedSource(
            sourceID: "familysearch", displayName: "FamilySearch (test)",
            results: [fsCorroboration])
        let result = await run(freeResults: [matchingBirth()], fs: fs)

        #expect(result.allScoredRecords.contains { $0.record.id == "b-match" })
        let fsCalls = await fs.searchCount
        #expect(fsCalls >= 1,
                "the free tier answered birth, but FS must STILL run for corroboration")
        #expect(result.allScoredRecords.contains { $0.record.id == "b-fs-corrob" },
                "FamilySearch's corroborating record must be captured")
    }

    // Two free-tier birth candidates a year apart (the John Cauldwell namesake
    // collision) must escalate to FamilySearch to break the tie — free
    // geographic widening cannot disambiguate, FS's relational records can.
    @Test func competingFreeCandidatesEscalateToFamilySearch() async {
        let subject = ResearchSubject(
            profileID: nil, surname: "Cauldwell", givenName: "John",
            birthYearFrom: 1859, birthYearTo: 1862,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: .county("Derbyshire"), mode: .extend,
            familyContext: nil, homeChapmanCode: "DBY")
        let birth1860 = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "b-1860", sourceID: "freebmd",
                                 name: "John Cauldwell", surname: "Cauldwell",
                                 givenName: "John", detailURL: nil, rawFields: [:]),
            birthYear: 1860, birthDate: "1860", birthPlace: nil,
            quarter: "Mar", district: "Belper", volume: "7b", page: "5",
            mothersMaidenName: nil))
        let birth1861 = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "b-1861", sourceID: "freebmd",
                                 name: "John Cauldwell", surname: "Cauldwell",
                                 givenName: "John", detailURL: nil, rawFields: [:]),
            birthYear: 1861, birthDate: "1861", birthPlace: nil,
            quarter: "Jun", district: "Belper", volume: "7b", page: "9",
            mothersMaidenName: nil))
        let fsBaptism = SourceRecord.parish(ParishRecord(
            common: RecordCommon(id: "p-fs-baptism", sourceID: "familysearch",
                                 name: "John Cauldwell", surname: "Cauldwell",
                                 givenName: "John", detailURL: nil, rawFields: [:]),
            eventType: "baptism", eventDate: "1860", eventYear: 1860, parish: "Windley"))
        let fs = StagedScriptedSource(
            sourceID: "familysearch", displayName: "FamilySearch (test)",
            results: [fsBaptism])

        let registry = SourceRegistry()
        registry.register(StagedScriptedSource(
            sourceID: "freebmd", displayName: "FreeBMD (test)",
            results: [birth1860, birth1861]))
        registry.register(fs)
        let pipeline = ResearchPipeline(
            dispatcher: SearchDispatcher(registry: registry),
            snapshot: .empty, sourceInfoMap: [:])
        let result = await pipeline.research(
            subject: subject,
            config: ResearchConfig(maxIterations: 3, maxFacts: 50, mode: .extend,
                                   scope: .county))

        let fsCalls = await fs.searchCount
        #expect(fsCalls >= 1,
                "two competing birth candidates must escalate to FamilySearch")
        #expect(result.allScoredRecords.contains { $0.record.id == "p-fs-baptism" },
                "FamilySearch's disambiguating baptism must be surfaced")
    }

    @Test func freeTierMissWalksTheLadderToFamilySearch() async {
        let fsRecord = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "b-fs", sourceID: "familysearch",
                                 name: "Robert Cauldwell", surname: "Cauldwell",
                                 givenName: "Robert", detailURL: nil, rawFields: [:]),
            birthYear: 1880, birthDate: "1880", birthPlace: nil,
            quarter: nil, district: "Belper", volume: nil, page: nil,
            mothersMaidenName: nil))
        let fs = StagedScriptedSource(
            sourceID: "familysearch", displayName: "FamilySearch (test)",
            results: [fsRecord])
        let result = await run(freeResults: [], fs: fs)

        let fsCalls = await fs.searchCount
        #expect(fsCalls > 0, "an unanswered free tier must escalate to FS")
        #expect(result.allScoredRecords.contains { $0.record.id == "b-fs" })
    }
}

/// Scripted staged source: fixed results, counted calls.
private actor StagedScriptedSource: RecordSource {
    nonisolated let sourceID: String
    nonisolated let scopeHandling: ScopeHandling = .scoped
    nonisolated let displayName: String
    nonisolated let recordTypes: Set<RecordType> = [.birth]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .communityEdited
    nonisolated let trustTier: SourceTrustTier = .community
    nonisolated let evidenceDirectness: EvidenceDirectness = .derivative
    nonisolated let tosStatus = SourceToSStatus(level: .community, summary: "test double")
    private let results: [SourceRecord]
    private(set) var searchCount = 0

    init(sourceID: String, displayName: String, results: [SourceRecord]) {
        self.sourceID = sourceID
        self.displayName = displayName
        self.results = results
    }

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        searchCount += 1
        return .results(results)
    }
}

/// Test double: declares `.scoped` but the dispatcher has no branch for it.
private struct ScopedImpostorSource: RecordSource {
    nonisolated let sourceID = "scoped-impostor"
    nonisolated let scopeHandling: ScopeHandling = .scoped
    nonisolated let displayName = "Scoped Impostor"
    nonisolated let recordTypes: Set<RecordType> = [.probate]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = []
    nonisolated let dataLineage: SourceLineage = .communityEdited
    nonisolated let trustTier: SourceTrustTier = .community
    nonisolated let evidenceDirectness: EvidenceDirectness = .derivative
    nonisolated let tosStatus = SourceToSStatus(level: .community, summary: "test double")
    func search(_ query: RecordQuery) async -> SourceQueryResult { .results([]) }
}
