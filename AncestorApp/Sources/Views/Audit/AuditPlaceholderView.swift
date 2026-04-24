import SwiftUI

/// Audit view — run rules, display errors/warnings/info grouped by severity.
struct AuditPlaceholderView: View {
    @Environment(AppState.self) private var appState
    @State private var auditVM = AuditViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar area
            HStack {
                Button {
                    auditVM.runAudit(snapshot: appState.snapshot)
                } label: {
                    Label("Run Audit", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .disabled(appState.snapshot.profiles.isEmpty)

                Spacer()

                if let summary = auditVM.summary {
                    HStack(spacing: 12) {
                        severityBadge(.error, count: summary.errors.count)
                        severityBadge(.warning, count: summary.warnings.count)
                        severityBadge(.info, count: summary.info.count)
                    }
                }

                Picker("Filter", selection: $auditVM.filterSeverity) {
                    Text("All").tag(nil as Severity?)
                    Text("Errors").tag(Severity.error as Severity?)
                    Text("Warnings").tag(Severity.warning as Severity?)
                    Text("Info").tag(Severity.info as Severity?)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                TextField("Search...", text: $auditVM.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }
            .padding()

            Divider()

            // Results
            if auditVM.isRunning {
                ProgressView("Running audit...")
                    .frame(maxHeight: .infinity)
            } else if let summary = auditVM.summary {
                if auditVM.filteredResults.isEmpty {
                    ContentUnavailableView {
                        Label("No Issues", systemImage: "checkmark.circle")
                    } description: {
                        Text("Checked \(summary.profilesChecked) profiles.")
                    }
                } else {
                    List(auditVM.filteredResults) { result in
                        HStack(alignment: .top) {
                            Image(systemName: result.severity.iconName)
                                .foregroundStyle(result.severity.color)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.message)
                                    .font(.callout)
                                Text(result.ruleID)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Audit", systemImage: "checkmark.shield")
                } description: {
                    Text("Press Run Audit to check your tree for errors and gaps.")
                }
            }
        }
        .navigationTitle("Audit")
    }

    private func severityBadge(_ severity: Severity, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: severity.iconName)
                .foregroundStyle(severity.color)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.semibold)
        }
    }
}

extension Severity {
    var iconName: String {
        switch self {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }
}

/// Gaps view — profiles missing key data.
struct GapsPlaceholderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let missing = appState.snapshot.profiles.values.filter { profile in
            let comp = appState.snapshot.completeness(for: profile.id)
            return comp.score < comp.maximum
        }.sorted { a, b in
            appState.snapshot.completeness(for: a.id).score <
                appState.snapshot.completeness(for: b.id).score
        }

        if missing.isEmpty {
            ContentUnavailableView {
                Label("No Gaps", systemImage: "checkmark.circle")
            } description: {
                Text("All profiles are complete.")
            }
        } else {
            List(missing) { profile in
                let comp = appState.snapshot.completeness(for: profile.id)
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.displayName)
                            .font(.headline)
                        Text(comp.missing.map(\.label).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(comp.score)/\(comp.maximum)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("Gaps (\(missing.count) incomplete)")
        }
    }
}

extension CompletenessCheck {
    var label: String {
        switch self {
        case .field(let field): "Missing \(field.rawValue)"
        case .hasParents: "No parents"
        }
    }
}
