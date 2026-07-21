import SwiftUI

/// Root of the detached "Record Review" window — the record review in its own
/// movable window, so the main window stays free for tree navigation and
/// profile cards while the user judges candidate records.
///
/// Owns a FRESH `ResearchViewModel` (never the main window's — sharing one vm
/// lets `reset()`/`runPipeline` in either window clobber the other, and the
/// shared vm's non-nil `currentResult` would hijack the main window's Triage
/// tab). Safe because every accept/discard persists to the project database at
/// click time; only unsaved session toggles are window-local.
///
/// PROJECT-IDENTITY GUARD (adversarial-review critical): the window binds to
/// the database captured at hydrate. If the main window switches or closes
/// the project, the `===` check in `body` flips this window to a placeholder
/// BEFORE any write path is reachable — a review popped out under project A
/// can never write into project B (GEDCOM string profile-IDs collide across
/// projects, so silent re-binding would be confident corruption). Re-binding
/// happens only on an explicit new pop-out (generation bump).
struct ReviewWindowRoot: View {
    let profileID: String

    @Environment(ReviewWindowBroker.self) private var broker
    @State private var vm = ResearchViewModel()

    private struct HydrationKey: Equatable {
        let profileID: String
        let generation: Int
    }

    var body: some View {
        Group {
            if let appState = broker.activeAppState {
                if let boundDB = vm.appDatabase {
                    if appState.currentDatabase === boundDB {
                        // Live rendering from the vm (not a one-shot copy):
                        // "Search nationally" re-runs show progress here and
                        // their results render on completion.
                        if vm.isResearching {
                            ResearchProgressView(vm: vm)
                                .environment(appState)
                        } else if let result = vm.currentResult {
                            ClusterReviewView(vm: vm, result: result, isDetachedWindow: true)
                                // The MAIN window's AppState: same database +
                                // snapshot; intents raised here (name clicks →
                                // tree) land in the main window's observers.
                                .environment(appState)
                        } else {
                            placeholder(
                                "No review to show",
                                "Pop a review out from Triage or the Research tab — or close this window.")
                        }
                    } else {
                        placeholder(
                            "Project changed",
                            "This review belonged to a different project. Close this window and reopen the review from Triage.")
                    }
                } else {
                    placeholder(
                        "No review loaded",
                        "Open a project in the main window, then pop a review out again.")
                }
            } else {
                placeholder(
                    "No main window",
                    "Open a main window with a project, then pop a review out again.")
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .navigationTitle(windowTitle)
        // Keyed on the broker's per-profile generation: a fresh pop-out for
        // this person re-fires hydration (consuming the new handoff) even
        // though macOS focused the existing window rather than making one.
        .task(id: HydrationKey(profileID: profileID, generation: broker.generation(for: profileID))) {
            hydrate()
        }
        // Launch-restore / opened-before-project: bind once a project becomes
        // available. Gated on never-bound (`vm.appDatabase == nil`) so a
        // later project SWITCH can never silently re-bind the window.
        .onChange(of: broker.activeAppState?.currentDatabase != nil) { _, ready in
            if ready && vm.appDatabase == nil { hydrate() }
        }
    }

    private func placeholder(_ title: String, _ message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(message)
        }
    }

    private var windowTitle: String {
        let name = broker.activeAppState?.snapshot.profiles[profileID]?.displayName
        return name.map { "Review: \($0)" } ?? "Record Review"
    }

    /// Set the VM quartet the review view needs (the same hydration the
    /// Triage drill-down performs), preferring the live handoff over disk
    /// reconstruction. No-op when the main window has no project open.
    private func hydrate() {
        guard let appState = broker.activeAppState,
              let db = appState.currentDatabase,
              let profile = appState.snapshot.profiles[profileID] else {
            return
        }
        vm.appDatabase = db
        vm.selectedProfile = profile
        vm.currentResult = broker.takeHandoff(profileID: profileID)
            ?? CampaignReviewService.reconstructResult(
                profileID: profileID, db: db, snapshot: appState.snapshot)
    }
}
