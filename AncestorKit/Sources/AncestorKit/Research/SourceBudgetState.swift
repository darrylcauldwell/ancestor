import Foundation

// MARK: - Daily-budget awareness (ENGINE_FOUNDATION #Change5)

/// A source's known daily request budget and the moment its counter resets.
///
/// Volunteer-run sources (FreeBMD, FreeCen, FreeREG, Wirksworth) treat a
/// sustained run as a DoS and enforce a daily ceiling. Today, when that
/// ceiling is hit, the source returns HTTP 429 and the circuit breaker
/// ladders 60s/300s/900s waits — burning ~21 minutes of wall-clock with zero
/// progress before giving up for the process (memory:
/// `reference_freebmd_circuit_breaker.md`,
/// `feedback_volunteer_sources_rate_limits.md`).
///
/// This type makes the daily ceiling EXPLICIT so the engine can distinguish
/// a spent daily budget (park until tomorrow, no laddering) from a transient
/// throttle (short cool-down, worth waiting out). It is a pure value type —
/// the count-and-persist mechanics live in the app-side `SourceBudgetTracker`
/// so this stays testable without a database.
public nonisolated struct SourceBudgetPolicy: Sendable, Equatable {
    /// Maximum requests we permit against the source per reset window.
    /// `nil` means "no known daily ceiling" — the source is never budget-paused.
    public let dailyLimit: Int?

    /// When the daily counter resets. `.utcMidnight` is the conservative
    /// default; a source with a documented reset (a fixed clock hour in some
    /// timezone) carries `.dailyAt`.
    public let reset: ResetSchedule

    public init(dailyLimit: Int?, reset: ResetSchedule = .utcMidnight) {
        self.dailyLimit = dailyLimit
        self.reset = reset
    }

    /// A source with no known daily ceiling — never budget-paused.
    public static let unlimited = SourceBudgetPolicy(dailyLimit: nil, reset: .utcMidnight)

    /// When the counter that started at `windowStart` next resets, given a
    /// reference `now`. Pure — a clock is passed in so this is deterministic
    /// under test (inject a fixed `now`).
    public func nextReset(after now: Date, calendar: Calendar = .utc) -> Date {
        reset.nextReset(after: now, calendar: calendar)
    }
}

/// When a source's daily request counter resets.
public nonisolated enum ResetSchedule: Sendable, Equatable {
    /// Reset at 00:00 UTC — the conservative fallback for any source whose
    /// documented reset time we don't know.
    case utcMidnight
    /// Reset every day at a fixed hour in a fixed timezone (the source's
    /// documented reset). `hour` is 0–23.
    case dailyAt(hour: Int, timeZoneIdentifier: String)

    /// The first reset instant strictly after `now`. Used to compute the
    /// `resumeAt` a budget-paused source carries.
    public func nextReset(after now: Date, calendar: Calendar = .utc) -> Date {
        switch self {
        case .utcMidnight:
            var cal = calendar
            cal.timeZone = TimeZone(identifier: "UTC")!
            let startOfDay = cal.startOfDay(for: now)
            // Strictly-after: if `now` is exactly midnight the next reset is
            // tomorrow, never "right now" (would let a spent budget resume
            // instantly).
            return cal.date(byAdding: .day, value: 1, to: startOfDay) ?? now.addingTimeInterval(86_400)
        case let .dailyAt(hour, tzID):
            var cal = calendar
            cal.timeZone = TimeZone(identifier: tzID) ?? TimeZone(identifier: "UTC")!
            let clampedHour = max(0, min(23, hour))
            let today = cal.startOfDay(for: now)
            let candidate = cal.date(bySettingHour: clampedHour, minute: 0, second: 0, of: today) ?? today
            if candidate > now { return candidate }
            return cal.date(byAdding: .day, value: 1, to: candidate) ?? now.addingTimeInterval(86_400)
        }
    }
}

/// The live budget state of one source, computed from its persisted request
/// count within the current reset window.
///
/// The `.pausedUntilTomorrow` case is the load-bearing distinction from a
/// transient throttle: it carries a concrete `resumeAt` (queryable by the
/// engine and the acceptance tests) and explicitly tells the dispatcher NOT
/// to ladder cool-downs — the source is out of budget, not merely busy.
public nonisolated enum SourceBudgetState: Sendable, Equatable {
    /// The source has budget remaining (or has no known daily ceiling).
    /// `remaining == nil` for unlimited sources.
    case available(remaining: Int?)
    /// The source's daily quota is spent; it will not be dispatched again
    /// until `resumeAt`.
    case pausedUntilTomorrow(resumeAt: Date)

    /// True when the source must not receive live dispatch right now.
    public var isPaused: Bool {
        if case .pausedUntilTomorrow = self { return true }
        return false
    }

    /// The moment the source resumes, if it is paused.
    public var resumeAt: Date? {
        if case let .pausedUntilTomorrow(at) = self { return at }
        return nil
    }
}

/// One source's request count within its current reset window. The pure
/// accounting kernel — increment on each dispatched request, ask whether the
/// budget is spent, and roll the window when the reset passes. Persisted by
/// the app-side tracker so counters survive a process restart
/// (ENGINE_FOUNDATION #Change5 → #Change6).
public nonisolated struct SourceBudgetWindow: Sendable, Equatable {
    public let sourceID: String
    /// Start of the reset window this count belongs to. Requests are counted
    /// against the window that was open when they fired.
    public var windowStart: Date
    /// Requests fired against the source within `windowStart..<nextReset`.
    public var requestCount: Int

    public init(sourceID: String, windowStart: Date, requestCount: Int) {
        self.sourceID = sourceID
        self.windowStart = windowStart
        self.requestCount = requestCount
    }

    /// The budget state given a policy and a reference `now`. Rolls the
    /// window first (a stale count from a prior day is a fresh 0), then
    /// compares against the daily limit. Pure — inject `now` under test.
    public func state(policy: SourceBudgetPolicy, now: Date) -> SourceBudgetState {
        let rolled = rolledForward(policy: policy, now: now)
        guard let limit = policy.dailyLimit else { return .available(remaining: nil) }
        if rolled.requestCount >= limit {
            return .pausedUntilTomorrow(resumeAt: policy.nextReset(after: now))
        }
        return .available(remaining: max(0, limit - rolled.requestCount))
    }

    /// A window rolled forward to the current reset period: if `now` is past
    /// this window's reset, the count is zeroed and the window re-anchored at
    /// the reset boundary. Otherwise unchanged. Idempotent.
    public func rolledForward(policy: SourceBudgetPolicy, now: Date) -> SourceBudgetWindow {
        let reset = policy.nextReset(after: windowStart)
        guard now >= reset else { return self }
        // The window that contains `now`. Anchoring at the reset boundary
        // (not at `now`) keeps the count aligned to the source's clock.
        return SourceBudgetWindow(sourceID: sourceID, windowStart: reset, requestCount: 0)
    }

    /// This window with one more request counted, after rolling forward.
    public func incremented(policy: SourceBudgetPolicy, now: Date) -> SourceBudgetWindow {
        var rolled = rolledForward(policy: policy, now: now)
        rolled.requestCount += 1
        return rolled
    }
}

// MARK: - Convenience

public extension Calendar {
    /// A UTC-anchored Gregorian calendar for deterministic reset math.
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}
