import SwiftUI

/// Sheet wrapper that opens the unified profile card straight into edit mode.
/// The tree-graph inspector edits in place via `ProfileDetailView`'s own
/// toggle, but a couple of external callsites (audit / tree-graph context
/// menu) still want a modal edit experience without first navigating to the
/// tree inspector. This wrapper preserves that affordance while keeping the
/// edit machinery and visual treatment unified.
struct EditPersonView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let profileID: String

    var body: some View {
        Group {
            if let profile = appState.snapshot.profiles[profileID] {
                ProfileDetailView(
                    profile: profile,
                    snapshot: appState.snapshot,
                    onClose: { dismiss() },
                    startInEditMode: true
                )
            } else {
                Text("Profile not found.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .frame(minWidth: 520, minHeight: 600)
        .padding(16)
    }
}
