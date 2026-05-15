import SwiftUI

/// Settings view with WikiTree connection and project info.
struct SettingsPlaceholderView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var sourceRegistry
    @State private var wikiTreePassword = ""
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

            Section("Demo Mode") {
                Toggle("Show demo family tree", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "demoModeEnabled") },
                    set: { enabled in
                        UserDefaults.standard.set(enabled, forKey: "demoModeEnabled")
                        if enabled {
                            let (demoProfiles, demoRelationships) = DemoDataGenerator.generate()
                            appState.snapshot = FamilyGraphSnapshot(profiles: demoProfiles, relationships: demoRelationships)
                        } else if let db = appState.currentDatabase {
                            appState.snapshot = (try? db.buildSnapshot()) ?? .empty
                        }
                    }
                ))
                Text("Replaces your tree with a fictional Ashford family for screenshots and demos. Your data is not affected.")
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
            }

            Section("Reasoning Model") {
                reasoningModelSection
            }

            #if !FIELD_RESEARCHER_DISABLED
            Section("Field Researcher") {
                fieldResearcherSection
            }
            #endif

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

            Section("Statistics") {
                NavigationLink("Statistics") { StatisticsView() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    // MARK: - Source Row

    private func sourceRow(_ source: any RecordSource) -> some View {
        HStack {
            Image(systemName: tosIcon(source.tosStatus.level))
                .foregroundStyle(tosColor(source.tosStatus.level))
                .accessibilityLabel("Terms of service status \(String(describing: source.tosStatus.level))")

            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .font(AppTypography.cardTitle)
                Text(source.tosStatus.summary)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                if let range = source.coverageYearRange {
                    Text("Coverage: \(range.lowerBound)–\(range.upperBound)")
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                }
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

    // MARK: - Field Researcher
    #if !FIELD_RESEARCHER_DISABLED
    @AppStorage("fieldResearcherEnabled") private var frEnabled = false
    @AppStorage("fieldResearcherModel") private var frModel = "claude-sonnet-4-20250514"
    @AppStorage("fieldResearcherBudget") private var frBudget = 0.50
    @State private var frAPIKey = ""
    @State private var frKeyStatus = ""
    #endif

    #if !FIELD_RESEARCHER_DISABLED
    private var fieldResearcherSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable Field Researcher", isOn: $frEnabled)

            if frEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SecureField("Claude API Key", text: $frAPIKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            saveAPIKey(frAPIKey)
                            frKeyStatus = frAPIKey.isEmpty ? "" : "Saved to Keychain"
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                    if !frKeyStatus.isEmpty {
                        Text(frKeyStatus)
                            .font(AppTypography.badge)
                            .foregroundStyle(.green)
                    }

                    Picker("Model", selection: $frModel) {
                        Text("Claude Sonnet 4").tag("claude-sonnet-4-20250514")
                        Text("Claude Opus 4").tag("claude-opus-4-20250514")
                    }

                    HStack {
                        Text("Per-session budget:")
                            .font(AppTypography.cardBody)
                        Picker("", selection: $frBudget) {
                            Text("$0.25").tag(0.25)
                            Text("$0.50").tag(0.50)
                            Text("$1.00").tag(1.00)
                            Text("$2.00").tag(2.00)
                            Text("$5.00").tag(5.00)
                        }
                        .frame(width: 100)
                    }

                    Text("The Field Researcher uses the Claude API to search the web for evidence not available in structured sources. Findings are verified and scored through the same pipeline as other sources. You pay Claude API costs.")
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func saveAPIKey(_ key: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.dreamfold.Ancestor-Research.claude-api",
            kSecAttrAccount as String: "api-key",
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.dreamfold.Ancestor-Research.claude-api",
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    #endif
}
