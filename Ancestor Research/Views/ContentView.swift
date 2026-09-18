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
        .alert("Sign in to FamilySearch", isPresented: .constant(appState.familySearchSignInPrompt)) {
            Button("Open Settings") {
                appState.familySearchSignInPrompt = false
                appState.requestSidebarTab = .settings
            }
            Button("Cancel", role: .cancel) { appState.familySearchSignInPrompt = false }
        } message: {
            Text("This action needs a FamilySearch sign-in. Open Settings ▸ FamilySearch to sign in, then try again.")
        }
        .alert("Success", isPresented: .constant(appState.successMessage != nil)) {
            // For fixes that add a research-unlocking field (married surname,
            // birth year), offer to research the just-updated profile right away
            // — the new anchor may surface death/probate/census evidence
            // (owner request 2026-07-25).
            if let researchID = appState.successResearchProfileID {
                Button("Research \(appState.snapshot.profiles[researchID]?.displayName ?? "profile")") {
                    appState.successMessage = nil
                    appState.successResearchProfileID = nil
                    appState.researchProfileID = researchID   // opens the mode/scope sheet
                }
            }
            Button("OK") {
                appState.successMessage = nil
                appState.successResearchProfileID = nil
            }
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

    private var importCleanseBinding: Binding<ImportCleanseReview?> {
        Binding(
            get: { appState.importCleanseReview },
            set: { if $0 == nil { appState.importCleanseReview = nil } }
        )
    }

    // Project onboarding Part A/B — extracted bindings + hooks keep the
    // MainView body under the SwiftUI type-checker's complexity ceiling.
    private var setupWizardBinding: Binding<Bool> {
        Binding(get: { appState.showSetupWizard }, set: { appState.showSetupWizard = $0 })
    }

    private var gettingStartedBinding: Binding<Bool> {
        Binding(get: { appState.showGettingStarted }, set: { appState.showGettingStarted = $0 })
    }

    private func onSetupWizardDismiss() {
        // If the wizard's end-of-setup "show me a quick tour" was left on,
        // open Getting Started AFTER the wizard closes (never two at once).
        if appState.pendingGettingStartedTour {
            appState.pendingGettingStartedTour = false
            appState.showGettingStarted = true
        }
    }

    private var resumableSessionBinding: Binding<Bool> {
        Binding(
            get: { appState.resumableSession != nil },
            set: { if !$0 { appState.dismissResumableSession() } }
        )
    }
    @State private var selectedTab: SidebarTab = {
        // Screenshot mode: jump directly to the requested screen
        if let screen = ScreenshotScreen.fromLaunchArguments() {
            switch screen {
            case .treePedigree, .treeDescendants: return .tree
            case .audit: return .tasks
            case .research: return .tree
            }
        }
        return .tree
    }()
    @State private var showingExporter = false
    @State private var showingReportPicker = false
    @State private var showingExportOptions = false
    /// WL5 — FamilySearch User Tree upload wizard (.sheet(item:) per
    /// the sheet(isPresented:) EmptyView race).
    @State private var fsUploadContext: FamilySearchUploadContext?
    /// User preference for the M14 sensitive-filter toggle, persisted
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
    /// SC-3 — a completed run's review opens in the detached record-review
    /// window (per-profile) instead of handing the user to the Triage tab.
    @Environment(ReviewWindowBroker.self) private var reviewWindowBroker
    @Environment(\.openWindow) private var openWindow

    /// In-situ research-progress sheet (Task #48). Driven by a stored flag
    /// rather than `researchVM.isResearching` so the sheet survives the brief
    /// moment after research completes — the user can still read the activity
    /// log and dismiss themselves. Presented after the config sheet dismisses,
    /// deferred by a tick so macOS doesn't drop the second `.sheet` call.
    @State private var showResearchProgress: Bool = false

    /// SC-consolidation follow-up (review C7) — a completed LEAD-investigation
    /// run's review session. Lead subjects aren't on the tree, so the detached
    /// record-review window (hydrated from a snapshot profile) can't host
    /// them; the review renders as a sheet over the main window's
    /// `researchVM`, whose `selectedLead` + `currentResult` the
    /// create-on-accept Apply path requires. `.sheet(item:)` per
    /// the sheet(isPresented:) EmptyView race.
    @State private var leadReviewSession: LeadReviewSession?

    private struct LeadReviewSession: Identifiable {
        let id = UUID()
        let leadName: String
    }

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
                UnifiedTasksView(
                    onOpenTriage: openTriage,
                    onOpenProfile: openProfileDetail
                )
            case .sourcing:
                SourcingIntegrityView()
            case .places:
                PlacesView(onOpenProfile: openProfileInEdit)
            case .health:
                HealthView(
                    onOpenProfile: openProfileDetail,
                    onEditProfile: openProfileInEdit
                )
            case .workbench:
                WorkbenchView(onOpenProfile: openProfileDetail)
            case .settings:
                SettingsPlaceholderView()
            }
        }
        .navigationTitle(appState.currentProject?.name ?? AppConstants.displayName)
        // Global keyboard shortcuts — the design Hidden buttons
        // register the shortcuts without taking up any visual space.
        .background { keyboardShortcutsLayer }
        .onAppear { appState.attachSearchRegistry(registry) }
        .toolbar {
            // Project onboarding Part B — re-openable Getting Started,
            // scrolled to the current tab. One insertion point in the shared
            // toolbar rather than a button in each view's (inconsistent) header.
            ToolbarItem {
                Button {
                    appState.showGettingStarted = true
                } label: {
                    Label("Getting Started", systemImage: "questionmark.circle")
                }
                .help("What is this area for? Open Getting Started")
            }
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
                    Divider()
                    Button("Upload Tree to FamilySearch…") {
                        guard let db = appState.currentDatabase else { return }
                        Task {
                            if await FamilySearchTokenStore.shared.validAccessToken(environment: .beta) != nil {
                                fsUploadContext = FamilySearchUploadContext(
                                    database: db,
                                    suggestedName: appState.currentProject?.name ?? "Family Tree")
                            } else {
                                appState.familySearchSignInPrompt = true
                            }
                        }
                    }
                    .disabled(appState.snapshot.profiles.isEmpty)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $fsUploadContext) { context in
            FamilySearchUploadSheet(model: FamilySearchUploadModel(
                database: context.database, suggestedName: context.suggestedName))
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
            defaultFilename: defaultGedcomFilename,
            onCompletion: handleExportResult
        )
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
        .onChange(of: appState.requestSidebarTab) { _, requested in
            // Cross-view tab navigation — e.g. a record-review "show on
            // tree" action. One-shot: consume and clear.
            guard let requested else { return }
            appState.requestSidebarTab = nil
            selectedTab = requested
        }
        .sheet(item: importCleanseBinding) { review in
            ImportCleanseSheet(review: review)
        }
        .sheet(item: researchConfigProfileBinding) { profile in
            ResearchConfigSheet(
                profile: profile,
                snapshot: appState.snapshot,
                focus: appState.researchConfigFocus,
                projectHomeChapmanCode: appState.currentProject?.resolvedHomeChapmanCode ?? ""
            ) { request in
                appState.researchConfigProfile = nil
                appState.researchConfigFocus = nil
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
                researchVM.runProseExtraction = request.runProseExtraction
                await researchVM.startResearch(
                    profile: profile,
                    snapshot: appState.snapshot,
                    registry: registry,
                    focus: request.focus
                )
            }
            researchVM.currentResearchTask = task
        }
        .onChange(of: appState.researchLeadRequest?.id) { _, _ in
            kickOffLeadResearch()
        }
        .sheet(isPresented: $showResearchProgress) {
            ResearchProgressSheet(
                vm: researchVM,
                onDismiss: handleResearchProgressDismiss,
                onOpenSettings: {
                    showResearchProgress = false
                    selectedTab = .settings
                }
            )
        }
        // C7 — the lead-review sheet. Renders the MAIN vm (not a fresh one):
        // the sheet's Apply buttons need `selectedLead` for the
        // create-on-accept promote, and lead evidence lives only on this vm
        // until then. Resetting on dismiss ends the session so a stale lead
        // identity can't leak into the next run.
        .sheet(item: $leadReviewSession, onDismiss: { researchVM.reset() }) { session in
            LeadReviewSheet(vm: researchVM, leadName: session.leadName)
        }
        .onChange(of: researchVM.isResearching) { wasRunning, isRunning in
            // C7 — a lead run finishing AFTER the progress sheet was closed
            // early would otherwise complete invisibly (lead evidence is
            // memory-only until promotion, unlike profile runs whose results
            // persist to the DB and land on the profile card).
            if wasRunning, !isRunning, !showResearchProgress, !researchVM.wasCancelled {
                presentLeadReviewIfRouted()
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
        ), onDismiss: {
            // Project onboarding Part A — after the manual family wizard
            // closes (built or skipped), offer the project setup wizard once.
            appState.offerSetupIfNeeded()
        }) {
            OnboardingWizardView()
        }
        // Project onboarding Part A — the project setup wizard (home
        // region now; local-AI later). Offered once per project by
        // offerSetupIfNeeded(), or re-run from Settings.
        .sheet(isPresented: setupWizardBinding, onDismiss: onSetupWizardDismiss) {
            ProjectSetupWizardView()
        }
        // Project onboarding Part B — the re-openable Getting Started
        // overview, scrolled to whichever tab is showing.
        .sheet(isPresented: gettingStartedBinding) {
            GettingStartedView(focusTab: selectedTab)
        }
        .sheet(isPresented: $showingReportPicker) {
            ReportPickerView()
        }
        // M8 W4 — surface the welcome-back prompt after openProject sets a
        // resumableSession. Continue reactivates the focus set (inside
        // SessionResumeView) but must NOT force-switch to the Workbench tab:
        // doing so on launch has dropped users into an empty Workbench with the
        // sidebar collapsed and no way back — a hard navigation dead-end (owner
        // report 2026-08-05, recurring). Stay on the working default (Tree); the
        // user opens the Workbench themselves (⌘4 / sidebar) when they want it.
        .sheet(isPresented: resumableSessionBinding) {
            if let resumable = appState.resumableSession {
                SessionResumeView(session: resumable) { }
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
    /// Extracted from the inline `.sheet(item:)` argument to keep the `body`
    /// modifier chain under the Swift type-checker's complexity limit — adding
    /// the Change 3b lead-research `.onChange` tipped an already-maxed body over.
    private var researchConfigProfileBinding: Binding<Profile?> {
        Binding(
            get: { appState.researchConfigProfile },
            set: {
                appState.researchConfigProfile = $0
                if $0 == nil { appState.researchConfigFocus = nil }
            }
        )
    }

    /// Progress-sheet dismiss routing — extracted from the inline closure so
    /// the large `body` expression stays under the type-checker's limit.
    /// SC-3 sends profile runs to the detached record-review window (the
    /// Triage tab is retired); C7 sends lead runs to the in-window review
    /// sheet. No result yet — run still going, or it produced nothing —
    /// means stay put: a profile run's outcome lands on the profile card
    /// (pending facts, leads) when it arrives, and a still-running lead run
    /// re-routes via the `isResearching` observer above when it completes.
    private func handleResearchProgressDismiss() {
        showResearchProgress = false
        switch researchVM.completedReviewRoute {
        case .profileWindow(let profileID):
            if let result = researchVM.currentResult {
                reviewWindowBroker.stageHandoff(profileID: profileID, result: result)
                openWindow(id: "record-review", value: profileID)
                researchVM.reset()
            }
        case .leadSheet:
            presentLeadReviewIfRouted()
        case .none:
            break
        }
    }

    /// C7 — present the lead-review sheet when the vm routes there. Deferred
    /// by a runloop tick for the same reason the config→progress handoff is:
    /// macOS silently drops a sheet presented while another is mid-dismiss.
    private func presentLeadReviewIfRouted() {
        guard researchVM.completedReviewRoute == .leadSheet,
              leadReviewSession == nil,
              let lead = researchVM.selectedLead else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            leadReviewSession = LeadReviewSession(leadName: lead.name)
        }
    }

    /// Change 3b — kick off research for a LEAD, mirroring the profile trigger.
    /// A lead has no tree profile yet, so there's no config sheet and no
    /// `persistProfileID`; discover-mode defaults drive the run. The result
    /// lands in `currentResult` exactly like profile research, and the
    /// progress sheet's "Review results" opens the lead-review sheet (C7),
    /// whose Apply buttons run the create-on-accept promote. Extracted from
    /// an inline `.onChange` closure so the large `body` expression stays
    /// under the type-checker's limit.
    private func kickOffLeadResearch() {
        guard let lead = appState.researchLeadRequest else { return }
        appState.researchLeadRequest = nil
        let task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            showResearchProgress = true
            researchVM.appDatabase = appState.currentDatabase
            researchVM.selectedMode = .discover
            researchVM.selectedScope = .county
            await researchVM.startResearch(
                lead: lead,
                snapshot: appState.snapshot,
                registry: registry
            )
        }
        researchVM.currentResearchTask = task
    }

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
            shortcutButton("3", modifiers: .command) { selectedTab = .workbench }
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

    /// Pre-computed to keep the file-exporter call out of SwiftUI's
    /// type-check budget (the in-line interpolation pushed body over
    /// the ceiling once focus plumbing landed).
    private var defaultGedcomFilename: String {
        let base = appState.currentProject?.name ?? "export"
        return "\(base).\(gedcomExportFormat.fileExtension)"
    }

    /// Pulled out of the body for the same type-check-budget reason.
    private func handleExportResult(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            appState.errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Tasks-row click handler — switches to the Tree tab and asks
    /// `TreeGraphView` to open the Full Detail sheet for the given
    /// profile via the `requestOpenProfileDetail` signal on AppState.
    /// Pairs with the double-click destination on the tree itself —
    /// both lands on the same Profile Detail surface.
    private func openProfileDetail(_ profileID: String) {
        selectedTab = .tree
        appState.requestOpenProfileDetail = profileID
    }

    /// Open a profile straight in the editor — used by Health findings so the
    /// user can jump from an issue to fixing it. Switches to the tree, opens the
    /// Full Detail, and fires the same edit intent as Cmd+E.
    private func openProfileInEdit(_ profileID: String) {
        selectedTab = .tree
        appState.requestOpenProfileDetail = profileID
        appState.selectedProfileID = profileID
        appState.pendingPersonAction = .editSelected(profileID: profileID)
    }

    /// Tasks' leads-pointer banner hands off here — with Triage retired
    /// (SC-9), the Workbench Attention router is the store-wide overview;
    /// review itself happens on profile cards.
    private func openTriage() {
        selectedTab = .workbench
    }
}

/// SC-consolidation follow-up (review C7) — host for a completed
/// lead-investigation run's review, replacing the render surface the retired
/// Triage tab provided. Lead subjects aren't on the tree, so
/// `ReviewWindowRoot` (a fresh vm hydrated from a snapshot profile) can't
/// host them; this sheet renders the MAIN window's vm — the only place
/// `selectedLead` and `currentResult` coexist — which `ClusterReviewView`'s
/// Apply → `materialiseLeadSubjectIfNeeded` → `promoteLeadToProfile`
/// create-on-accept path requires. Evidence persists under the
/// matched-or-created profile at that moment; nothing is written before the
/// human accepts (leads never apply automatically).
struct LeadReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var vm: ResearchViewModel
    let leadName: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Lead findings: \(leadName)")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if let result = vm.currentResult {
                // isDetachedWindow hides the "New Research" reset — Close is
                // the only exit here too; the presenter resets on dismiss.
                ClusterReviewView(vm: vm, result: result, isDetachedWindow: true)
            } else {
                ContentUnavailableView(
                    "No findings to review",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("This lead's research run produced no reviewable records."))
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

nonisolated enum SidebarTab: String, CaseIterable {
    case tree = "Tree"
    case tasks = "Tasks"
    case sourcing = "Sourcing"
    /// Places: the location gazetteer — every distinct place string the tree
    /// uses, scored for how confidently it maps to a registration district, so
    /// a human settles what the data cannot. Deliberately NOT a Health audit
    /// (owner direction 2026-08-17): an audit reports a rule's verdict on the
    /// subset the app judges worth raising, and the app's judgement about which
    /// places are settled is the thing that was wrong.
    case places = "Places"
    /// Health: the data-quality home — audit findings (cruft, impossibilities,
    /// duplicates, suspect locations, gaps), the completeness/evidenced summary,
    /// and the entry into Cleanse. Distinct from Tasks (the research worklist):
    /// Health answers "is my data wrong/dirty?", Tasks answers "what next?".
    case health = "Health"
    case workbench = "Workbench"
    case settings = "Settings"
}

/// Tiny pre-export sheet (M14). Surfaces the "exclude sensitive"
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
