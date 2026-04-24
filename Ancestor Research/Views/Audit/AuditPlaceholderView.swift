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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }
}

nonisolated extension Severity {
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

/// Gaps view — profiles missing key data, grouped by what's missing.
struct GapsPlaceholderView: View {
    @Environment(AppState.self) private var appState
    @State private var filterCheck: CompletenessCheck?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            if !appState.snapshot.profiles.isEmpty {
                HStack(spacing: 12) {
                    gapSummary
                    Spacer()
                    TextField("Search...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
                .padding()
                Divider()
            }

            // List
            let gaps = filteredProfiles
            if gaps.isEmpty {
                ContentUnavailableView {
                    Label("No Gaps", systemImage: "checkmark.circle")
                } description: {
                    Text(appState.snapshot.profiles.isEmpty
                         ? "Import data to see gaps."
                         : "All profiles are complete.")
                }
            } else {
                List(gaps) { profile in
                    let comp = appState.snapshot.completeness(for: profile.id)
                    HStack {
                        // Completeness bar
                        completenessBar(comp)
                            .frame(width: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(.headline)
                            if let year = profile.birthDate?.bestYear {
                                Text("b. \(year)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 4) {
                                ForEach(comp.missing, id: \.label) { check in
                                    Text(check.shortLabel)
                                        .font(.system(size: 9))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .glassEffect(.regular, in: .capsule)
                                }
                            }
                        }

                        Spacer()

                        Text("\(comp.score)/\(comp.maximum)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(comp.score == 0 ? .red : .orange)
                    }
                }
            }
        }
        .navigationTitle("Gaps (\(filteredProfiles.count) incomplete)")
    }

    private var filteredProfiles: [Profile] {
        appState.snapshot.profiles.values
            .filter { profile in
                let comp = appState.snapshot.completeness(for: profile.id)
                guard comp.score < comp.maximum else { return false }
                if let filter = filterCheck {
                    guard comp.missing.contains(where: { $0.label == filter.label }) else { return false }
                }
                if !searchText.isEmpty {
                    guard profile.displayName.localizedCaseInsensitiveContains(searchText) else { return false }
                }
                return true
            }
            .sorted {
                appState.snapshot.completeness(for: $0.id).score <
                    appState.snapshot.completeness(for: $1.id).score
            }
    }

    private var gapSummary: some View {
        let total = appState.snapshot.profiles.count
        let incomplete = appState.snapshot.profiles.values.filter {
            let c = appState.snapshot.completeness(for: $0.id)
            return c.score < c.maximum
        }.count
        let complete = total - incomplete
        return HStack(spacing: 8) {
            Text("\(complete)/\(total) complete")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(incomplete == 0 ? .green : .secondary)
            if total > 0 {
                let pct = Int(Double(complete) / Double(total) * 100)
                Text("\(pct)%")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
            }
        }
    }

    private func completenessBar(_ comp: ProfileCompleteness) -> some View {
        let ratio = comp.maximum > 0 ? Double(comp.score) / Double(comp.maximum) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(ratio >= 1.0 ? Color.green : (ratio > 0.5 ? .orange : .red))
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(height: 6)
    }
}

nonisolated extension CompletenessCheck {
    var label: String {
        switch self {
        case .field(let field): "Missing \(field.rawValue)"
        case .hasParents: "No parents"
        }
    }

    var shortLabel: String {
        switch self {
        case .field(let field):
            switch field {
            case .firstName: "name"
            case .lastName: "surname"
            case .gender: "gender"
            case .birthDate: "birth"
            case .birthLocation: "b.loc"
            case .deathDate: "death"
            case .deathLocation: "d.loc"
            case .bio: "bio"
            }
        case .hasParents: "parents"
        }
    }
}
