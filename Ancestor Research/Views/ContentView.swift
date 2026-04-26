import UniformTypeIdentifiers
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.currentProject != nil {
                MainView()
            } else {
                ProjectPickerView()
            }
        }
        .alert("Error", isPresented: .constant(appState.errorMessage != nil)) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .alert("Success", isPresented: .constant(appState.successMessage != nil)) {
            Button("OK") { appState.successMessage = nil }
        } message: {
            Text(appState.successMessage ?? "")
        }
        .overlay {
            if appState.isLoading {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        if let message = appState.loadingMessage {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }
            }
        }
    }
}

/// Main app view shown when a project is open.
struct MainView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: SidebarTab = {
        // Screenshot mode: jump directly to the requested screen
        if let screen = ScreenshotScreen.fromLaunchArguments() {
            switch screen {
            case .treePedigree, .treeDescendants: return .tree
            case .audit: return .audit
            case .research: return .research
            }
        }
        return .tree
    }()
    @State private var showingExporter = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab)
        } detail: {
            switch selectedTab {
            case .tree:
                if appState.snapshot.profiles.isEmpty {
                    TreePlaceholderView()
                } else {
                    TreeGraphView()
                }
            case .audit:
                AuditPlaceholderView()
            case .research:
                ResearchView()
            case .leads:
                LeadListView()
            case .settings:
                SettingsPlaceholderView()
            }
        }
        .navigationTitle(appState.currentProject?.name ?? AppConstants.displayName)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Export GEDCOM...") {
                        showingExporter = true
                    }
                    .disabled(appState.snapshot.profiles.isEmpty)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: GEDCOMDocument(snapshot: appState.snapshot),
            contentType: .init(filenameExtension: "ged") ?? .plainText,
            defaultFilename: "\(appState.currentProject?.name ?? "export").ged"
        ) { result in
            if case .failure(let error) = result {
                appState.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        .onChange(of: appState.researchProfileID) { _, newID in
            if newID != nil {
                selectedTab = .research
            }
        }
        .sheet(isPresented: .init(
            get: { appState.pendingDiff != nil },
            set: { if !$0 { appState.rejectPendingDiff() } }
        )) {
            if let diff = appState.pendingDiff {
                TreeDiffView(diff: diff)
            }
        }
    }
}

nonisolated enum SidebarTab: String, CaseIterable {
    case tree = "Tree"
    case audit = "Audit"
    case research = "Research"
    case leads = "Leads"
    case settings = "Settings"
}
