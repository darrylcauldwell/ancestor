import Testing
import Foundation
@testable import Ancestor_Research

/// Connector-audit T1-04 — end-to-end suppression through the dispatcher.
/// A query a prior run proved cleanly empty is SKIPPED on the next run:
/// no HTTP request, a `suppressed` outcome recorded in its place, and the
/// ladder still broadening on the (conclusive) empty.
///
/// Method: run the main-loop dispatch once with no negative cache to
/// learn the exact `queryKey` the dispatcher emits, seed a
/// `NegativeSearchCache` with that key, re-dispatch, and assert the
/// source was not called again for the suppressed tier.
@MainActor
struct NegativeSearchSuppressionDispatchTests {

    @Test func suppressedQuerySkipsTheWireAndFlagsTheOutcome() async {
        // Two clean-empty answers scripted so the .extend ladder can walk
        // .strict then .loose on a genuine empty during the learning run.
        let source = CountingKeySource(sourceID: "probate")
        let dispatcher = Self.makeDispatcher(source: source)

        // Learning run — no suppression. Records the emitted queryKey(s).
        let (_, learnOutcomes) = await dispatcher.dispatchWithOutcomes(
            subject: Self.subject(), recordTypes: [.probate],
            scope: .county, mode: .extend, cache: QueryCache()
        )
        let learnedCalls = await source.searchCount
        #expect(learnedCalls >= 1, "the learning run must reach the wire at least once")
        let keys = Set(learnOutcomes.map(\.queryKey))
        #expect(!keys.isEmpty)

        // Build a negative cache from every learned key, as if a prior run
        // had persisted them all as clean negatives.
        let rows = keys.map {
            (sourceID: "probate", recordType: "probate", queryKey: $0, date: Date())
        }
        let negativeCache = NegativeSearchCache(rows: rows, window: .default, now: Date())

        // Re-dispatch WITH suppression on a fresh source + fresh per-run
        // cache (so the only thing that can prevent a wire call is the
        // cross-run negative cache).
        let source2 = CountingKeySource(sourceID: "probate")
        let dispatcher2 = Self.makeDispatcher(source: source2)
        let (records, outcomes) = await dispatcher2.dispatchWithOutcomes(
            subject: Self.subject(), recordTypes: [.probate],
            scope: .county, mode: .extend, cache: QueryCache(),
            negativeCache: negativeCache
        )
        let suppressedRunCalls = await source2.searchCount
        #expect(suppressedRunCalls == 0,
                "every proven-empty query must be suppressed — no HTTP call; got \(suppressedRunCalls)")
        #expect(records.isEmpty)
        #expect(!outcomes.isEmpty)
        #expect(outcomes.allSatisfy { $0.outcome.suppressed },
                "every recorded outcome must be a suppressed replay")
        #expect(outcomes.allSatisfy { $0.outcome.isConclusive },
                "a suppressed empty is conclusive so the ladder still broadens")
        #expect(outcomes.allSatisfy { !$0.outcome.isCleanNegative },
                "a suppressed replay must never be re-persisted as a new negative")
    }

    @Test func unsuppressedQueryStillReachesTheWire() async {
        // A negative cache that doesn't contain this query's key must not
        // interfere — the query dispatches normally.
        let source = CountingKeySource(sourceID: "probate")
        let dispatcher = Self.makeDispatcher(source: source)
        let negativeCache = NegativeSearchCache(
            rows: [(sourceID: "probate", recordType: "probate", queryKey: "unrelated-key", date: Date())],
            window: .default, now: Date()
        )
        let (_, _) = await dispatcher.dispatchWithOutcomes(
            subject: Self.subject(), recordTypes: [.probate],
            scope: .county, mode: .extend, cache: QueryCache(),
            negativeCache: negativeCache
        )
        let calls = await source.searchCount
        #expect(calls >= 1, "a query with no stored negative must reach the wire; got \(calls)")
    }

    @Test func disabledCacheNeverSuppresses() async {
        let source = CountingKeySource(sourceID: "probate")
        let dispatcher = Self.makeDispatcher(source: source)
        // Default negativeCache is `.disabled` — behaviour identical to
        // pre-T1-04.
        let (_, _) = await dispatcher.dispatchWithOutcomes(
            subject: Self.subject(), recordTypes: [.probate],
            scope: .county, mode: .extend, cache: QueryCache()
        )
        let calls = await source.searchCount
        #expect(calls >= 1)
    }

    // MARK: - Helpers

    private static func makeDispatcher(source: any RecordSource) -> SearchDispatcher {
        let registry = SourceRegistry()
        registry.register(source)
        return SearchDispatcher(registry: registry)
    }

    private static func subject() -> ResearchSubject {
        ResearchSubject(
            profileID: "p-suppress",
            surname: "Cauldwell", givenName: "Ernest",
            birthYearFrom: 1918, birthYearTo: 1922,
            deathYearFrom: 1918, deathYearTo: 1922,
            gender: .male, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
    }
}

/// Empty-returning source that counts wire calls — used to prove a
/// suppressed query never reaches `search`.
private actor CountingKeySource: RecordSource {
    nonisolated let sourceID: String
    nonisolated let scopeHandling: ScopeHandling = .inherentlyNational(reason: "test double")
    nonisolated let displayName = "Counting Key Source"
    nonisolated let recordTypes: Set<RecordType> = [.probate, .death, .burial]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "test")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(level: .open, summary: "test stub")

    private(set) var searchCount = 0

    init(sourceID: String) { self.sourceID = sourceID }

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        searchCount += 1
        return .results([])
    }
}
