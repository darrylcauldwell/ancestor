import UniformTypeIdentifiers
import SwiftUI
import AppKit

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
            case .audit: return .tasks
            case .research: return .triage
            }
        }
        return .tree
    }()
    @State private var showingExporter = false
    @State private var showingReportPicker = false
    @State private var showingExportOptions = false
    /// User preference for the M14 §7.15.2 sensitive-filter toggle, persisted
    /// across launches via AppStorage so repeat exports remember the choice.
    @AppStorage("excludeSensitiveOnExport") private var excludeSensitiveOnExport: Bool = false
    @AppStorage("gedcomExportFormat") private var gedcomExportFormatRaw: String = GEDCOMFormat.v5_5_1.rawValue
    /// ResearchViewModel lives at the top level so a research run can be started
    /// from any tab (profile detail sheet, tree popover, etc.) and the pipeline
    /// keeps running while the user navigates elsewhere. Previously it was
    /// owned by ResearchView, which meant the trigger only fired when that tab
    /// was visible — forcing a tab switch on every research start.
    @State private var researchVM = ResearchViewModel()
    @Environment(SourceRegistry.self) private var registry

    /// In-situ research-progress sheet (Task #48). Driven by a stored flag
    /// rather than `researchVM.isResearching` so the sheet survives the brief
    /// moment after research completes — the user can still read the activity
    /// log and dismiss themselves. Presented after the config sheet dismisses,
    /// deferred by a tick so macOS doesn't drop the second `.sheet` call.
    @State private var showResearchProgress: Bool = false

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
            case .tasks:
                UnifiedTasksView(onResearchLead: researchLead)
            case .sourcing:
                SourcingIntegrityView()
            case .triage:
                ResearchView(researchVM: researchVM)
            case .workbench:
                WorkbenchView()
            case .settings:
                SettingsPlaceholderView()
            }
        }
        .navigationTitle(appState.currentProject?.name ?? AppConstants.displayName)
        // Global keyboard shortcuts — DESIGN.md §7.10.1. Hidden buttons
        // register the shortcuts without taking up any visual space.
        .background { keyboardShortcutsLayer }
        .onAppear { appState.attachSearchRegistry(registry) }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Export GEDCOM...") {
                        showingExportOptions = true
                    }
                    .disabled(appState.snapshot.profiles.isEmpty)
                    Button("Generate report...") {
                        showingReportPicker = true
                    }
                    .disabled(appState.snapshot.profiles.isEmpty)
                    Button("Export to HTML...") {
                        presentHTMLExport()
                    }
                    .disabled(appState.snapshot.profiles.isEmpty)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingExportOptions) {
            GEDCOMExportOptionsSheet(
                excludeSensitive: $excludeSensitiveOnExport,
                format: Binding(
                    get: { GEDCOMFormat(rawValue: gedcomExportFormatRaw) ?? .v5_5_1 },
                    set: { gedcomExportFormatRaw = $0.rawValue }
                ),
                onExport: {
                    showingExportOptions = false
                    showingExporter = true
                }
            )
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: gedcomDocument,
            contentType: gedcomExportFormat.contentType,
            defaultFilename: "\(appState.currentProject?.name ?? "export").\(gedcomExportFormat.fileExtension)"
        ) { result in
            if case .failure(let error) = result {
                appState.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        .onChange(of: appState.researchProfileID) { _, newID in
            // Now treated as "open the research config sheet for this profile"
            // — every research trigger flows through the mode/scope picker so
            // settings travel with each run instead of relying on stale global
            // state on the Research tab.
            guard let newID,
                  let profile = appState.snapshot.profiles[newID] else { return }
            appState.researchProfileID = nil
            appState.researchConfigProfile = profile
        }
        .sheet(item: Binding(
            get: { appState.researchConfigProfile },
            set: { appState.researchConfigProfile = $0 }
        )) { profile in
            ResearchConfigSheet(profile: profile, snapshot: appState.snapshot) { request in
                appState.researchConfigProfile = nil
                appState.researchRequest = request
            }
        }
        .onChange(of: appState.researchRequest?.profileID) { _, _ in
            // Profile-contextual trigger: applies mode/scope from the request
            // and kicks off the pipeline. Surface progress in-situ via the
            // research-progress sheet so the user sees their click did
            // something — previously the run was silent until they navigated
            // to the Research tab.
            guard let request = appState.researchRequest,
                  let profile = appState.snapshot.profiles[request.profileID] else { return }
            appState.researchRequest = nil
            let task = Task { @MainActor in
                // Wait one runloop tick so the config sheet's dismiss
                // animation completes before we present the progress sheet —
                // macOS otherwise silently drops the second `.sheet` call.
                try? await Task.sleep(for: .milliseconds(200))
                showResearchProgress = true
                researchVM.appDatabase = appState.currentDatabase
                researchVM.selectedMode = request.mode
                researchVM.selectedScope = request.scope
                await researchVM.startResearch(
                    profile: profile,
                    snapshot: appState.snapshot,
                    registry: registry
                )
            }
            researchVM.currentResearchTask = task
        }
        .sheet(isPresented: $showResearchProgress) {
            ResearchProgressSheet(vm: researchVM) {
                showResearchProgress = false
                // Hand the user off to the Triage tab so they can act on
                // any clusters / leads the run produced (or watch it finish
                // if they closed early while it was still running).
                selectedTab = .triage
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
        .sheet(isPresented: Binding(
            get: { appState.showOnboardingWizard },
            set: { appState.showOnboardingWizard = $0 }
        )) {
            OnboardingWizardView()
        }
        .sheet(isPresented: $showingReportPicker) {
            ReportPickerView()
        }
        // M8 W4 — surface the welcome-back prompt after openProject sets a
        // resumableSession. Continue activates the focus set and switches
        // the sidebar to the Workbench view.
        .sheet(isPresented: Binding(
            get: { appState.resumableSession != nil },
            set: { if !$0 { appState.dismissResumableSession() } }
        )) {
            if let resumable = appState.resumableSession {
                SessionResumeView(session: resumable) {
                    if appState.workbenchHasContent {
                        selectedTab = .workbench
                    }
                }
            }
        }
        .alert("Welcome", isPresented: Binding(
            get: { appState.onboardingCompletionMessage != nil },
            set: { if !$0 { appState.onboardingCompletionMessage = nil } }
        )) {
            Button("Continue") { appState.onboardingCompletionMessage = nil }
            Button("Undo wizard", role: .destructive) {
                appState.undoLastTransaction()
                appState.onboardingCompletionMessage = nil
            }
        } message: {
            Text(appState.onboardingCompletionMessage ?? "")
        }
    }

    /// Resolved format from the persisted AppStorage string. Falls back to
    /// 5.5.1 if the persisted value somehow doesn't decode (e.g. user
    /// downgraded the app and an older case is unknown).
    private var gedcomExportFormat: GEDCOMFormat {
        GEDCOMFormat(rawValue: gedcomExportFormatRaw) ?? .v5_5_1
    }

    /// Build the GEDCOM document on demand so toggling `excludeSensitive`
    /// or changing format in the options sheet is honoured by the very
    /// next export. The document is recomputed when the .fileExporter is
    /// presented.
    private var gedcomDocument: GEDCOMDocument {
        if let db = appState.currentDatabase {
            return GEDCOMDocument(
                snapshot: appState.snapshot,
                db: db,
                projectID: appState.currentProject?.id,
                excludeSensitive: excludeSensitiveOnExport,
                format: gedcomExportFormat
            )
        }
        return GEDCOMDocument(snapshot: appState.snapshot)
    }

    /// M21 — show a directory picker, then write the static HTML bundle to
    /// the chosen folder. Sensitive life events follow the existing
    /// "Exclude sensitive items" preference; the index always omits living
    /// people (privacy default for shared exports).
    private func presentHTMLExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.title = "Choose a folder for the HTML export"
        panel.prompt = "Export"
        if panel.runModal() == .OK, let url = panel.url {
            appState.exportHTML(
                to: url,
                excludeLiving: true,
                excludeSensitive: excludeSensitiveOnExport
            )
        }
    }

    /// Bundle of zero-size Buttons that register global keyboard shortcuts.
    /// Hidden via opacity + frame so they don't affect layout. Placed in a
    /// `.background` modifier so they live alongside the chrome but never
    /// obscure user-visible content.
    private var keyboardShortcutsLayer: some View {
        ZStack {
            // Sidebar tab switching: Cmd+1 ... Cmd+5
            shortcutButton("1", modifiers: .command) { selectedTab = .tree }
            shortcutButton("2", modifiers: .command) { selectedTab = .tasks }
            shortcutButton("3", modifiers: .command) { selectedTab = .triage }
            shortcutButton("4", modifiers: .command) {
                if appState.workbenchHasContent { selectedTab = .workbench }
            }
            shortcutButton("5", modifiers: .command) { selectedTab = .settings }

            // Cmd+Z undo / Cmd+Shift+Z redo (redo is structurally undo's
            // inverse — single-step for now; full redo stack ships with M14).
            shortcutButton("z", modifiers: .command) {
                appState.undoLastTransaction()
            }
            shortcutButton("z", modifiers: [.command, .shift]) {
                // Redo placeholder — same handler today; tracked for M14.
                appState.undoLastTransaction()
            }

            // Cmd+Shift+W toggles the active focus filter on the tree.
            shortcutButton("w", modifiers: [.command, .shift]) {
                appState.focusFilterEnabled.toggle()
            }

            // M16.9 — promote the per-tree shortcuts to the global layer so
            // Cmd+N / Cmd+Shift+N / Cmd+E work from any sidebar tab. Each
            // shortcut activates the tree (so the user can see the result of
            // an Add) and routes the action through AppState; TreeGraphView
            // observes `pendingPersonAction` and presents the matching sheet.
            shortcutButton("n", modifiers: .command) {
                selectedTab = .tree
                appState.requestAddPerson()
            }
            shortcutButton("n", modifiers: [.command, .shift]) {
                selectedTab = .tree
                appState.requestAddFamily()
            }
            shortcutButton("e", modifiers: .command) {
                guard appState.selectedProfileID != nil else { return }
                selectedTab = .tree
                appState.requestEditSelectedPerson()
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func shortcutButton(
        _ key: KeyEquivalent,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(key, modifiers: modifiers)
    }

    /// Shared "research this lead" handler — invoked from Task rows in
    /// `UnifiedTasksView`. Flips the progress sheet on, attaches the
    /// current database, and kicks off the pipeline.
    private func researchLead(_ lead: Lead) {
        Task { @MainActor in
            showResearchProgress = true
            researchVM.appDatabase = appState.currentDatabase
            await researchVM.startResearch(
                lead: lead,
                snapshot: appState.snapshot,
                registry: registry
            )
        }
    }
}

nonisolated enum SidebarTab: String, CaseIterable {
    case tree = "Tree"
    case tasks = "Tasks"
    case sourcing = "Sourcing"
    /// Triage: review cluster matches / leads from a research run, accept or
    /// defer them. Research itself is now triggered profile-contextually from
    /// the tree popover — this tab is where the results land for the user to
    /// act on, not where runs are kicked off.
    case triage = "Triage"
    case workbench = "Workbench"
    case settings = "Settings"
}

/// Tiny pre-export sheet (M14 §7.15.2). Surfaces the "exclude sensitive"
/// toggle to the user before the file picker so the choice is explicit.
/// The toggle is bound to AppStorage so the preference persists across
/// runs — repeat exports remember the last setting.
struct GEDCOMExportOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var excludeSensitive: Bool
    @Binding var format: GEDCOMFormat
    let onExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export GEDCOM")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Picker("Format", selection: $format) {
                    ForEach(GEDCOMFormat.allCases, id: \.self) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.menu)
                Text(formatExplanation)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Exclude sensitive items", isOn: $excludeSensitive)
                Text("When enabled, attachments tied to life events you've marked sensitive are dropped from the exported file. The file you keep on this Mac is unaffected.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Export...") { onExport() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 280)
    }

    private var formatExplanation: String {
        switch format {
        case .v5_5_1:
            return "Most compatible. Ancestry, MyHeritage, and FamilySearch importers expect 5.5.1."
        case .v7_0:
            return "Cleaner tag semantics; UTF-8 mandatory. Adoption in third-party tools is still growing."
        case .gedZip_7_0:
            return "GEDCOM 7.0 bundled with attached media into a single .gdz archive — useful for handing off everything together."
        }
    }
}
