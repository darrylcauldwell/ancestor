import SwiftUI

/// Sourcing integrity view — the audit's twin. Surfaces facts that lack
/// credible backing (no source / estimate-only / manual-only) so the user
/// can prioritise citation work before generating a research report.
///
/// Three sections, each collapsible:
///   - Unsourced     — the field has no FieldSource at all
///   - Estimate only — every source has origin == .manualEstimate
///   - Manual only   — every source is one of manual.* (no external corroboration)
///
/// Each row exposes "Add citation" which opens EditPersonView for that profile.
struct SourcingIntegrityView: View {
    @Environment(AppState.self) private var appState

    @State private var editProfileID: String?
    @State private var showEditSheet = false

    @State private var unsourcedExpanded = true
    @State private var estimateOnlyExpanded = true
    @State private var manualOnlyExpanded = false

    @State private var searchText = ""

    private var report: SourcingIntegrityReport {
        SourcingIntegrityAnalyser.analyse(snapshot: appState.snapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if appState.snapshot.profiles.isEmpty {
                ContentUnavailableView {
                    Label("Sourcing", systemImage: "checkmark.seal")
                } description: {
                    Text("Import or enter profiles to see sourcing integrity.")
                }
            } else {
                let r = report
                if r.unsourced.isEmpty && r.estimateOnly.isEmpty && r.manualOnly.isEmpty {
                    ContentUnavailableView {
                        Label("All facts cited", systemImage: "checkmark.seal.fill")
                    } description: {
                        Text("Every populated field has a non-manual source.")
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            section(
                                title: "Unsourced",
                                description: "No source recorded for this field.",
                                icon: "questionmark.circle.fill",
                                color: .red,
                                issues: filtered(r.unsourced),
                                isExpanded: $unsourcedExpanded
                            )
                            section(
                                title: "Estimate only",
                                description: "Backed solely by a manual estimate.",
                                icon: "exclamationmark.triangle.fill",
                                color: .orange,
                                issues: filtered(r.estimateOnly),
                                isExpanded: $estimateOnlyExpanded
                            )
                            section(
                                title: "Manual only",
                                description: "No external corroboration — only manual entries.",
                                icon: "hand.raised.fill",
                                color: .yellow,
                                issues: filtered(r.manualOnly),
                                isExpanded: $manualOnlyExpanded
                            )
                        }
                        .padding()
                    }
                }
            }
        }
        .navigationTitle("Sourcing")
        .sheet(isPresented: $showEditSheet) {
            if let id = editProfileID {
                EditPersonView(profileID: id)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        let r = report
        return HStack(spacing: 12) {
            countBadge(label: "Unsourced", count: r.unsourced.count, color: .red)
            countBadge(label: "Estimate", count: r.estimateOnly.count, color: .orange)
            countBadge(label: "Manual only", count: r.manualOnly.count, color: .yellow)

            Spacer()

            Text("\(r.totalFields) populated fields")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)

            TextField("Search...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .padding()
    }

    private func countBadge(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(count)")
                .font(.callout)
                .fontWeight(.semibold)
            Text(label)
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Section

    private func section(
        title: String,
        description: String,
        icon: String,
        color: Color,
        issues: [SourcingIssue],
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(AppTypography.cardTitle)
                    Text("(\(issues.count))")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                Text(description)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)

                if issues.isEmpty {
                    Text("None.")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 22)
                } else {
                    VStack(spacing: 6) {
                        ForEach(issues) { issue in
                            row(issue)
                        }
                    }
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func row(_ issue: SourcingIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(issue.profileName)
                        .font(AppTypography.cardTitle)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(issue.field.rawValue)
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
                Text(issue.displayValue)
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                editProfileID = issue.profileID
                showEditSheet = true
            } label: {
                Label("Add citation", systemImage: "quote.bubble")
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .help("Open the editor for this profile to add or upgrade the source")
            .accessibilityHint("Open the editor for this profile to add or upgrade the source")
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    // MARK: - Filtering

    private func filtered(_ issues: [SourcingIssue]) -> [SourcingIssue] {
        guard !searchText.isEmpty else { return issues }
        let q = searchText
        return issues.filter {
            $0.profileName.localizedCaseInsensitiveContains(q)
                || $0.field.rawValue.localizedCaseInsensitiveContains(q)
                || $0.displayValue.localizedCaseInsensitiveContains(q)
        }
    }
}
