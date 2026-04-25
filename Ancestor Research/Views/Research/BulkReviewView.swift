import SwiftUI

/// Bulk review UI for whole-tree research results.
/// Sorts findings by friction tier: conflicts first, then corrections,
/// then confirmations, then refinements. Allows batch operations.
struct BulkReviewView: View {
    @Environment(AppState.self) private var appState
    let results: [String: ResearchResult]  // profileID → result
    @State private var filterTier: FrictionTier?
    @State private var processedCount = 0

    var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            HStack(spacing: 16) {
                Text("Bulk Review")
                    .font(AppTypography.popoverTitle)

                Spacer()

                ForEach(FrictionTier.allCases, id: \.self) { tier in
                    let count = findings(for: tier).count
                    if count > 0 {
                        frictionBadge(tier, count: count)
                    }
                }

                Text("\(processedCount) processed")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()

            // Findings list sorted by friction
            let items = sortedFindings
            if items.isEmpty {
                ContentUnavailableView {
                    Label("All Clear", systemImage: "checkmark.circle")
                } description: {
                    Text("No findings to review.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items, id: \.id) { finding in
                            findingCard(finding)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    // MARK: - Friction Sorting

    private var sortedFindings: [BulkFinding] {
        var all: [BulkFinding] = []

        for (profileID, result) in results {
            let profile = appState.snapshot.profiles[profileID]
            let profileName = profile?.displayName ?? profileID

            for cluster in result.clusters {
                let tier = frictionTier(for: cluster)
                if let filter = filterTier, tier != filter { continue }

                all.append(BulkFinding(
                    id: cluster.id,
                    profileID: profileID,
                    profileName: profileName,
                    tier: tier,
                    summary: "\(cluster.displayName) — \(cluster.records.count) records, \(cluster.confidence.rawValue)",
                    cluster: cluster
                ))
            }
        }

        // Sort: conflicts first, then corrections, confirmations, refinements
        return all.sorted { $0.tier.sortOrder < $1.tier.sortOrder }
    }

    private func findings(for tier: FrictionTier) -> [BulkFinding] {
        sortedFindings.filter { $0.tier == tier }
    }

    private func frictionTier(for cluster: LifeCluster) -> FrictionTier {
        if cluster.confidence == .ambiguous { return .conflict }
        let hasFacts = cluster.records.contains { $0.verdict == .fact }
        if !hasFacts { return .correction }
        if cluster.confidence == .weak { return .confirmation }
        return .refinement
    }

    // MARK: - Card

    private func findingCard(_ finding: BulkFinding) -> some View {
        HStack(spacing: 10) {
            frictionIcon(finding.tier)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(finding.profileName)
                        .font(AppTypography.cardTitle)
                    Text(finding.tier.rawValue)
                        .font(AppTypography.badge)
                        .foregroundStyle(finding.tier.color)
                }
                Text(finding.summary)
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Review") {
                appState.researchProfileID = finding.profileID
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func frictionBadge(_ tier: FrictionTier, count: Int) -> some View {
        HStack(spacing: 4) {
            frictionIcon(tier)
            Text("\(count)")
                .font(AppTypography.cardMeta)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .onTapGesture {
            filterTier = filterTier == tier ? nil : tier
        }
    }

    @ViewBuilder
    private func frictionIcon(_ tier: FrictionTier) -> some View {
        switch tier {
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .correction:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        case .confirmation:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.blue)
        case .refinement:
            Image(systemName: "plus.circle")
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Types

/// Review friction per §20.6 — how much user effort is needed to process a finding.
/// Higher friction = more attention required. Sorted highest-first in bulk review.
nonisolated enum ReviewFriction: Int, CaseIterable, Sendable {
    case autoStage = 0          // Refinements — applied with undo, user glances
    case batchReview = 1        // Confirmations — "Accept all N" button
    case individualReview = 2   // Corrections — old→new comparison per item
    case mustResolve = 3        // Conflicts — cannot commit until resolved
    case newFinding = 4         // Discoveries — novel information for user attention
}

nonisolated enum FrictionTier: String, CaseIterable, Sendable {
    case conflict = "Conflict"
    case correction = "Correction"
    case confirmation = "Confirmation"
    case refinement = "Refinement"

    var sortOrder: Int {
        switch self {
        case .conflict: 0
        case .correction: 1
        case .confirmation: 2
        case .refinement: 3
        }
    }

    var color: Color {
        switch self {
        case .conflict: .red
        case .correction: .orange
        case .confirmation: .blue
        case .refinement: .green
        }
    }

    /// Map to the spec's ReviewFriction level.
    var reviewFriction: ReviewFriction {
        switch self {
        case .conflict: .mustResolve
        case .correction: .individualReview
        case .confirmation: .batchReview
        case .refinement: .autoStage
        }
    }
}

private struct BulkFinding {
    let id: String
    let profileID: String
    let profileName: String
    let tier: FrictionTier
    let summary: String
    let cluster: LifeCluster
}
