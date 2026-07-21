import SwiftUI
import UniformTypeIdentifiers

/// Settings view with WikiTree connection and project info.
struct SettingsPlaceholderView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var sourceRegistry
    @State private var wikiTreePassword = ""
    @State private var cleansePresentation: CleansePresentation?
    @State private var unresolvableFlagCount: Int = 0
    @State private var familySearchSignedIn: Bool = false
    @State private var familySearchProbeStatus: String?
    @State private var familySearchProbing: Bool = false
    @State private var showFamilySearchAuth: Bool = false
    /// M16.11 — controls whether the tree canvas draws note dots, open-question
    /// markers, focus rings, and tentative-fact glyphs. Hidden state is useful
    /// for printing or screen-shotting a clean tree.
    @AppStorage("showResearchIndicators") private var showResearchIndicators: Bool = true
    /// Persists the user's reasoning-model choice. Backed by `ReasoningModel.rawValue`.
    @AppStorage("reasoningModelChoice") private var reasoningModelChoiceRaw: String = ReasoningModel.default.rawValue
    /// PROJECT_ONBOARDING_SPEC Part A Step 2 — semantic embedder consent
    /// (shared with the setup wizard + the launch auto-load).
    @AppStorage("semanticEmbedderEnabled") private var semanticEmbedderEnabled = false
    @State private var semanticEmbedderProgress: Double?

    /// Email extracted from project source — single source of truth.
    private var wikiTreeEmail: String {
        if case .wikitree(let email) = appState.currentProject?.source {
            return email
        }
        return ""
    }

    private var isWikiTreeProject: Bool {
        if case .wikitree = appState.currentProject?.source { return true }
        return false
    }

    private var isManualProject: Bool {
        if case .manual = appState.currentProject?.source { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Project") {
                if let project = appState.currentProject {
                    LabeledContent("Name", value: project.name)
                    LabeledContent("Created", value: project.createdAt.formatted())
                    if let refreshed = project.lastRefreshed {
                        LabeledContent("Last Refreshed", value: refreshed.formatted())
                    }
                    LabeledContent("Profiles", value: "\(appState.snapshot.profiles.count)")
                    LabeledContent("Relationships", value: "\(appState.snapshot.relationships.count)")

                    // The final fallback of the home-county derivation
                    // chain (profile birth location code → birth location →
                    // THIS). Existed on the model since the chapman-default
                    // removal but had no UI — every location-less subject
                    // in a project without it is anchor-less, skipping the
                    // whole chapman-scoped source trio (owner frustration
                    // 2026-07-15: Elsie Twyford, known-Youlgrave family,
                    // shallow anchor-less profile).
                    Picker("Home county", selection: Binding(
                        get: { appState.currentProject?.homeChapmanCode ?? "" },
                        set: { newCode in
                            guard var project = appState.currentProject else { return }
                            project.homeChapmanCode = newCode.isEmpty ? nil : newCode
                            appState.currentProject = project
                            try? appState.currentDatabase?.saveProjectMeta(project)
                        }
                    )) {
                        Text("None — derive per profile").tag("")
                        ForEach(UKChapmanCodes.shared.gbAndChannelIslands(), id: \.code) { entry in
                            Text("\(entry.name) (\(entry.code))").tag(entry.code)
                        }
                    }
                    Text("Used as the research anchor for any profile whose own birth location can't provide one. Profiles with locations keep deriving their own county.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let summary = appState.auditSummary {
                        LabeledContent("Audit") {
                            HStack(spacing: 8) {
                                Text("\(summary.errors.count) errors")
                                    .foregroundColor(summary.errors.isEmpty ? .secondary : .red)
                                Text("\(summary.warnings.count) warnings")
                                    .foregroundColor(summary.warnings.isEmpty ? .secondary : .orange)
                                Text("\(summary.info.count) info")
                                    .foregroundColor(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            if isWikiTreeProject {
                Section("WikiTree") {
                    LabeledContent("Email", value: wikiTreeEmail)

                    HStack {
                        SecureField("Password", text: $wikiTreePassword)
                            .textFieldStyle(.roundedBorder)
                        if !wikiTreePassword.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .accessibilityLabel("Password entered")
                        }
                    }

                    HStack {
                        Button("Connect & Import") {
                            Task {
                                await appState.connectWikiTree(
                                    email: wikiTreeEmail,
                                    password: wikiTreePassword
                                )
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(wikiTreePassword.isEmpty)

                        if appState.snapshot.profiles.count > 0 {
                            Button("Refresh with Diff") {
                                Task {
                                    await appState.refreshWikiTreeWithDiff()
                                }
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }
            }

            let allSources = sourceRegistry.allSources()
            let generalSources = allSources.filter { $0.kind == .general }
            let localPluginSources = allSources.filter { $0.kind == .localPlugin }

            Section("General sources (\(generalSources.count))") {
                ForEach(generalSources, id: \.sourceID) { source in
                    sourceRow(source)
                }
            }

            if !localPluginSources.isEmpty {
                Section {
                    ForEach(localPluginSources, id: \.sourceID) { source in
                        sourceRow(source)
                    }
                } header: {
                    Text("Local sources (\(localPluginSources.count))")
                } footer: {
                    Text("Niche sources covering a specific area or record type. Enable the ones your tree intersects.")
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                }
            }

            ProseCorporaSettingsView()

            // PROJECT_ONBOARDING_SPEC Part A — re-run the project setup wizard
            // (home region etc.), available for ANY project type. Distinct from
            // the manual-only family-entry wizard below.
            Section("Project setup") {
                Button("Re-run setup") {
                    appState.rerunSetup()
                }
                .buttonStyle(.glass)
                Text("Revisit the home region and other project settings. Changes nothing you don't confirm.")
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
            }

            if isManualProject {
                Section("Onboarding") {
                    Button("Re-launch wizard") {
                        appState.showOnboardingWizard = true
                    }
                    .buttonStyle(.glass)
                    Text("Walk through the guided family builder again. Existing profiles aren't replaced — the wizard adds new people in a single transaction.")
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Deleted People") {
                DeletedPeopleView()
            }

            Section("Tree Visualisation") {
                Toggle("Show research indicators on tree nodes", isOn: $showResearchIndicators)
                Text("Hide note and question icons, focus rings, and tentative-fact glyphs from the tree view (useful for printing or demos).")
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
            }

            Section("Reasoning Model") {
                reasoningModelSection
            }

            // PROJECT_ONBOARDING_SPEC Part A Step 2 — the semantic embedder's
            // opt-in, matching the setup wizard. Enabling downloads it (if
            // absent) and the app auto-uses it whenever present thereafter;
            // disabling stops the launch auto-load next session.
            Section("Semantic clustering") {
                semanticEmbedderSection
            }

            Section {
                DisclosureGroup("Backups") {
                    BackupsListView()
                }
            }

            Section("Audit Rules") {
                NavigationLink {
                    AuditRulesView()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Configure audit rules")
                                .font(AppTypography.cardTitle)
                            Text("Enable, disable, snooze, or tune thresholds for the \(AuditRules.builtIn.count) built-in rules.")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }

            Section("Data Cleansing") {
                Button("Cleanse all profiles") {
                    cleansePresentation = .allProfiles
                }
                .buttonStyle(.glass)
                Text("Walk every profile in the tree, surfacing ambiguous locations, missing parents, and bare-year dates one at a time.")
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)

                if unresolvableFlagCount > 0 {
                    HStack {
                        Text("Unresolvable flags: \(unresolvableFlagCount)")
                            .font(AppTypography.cardBody)
                        Spacer()
                        Button("Reset all") {
                            try? appState.currentDatabase?.clearAllCleanseUnresolvableFlags()
                            refreshUnresolvableFlagCount()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                    Text("Resetting re-surfaces every finding you previously marked as unresolvable.")
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Statistics") {
                NavigationLink("Statistics") { StatisticsView() }
            }

            Section("FamilySearch (development)") {
                familySearchSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear(perform: refreshUnresolvableFlagCount)
        .task {
            familySearchSignedIn = await FamilySearchCookieStore.shared.hasCookies()
        }
        .sheet(item: $cleansePresentation) { presentation in
            ProfileCleanseWizard(mode: presentation.mode)
        }
        .sheet(isPresented: $showFamilySearchAuth) {
            FamilySearchAuthView { success in
                if success {
                    Task {
                        familySearchSignedIn = await FamilySearchCookieStore.shared.hasCookies()
                        familySearchProbeStatus = nil
                    }
                }
            }
        }
    }

    // MARK: - FamilySearch (dev section)

    private var familySearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: familySearchSignedIn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(familySearchSignedIn ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(familySearchSignedIn ? "Signed in" : "Not signed in")
                        .font(AppTypography.cardTitle)
                    Text("Cookie-based session; expires every 1–2 hours")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(familySearchSignedIn ? "Re-authenticate" : "Sign in") {
                    showFamilySearchAuth = true
                }
                .buttonStyle(.glass)
            }

            if familySearchSignedIn {
                HStack(spacing: 8) {
                    Button(familySearchProbing ? "Testing…" : "Test session") {
                        Task { await runProbe() }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(familySearchProbing)

                    Button("Clear session") {
                        Task {
                            await FamilySearchCookieStore.shared.clear()
                            familySearchSignedIn = false
                            familySearchProbeStatus = nil
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                if let status = familySearchProbeStatus {
                    Text(status)
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func runProbe() async {
        familySearchProbing = true
        let outcome = await FamilySearchTestProbe.run()
        familySearchProbing = false
        if outcome.success {
            let count = outcome.resultCount ?? 0
            let total = outcome.totalCount ?? 0
            let noun = count == 1 ? "entry" : "entries"
            familySearchProbeStatus = "OK: HTTP \(outcome.httpStatus ?? 0), \(count) \(noun) of \(total) total"
        } else {
            familySearchProbeStatus = "Failed: \(outcome.error ?? "unknown error")"
        }
    }

    private func refreshUnresolvableFlagCount() {
        let count = (try? appState.currentDatabase?.loadCleanseUnresolvableFlags().count) ?? 0
        unresolvableFlagCount = count
    }

    // MARK: - Source Row

    private func sourceRow(_ source: any RecordSource) -> some View {
        HStack {
            Image(systemName: tosIcon(source.tosStatus.level))
                .foregroundStyle(tosColor(source.tosStatus.level))
                .accessibilityLabel("Terms of service status \(String(describing: source.tosStatus.level))")

            VStack(alignment: .leading, spacing: 2) {
                Text(source.descriptiveName)
                    .font(AppTypography.cardTitle)
                Text(source.tosStatus.summary)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Text(Self.coverageLabel(for: source))
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { sourceRegistry.isEnabled(source.sourceID) },
                set: { sourceRegistry.setEnabled(sourceID: source.sourceID, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    // MARK: - ToS Helpers

    /// Human-readable coverage line for any source. Bounded sources render
    /// the year range; unbounded ones (FamilySearch, Find a Grave — both
    /// worldwide and undated) render "Worldwide, all years" so every row in
    /// the Settings list has parity.
    private static func coverageLabel(for source: any RecordSource) -> String {
        if let range = source.coverageYearRange {
            return "Coverage: \(range.lowerBound)–\(range.upperBound)"
        }
        return "Coverage: worldwide, all years"
    }

    private func tosIcon(_ level: SourceToSStatus.ToSLevel) -> String {
        switch level {
        case .open: "checkmark.shield.fill"
        case .community: "person.3.fill"
        case .restricted: "exclamationmark.triangle.fill"
        }
    }

    private func tosColor(_ level: SourceToSStatus.ToSLevel) -> Color {
        switch level {
        case .open: .green
        case .community: .blue
        case .restricted: .orange
        }
    }

    // MARK: - Reasoning Model

    @State private var modelStatus = "Not loaded"
    @State private var isLoadingModel = false
    @State private var loadedModelID: String?
    @State private var loadProgress: Double = 0  // 0.0–1.0 during download/load
    @State private var onDiskBytes: Int64 = 0    // truth from filesystem
    @State private var showSeedPicker = false
    @State private var seedStatus: String?
    @State private var isSeeding = false

    private var selectedReasoningModel: ReasoningModel {
        ReasoningModel(rawValue: reasoningModelChoiceRaw) ?? .default
    }

    /// True when a model is loaded and the user has picked a different one.
    private var needsReload: Bool {
        guard let loaded = loadedModelID else { return false }
        return loaded != selectedReasoningModel.huggingFaceID
    }

    private var loadButtonLabel: String {
        if isLoadingModel { return "Loading…" }
        if needsReload { return "Switch Model" }
        return "Load Model"
    }

    /// PROJECT_ONBOARDING_SPEC Part A Step 2 — the semantic embedder toggle,
    /// mirroring the setup wizard. Enabling downloads it (with progress) and
    /// the launch auto-load uses it whenever present thereafter.
    @ViewBuilder
    private var semanticEmbedderSection: some View {
        #if canImport(MLXEmbedders) && canImport(MLX)
        Toggle("Use semantic clustering model", isOn: Binding(
            get: { semanticEmbedderEnabled },
            set: { on in
                semanticEmbedderEnabled = on
                if on { downloadSemanticEmbedder() }
            }
        ))
        if let p = semanticEmbedderProgress {
            ProgressView(value: p) { Text("Downloading… \(Int(p * 100))%") }
        }
        Text("Tighter “Possible People” grouping by meaning, not just spelling. About \(MLXTextEmbedder.estimatedSizeMB) MB, downloaded on demand. Off by default — clustering works without it.")
            .font(AppTypography.badge)
            .foregroundStyle(.tertiary)
        #else
        Text("Not available in this build.")
            .font(AppTypography.badge)
            .foregroundStyle(.tertiary)
        #endif
    }

    private func downloadSemanticEmbedder() {
        #if canImport(MLXEmbedders) && canImport(MLX)
        semanticEmbedderProgress = 0
        Task {
            try? await MLXTextEmbedder.shared.loadModel(
                onProgress: { fraction in
                    Task { @MainActor in semanticEmbedderProgress = fraction }
                })
            await MainActor.run { semanticEmbedderProgress = nil }
        }
        #endif
    }

    private var reasoningModelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Model", selection: $reasoningModelChoiceRaw) {
                ForEach(ReasoningModel.allCases) { model in
                    Text(model.displayName).tag(model.rawValue)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedReasoningModel.subtitle)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Text(String(format: "≈ %.1f GB memory · first load downloads from Hugging Face", selectedReasoningModel.memoryEstimateGB))
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
            }

            if isLoadingModel {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: loadProgress)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("\(Int(loadProgress * 100))% reported")
                            .monospacedDigit()
                        Spacer()
                        Text("\(Self.formatGB(onDiskBytes)) / \(String(format: "%.1f", selectedReasoningModel.memoryEstimateGB)) GB on disk")
                            .monospacedDigit()
                    }
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Text(modelStatus)
                    .font(AppTypography.badge)
                    .foregroundStyle(modelStatus == "Ready" ? .green : .secondary)
                Spacer()
                Button(loadButtonLabel) {
                    isLoadingModel = true
                    loadProgress = 0
                    modelStatus = "Loading…"
                    let chosen = selectedReasoningModel
                    Task {
                        do {
                            if needsReload {
                                await LocalInferenceService.shared.unload()
                            }
                            try await LocalInferenceService.shared.loadModel(
                                configuration: chosen.configuration,
                                onProgress: { fraction in
                                    Task { @MainActor in
                                        loadProgress = fraction
                                    }
                                }
                            )
                            loadedModelID = chosen.huggingFaceID
                            modelStatus = "Ready"
                        } catch {
                            modelStatus = "Error: \(error.localizedDescription)"
                        }
                        isLoadingModel = false
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(isLoadingModel)

                Button("Unload") {
                    Task {
                        await LocalInferenceService.shared.unload()
                        loadedModelID = nil
                        modelStatus = "Not loaded"
                        onDiskBytes = LocalInferenceService.shared.onDiskBytes(for: selectedReasoningModel)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isLoadingModel || loadedModelID == nil)
            }

            // Escape hatch: power users who already have the model on disk
            // (e.g. from Python tooling at `~/.cache/huggingface/hub/…`) can
            // copy files into the sandbox in one shot instead of paying the
            // re-download tax. Sandboxed app needs the user to grant access
            // via folder picker.
            HStack {
                Button(isSeeding ? "Seeding…" : "Seed from existing download…") {
                    showSeedPicker = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isLoadingModel || isSeeding)
                if let seedStatus {
                    Text(seedStatus)
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task {
            loadedModelID = await LocalInferenceService.shared.currentModelID
            if loadedModelID != nil {
                modelStatus = "Ready"
            }
            onDiskBytes = LocalInferenceService.shared.onDiskBytes(for: selectedReasoningModel)
        }
        .task(id: isLoadingModel) {
            guard isLoadingModel else { return }
            while !Task.isCancelled && isLoadingModel {
                onDiskBytes = LocalInferenceService.shared.onDiskBytes(for: selectedReasoningModel)
                try? await Task.sleep(for: .seconds(1))
            }
            // Final read once load completes so the "on disk" line settles.
            onDiskBytes = LocalInferenceService.shared.onDiskBytes(for: selectedReasoningModel)
        }
        .onChange(of: reasoningModelChoiceRaw) { _, _ in
            onDiskBytes = LocalInferenceService.shared.onDiskBytes(for: selectedReasoningModel)
            seedStatus = nil
        }
        .fileImporter(
            isPresented: $showSeedPicker,
            allowedContentTypes: [.folder]
        ) { result in
            handleSeedPickerResult(result)
        }
    }

    private func handleSeedPickerResult(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            seedStatus = "Picker failed: \(error.localizedDescription)"
        case .success(let url):
            isSeeding = true
            seedStatus = "Copying files…"
            let chosen = selectedReasoningModel
            Task.detached(priority: .userInitiated) {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    let copied = try LocalInferenceService.shared.seedFromExternalDirectory(
                        source: url, for: chosen
                    )
                    let bytes = LocalInferenceService.shared.onDiskBytes(for: chosen)
                    await MainActor.run {
                        seedStatus = "Copied \(copied) file(s) · \(Self.formatGB(bytes)) GB on disk"
                        onDiskBytes = bytes
                        isSeeding = false
                    }
                } catch {
                    await MainActor.run {
                        seedStatus = "Seed failed: \(error.localizedDescription)"
                        isSeeding = false
                    }
                }
            }
        }
    }

    /// Formats a byte count as "X.X" (in GB, 1 decimal place). Used by both
    /// the live progress line and the seed status message.
    private static func formatGB(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000.0)
    }

}
