import Foundation
import Observation
import AncestorKit

/// What's happening inside the pipeline / sources — surfaced to the UI so the
/// user sees per-source progress and a live activity feed instead of an opaque
/// spinner. Each event carries enough context for a meaningful one-line label
/// like "FreeBMD Belper births: Cauldwell" or "FreeBMD Derby marriages:
/// Cauldwell × Holmes".
nonisolated enum ResearchActivityEvent: Sendable {
    case sourceQueryStarted(sourceID: String, summary: String, strictness: SearchStrictness = .strict)
    case sourceQueryCompleted(sourceID: String, summary: String, resultCount: Int, strictness: SearchStrictness = .strict)
    case sourceError(sourceID: String, summary: String, reason: String, strictness: SearchStrictness = .strict)
    case pipelineStage(message: String)
    /// Per-run scorer attrition summary (ENGINE_FOUNDATION_SPEC
    /// #Change4). Published once per research run after the scorer
    /// settles. Lets the UI / eval harness see whether the brake is
    /// engaged at the periphery.
    case scorerAttrition(ScorerAttrition)

    /// A source's daily request quota is spent (ENGINE_FOUNDATION
    /// #Change5). The source is parked until `resumeAt` (its documented
    /// reset, else UTC midnight); the engine continues with the
    /// non-paused sources. Distinct from `sourceError(reason: "throttled")`
    /// — a budget exhaustion is NOT laddered with cool-down retries, it's
    /// a hard "come back tomorrow".
    case dailyBudgetExhausted(sourceID: String, resumeAt: Date)

    /// The dispatcher skipped a scoped source entirely for this run's
    /// (subject, scope) — e.g. anchor-less subject at a bounded scope
    /// (SOURCE_WEIGHTING Change 2). Informational, not an error: explains
    /// a coverage gap that would otherwise read as "source never ran".
    case sourceSkipped(sourceID: String, reason: String)

    /// Strictness tier this event was issued at. `.strict` for pipeline-stage
    /// events. Activity feed labels broadened tiers ("Cauldwell — phonetic")
    /// so the user can tell when the dispatcher has escalated.
    var strictness: SearchStrictness {
        switch self {
        case .sourceQueryStarted(_, _, let s):     return s
        case .sourceQueryCompleted(_, _, _, let s): return s
        case .sourceError(_, _, _, let s):         return s
        case .pipelineStage:                       return .strict
        case .scorerAttrition:                     return .strict
        case .dailyBudgetExhausted:                return .strict
        case .sourceSkipped:                       return .strict
        }
    }

    /// One-line human description for the activity feed. Non-strict tiers
    /// pick up a suffix so escalations are visible in the live feed.
    var description: String {
        let tierSuffix: String
        switch strictness {
        case .strict:  tierSuffix = ""
        case .loose:   tierSuffix = " (phonetic)"
        case .variant: tierSuffix = " (variant)"
        }
        switch self {
        case .sourceQueryStarted(_, let summary, _):
            return "\(summary)\(tierSuffix) — searching…"
        case .sourceQueryCompleted(_, let summary, let n, _):
            return "\(summary)\(tierSuffix) — \(n) result\(n == 1 ? "" : "s")"
        case .sourceError(_, let summary, let reason, _):
            return "\(summary)\(tierSuffix) — error: \(reason)"
        case .pipelineStage(let msg):
            return msg
        case .scorerAttrition(let a):
            return "Scorer: \(a.humanSummary)"
        case .dailyBudgetExhausted(let sourceID, let resumeAt):
            let fmt = DateFormatter()
            fmt.dateStyle = .none
            fmt.timeStyle = .short
            return "\(sourceID) — daily budget spent, resuming \(fmt.string(from: resumeAt))"
        case .sourceSkipped(let sourceID, let reason):
            return "\(sourceID) — skipped: \(reason)"
        }
    }
}

/// Shared event bus for research activity. Sources and the pipeline publish;
/// the view model subscribes to drive UI state during a research run.
///
/// Multiple concurrent subscribers each get their own AsyncStream via fan-out
/// — the bus retains a continuation per subscriber and broadcasts.
///
/// Cleanup: subscribers must cancel their iterator when done to free the slot.
actor ResearchActivityBus {
    static let shared = ResearchActivityBus()

    private var continuations: [UUID: AsyncStream<ResearchActivityEvent>.Continuation] = [:]

    /// Subscribe to all subsequent events. Caller iterates the returned stream.
    func subscribe() -> AsyncStream<ResearchActivityEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
        }
    }

    private func unsubscribe(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    /// Publish an event to all current subscribers. Non-throwing.
    func publish(_ event: ResearchActivityEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}
