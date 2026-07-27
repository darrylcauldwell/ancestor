import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// A budget-paused source must not vanish silently. When the dispatcher drops
/// a source because its daily budget is spent *before this run began* (e.g.
/// FreeBMD, 200/day, spent on a prior run), the skip has to be VISIBLE in the
/// dispatch log — otherwise the source just disappears from the results and
/// reads as an inexplicable coverage gap.
///
/// The pause loop in `SearchDispatcher.dispatchWithOutcomes` now re-publishes
/// a `.dailyBudgetExhausted` event for every dropped source. That event is
/// carried through `DispatchLogCollector` (which the run wraps around
/// `ResearchActivityBus`) into `get_research_result`'s `_dispatch_log` as an
/// error-kind entry. This test drives that exact chain: subscribe the
/// collector to the bus, dispatch with an already-exhausted tracker, and
/// assert a visible budget-exhausted entry lands for the paused source while
/// the source itself is never hit.
@MainActor
struct PausedSourceVisibleSkipTests {

    @Test func pausedSourceProducesVisibleSkipEntry() async {
        let source = BudgetedCountingSource(sourceID: "freebmd")
        let registry = SourceRegistry(defaults: .ephemeralSuite())
        registry.register(source)

        // A tracker whose FreeBMD window is already at its 1/day ceiling, so
        // `isPaused` is true up front — the source is dropped before it can
        // fire a single request (the mid-run `.dailyBudgetExhausted` from
        // `recordRequest` never gets a chance to emit).
        let tracker = SourceBudgetTracker(
            policies: ["freebmd": SourceBudgetPolicy(dailyLimit: 1, reset: .utcMidnight)],
            restoredWindows: [
                SourceBudgetWindow(sourceID: "freebmd", windowStart: Date(), requestCount: 1)
            ]
        )
        #expect(await tracker.isPaused("freebmd"),
                "precondition: freebmd must be budget-paused for this test")

        var dispatcher = SearchDispatcher(registry: registry)
        dispatcher.budgetTracker = tracker

        // Drain the bus into a DispatchLogCollector exactly as the run does,
        // so we assert on what actually reaches `_dispatch_log`.
        let collector = DispatchLogCollector()
        let busStream = await ResearchActivityBus.shared.subscribe()
        let collectorTask = Task {
            for await event in busStream {
                await collector.record(event)
            }
        }
        // Let the subscription register before we publish.
        await Task.yield()

        let (records, _) = await dispatcher.dispatchWithOutcomes(
            subject: Self.subject(), recordTypes: [.birth],
            scope: .county, mode: .extend, cache: QueryCache()
        )

        // Give the async collector task a moment to drain, then stop it.
        await Task.yield()
        collectorTask.cancel()
        let entries = await collector.entries

        // The paused source never reached the wire…
        let calls = await source.searchCount
        #expect(calls == 0, "a budget-paused source must not be dispatched; got \(calls) calls")
        #expect(records.isEmpty)

        // …but its skip IS visible in the dispatch log.
        let skip = entries.first { $0.sourceID == "freebmd" && $0.kind == .error }
        #expect(skip != nil,
                "a budget-paused source must leave a visible skip entry in the dispatch log")
        #expect(skip?.errorReason?.contains("budget_exhausted") == true,
                "the skip entry must name the reason (budget exhausted); got \(String(describing: skip?.errorReason))")
    }

    // MARK: - Helpers

    private static func subject() -> ResearchSubject {
        ResearchSubject(
            profileID: "p-paused",
            surname: "Cauldwell", givenName: "Ernest",
            birthYearFrom: 1918, birthYearTo: 1922,
            deathYearFrom: 1918, deathYearTo: 1922,
            gender: .male, region: nil,
            mode: .extend, familyContext: nil,
            homeChapmanCode: "DBY"
        )
    }
}

/// A birth-covering source that counts wire calls and declares a daily budget,
/// so the dispatcher's pause loop treats it exactly like FreeBMD.
private actor BudgetedCountingSource: RecordSource {
    nonisolated let sourceID: String
    nonisolated let scopeHandling: ScopeHandling = .inherentlyNational(reason: "test double")
    nonisolated let displayName = "Budgeted Counting Source"
    nonisolated let recordTypes: Set<RecordType> = [.birth]
    nonisolated let coverageYearRange: ClosedRange<Int>? = nil
    nonisolated let coverageRegions: Set<Region> = [.englandAndWales]
    nonisolated let dataLineage: SourceLineage = .independentTranscription(of: "test")
    nonisolated let trustTier: SourceTrustTier = .transcription
    nonisolated let evidenceDirectness: EvidenceDirectness = .directTranscription
    nonisolated let tosStatus = SourceToSStatus(level: .open, summary: "test stub")
    nonisolated let budgetPolicy = SourceBudgetPolicy(dailyLimit: 1, reset: .utcMidnight)

    private(set) var searchCount = 0

    init(sourceID: String) { self.sourceID = sourceID }

    func search(_ query: RecordQuery) async -> SourceQueryResult {
        searchCount += 1
        return .results([])
    }
}
