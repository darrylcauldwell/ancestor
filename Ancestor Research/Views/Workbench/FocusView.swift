import SwiftUI

/// List of focus sets, with an "active" indicator. Selecting a focus set
/// makes it active (and bumps its lastActiveAt). Per-row buttons rename
/// or delete. The Tree's "Focus only" toggle reads from the active set.
struct FocusView: View {
    @Environment(AppState.self) private var appState
    @State private var showingComposer: Bool = false
    @State private var editing: FocusSet?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if appState.focusSets.isEmpty {
                ContentUnavailableView(
                    "No focus sets",
                    systemImage: "scope",
                    description: Text("Group profiles you're investigating right now. The Tree gains a 'Focus only' filter that hides the rest.")
                )
            } else {
                List {
                    ForEach(appState.focusSets) { set in
                        Button {
                            appState.setActiveFocusSet(id: set.id)
                        } label: {
                            row(for: set)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename / edit") { editing = set }
                            Button("Make active") { appState.setActiveFocusSet(id: set.id) }
                                .disabled(set.id == appState.activeFocusSetID)
                            Divider()
                            Button("Delete", role: .destructive) {
                                appState.deleteFocusSet(id: set.id)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingComposer) {
            FocusComposerView(initial: nil)
        }
        .sheet(item: $editing) { set in
            FocusComposerView(initial: set)
        }
    }

    private var header: some View {
        HStack {
            Text("\(appState.focusSets.count) focus sets")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showingComposer = true
            } label: {
                Label("New focus", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func row(for set: FocusSet) -> some View {
        let isActive = set.id == appState.activeFocusSetID
        return HStack(spacing: 8) {
            Image(systemName: isActive ? "scope" : "circle")
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(isActive ? "Active focus set" : "Inactive focus set")
            VStack(alignment: .leading, spacing: 2) {
                Text(set.displayTitle)
                    .font(AppTypography.cardBody.weight(isActive ? .semibold : .regular))
                Text(profileSummary(set))
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(set.lastActiveAt, style: .relative)
                .font(AppTypography.cardMeta)
                .foregroundStyle(.tertiary)
        }
    }

    private func profileSummary(_ set: FocusSet) -> String {
        let names = set.profileIDs
            .compactMap { appState.snapshot.profiles[$0]?.displayName }
            .prefix(3)
        let suffix = set.profileIDs.count > 3 ? " +\(set.profileIDs.count - 3) more" : ""
        if names.isEmpty {
            return "No profiles yet"
        }
        return names.joined(separator: ", ") + suffix
    }
}
