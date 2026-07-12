import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// ENGINE_FOUNDATION_SPEC §Change5 — daily-budget awareness, acceptance (5).
///
/// Simulate FreeBMD quota exhaustion → FreeBMD pauses while FreeREG/CWGC/others
/// continue; resume time is queryable; the budget-vs-throttle distinction is
/// preserved (a spent daily budget does NOT ladder the transient circuit
/// breaker); counters persist across a process restart (rehydrated from
/// `source_budget_state`).
///
/// The pure accounting kernel (`SourceBudgetWindow` / `SourceBudgetPolicy`,
/// AncestorKit) is tested directly with an injected clock so exhaustion and
/// day-rollover are deterministic without a wall-clock wait.
struct SourceBudgetStateTests {

    // A fixed reference instant (2026-07-12 10:00 UTC) so reset math is exact.
    private static func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso)!
    }
    private let noon = at("2026-07-12T10:00:00Z")

    // MARK: - Pure window accounting

    @Test func unlimitedPolicyNeverPauses() {
        let policy = SourceBudgetPolicy.unlimited
        var w = SourceBudgetWindow(sourceID: "cwgc", windowStart: noon, requestCount: 0)
        for _ in 0..<10_000 { w = w.incremented(policy: policy, now: noon) }
        #expect(w.state(policy: policy, now: noon) == .available(remaining: nil))
    }

    @Test func countReachingLimitPausesUntilTomorrow() {
        let policy = SourceBudgetPolicy(dailyLimit: 3, reset: .utcMidnight)
        var w = SourceBudgetWindow(sourceID: "freebmd", windowStart: noon, requestCount: 0)
        #expect(!w.state(policy: policy, now: noon).isPaused)
        w = w.incremented(policy: policy, now: noon)  // 1
        w = w.incremented(policy: policy, now: noon)  // 2
        #expect(w.state(policy: policy, now: noon) == .available(remaining: 1))
        w = w.incremented(policy: policy, now: noon)  // 3 == limit
        #expect(w.state(policy: policy, now: noon).isPaused)
    }

    @Test func resumeTimeIsQueryableAndIsNextUTCMidnight() {
        let policy = SourceBudgetPolicy(dailyLimit: 1, reset: .utcMidnight)
        var w = SourceBudgetWindow(sourceID: "freebmd", windowStart: noon, requestCount: 0)
        w = w.incremented(policy: policy, now: noon)
        let resumeAt = w.state(policy: policy, now: noon).resumeAt
        #expect(resumeAt == Self.at("2026-07-13T00:00:00Z"))
    }

    @Test func windowRollsForwardAfterResetAndUnpauses() {
        let policy = SourceBudgetPolicy(dailyLimit: 1, reset: .utcMidnight)
        var w = SourceBudgetWindow(sourceID: "freebmd", windowStart: noon, requestCount: 0)
        w = w.incremented(policy: policy, now: noon)
        #expect(w.state(policy: policy, now: noon).isPaused)
        // Next day at 01:00 UTC — past the reset, so the source is available
        // again and a fresh request counts against a zeroed window.
        let nextDay = Self.at("2026-07-13T01:00:00Z")
        #expect(!w.state(policy: policy, now: nextDay).isPaused)
        let rolled = w.rolledForward(policy: policy, now: nextDay)
        #expect(rolled.requestCount == 0)
        #expect(rolled.windowStart == Self.at("2026-07-13T00:00:00Z"))
    }

    @Test func documentedResetHourIsHonoured() {
        // A source that resets at 07:00 in a fixed zone, not UTC midnight.
        let policy = SourceBudgetPolicy(dailyLimit: 1, reset: .dailyAt(hour: 7, timeZoneIdentifier: "UTC"))
        var w = SourceBudgetWindow(sourceID: "x", windowStart: noon, requestCount: 0)
        w = w.incremented(policy: policy, now: noon)  // 10:00, past 07:00 → next reset tomorrow 07:00
        #expect(w.state(policy: policy, now: noon).resumeAt == Self.at("2026-07-13T07:00:00Z"))
    }

    // MARK: - Tracker behaviour (criterion 5 end-to-end, in-memory)

    @Test func freeBMDExhaustionPausesFreeBMDButNotOthers() async {
        let policies: [String: SourceBudgetPolicy] = [
            "freebmd": SourceBudgetPolicy(dailyLimit: 2, reset: .utcMidnight),
            "freereg": SourceBudgetPolicy(dailyLimit: 100, reset: .utcMidnight),
            "cwgc": .unlimited,
        ]
        let clock = noon
        let tracker = SourceBudgetTracker(policies: policies, now: { clock })

        await tracker.recordRequest("freebmd")
        await tracker.recordRequest("freebmd")  // hits limit

        #expect(await tracker.isPaused("freebmd"))
        #expect(!(await tracker.isPaused("freereg")))
        #expect(!(await tracker.isPaused("cwgc")))
        // Resume time queryable.
        #expect(await tracker.resumeAt(for: "freebmd") == Self.at("2026-07-13T00:00:00Z"))
    }

    @Test func exhaustionEmitsDailyBudgetExhaustedOncePerWindow() async {
        actor Sink { var events: [(String, Date)] = []; func add(_ s: String, _ d: Date) { events.append((s, d)) } }
        let sink = Sink()
        let policies = ["freebmd": SourceBudgetPolicy(dailyLimit: 1, reset: .utcMidnight)]
        let clock = noon
        let tracker = SourceBudgetTracker(
            policies: policies,
            now: { clock },
            emit: { id, at in await sink.add(id, at) }
        )
        await tracker.recordRequest("freebmd")  // crosses limit → emit
        await tracker.recordRequest("freebmd")  // still exhausted → no second emit
        await tracker.recordRequest("freebmd")
        let events = await sink.events
        #expect(events.count == 1)
        #expect(events.first?.0 == "freebmd")
        #expect(events.first?.1 == Self.at("2026-07-13T00:00:00Z"))
    }

    // MARK: - Persistence across restart (criterion 5)

    @Test func countersPersistAcrossRestart() async {
        // "Process 1": count two requests, persisting each window snapshot.
        actor Store { var rows: [String: SourceBudgetWindow] = [:]; func put(_ w: SourceBudgetWindow) { rows[w.sourceID] = w }; func all() -> [SourceBudgetWindow] { Array(rows.values) } }
        let store = Store()
        let policies = ["freebmd": SourceBudgetPolicy(dailyLimit: 3, reset: .utcMidnight)]
        let clock = noon

        let t1 = SourceBudgetTracker(
            policies: policies,
            now: { clock },
            persist: { w in Task { await store.put(w) } }
        )
        await t1.recordRequest("freebmd")
        await t1.recordRequest("freebmd")
        // let the detached persist tasks flush
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!(await t1.isPaused("freebmd")))  // 2 of 3

        // "Process 2": rehydrate from the persisted windows. The count must
        // survive — one more request tips it over.
        let restored = await store.all()
        #expect(restored.first?.requestCount == 2)
        let t2 = SourceBudgetTracker(policies: policies, restoredWindows: restored, now: { clock })
        #expect(!(await t2.isPaused("freebmd")))
        await t2.recordRequest("freebmd")  // 3 → paused
        #expect(await t2.isPaused("freebmd"))
    }

    // MARK: - Budget-vs-throttle distinction (the load-bearing invariant)

    @Test func budgetExhaustedAvailabilityIsDistinctFromThrottled() {
        // The two must be different cases so the dispatcher/circuit-breaker can
        // tell "come back tomorrow" (no laddering) from "back off for seconds"
        // (ladder). Equality is the guard against a future refactor collapsing
        // them.
        let resume = Self.at("2026-07-13T00:00:00Z")
        let budget = SearchAvailability.budgetExhausted(resumeAt: resume)
        #expect(budget != .throttled)
        #expect(budget == .budgetExhausted(resumeAt: resume))
        // A budget-exhausted outcome is never a clean negative (emptiness is
        // meaningless), so it can't poison negative-evidence reasoning.
        let outcome = SearchOutcome(resultCount: 0, availability: budget)
        #expect(!outcome.isConclusive)
        #expect(!outcome.isCleanNegative)
    }
}
