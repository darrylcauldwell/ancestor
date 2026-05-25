import Foundation

/// Subscriber that drains `ResearchActivityBus` during one research run
/// and accumulates a compact per-query log for the eval envelope's
/// `_dispatch_log` field.
///
/// Why this exists (2026-05-24): the §5.8 parity report showed Ernest's
/// FreeBMD marriage (Q1 1915 Ashbourne, well within his home county's
/// district set) had zero records in `evidence_records` — the search
/// either never fired or returned 0 inexplicably. Without per-query
/// visibility a parity disagreement looks identical to a search-side
/// dispatch bug. Surfacing each query into the envelope lets the
/// harness comparison localise the gap to a specific (source,
/// strictness, summary) triple.
///
/// Bounded by `cap` to keep `result_json` reasonable — a `.all`-mode
/// full-corpus run can emit thousands of events. Drops further events
/// once the cap is reached; the harness sees a `_dispatch_log_capped`
/// marker when truncation happened so it doesn't quietly fail downstream
/// analysis.
actor DispatchLogCollector {

    /// One row per per-source-per-query event.
    nonisolated struct Entry: Sendable {
        enum Kind: String, Sendable {
            case started, completed, error
        }
        let sourceID: String
        let kind: Kind
        let summary: String
        let resultCount: Int?    // populated on .completed
        let errorReason: String? // populated on .error
    }

    private let cap: Int
    private var collected: [Entry] = []
    private var truncated = false

    init(cap: Int = 500) {
        self.cap = cap
    }

    func record(_ event: ResearchActivityEvent) {
        // Drop completion events once we've hit cap; keep accepting
        // errors (those are rarer and more diagnostic per row).
        if collected.count >= cap {
            if case .sourceError = event {
                // Allow errors through even after cap so the dispatch
                // log doesn't lose evidence of why things went wrong.
            } else {
                truncated = true
                return
            }
        }
        switch event {
        case .sourceQueryStarted:
            // Started events are noise once we have a completed
            // counterpart with the same summary — skip to save space.
            break
        case .sourceQueryCompleted(let sourceID, let summary, let n, _):
            collected.append(Entry(
                sourceID: sourceID,
                kind: .completed,
                summary: summary,
                resultCount: n,
                errorReason: nil
            ))
        case .sourceError(let sourceID, let summary, let reason, _):
            collected.append(Entry(
                sourceID: sourceID,
                kind: .error,
                summary: summary,
                resultCount: nil,
                errorReason: reason
            ))
        case .pipelineStage:
            break  // not source-scoped, not useful for dispatch analysis
        case .scorerAttrition:
            break  // aggregate stat, separate concern from dispatch log
        }
    }

    var entries: [Entry] {
        collected
    }

    var wasTruncated: Bool {
        truncated
    }
}
