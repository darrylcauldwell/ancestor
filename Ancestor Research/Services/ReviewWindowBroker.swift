import SwiftUI

/// App-level bridge between a main window and the detached "Record Review"
/// window (owner request 2026-07-21: keep reviewing records while navigating
/// the tree — e.g. a thin subject like Mrs Bown, whose age/place must be
/// judged from her husband's and children's profiles).
///
/// Each main window deliberately owns its own `AppState` (M23 isolation), so
/// the review window must NOT create one — it shares the ORIGINATING window's
/// AppState: same database handle, same snapshot, and the same cross-surface
/// intents, so a name click in the review window drives the main window's
/// tree. This broker is the sanctioned handoff point: `ContentRoot` registers
/// its AppState here (and deregisters on window close), and the review scene
/// resolves it. With multiple main windows the most recently opened wins —
/// documented limitation; the common case is a single main window.
///
/// `handoff` carries the LIVE `ResearchResult` at pop-out time so the window
/// opens with full fidelity (household members included — the disk
/// reconstruction drops them). Take-once: `ResearchResult` is a value type,
/// so the window gets an independent copy and the main window's `vm.reset()`
/// cannot disturb it. When no handoff exists (window reopened later), the
/// window falls back to `CampaignReviewService.reconstructResult`.
@MainActor @Observable
final class ReviewWindowBroker {
    /// The AppState of the most recently registered main window. Weak: a
    /// closed window's state must not be kept alive by the broker
    /// (`ContentRoot` also deregisters explicitly on disappear so the
    /// change is observable, not just zeroed).
    weak var activeAppState: AppState?

    /// Live-result handoff keyed by profileID, set at pop-out.
    private var handoff: [String: ResearchResult] = [:]

    /// Monotonic per-profile stamp, bumped on every stage. The review
    /// window keys its hydration task on this, so re-popping a person whose
    /// window is ALREADY open re-fires hydration and consumes the fresh
    /// result instead of showing the stale one (macOS focuses the existing
    /// window for the same WindowGroup value — `.task(id:)` alone would
    /// never re-run).
    private(set) var generations: [String: Int] = [:]

    func generation(for profileID: String) -> Int {
        generations[profileID] ?? 0
    }

    func stageHandoff(profileID: String, result: ResearchResult) {
        handoff[profileID] = result
        generations[profileID, default: 0] += 1
    }

    /// Take-once: returns and removes the staged result.
    func takeHandoff(profileID: String) -> ResearchResult? {
        handoff.removeValue(forKey: profileID)
    }
}
