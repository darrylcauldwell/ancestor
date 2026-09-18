import SwiftUI
import AncestorKit

/// SC-2 — this profile's lead queue, reviewed IN CONTEXT on the card.
///
/// The consolidation ruling (owner, 2026-08-24): per-profile is THE review
/// surface; the global Triage tab was retired. This block gives every lead
/// action Triage had — contextual Add (including the #37
/// child-of-shared-parents promotion), Research, Dismiss/Restore, the
/// contradicted fold — scoped to one person, with no watermark: the queue
/// is the truth, a row leaves when acted on.
///
/// Same identity-grouping as the old Findings queue (`leadGroupKey`), so a
/// candidate surfaced by three records is one row, not three.
struct ProfileLeadsBlock: View {
    @Environment(AppState.self) private var appState
    let profile: Profile

    @State private var active: [[Lead]] = []        // grouped, representative first
    @State private var contradicted: [(group: [Lead], reason: String)] = []
    @State private var dismissed: [Lead] = []
    @State private var evidenceMeta: [String: ProjectDatabase.LeadEvidenceMeta] = [:]
    @State private var showContradicted = false
    @State private var showDismissed = false
    @State private var showAllActive = false

    /// Bound the default view — a research run can mint dozens of namesake
    /// candidates (60 on one profile, 2026-08-25). Never silently: the
    /// "show all" row states what's folded away.
    private let activeCap = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !active.isEmpty || !contradicted.isEmpty || !dismissed.isEmpty {
                HStack(spacing: 6) {
                    Text("Leads")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(active.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                let visible = showAllActive ? active : Array(active.prefix(activeCap))
                ForEach(visible.indices, id: \.self) { i in
                    leadRow(visible[i])
                }
                if active.count > activeCap && !showAllActive {
                    Button("Show all \(active.count) leads") { showAllActive = true }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }
                if !contradicted.isEmpty {
                    DisclosureGroup(isExpanded: $showContradicted) {
                        ForEach(contradicted.indices, id: \.self) { i in
                            contradictedRow(contradicted[i])
                        }
                    } label: {
                        Label("Contradicted by applied facts (\(contradicted.count))",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !dismissed.isEmpty {
                    DisclosureGroup(isExpanded: $showDismissed) {
                        ForEach(dismissed, id: \.id) { lead in
                            dismissedRow(lead)
                        }
                    } label: {
                        Label("Dismissed (\(dismissed.count))", systemImage: "archivebox")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, (active.isEmpty && contradicted.isEmpty && dismissed.isEmpty) ? 0 : 4)
        .task(id: profile.id) { reload() }
        .onChange(of: appState.treeContentRevision) { _, _ in reload() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func leadRow(_ group: [Lead]) -> some View {
        if let lead = group.first {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(lead.name)
                            .font(.caption.weight(.semibold))
                        if let year = lead.birthYear {
                            Text("b. \(String(year))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let rel = lead.relationship, !rel.isEmpty {
                            Text(rel)
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .glassEffect(.regular, in: .capsule)
                        }
                        if group.count > 1 {
                            Text("\(group.count) records")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(lead.evidence)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let meta = evidenceMeta[lead.id], let sourceID = meta.sourceID {
                        SourceVerifyLink(sourceID: sourceID, citationURL: meta.citationURL)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let action = CampaignReviewService.addAction(
                    for: lead, generatorParents: generatorParents()
                ) {
                    Button(action.label) {
                        if appState.addLeadToTree(lead, action: action) { reload() }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.mini)
                } else {
                    Button("Research") { appState.researchLeadRequest = lead }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                        .help(CampaignReviewService.researchExplanation(for: lead))
                }
                Button("Dismiss") {
                    for member in group { appState.dismissLead(member) }
                    reload()
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            .padding(8)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func contradictedRow(_ entry: (group: [Lead], reason: String)) -> some View {
        if let lead = entry.group.first {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lead.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.reason)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss") {
                    for member in entry.group { appState.dismissLead(member) }
                    reload()
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            .padding(8)
            .opacity(0.75)
        }
    }

    private func dismissedRow(_ lead: Lead) -> some View {
        HStack(spacing: 8) {
            Text(lead.name)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore") {
                appState.restoreLead(lead)
                reload()
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Data

    // Review C10 — resolved by the shared helper, which filters out step and
    // adoptive parent edges: the #37 promotion mints BIOLOGICAL edges, so a
    // step-mother must never head an "Add as child of X & Y" button.
    private func generatorParents() -> [(id: String, name: String)] {
        CampaignReviewService.generatorParents(for: profile.id, snapshot: appState.snapshot)
    }

    private func reload() {
        guard let db = appState.currentDatabase else { return }
        let all = (try? db.loadLeads(profileID: profile.id)) ?? []
        evidenceMeta = (try? db.leadEvidenceMeta()) ?? [:]

        dismissed = all.filter { $0.status == .dismissed }

        let pending = all.filter { $0.status == .new || $0.status == .investigated }
        var groups: [String: [Lead]] = [:]
        for lead in pending {
            groups[CampaignReviewService.leadGroupKey(lead), default: []].append(lead)
        }
        var activeGroups: [[Lead]] = []
        var contradictedGroups: [(group: [Lead], reason: String)] = []
        for group in groups.values.sorted(by: { ($0.first?.name ?? "") < ($1.first?.name ?? "") }) {
            if let lead = group.first,
               let reason = LeadContradictionCheck.contradiction(lead: lead, profile: profile) {
                contradictedGroups.append((group, reason))
            } else {
                activeGroups.append(group)
            }
        }
        active = activeGroups
        contradicted = contradictedGroups
    }
}
