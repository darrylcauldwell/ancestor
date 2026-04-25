import SwiftUI

/// Settings view with WikiTree connection and project info.
struct SettingsPlaceholderView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var sourceRegistry
    @State private var wikiTreePassword = ""
    @AppStorage("disabledAuditRuleIDs") private var disabledRuleIDsData: Data = Data()

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

            Section("Record Sources (\(sourceRegistry.allSources().count))") {
                ForEach(sourceRegistry.allSources(), id: \.sourceID) { source in
                    HStack {
                        // ToS indicator
                        Image(systemName: tosIcon(source.tosStatus.level))
                            .foregroundStyle(tosColor(source.tosStatus.level))

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

                        // Enable/disable toggle
                        Toggle("", isOn: Binding(
                            get: { sourceRegistry.isEnabled(source.sourceID) },
                            set: { sourceRegistry.setEnabled(sourceID: source.sourceID, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }

            Section("Audit Rules (\(enabledRuleCount)/\(AuditRules.builtIn.count) enabled)") {
                ForEach(AuditRules.builtIn, id: \.id) { rule in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Invariant") {
                                Text(rule.description)
                                    .font(.caption)
                            }
                            LabeledContent("Error fires when") {
                                Text(rule.fireCondition)
                                    .font(.caption.monospaced())
                            }
                            if let warning = rule.warningCondition {
                                LabeledContent("Warning fires when") {
                                    Text(warning)
                                        .font(.caption.monospaced())
                                }
                            }
                            if !rule.workedExample.isEmpty {
                                LabeledContent("Example") {
                                    Text(rule.workedExample)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Toggle(isOn: ruleBinding(for: rule.id)) {
                                HStack {
                                    Image(systemName: rule.defaultSeverity.iconName)
                                        .foregroundStyle(isRuleEnabled(rule.id) ? rule.defaultSeverity.color : .secondary.opacity(0.3))
                                    Text(rule.displayName)
                                        .foregroundStyle(isRuleEnabled(rule.id) ? .primary : .secondary)
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    // MARK: - Disabled Rules Storage

    private var disabledRuleIDs: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: disabledRuleIDsData)) ?? []
        }
        nonmutating set {
            disabledRuleIDsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private var enabledRuleCount: Int {
        AuditRules.builtIn.count - disabledRuleIDs.count
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

    private func isRuleEnabled(_ ruleID: String) -> Bool {
        !disabledRuleIDs.contains(ruleID)
    }

    private func ruleBinding(for ruleID: String) -> Binding<Bool> {
        Binding(
            get: { isRuleEnabled(ruleID) },
            set: { enabled in
                var ids = disabledRuleIDs
                if enabled {
                    ids.remove(ruleID)
                } else {
                    ids.insert(ruleID)
                }
                disabledRuleIDs = ids
            }
        )
    }
}
