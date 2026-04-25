import SwiftUI

/// Review UI for pending facts submitted by the Field Researcher.
/// Each finding shows: evidence text, source link, 4-gate score,
/// convergence assessment, any discrepancy, and the model's reasoning.
/// Review friction: individualReview minimum — human decides each one.
struct PendingFactsReviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry
    @State private var processedFindings: [ProcessedFinding] = []
    @State private var isProcessing = false
    @State private var narrativeFindings: [NarrativeFindingRow] = []

    let profileID: String

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
                .padding()
            Divider()

            if isProcessing {
                ProgressView("Processing pending facts through Evidence Firewall...")
                    .frame(maxHeight: .infinity)
            } else if processedFindings.isEmpty && narrativeFindings.isEmpty {
                ContentUnavailableView {
                    Label("No Pending Findings", systemImage: "tray")
                } description: {
                    Text("Run the Field Researcher to discover evidence from unstructured sources.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        // Structured findings
                        if !processedFindings.isEmpty {
                            Text("Evidence Findings")
                                .font(AppTypography.cardTitle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)

                            ForEach(processedFindings) { finding in
                                findingCard(finding)
                            }
                        }

                        // Narrative findings
                        if !narrativeFindings.isEmpty {
                            Text("Narrative Findings")
                                .font(AppTypography.cardTitle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.top, 8)

                            ForEach(narrativeFindings) { narrative in
                                narrativeCard(narrative)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear { processFindings() }
    }

    // MARK: - Summary

    private var summaryBar: some View {
        let readyCount = processedFindings.filter { $0.status == .readyForReview }.count
        let rejectedCount = processedFindings.filter { $0.status == .rejected }.count

        return HStack(spacing: 16) {
            if let profile = appState.snapshot.profiles[profileID] {
                Text(profile.displayName)
                    .font(AppTypography.cardTitle)
            }

            Spacer()

            if readyCount > 0 {
                Text("\(readyCount) to review")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            }

            if rejectedCount > 0 {
                Text("\(rejectedCount) rejected")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            }

            if !narrativeFindings.isEmpty {
                Text("\(narrativeFindings.count) narrative")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            }

            Button("Refresh") { processFindings() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }

    // MARK: - Finding Card

    private func findingCard(_ finding: ProcessedFinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                if finding.status == .rejected {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(finding.finding.field)
                            .font(AppTypography.cardTitle)
                        Text(finding.finding.value)
                            .font(AppTypography.cardBody)
                            .foregroundStyle(.secondary)
                    }

                    // Source with tier badge
                    HStack(spacing: 4) {
                        if let tier = finding.sourceTier {
                            Text(tier.description)
                                .font(AppTypography.sourceBadge)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .glassEffect(.regular, in: .capsule)
                        }
                        Text(finding.finding.sourceTitle)
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Scorer verdict
                if let verdict = finding.scorerVerdict {
                    verdictBadge(verdict)
                }
            }

            // Evidence text
            Text(finding.finding.evidenceText)
                .font(AppTypography.cardBody)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)

            // Source URL (clickable)
            if let url = URL(string: finding.finding.sourceURL) {
                Link(finding.finding.sourceURL, destination: url)
                    .font(AppTypography.badge)
                    .lineLimit(1)
            }

            // Discrepancy warning
            if let discrepancy = finding.discrepancy {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Conflicts with tree: \(discrepancy.existingValue) → \(discrepancy.sourceValue) (\(discrepancy.severity.rawValue))")
                        .font(AppTypography.badge)
                        .foregroundStyle(.orange)
                }
            }

            // Rejection reason
            if let reason = finding.rejectionReason {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.red)
                    Text(reason)
                        .font(AppTypography.badge)
                        .foregroundStyle(.red)
                }
            }

            // Reasoning (collapsible)
            DisclosureGroup("Reasoning") {
                Text(finding.finding.reasoning)
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
            }
            .font(AppTypography.badge)
            .foregroundStyle(.secondary)

            // Actions
            if finding.status == .readyForReview {
                Divider()
                HStack {
                    Button("Accept") {
                        acceptFinding(finding)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)

                    Button("Reject") {
                        rejectFinding(finding)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Spacer()

                    Text(finding.finding.confidence)
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .opacity(finding.status == .rejected ? 0.5 : 1.0)
    }

    @ViewBuilder
    private func verdictBadge(_ verdict: RecordVerdict) -> some View {
        let (label, color): (String, Color) = switch verdict {
        case .fact: ("Fact", .green)
        case .lead: ("Lead", .orange)
        case .impossible: ("Impossible", .red)
        }
        Text(label)
            .font(AppTypography.badge)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Narrative Card

    private func narrativeCard(_ narrative: NarrativeFindingRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "book")
                    .foregroundStyle(.purple)
                Text(narrative.category)
                    .font(AppTypography.cardTitle)
                if let period = narrative.dateOrPeriod {
                    Text(period)
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(narrative.description)
                .font(AppTypography.cardBody)

            Text(narrative.evidenceText)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let url = URL(string: narrative.sourceURL) {
                Link(narrative.sourceTitle, destination: url)
                    .font(AppTypography.badge)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    // MARK: - Data Loading

    private func processFindings() {
        guard let db = appState.currentDatabase else { return }
        isProcessing = true

        Task {
            let processor = PendingFactsProcessor(
                db: db, snapshot: appState.snapshot,
                sourceInfoMap: registry.buildSourceInfoMap()
            )
            let results = await processor.process(profileID: profileID)
            processedFindings = results

            // Load narrative findings
            narrativeFindings = loadNarrativeFindings(db: db)

            isProcessing = false
        }
    }

    private func loadNarrativeFindings(db: ProjectDatabase) -> [NarrativeFindingRow] {
        (try? db.dbQueue.read { readDB in
            let rows = try Row.fetchAll(readDB, sql: """
                SELECT * FROM narrative_findings WHERE profile_id = ? ORDER BY submitted_at DESC
                """, arguments: [profileID])
            return rows.map { row in
                NarrativeFindingRow(
                    id: row["id"] as String? ?? UUID().uuidString,
                    category: row["category"] as String? ?? "",
                    description: row["description"] as String? ?? "",
                    dateOrPeriod: row["date_or_period"] as String?,
                    sourceURL: row["source_url"] as String? ?? "",
                    sourceTitle: row["source_title"] as String? ?? "",
                    evidenceText: row["evidence_text"] as String? ?? ""
                )
            }
        }) ?? []
    }

    // MARK: - Actions

    private func acceptFinding(_ finding: ProcessedFinding) {
        guard let db = appState.currentDatabase else { return }
        try? db.updatePendingFactStatus(id: finding.id, status: "accepted", verificationStatus: "verified")
        processedFindings.removeAll { $0.id == finding.id }
    }

    private func rejectFinding(_ finding: ProcessedFinding) {
        guard let db = appState.currentDatabase else { return }
        try? db.updatePendingFactStatus(id: finding.id, status: "rejected", verificationStatus: "rejected")
        // Record rejection for this profile (sticky memory)
        try? db.saveRejection(profileID: profileID, recordID: finding.id)
        processedFindings.removeAll { $0.id == finding.id }
    }
}

// MARK: - Helper Types

import GRDB

struct NarrativeFindingRow: Identifiable {
    let id: String
    let category: String
    let description: String
    let dateOrPeriod: String?
    let sourceURL: String
    let sourceTitle: String
    let evidenceText: String
}
