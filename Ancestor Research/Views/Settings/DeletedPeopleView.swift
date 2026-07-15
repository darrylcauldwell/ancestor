import SwiftUI

/// List of soft-deleted profiles with one-tap restore plus M14
/// "Permanently remove". Soft-deleted profiles still live in the database
/// (`is_deleted = 1`) and are loaded directly from
/// `ProjectDatabase.loadDeletedProfiles()` since the in-memory snapshot
/// filters them out.
struct DeletedPeopleView: View {
    @Environment(AppState.self) private var appState
    @State private var deleted: [Profile] = []
    /// Profile pending hard-delete confirmation. Non-nil drives the alert.
    @State private var pendingHardDelete: Profile?

    var body: some View {
        Group {
            if deleted.isEmpty {
                Text("No deleted people.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(deleted) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(AppTypography.cardBody)
                            if let year = profile.birthDate?.bestYear {
                                Text("b. \(String(year))")
                                    .font(AppTypography.cardMeta)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button("Restore") {
                            appState.restoreDeletedProfile(id: profile.id)
                            reload()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        Button(role: .destructive) {
                            pendingHardDelete = profile
                        } label: {
                            Text("Permanently remove")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .tint(.red)
                    }
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: appState.snapshot.profiles.count) { reload() }
        .alert(
            "Permanently remove?",
            isPresented: Binding(
                get: { pendingHardDelete != nil },
                set: { if !$0 { pendingHardDelete = nil } }
            ),
            presenting: pendingHardDelete
        ) { profile in
            Button("Cancel", role: .cancel) {
                pendingHardDelete = nil
            }
            Button("Delete", role: .destructive) {
                appState.hardDeleteProfile(id: profile.id)
                pendingHardDelete = nil
                reload()
            }
        } message: { _ in
            Text("This deletes the profile and all its life events, attachments, sources, and notes. This cannot be undone.")
        }
    }

    private func reload() {
        guard let db = appState.currentDatabase else {
            deleted = []
            return
        }
        deleted = (try? db.loadDeletedProfiles()) ?? []
    }
}
