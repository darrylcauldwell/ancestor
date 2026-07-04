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
    @State private var agentFilter: AgentFilter = .all

    let profileID: String

    /// Filter the review surface by agent origin. The prose-corpus
    /// subsystem emits facts under `prose-extractor:<corpus_id>`
    /// agent IDs; the MCP field-researcher emits under
    /// `field-researcher` or `claude-code`. The filter chip lets the
    /// user isolate prose-extracted findings (typically softer
    /// evidence, narrative-heavy) from structured MCP submissions
    /// when reviewing.
    enum AgentFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case proseCorpus = "Prose corpora"
        case fieldResearcher = "Field researcher"

        var id: Self { self }

        func matches(agentID: String) -> Bool {
            switch self {
            case .all: return true
            case .proseCorpus: return agentID.hasPrefix("prose-extractor:")
            case .fieldResearcher: return !agentID.hasPrefix("prose-extractor:")
            }
        }
    }

    private var visibleFindings: [ProcessedFinding] {
        processedFindings.filter { agentFilter.matches(agentID: $0.finding.agentID) }
    }

    private var visibleNarratives: [NarrativeFindingRow] {
        narrativeFindings.filter { agentFilter.matches(agentID: $0.agentID) }
    }

    /// `true` when at least one prose-extracted finding is present
    /// in either pending facts or narratives. Drives the filter
    /// picker's visibility — the toolbar stays clean for users who
    /// don't have prose corpora configured.
    private var hasProseExtractedFindings: Bool {
        processedFindings.contains(where: { $0.finding.agentID.hasPrefix("prose-extractor:") })
            || narrativeFindings.contains(where: { $0.agentID.hasPrefix("prose-extractor:") })
    }

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
                let shownFindings = visibleFindings
                let shownNarratives = visibleNarratives
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if shownFindings.isEmpty && shownNarratives.isEmpty {
                            ContentUnavailableView {
                                Label("Nothing matches this filter", systemImage: "line.3.horizontal.decrease.circle")
                            } description: {
                                Text("Switch to \"All\" to see every pending finding.")
                            }
                            .padding(.top, 32)
                        }

                        // Structured findings
                        if !shownFindings.isEmpty {
                            Text("Evidence Findings")
                                .font(AppTypography.cardTitle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)

                            ForEach(shownFindings) { finding in
                                findingCard(finding)
                            }
                        }

                        // Narrative findings
                        if !shownNarratives.isEmpty {
                            Text("Narrative Findings")
                                .font(AppTypography.cardTitle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.top, 8)

                            ForEach(shownNarratives) { narrative in
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

            // Agent-origin filter. Only rendered when there's any
            // prose-extracted finding present — keeps the toolbar
            // uncluttered for users who don't have prose corpora set up.
            if hasProseExtractedFindings {
                Picker("Filter", selection: $agentFilter) {
                    ForEach(AgentFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .labelsHidden()
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
        (try? db.loadNarrativeFindingRows(profileID: profileID)) ?? []
    }

    // MARK: - Actions

    private func acceptFinding(_ finding: ProcessedFinding) {
        guard let db = appState.currentDatabase else { return }

        // 1. Mark pending fact as accepted
        try? db.updatePendingFactStatus(id: finding.id, status: "accepted", verificationStatus: "verified")

        // 2. Apply the fact to the tree profile
        applyFactToProfile(finding: finding, db: db)

        // 3. Add field source for provenance tracking
        addFieldSource(finding: finding, db: db)

        processedFindings.removeAll { $0.id == finding.id }
    }

    private func applyFactToProfile(finding: ProcessedFinding, db: ProjectDatabase) {
        try? db.applyAcceptedPendingFact(
            profileID: profileID,
            field: finding.finding.field,
            value: finding.finding.value
        )

        // Rebuild snapshot to reflect the change
        if let newSnapshot = try? db.buildSnapshot() {
            appState.snapshot = newSnapshot
        }
    }

    private func addFieldSource(finding: ProcessedFinding, db: ProjectDatabase) {
        try? db.addFieldResearcherProvenance(
            profileID: profileID,
            field: finding.finding.field,
            value: finding.finding.value,
            sourceTitle: finding.finding.sourceTitle
        )
    }

    private func rejectFinding(_ finding: ProcessedFinding) {
        guard let db = appState.currentDatabase else { return }
        try? db.updatePendingFactStatus(id: finding.id, status: "rejected", verificationStatus: "rejected")
        // Record rejection for this profile (sticky memory)
        try? db.saveRejection(profileID: profileID, recordID: finding.id)
        processedFindings.removeAll { $0.id == finding.id }
    }
}
