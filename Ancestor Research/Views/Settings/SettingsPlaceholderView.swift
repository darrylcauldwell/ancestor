import SwiftUI

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

            if isManualProject {
                Section("Onboarding") {
                    Button("Re-launch wizard") {
                        appState.showOnboardingWizard = true
                    }
                    .buttonStyle(.glass)
                    Text("Walk through the guided setup again. Existing profiles aren't replaced — the wizard adds new people in a single transaction.")
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

    private var reasoningModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DeepSeek-R1 14B (4-bit)")
                        .font(AppTypography.cardTitle)
                    Text("Chain-of-thought reasoning for genealogical analysis")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(modelStatus)
                    .font(AppTypography.badge)
                    .foregroundStyle(modelStatus == "Ready" ? .green : .secondary)
            }

            HStack(spacing: 12) {
                Button(isLoadingModel ? "Loading..." : "Load Model") {
                    isLoadingModel = true
                    modelStatus = "Loading..."
                    Task {
                        do {
                            try await LocalInferenceService.shared.loadModel()
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
                        modelStatus = "Not loaded"
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            Text("Requires ~7 GB memory. First load downloads the model from Hugging Face.")
                .font(AppTypography.badge)
                .foregroundStyle(.tertiary)
        }
    }

}
