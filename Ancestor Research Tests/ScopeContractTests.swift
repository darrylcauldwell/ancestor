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

    @Test func familySearchDeclaresScoped() async {
        // Change 4 — scope steers FS's place-axis level.
        #expect(FamilySearchSource().scopeHandling == .scoped)
    }

    @Test func familySearchScopeSteersAxisLevel() {
        let dispatcher = makeDispatcher()
        // Region derives from the subject; give it a county so the
        // bounded-scope axes have a value to carry.
        let subject = ResearchSubject(
            profileID: nil, surname: "Cauldwell", givenName: "Robert",
            birthYearFrom: 1880, birthYearTo: 1880,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: .county("Derbyshire"), mode: .extend,
            familyContext: nil, homeChapmanCode: "DBY")
        let source = FamilySearchSource()

        // Bounded scopes share county-level axes (adjacent is the
        // disclosed residual — single-value fuzzy axes cannot fan out).
        let county = keys(source, .birth, .county, dispatcher: dispatcher, subject: subject)
        for scope in [ResearchScope.parish, .district, .adjacent] {
            #expect(keys(source, .birth, scope, dispatcher: dispatcher, subject: subject) == county)
        }
        // National drops the county axis — remote true records must not
        // be rank-demoted below the single fetched page.
        let national = keys(source, .birth, .national, dispatcher: dispatcher, subject: subject)
        #expect(national != county, "national must not carry the county place axis")
        // A KNOWN death place is evidence, not scoping — it rides at
        // every scope including national.
        let deathSubject = ResearchSubject(
            profileID: nil, surname: "Cauldwell", givenName: "Robert",
            birthYearFrom: 1880, birthYearTo: 1880,
            deathYearFrom: 1950, deathYearTo: 1960,
            gender: .male, region: .county("Derbyshire"),
            deathLocation: "Glasgow, Scotland", mode: .extend,
            familyContext: nil, homeChapmanCode: "DBY")
        let deathNational = dispatcher.buildQueriesForTest(
            source: source, subject: deathSubject, recordType: .death, scope: .national)
        #expect(deathNational.allSatisfy { $0.deathPlace == "Glasgow, Scotland" })
    }

    @Test func familySearchNeverScopeSkips() {
        // FS is .scoped via axis-level steering but needs no chapman
        // anchor — an anchor-less subject at a bounded scope still
        // searches FS (it is the wide net, not a chapman fan-out).
        let anchorless = ResearchSubject(
            profileID: nil, surname: "Cauldwell", givenName: "Robert",
            birthYearFrom: 1880, birthYearTo: 1880,
            deathYearFrom: nil, deathYearTo: nil,
            gender: .male, region: nil, mode: .extend,
            familyContext: nil, homeChapmanCode: "")
        #expect(SearchDispatcher.scopeSkipReason(
            source: FamilySearchSource(), subject: anchorless, scope: .county) == nil)
    }

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
        #expect(!DispatchStage.localFree.includes(FamilySearchSource()))
        #expect(DispatchStage.adjacentFree.includes(FreeREGSource()))
        #expect(!DispatchStage.adjacentFree.includes(ProbateSource()),
                "widening stages are the chapman trio only")
        #expect(!DispatchStage.nationalFree.includes(FamilySearchSource()))
        #expect(DispatchStage.familySearch.includes(FamilySearchSource()))
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
