import Foundation
import Observation

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

    /// Strictness tier this event was issued at. `.strict` for pipeline-stage
    /// events. Activity feed labels broadened tiers ("Cauldwell — phonetic")
    /// so the user can tell when the dispatcher has escalated.
    var strictness: SearchStrictness {
        switch self {
        case .sourceQueryStarted(_, _, let s):     return s
        case .sourceQueryCompleted(_, _, _, let s): return s
        case .sourceError(_, _, _, let s):         return s
        case .pipelineStage:                       return .strict
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
