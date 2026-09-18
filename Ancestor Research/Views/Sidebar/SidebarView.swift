import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedTab: SidebarTab

    /// By design: progressive disclosure. The sidebar reveals tabs as the
    /// project earns them — Tasks once a manual project crosses the
    /// 5-profile threshold (always visible for imported projects), Places
    /// and Sourcing on their own conditions. Tree, Health, Workbench and
    /// Settings are always shown: the Workbench carries the Attention
    /// router now the Research/Triage tabs are retired (SC-9; review
    /// happens on profile cards), so it can no longer be gated behind a
    /// first note.
    private var visibleTabs: [SidebarTab] {
        SidebarTab.allCases.filter { tab in
            switch tab {
            case .tree, .health, .settings:
                return true
            case .tasks:
                return appState.tasksTabVisible
            case .places:
                return appState.placesTabVisible
            case .sourcing:
                return appState.sourcingTabVisible
            case .workbench:
                return true
            }
        }
    }

    var body: some View {
        List(visibleTabs, id: \.self, selection: $selectedTab) { tab in
            Label(tab.label, systemImage: tab.systemImage)
        }
        .listStyle(.sidebar)
        // If the selected tab disappears (e.g. user dropped below the Tasks
        // threshold by deleting profiles), fall back to Tree.
        .onChange(of: visibleTabs) { _, tabs in
            if !tabs.contains(selectedTab) {
                selectedTab = .tree
            }
        }
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
        case .tasks: "checklist"
        case .sourcing: "checkmark.seal"
        case .places: "mappin.and.ellipse"
        case .health: "heart.text.square"
        case .workbench: "rectangle.grid.2x2"
        case .settings: "gear"
        }
    }
}
