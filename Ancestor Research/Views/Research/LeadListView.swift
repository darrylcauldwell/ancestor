import SwiftUI

/// Lead management view — shows all leads with status, investigation, and promotion actions.
struct LeadListView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry
    @State private var leads: [Lead] = []
    @State private var filterStatus: LeadStatus?
    @State private var isLoading = false

    /// Callback that runs the research pipeline against a lead. Owned by
    /// ContentView so it can also flip the shared `showResearchProgress`
    /// sheet — keeping the trigger out of the parent body's modifier chain,
    /// which is already at Swift's type-checker complexity ceiling.
    let onResearchLead: (Lead) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 12) {
                Text("Leads")
                    .font(AppTypography.popoverTitle)

                Spacer()

                Picker("Status", selection: $filterStatus) {
                    Text("All").tag(nil as LeadStatus?)
                    Text("New").tag(LeadStatus.new as LeadStatus?)
                    Text("Investigated").tag(LeadStatus.investigated as LeadStatus?)
                    Text("Promoted").tag(LeadStatus.promoted as LeadStatus?)
                    Text("Dismissed").tag(LeadStatus.dismissed as LeadStatus?)
                }
                .pickerStyle(.segmented)
                .frame(width: 400)

                Button("Refresh") { loadLeads() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .padding()
            Divider()

            // Lead list
            let filtered = filteredLeads
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label("No Leads", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text(leads.isEmpty ? "Research profiles to discover leads." : "No leads match this filter.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { lead in
                            leadCard(lead)
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear { loadLeads() }
    }

    private var filteredLeads: [Lead] {
        guard let status = filterStatus else { return leads }
        return leads.filter { $0.status == status }
    }

    private func leadCard(_ lead: Lead) -> some View {
        HStack(spacing: 10) {
            leadStatusIcon(lead.status)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(lead.name)
                        .font(AppTypography.cardTitle)
                    if let year = lead.birthYear {
                        Text("b. ~\(String(year))")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                    if let rel = lead.relationship {
                        Text(rel)
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(lead.evidence)
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(lead.source.rawValue)
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                    Text(lead.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Actions
            if lead.status == .new || lead.status == .investigated {
                Button("Research") {
                    onResearchLead(lead)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .help("Run the research pipeline against this lead's identity (not the profile that generated it). Opens Triage with the results.")

                Button("Dismiss") {
                    dismissLead(lead)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .opacity(lead.status == .dismissed ? 0.5 : 1.0)
    }

    @ViewBuilder
    private func leadStatusIcon(_ status: LeadStatus) -> some View {
        switch status {
        case .new:
            Image(systemName: "sparkle")
                .foregroundStyle(.blue)
        case .investigating:
            ProgressView()
                .controlSize(.small)
        case .investigated:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.orange)
        case .promoted:
            Image(systemName: "person.badge.plus")
                .foregroundStyle(.green)
        case .dismissed:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func loadLeads() {
        guard let db = appState.currentDatabase else { return }
        leads = (try? db.loadLeads()) ?? []
    }

    private func dismissLead(_ lead: Lead) {
        guard let db = appState.currentDatabase else { return }
        var dismissed = lead
        dismissed = Lead(
            id: dismissed.id, profileID: dismissed.profileID,
            name: dismissed.name, surname: dismissed.surname, givenName: dismissed.givenName,
            birthYear: dismissed.birthYear, deathYear: dismissed.deathYear,
            relationship: dismissed.relationship, source: dismissed.source,
            status: .dismissed, evidence: dismissed.evidence,
            createdAt: dismissed.createdAt,
            investigatedAt: dismissed.investigatedAt,
            resolvedAt: Date(), resolution: .dismissed
        )
        try? db.saveLead(dismissed)
        loadLeads()
    }
}
