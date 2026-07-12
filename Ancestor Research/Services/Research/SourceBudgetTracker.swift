import Foundation
import os
import AncestorKit

/// Tracks per-source daily request budgets across a sustained run
/// (ENGINE_FOUNDATION #Change5). The pure accounting lives in AncestorKit's
/// `SourceBudgetWindow` / `SourceBudgetPolicy`; this actor holds the live
/// windows, persists them so a spent budget survives a process restart
/// (§Change6), and answers the dispatcher's two questions:
///
///   1. `isPaused(sourceID:)` — should this source be skipped right now
///      because its daily quota is spent? (Checked before dispatch.)
///   2. `recordRequest(sourceID:)` — count one request that just fired, roll
///      the reset window if the day turned over, and emit
///      `DailyBudgetExhausted` the first time the ceiling is crossed.
///
/// **Budget vs. throttle.** A budget pause is a *hard* "come back tomorrow":
/// no cool-down laddering, no retrying. It is deliberately distinct from the
/// source-level 60s/300s/900s circuit breaker, which handles transient HTTP
/// 429s worth waiting out. The dispatcher parks a budget-paused source and
/// continues with the others — some progress beats none.
///
/// The clock and the persistence sink are injected so the acceptance tests
/// can drive quota exhaustion and cross-restart persistence deterministically
/// without a live database or a wall-clock wait.
actor SourceBudgetTracker {
    /// Per-source known policy (declarative, from `RecordSource.budgetPolicy`).
    private let policies: [String: SourceBudgetPolicy]
    /// Live per-source request windows, rehydrated from disk at init.
    private var windows: [String: SourceBudgetWindow]
    /// Source IDs we've already announced as exhausted this window — so we
    /// emit `DailyBudgetExhausted` exactly once per window, not per request.
    private var announcedExhausted: Set<String> = []

    /// Injected clock. Defaults to the real clock; tests pass a controllable one.
    private let now: @Sendable () -> Date
    /// Injected persistence sink. Defaults to a no-op (pure in-memory use in
    /// tests); the app wires it to `ProjectDatabase.saveSourceBudgetWindow`.
    private let persist: @Sendable (SourceBudgetWindow) -> Void
    /// Injected event emitter. Defaults to the shared research bus; tests can
    /// capture emissions.
    private let emit: @Sendable (String, Date) async -> Void

    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "SourceBudget")

    /// - Parameters:
    ///   - policies: source_id → known daily policy.
    ///   - restoredWindows: windows loaded from `source_budget_state` — the
    ///     count that survived the last process. Missing sources start fresh.
    ///   - now: clock injection (default: real clock).
    ///   - persist: called after every counted request (default: no-op).
    ///   - emit: called once per window when a source first exhausts
    ///     (default: publishes `.dailyBudgetExhausted` on the shared bus).
    init(
        policies: [String: SourceBudgetPolicy],
        restoredWindows: [SourceBudgetWindow] = [],
        now: @escaping @Sendable () -> Date = { Date() },
        persist: @escaping @Sendable (SourceBudgetWindow) -> Void = { _ in },
        emit: (@Sendable (String, Date) async -> Void)? = nil
    ) {
        self.policies = policies
        self.windows = Dictionary(uniqueKeysWithValues: restoredWindows.map { ($0.sourceID, $0) })
        self.now = now
        self.persist = persist
        self.emit = emit ?? { sourceID, resumeAt in
            await ResearchActivityBus.shared.publish(.dailyBudgetExhausted(sourceID: sourceID, resumeAt: resumeAt))
        }
    }

    // MARK: - Queries

    /// The current budget state of a source. Rolls the window forward against
    /// the live clock first, so a paused source automatically becomes
    /// available again once its reset passes — no separate un-pause step.
    func state(for sourceID: String) -> SourceBudgetState {
        let policy = policies[sourceID] ?? .unlimited
        let window = windows[sourceID] ?? SourceBudgetWindow(sourceID: sourceID, windowStart: now(), requestCount: 0)
        return window.state(policy: policy, now: now())
    }

    /// Whether this source must be skipped right now (daily budget spent).
    func isPaused(_ sourceID: String) -> Bool {
        state(for: sourceID).isPaused
    }

    /// When a paused source resumes, if paused. Queryable by the engine and
    /// the acceptance tests (#Change5 "resume time is queryable").
    func resumeAt(for sourceID: String) -> Date? {
        state(for: sourceID).resumeAt
    }

    /// Snapshot of every source that is currently paused, with its resume
    /// time. Used by callers that want to report the parked set.
    func pausedSources() -> [(sourceID: String, resumeAt: Date)] {
        policies.keys.compactMap { id in
            state(for: id).resumeAt.map { (sourceID: id, resumeAt: $0) }
        }
    }

    // MARK: - Mutations

    /// Count one request that just fired against `sourceID`. Rolls the reset
    /// window if the day turned over (a fresh window resets the announced-
    /// exhausted flag), persists the new count, and — the first time the
    /// ceiling is crossed this window — emits `DailyBudgetExhausted`.
    func recordRequest(_ sourceID: String) async {
        let policy = policies[sourceID] ?? .unlimited
        let current = windows[sourceID] ?? SourceBudgetWindow(sourceID: sourceID, windowStart: now(), requestCount: 0)

        // Detect a window roll so the once-per-window announcement re-arms.
        let rolled = current.rolledForward(policy: policy, now: now())
        if rolled.windowStart != current.windowStart {
            announcedExhausted.remove(sourceID)
        }

        let updated = current.incremented(policy: policy, now: now())
        windows[sourceID] = updated
        persist(updated)

        // Announce exhaustion exactly once per window, at the moment the count
        // reaches the ceiling.
        if case let .pausedUntilTomorrow(resumeAt) = updated.state(policy: policy, now: now()),
           !announcedExhausted.contains(sourceID) {
            announcedExhausted.insert(sourceID)
            logger.warning("Source \(sourceID, privacy: .public) daily budget exhausted — parking until \(resumeAt, privacy: .public); NOT laddering circuit breaker")
            await emit(sourceID, resumeAt)
        }
    }
}
