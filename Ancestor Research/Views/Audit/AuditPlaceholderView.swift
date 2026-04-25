import SwiftUI

/// Audit view — run rules, display errors/warnings/info grouped by severity.
struct AuditPlaceholderView: View {
    @Environment(AppState.self) private var appState
    @State private var auditVM = AuditViewModel()
    @AppStorage("disabledAuditRuleIDs") private var disabledRuleIDsData: Data = Data()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar area
            HStack {
                Button {
                    let disabled = (try? JSONDecoder().decode(Set<String>.self, from: disabledRuleIDsData)) ?? []
                    auditVM.runAudit(snapshot: appState.snapshot, disabledRuleIDs: disabled)
                } label: {
                    Label("Re-run Audit", systemImage: "arrow.clockwise")
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
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(auditVM.filteredResults) { result in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: result.severity.iconName)
                                        .foregroundStyle(result.severity.color)
                                        .font(.body)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.profileName)
                                            .font(AppTypography.cardTitle)
                                        Text(strippedMessage(result))
                                            .font(AppTypography.cardBody)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                            }
                        }
                        .padding()
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
        .onAppear {
            // Use auto-audit from AppState if available and no manual run yet
            if auditVM.summary == nil, let autoSummary = appState.auditSummary {
                auditVM.summary = autoSummary
            }
        }
    }

    /// Strip the profile name from the start of the message to avoid duplication with the header.
    private func strippedMessage(_ result: AuditResult) -> String {
        var msg = result.message
        if msg.hasPrefix(result.profileName) {
            msg = String(msg.dropFirst(result.profileName.count))
            // Remove leading separator: " — ", " - ", " "
            if msg.hasPrefix(" — ") {
                msg = String(msg.dropFirst(3))
            } else if msg.hasPrefix(" ") {
                msg = String(msg.dropFirst(1))
            }
        }
        // Capitalize first letter
        return msg.prefix(1).uppercased() + msg.dropFirst()
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

/// Gaps view — profiles missing key data, filterable by missing field.
struct GapsPlaceholderView: View {
    @Environment(AppState.self) private var appState
    @State private var filterCheck: CompletenessCheck?
    @State private var searchText = ""

    /// All distinct missing checks across all incomplete profiles, with counts.
    private var availableFilters: [(check: CompletenessCheck, count: Int)] {
        var counts: [String: (check: CompletenessCheck, count: Int)] = [:]
        for profile in appState.snapshot.profiles.values {
            let comp = appState.snapshot.completeness(for: profile.id)
            for check in comp.missing {
                let key = check.label
                if let existing = counts[key] {
                    counts[key] = (check: existing.check, count: existing.count + 1)
                } else {
                    counts[key] = (check: check, count: 1)
                }
            }
        }
        return counts.values.sorted { $0.count > $1.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Summary + filter bar
            if !appState.snapshot.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        gapSummary
                        Spacer()
                        TextField("Search...", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    // Field filter buttons
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            filterButton(label: "All", check: nil, count: totalIncomplete)

                            ForEach(availableFilters, id: \.check.label) { filter in
                                filterButton(
                                    label: filter.check.shortLabel.capitalized,
                                    check: filter.check,
                                    count: filter.count
                                )
                            }
                        }
                    }
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
                         : filterCheck != nil
                            ? "No profiles missing this field."
                            : "All profiles are complete.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(gaps) { profile in
                            let comp = appState.snapshot.completeness(for: profile.id)
                            let ratio = comp.maximum > 0 ? Double(comp.score) / Double(comp.maximum) : 0
                            HStack(spacing: 10) {
                                // Severity indicator
                                Image(systemName: ratio > 0.5 ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ratio > 0.5 ? .orange : .red)
                                    .font(.body)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(profile.displayName)
                                            .font(AppTypography.cardTitle)
                                        if let year = profile.birthDate?.bestYear {
                                            Text("b. \(String(year))")
                                                .font(AppTypography.cardMeta)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text("Missing: \(comp.missing.map(\.shortLabel).joined(separator: ", "))")
                                        .font(AppTypography.cardBody)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("\(comp.score)/\(comp.maximum)")
                                    .font(AppTypography.cardTitle)
                                    .foregroundStyle(comp.score == 0 ? .red : .orange)
                            }
                            .padding(12)
                            .glassEffect(.regular, in: .rect(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Gaps (\(filteredProfiles.count) incomplete)")
    }

    // MARK: - Filter Button

    private func filterButton(label: String, check: CompletenessCheck?, count: Int) -> some View {
        let isActive = (filterCheck?.label == check?.label)
        return Button {
            if isActive {
                filterCheck = nil
            } else {
                filterCheck = check
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(AppTypography.cardMeta)
                    .fontWeight(isActive ? .bold : .regular)
                Text("\(count)")
                    .font(AppTypography.badge)
                    .foregroundStyle(isActive ? .primary : .tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func isActiveFilter(_ check: CompletenessCheck) -> Bool {
        filterCheck?.label == check.label
    }

    // MARK: - Data

    private var totalIncomplete: Int {
        appState.snapshot.profiles.values.filter {
            let c = appState.snapshot.completeness(for: $0.id)
            return c.score < c.maximum
        }.count
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
        let incomplete = totalIncomplete
        let complete = total - incomplete
        return HStack(spacing: 8) {
            Text("\(complete)/\(total) complete")
                .font(AppTypography.cardBody)
                .fontWeight(.semibold)
                .foregroundStyle(incomplete == 0 ? .green : .secondary)
            if total > 0 {
                let pct = Int(Double(complete) / Double(total) * 100)
                Text("\(pct)%")
                    .font(AppTypography.cardMeta)
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
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 4)
                    .fill(ratio >= 1.0 ? Color.green : (ratio > 0.5 ? .orange : .red))
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(height: 8)
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
