import SwiftUI

/// Review candidate life clusters from a research run.
/// Each cluster is a card showing records, confidence, and accept/reject actions.
struct ClusterReviewView: View {
    @Bindable var vm: ResearchViewModel
    let result: ResearchResult
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            summaryBar
                .padding()
            Divider()

            if result.clusters.isEmpty {
                ContentUnavailableView {
                    Label("No Candidates", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("No matching records were found across the searched sources.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(result.clusters) { cluster in
                            clusterCard(cluster)
                        }

                        // Discoveries
                        if !discoveries.isEmpty {
                            discoveriesSection
                        }

                        // Source frontier
                        sourceFrontierSection
                    }
                    .padding()
                }
            }
        }
    }

    // MARK: - Summary Bar

    @Environment(SourceRegistry.self) private var registry

    private var gpsScore: GPSScore {
        let sourceInfoMap = registry.buildSourceInfoMap()
        let searchedSources = Set(result.allScoredRecords.map(\.record.sourceID))
        return GPSScorer.score(
            result: result,
            sourceInfoMap: sourceInfoMap,
            searchedSourceCount: searchedSources.count,
            totalSourceCount: registry.allSources().count
        )
    }

    private var summaryBar: some View {
        HStack(spacing: 16) {
            if let profile = vm.selectedProfile {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(AppTypography.cardTitle)
                    Text("\(result.clusters.count) candidate\(result.clusters.count == 1 ? "" : "s"), \(result.confirmedFacts.count) facts, \(result.leads.count) leads")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // GPS score
            gpsScoreBadge

            if vm.pendingDecisions > 0 {
                Text("\(vm.pendingDecisions) to review")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.orange)
            }

            Button("New Research") {
                vm.reset()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    private var gpsScoreBadge: some View {
        let gps = gpsScore
        let color: Color = switch gps.score {
        case 5: .green
        case 4: .blue
        case 3: .teal
        case 2: .orange
        default: .red
        }

        return VStack(spacing: 2) {
            Text("GPS \(gps.score)/\(gps.maximum)")
                .font(AppTypography.cardMeta)
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(gps.label)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }

    // MARK: - Cluster Card

    private func clusterCard(_ cluster: LifeCluster) -> some View {
        let decision = vm.clusterDecisions[cluster.id]

        return VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cluster.displayName)
                        .font(AppTypography.cardTitle)
                    HStack(spacing: 8) {
                        confidenceBadge(cluster.confidence)
                        if let birth = cluster.impliedBirthYear {
                            Text("b. ~\(String(birth))")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        if let death = cluster.impliedDeathYear {
                            Text("d. ~\(String(death))")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(cluster.records.count) records")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let merge = cluster.mergeCandidate {
                    Text("Possible duplicate")
                        .font(AppTypography.badge)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glassEffect(.regular, in: .capsule)
                }
            }

            Divider()

            // Records
            ForEach(cluster.records, id: \.id) { scored in
                recordRow(scored)
            }

            // Household members
            if !cluster.householdMembers.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Household members")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                    ForEach(cluster.householdMembers, id: \.name) { member in
                        HStack(spacing: 8) {
                            Text(member.name)
                                .font(AppTypography.cardBody)
                            if let rel = member.relationship.nilIfEmpty {
                                Text(rel)
                                    .font(AppTypography.badge)
                                    .foregroundStyle(.tertiary)
                            }
                            if let age = member.age {
                                Text("age \(age)")
                                    .font(AppTypography.badge)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            Divider()

            // Actions
            HStack {
                if decision == .accepted {
                    Label("Accepted", systemImage: "checkmark.circle.fill")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.green)
                } else if decision == .rejected {
                    Label("Rejected", systemImage: "xmark.circle.fill")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.red)
                } else if decision == .deferred {
                    Label("Deferred", systemImage: "clock")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.orange)
                }

                Spacer()

                if decision != .accepted {
                    Button("Accept") { vm.acceptCluster(cluster) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
                if decision != .rejected {
                    Button("Reject") { vm.rejectCluster(cluster) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                if decision != .deferred && decision != nil {
                    Button("Defer") { vm.deferCluster(cluster) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .opacity(decision == .rejected ? 0.5 : 1.0)
    }

    // MARK: - Record Row

    @State private var expandedCitations: Set<String> = []

    private func recordRow(_ scored: ScoredRecord) -> some View {
        let citation = CitationRenderer.cite(scored.record)
        let isExpanded = expandedCitations.contains(scored.id)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                verdictIcon(scored.verdict)

                VStack(alignment: .leading, spacing: 2) {
                    Text(scored.summary)
                        .font(AppTypography.cardBody)
                        .lineLimit(2)

                    // Gate results
                    HStack(spacing: 6) {
                        ForEach(scored.gates, id: \.gate) { gate in
                            gateChip(gate)
                        }
                    }
                }

                Spacer()

                Text(scored.record.sourceID.uppercased())
                    .font(AppTypography.sourceBadge)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)

                Button {
                    if isExpanded {
                        expandedCitations.remove(scored.id)
                    } else {
                        expandedCitations.insert(scored.id)
                    }
                } label: {
                    Image(systemName: "quote.opening")
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Expandable citation
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    Text(citation.full)
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let url = citation.url {
                        Text(url)
                            .font(AppTypography.badge)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func verdictIcon(_ verdict: RecordVerdict) -> some View {
        switch verdict {
        case .fact:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .lead:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
        case .impossible:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func gateChip(_ gate: GateResult) -> some View {
        let color: Color = switch gate.outcome {
        case .pass: .green
        case .fail: .red
        case .softFail: .orange
        case .impossible: .red
        case .skip: .gray
        }

        return Text(gate.gate.rawValue)
            .font(AppTypography.badge)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color.opacity(0.5), lineWidth: 0.5)
            )
    }

    private func confidenceBadge(_ confidence: ClusterConfidence) -> some View {
        let (label, color): (String, Color) = switch confidence {
        case .strong: ("Strong", .green)
        case .moderate: ("Moderate", .blue)
        case .weak: ("Weak", .orange)
        case .ambiguous: ("Ambiguous", .red)
        }

        return Text(label)
            .font(AppTypography.badge)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Discoveries

    private var discoveries: [Discovery] {
        guard let profile = vm.selectedProfile else { return [] }
        return DiscoveryExtractor.extract(from: result, profile: profile, snapshot: appState.snapshot)
    }

    private var discoveriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Discoveries")
                    .font(AppTypography.cardTitle)
                Text("\(discoveries.count)")
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
            }

            ForEach(discoveries) { discovery in
                HStack(spacing: 10) {
                    discoveryIcon(discovery.type)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(discovery.description)
                            .font(AppTypography.cardBody)
                        Text(discovery.evidence)
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                        Text(discovery.suggestedAction)
                            .font(AppTypography.badge)
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func discoveryIcon(_ type: DiscoveryType) -> some View {
        switch type {
        case .newAncestor:
            Image(systemName: "person.badge.plus")
                .foregroundStyle(.green)
        case .maidenName:
            Image(systemName: "person.2")
                .foregroundStyle(.purple)
        case .unknownSibling:
            Image(systemName: "person.3")
                .foregroundStyle(.blue)
        case .spouseIdentified:
            Image(systemName: "heart")
                .foregroundStyle(.pink)
        case .householdMember:
            Image(systemName: "house")
                .foregroundStyle(.orange)
        case .militaryService:
            Image(systemName: "shield")
                .foregroundStyle(.red)
        case .unknownChild:
            Image(systemName: "figure.and.child.holdinghands")
                .foregroundStyle(.blue)
        case .occupationRevealed:
            Image(systemName: "briefcase")
                .foregroundStyle(.teal)
        case .addressFound:
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.cyan)
        case .alternateSpelling:
            Image(systemName: "textformat.abc")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Source Frontier

    private var sourceFrontierSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search Frontier")
                .font(AppTypography.cardTitle)
                .foregroundStyle(.secondary)

            ForEach(vm.sourceStatuses) { status in
                HStack(spacing: 8) {
                    Image(systemName: status.state == .complete ? "checkmark.circle" : "minus.circle")
                        .foregroundStyle(status.state == .complete ? Color.green : Color.gray)
                    Text(status.displayName)
                        .font(AppTypography.cardBody)
                    Spacer()
                    if status.resultCount > 0 {
                        Text("\(status.resultCount) results")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                    if let reason = status.reason {
                        Text(reason)
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
