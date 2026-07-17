import SwiftUI

/// Phase 1 of the lead-discovery pivot (`AncestorApp/LEAD_DISCOVERY_SPEC.md`).
///
/// A READ-ONLY view of the orphan lead pool clustered into candidate
/// identities by the deterministic `LeadDiscoveryEngine` — "possible people"
/// that emerge from leads the user hasn't linked to anyone yet. No AI, no
/// hypotheses, no mutation: it only re-presents leads that already exist,
/// grouped by who they might describe. Precision-first — confident clusters
/// (those with a consensus birth year) show first; yearless place-only
/// clusters sit behind a disclosure as explicitly lower confidence.
///
/// The heavy clustering runs off the main actor; the view shows a spinner
/// until it lands.
struct PossiblePeopleView: View {
    @Environment(AppState.self) private var appState

    @State private var confident: [LeadDiscoveryEngine.EmergentCluster] = []
    @State private var lowConfidence: [LeadDiscoveryEngine.EmergentCluster] = []
    @State private var totalLeads = 0
    @State private var isLoading = true
    @State private var showLowConfidence = false
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Finding possible people…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if confident.isEmpty && lowConfidence.isEmpty {
                ContentUnavailableView {
                    Label("No candidates yet", systemImage: "person.2.slash")
                } description: {
                    Text("Coherent people emerge from the lead pool as research accumulates leads. Run research to generate more.")
                }
            } else {
                header
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(confident) { clusterCard($0) }

                        if !lowConfidence.isEmpty {
                            DisclosureGroup(isExpanded: $showLowConfidence) {
                                ForEach(lowConfidence) { clusterCard($0) }
                            } label: {
                                Label("\(lowConfidence.count) lower-confidence (no birth year)",
                                      systemImage: "questionmark.circle")
                                    .font(AppTypography.cardMeta)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding()
                }
            }
        }
        .task { await compute() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Possible People")
                    .font(AppTypography.cardTitle)
                Text("\(confident.count) candidate\(confident.count == 1 ? "" : "s") from \(totalLeads) leads — read-only")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Cluster card

    @ViewBuilder
    private func clusterCard(_ cluster: LeadDiscoveryEngine.EmergentCluster) -> some View {
        let isOpen = expanded.contains(cluster.id)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if isOpen { expanded.remove(cluster.id) } else { expanded.insert(cluster.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(representativeName(cluster))
                            .font(AppTypography.cardTitle)
                        Text(metaLine(cluster))
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(cluster.leads.count) records")
                        .font(AppTypography.badge)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cluster.leads) { lead in
                        memberRow(lead)
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func memberRow(_ lead: Lead) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(lead.name.trimmingCharacters(in: .whitespaces).isEmpty ? "(unnamed)" : lead.name)
                    .font(AppTypography.cardBody)
                if let place = lead.place, !place.isEmpty {
                    Text("· \(place)")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !lead.evidence.isEmpty {
                Text(lead.evidence)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Presentation helpers

    /// The fullest name in the cluster stands in as its label — the record
    /// that spelled the person out most completely (e.g. "George Edwin Ward"
    /// over "George Ward").
    private func representativeName(_ cluster: LeadDiscoveryEngine.EmergentCluster) -> String {
        let best = cluster.leads
            .map { $0.name.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .max(by: { $0.count < $1.count })
        return best ?? cluster.surname.capitalized
    }

    private func metaLine(_ cluster: LeadDiscoveryEngine.EmergentCluster) -> String {
        var parts: [String] = []
        if let by = cluster.birthYear {
            parts.append("b~\(by)")
        } else {
            parts.append("no birth year")
        }
        let kinds = cluster.coherence.distinctEventKinds
        parts.append("\(kinds) event kind\(kinds == 1 ? "" : "s")")
        if cluster.coherence.distinctSources > 1 {
            parts.append("\(cluster.coherence.distinctSources) sources")
        }
        if cluster.coherence.originProfileCount > 1 {
            parts.append("from \(cluster.coherence.originProfileCount) relatives")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Compute

    private func compute() async {
        guard let db = appState.currentDatabase else { isLoading = false; return }
        // Cheap DB read on-actor; the O(n²)-within-block clustering runs off
        // the main actor so a large pool never beach-balls the UI.
        let leads = (try? db.loadLeads()) ?? []
        totalLeads = leads.count
        let clusters = await Task.detached(priority: .userInitiated) {
            LeadDiscoveryEngine.discover(leads: leads).filter { $0.coherence.isSurfaceable }
        }.value
        confident = clusters.filter { $0.birthYear != nil }
        lowConfidence = clusters.filter { $0.birthYear == nil }
        isLoading = false
    }
}
