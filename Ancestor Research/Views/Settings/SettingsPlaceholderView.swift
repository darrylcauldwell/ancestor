import SwiftUI

/// Settings view with WikiTree connection and project info.
struct SettingsPlaceholderView: View {
    @Environment(AppState.self) private var appState
    @State private var wikiTreePassword = ""

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

            Section("Audit Rules (\(AuditRules.builtIn.count) rules)") {
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
                            Image(systemName: rule.defaultSeverity.iconName)
                                .foregroundStyle(rule.defaultSeverity.color)
                            Text(rule.displayName)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
