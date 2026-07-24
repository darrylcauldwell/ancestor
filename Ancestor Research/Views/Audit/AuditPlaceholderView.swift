import SwiftUI

/// Health view — the tree's data-quality home. Runs the audit rules and
/// displays errors / warnings / info grouped by severity, with Issues/Gaps and
/// severity filters, the conflict sweep, import-duplicate scan, and the open-
/// disputes list. Wired to the `.health` sidebar tab. (Formerly the tab-less
/// AuditPlaceholderView.)
struct HealthView: View {
    /// Navigate to a finding's profile (Tree → Full Detail). Injected by
    /// ContentView; nil disables the affordance in previews.
    var onOpenProfile: ((String) -> Void)? = nil
    /// Open a finding's profile straight in the editor.
    var onEditProfile: ((String) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @State private var auditVM = AuditViewModel()
    @State private var openDisputeCount: Int?
    @State private var showDisputeList = false
    @State private var openDisputeRows: [DisputeRow] = []

    var body: some View {
        VStack(spacing: 0) {
            // Two-row toolbar: actions on top, filters below — keeps the bar
            // calm and stops the buttons truncating on a single line.
            VStack(alignment: .leading, spacing: 10) {
                // Row 1 — actions + search. No manual "Re-run Audit": AppState
                // keeps the audit current after every change, so Health is always
                // up to date on open.
                HStack {
                    // Secondary sweeps tucked into a menu — run occasionally, so
                    // they don't need to sit out on the bar competing for space.
                    Menu {
                        Button {
                            // CONFLICT_LAYER_SPEC CL2 — manual conflict sweep;
                            // refreshes the live open-dispute count.
                            appState.runConflictSweep(force: true)
                            openDisputeCount = try? appState.currentDatabase?.openDisputeCount()
                        } label: {
                            Label("Scan for Conflicts", systemImage: "exclamationmark.triangle")
                        }
                        Button {
                            appState.scanForImportDuplicates()
                        } label: {
                            Label("Find Import Duplicates", systemImage: "person.2.slash")
                        }
                    } label: {
                        Label("Tools", systemImage: "wrench.and.screwdriver")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .disabled(appState.snapshot.profiles.isEmpty)

                    if let count = openDisputeCount, count > 0 {
                        Button {
                            showDisputeList.toggle()
                            if showDisputeList {
                                openDisputeRows = (try? appState.currentDatabase?.allOpenDisputes()) ?? []
                            }
                        } label: {
                            Text("\(count) open dispute\(count == 1 ? "" : "s")")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    TextField("Search...", text: $auditVM.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                // Row 2 — category + severity filters, with the severity summary
                // badges sitting between them.
                HStack(spacing: 12) {
                    Picker("Category", selection: $auditVM.filterCategory) {
                        Text("All").tag(nil as AuditCategory?)
                        HStack(spacing: 4) {
                            Text("Issues")
                            Text("(\(auditVM.issueCount))").foregroundStyle(.secondary)
                        }.tag(AuditCategory.issue as AuditCategory?)
                        HStack(spacing: 4) {
                            Text("Gaps")
                            Text("(\(auditVM.gapCount))").foregroundStyle(.secondary)
                        }.tag(AuditCategory.gap as AuditCategory?)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)

                    Spacer()

                    if let summary = auditVM.summary {
                        HStack(spacing: 12) {
                            severityBadge(.error, count: summary.errors.count)
                            severityBadge(.warning, count: summary.warnings.count)
                            severityBadge(.info, count: summary.info.count)
                        }
                    }

                    Picker("Severity", selection: $auditVM.filterSeverity) {
                        Text("All").tag(nil as Severity?)
                        Text("Errors").tag(Severity.error as Severity?)
                        Text("Warnings").tag(Severity.warning as Severity?)
                        Text("Info").tag(Severity.info as Severity?)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
            }
            .padding()
            .onAppear {
                openDisputeCount = try? appState.currentDatabase?.openDisputeCount()
            }

            Divider()

            // CONFLICT_LAYER_SPEC CL2 AC6 — open-disputes list: severity
            // desc, rows deep-link to the owning profile's resolution UI.
            if showDisputeList && !openDisputeRows.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(openDisputeRows.sorted {
                            ($0.severity ?? .none).rawValue > ($1.severity ?? .none).rawValue
                        }) { row in
                            Button {
                                appState.selectedProfileID = row.entityID
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(appState.snapshot.profiles[row.entityID]?.displayName ?? row.entityID)
                                            .font(AppTypography.cardTitle)
                                        Text("\(row.kind.rawValue) · \(row.field)\(row.severity.map { " · \($0.rawValue)" } ?? "")")
                                            .font(AppTypography.cardMeta)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 260)
                Divider()
            }

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
                                        .accessibilityLabel("Severity \(result.severity.rawValue)")
                                    // Clicking the finding jumps to the profile it
                                    // is about (Tree → Full Detail), so the user can
                                    // investigate or fix it in context.
                                    Button {
                                        onOpenProfile?(result.profileID)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(result.profileName)
                                                .font(AppTypography.cardTitle)
                                            Text(strippedMessage(result))
                                                .font(AppTypography.cardBody)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(onOpenProfile == nil)
                                    .help("Open \(result.profileName) in the tree")

                                    Button {
                                        onEditProfile?(result.profileID)
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .buttonStyle(.glass)
                                    .controlSize(.mini)
                                    .disabled(onEditProfile == nil)
                                    .help("Edit \(result.profileName)")

                                    Button {
                                        promoteToQuestion(result)
                                    } label: {
                                        Label("Promote", systemImage: "questionmark.bubble")
                                    }
                                    .buttonStyle(.glass)
                                    .controlSize(.mini)
                                    .help("Add as an open question on the workbench")
                                    .accessibilityHint("Add as an open question on the workbench")
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
        .navigationTitle("Health")
        .onAppear {
            // Always show the latest maintained summary. AppState keeps
            // `auditSummary` current after every mutation (import, edit, cleanse,
            // snooze), so this is free — no per-open recompute needed to be up to
            // date, which is why there's no manual "Re-run Audit" button.
            if let auto = appState.auditSummary { auditVM.summary = auto }
        }
    }

    /// Promote an audit issue to an OpenQuestion. The question text mirrors
    /// the audit message; provenance is recorded via QuestionOrigin.fromAudit
    /// so the workbench can surface where the question came from. Maps audit
    /// severity to question priority (error → high, warning → medium, info → low).
    private func promoteToQuestion(_ result: AuditResult) {
        let priority: QuestionPriority = switch result.severity {
        case .error: .high
        case .warning: .medium
        case .info: .low
        }
        let text = "\(result.profileName): \(strippedMessage(result))"
        appState.createQuestion(
            text: text,
            profileIDs: [result.profileID],
            priority: priority,
            promotedFrom: .fromAudit(ruleID: result.ruleID)
        )
        appState.successMessage = "Added to workbench questions."
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
                .accessibilityHidden(true)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(severity.rawValue) issues")
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
                                    .accessibilityLabel(ratio > 0.5 ? "Partial completeness" : "Severely incomplete")

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

                                Button("Research") {
                                    appState.researchProfileID = profile.id
                                }
                                .buttonStyle(.glass)
                                .controlSize(.mini)
                                // Per-profile promote: turn the missing-field
                                // checks into one OpenQuestion per gap with
                                // QuestionOrigin.fromGap. Menu shows one entry
                                // per missing check so the user can be selective.
                                Menu {
                                    ForEach(comp.missing, id: \.self) { check in
                                        Button("Promote \"\(check.shortLabel)\"") {
                                            promoteGap(profile: profile, check: check)
                                        }
                                    }
                                } label: {
                                    Label("Promote", systemImage: "questionmark.bubble")
                                }
                                .menuStyle(.borderlessButton)
                                .controlSize(.mini)
                                .help("Add a missing field as a workbench question")
                                .accessibilityHint("Add a missing field as a workbench question")
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

    /// Promote a missing-field gap to an OpenQuestion, recording the field
    /// in `QuestionOrigin.fromGap` so the workbench shows where it came from.
    private func promoteGap(profile: Profile, check: CompletenessCheck) {
        let text: String
        let origin: QuestionOrigin
        switch check {
        case .field(let field):
            text = "\(profile.displayName): missing \(field.rawValue)"
            origin = .fromGap(profileID: profile.id, field: field)
        case .hasParents:
            text = "\(profile.displayName): missing parents"
            // hasParents isn't a ProfileField — reuse fromGap with a
            // sentinel field. firstName is the closest "identity" field.
            origin = .fromGap(profileID: profile.id, field: .firstName)
        }
        appState.createQuestion(
            text: text, profileIDs: [profile.id],
            priority: .medium, promotedFrom: origin
        )
        appState.successMessage = "Added to workbench questions."
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
