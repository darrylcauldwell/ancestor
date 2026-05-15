import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedTab: SidebarTab

    /// Per DESIGN.md §7.7 + §7.16: progressive disclosure. The sidebar
    /// reveals tabs as the project earns them — Workbench on first note,
    /// Tasks once a manual project crosses the 5-profile threshold (always
    /// visible for imported projects), Sourcing once any citation exists.
    /// Tree, Triage, Leads, and Settings are always shown.
    private var visibleTabs: [SidebarTab] {
        SidebarTab.allCases.filter { tab in
            switch tab {
            case .tree, .triage, .leads, .settings:
                return true
            case .tasks:
                return appState.tasksTabVisible
            case .sourcing:
                return appState.sourcingTabVisible
            case .workbench:
                return appState.workbenchHasContent
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
        case .triage: "checklist.checked"
        case .workbench: "rectangle.grid.2x2"
        case .leads: "person.crop.circle.badge.questionmark"
        case .settings: "gear"
        }
    }
}
