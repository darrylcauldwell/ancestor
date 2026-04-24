import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedTab: SidebarTab

    var body: some View {
        List(SidebarTab.allCases, id: \.self, selection: $selectedTab) { tab in
            Label(tab.label, systemImage: tab.systemImage)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                let count = appState.snapshot.profiles.count
                let relCount = appState.snapshot.relationships.count
                Text("\(count) profiles, \(relCount) relationships")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let refreshed = appState.currentProject?.lastRefreshed {
                    Text("Refreshed \(refreshed, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    appState.closeProject()
                } label: {
                    Label("Close Project", systemImage: "xmark.circle")
                }
            }
        }
    }
}

nonisolated extension SidebarTab {
    var label: String { rawValue }

    var systemImage: String {
        switch self {
        case .tree: "person.3"
        case .audit: "checkmark.shield"
        case .gaps: "exclamationmark.triangle"
        case .settings: "gear"
        }
    }
}
