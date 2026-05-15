import Foundation
import Observation

/// What's happening inside the pipeline / sources — surfaced to the UI so the
/// user sees per-source progress and a live activity feed instead of an opaque
/// spinner. Each event carries enough context for a meaningful one-line label
/// like "FreeBMD Belper births: Cauldwell" or "FreeBMD Derby marriages:
/// Cauldwell × Holmes".
nonisolated enum ResearchActivityEvent: Sendable {
    case sourceQueryStarted(sourceID: String, summary: String)
    case sourceQueryCompleted(sourceID: String, summary: String, resultCount: Int)
    case sourceError(sourceID: String, summary: String, reason: String)
    case pipelineStage(message: String)

    /// One-line human description for the activity feed.
    var description: String {
        switch self {
        case .sourceQueryStarted(_, let summary):
            return "\(summary) — searching…"
        case .sourceQueryCompleted(_, let summary, let n):
            return "\(summary) — \(n) result\(n == 1 ? "" : "s")"
        case .sourceError(_, let summary, let reason):
            return "\(summary) — error: \(reason)"
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
