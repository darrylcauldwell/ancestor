import SwiftUI

/// Settings view with WikiTree connection and project info.
struct SettingsPlaceholderView: View {
    @Environment(AppState.self) private var appState
    @State private var wikiTreeEmail = ""
    @State private var wikiTreePassword = ""
    @State private var wikiTreeSeedProfile = ""
    @State private var isConnecting = false

    var body: some View {
        Form {
            Section("Project") {
                if let project = appState.currentProject {
                    LabeledContent("Name", value: project.name)
                    LabeledContent("Source", value: project.source.description)
                    LabeledContent("Created", value: project.createdAt.formatted())
                    if let refreshed = project.lastRefreshed {
                        LabeledContent("Last Refreshed", value: refreshed.formatted())
                    }
                    LabeledContent("Profiles", value: "\(appState.snapshot.profiles.count)")
                    LabeledContent("Relationships", value: "\(appState.snapshot.relationships.count)")
                }
            }

            if case .wikitree = appState.currentProject?.source {
                Section("WikiTree Connection") {
                    TextField("Email", text: $wikiTreeEmail)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $wikiTreePassword)
                        .textFieldStyle(.roundedBorder)
                    TextField("Seed Profile ID", text: $wikiTreeSeedProfile)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Connect & Import") {
                            Task {
                                await appState.connectWikiTree(
                                    email: wikiTreeEmail,
                                    password: wikiTreePassword,
                                    seedProfileID: wikiTreeSeedProfile
                                )
                            }
                        }
                        .disabled(wikiTreeEmail.isEmpty || wikiTreePassword.isEmpty || wikiTreeSeedProfile.isEmpty)

                        if appState.snapshot.profiles.count > 0 {
                            Button("Refresh with Diff") {
                                Task {
                                    await appState.refreshWikiTreeWithDiff()
                                }
                            }
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
