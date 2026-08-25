import SwiftUI
import AncestorKit

/// SC-6 — the Workbench "Needs attention" router.
///
/// The consolidation ruling: per-profile is the review surface; this section
/// is the ROUTER that preserves the store-wide guarantee (nothing is ever
/// reachable only by knowing which profile to open — the 2026-08-21 lesson).
/// It answers "what needs me, anywhere?" with counts and jump-links and
/// performs NO review actions itself. No watermark: the queues are the
/// truth; a row disappears when its queues empty.
///
/// Below it, "Research suggestions" — the compact successor to the retired
/// Research tab's gap-ranked launcher (owner, 2026-08-25): the least-complete
/// real people, one Research button each.
struct WorkbenchAttentionView: View {
    @Environment(AppState.self) private var appState
    var onOpenProfile: (String) -> Void = { _ in }

    private struct AttentionRow: Identifiable {
        let id: String          // profile id
        let name: String
        let birthYear: Int?
        let pendingFacts: Int
        let leads: Int
        let proposals: Int
        let disputes: Int
        var total: Int { pendingFacts + leads + proposals + disputes }
    }

    @State private var rows: [AttentionRow] = []
    @State private var showAllRows = false
    private let rowCap = 15
    private let suggestionCap = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label("All caught up", systemImage: "checkmark.seal")
                    } description: {
                        Text("No pending facts, leads, proposals or disputes anywhere in the tree.")
                    }
                } else {
                    Text("Needs attention")
                        .font(.headline)
                    let visible = showAllRows ? rows : Array(rows.prefix(rowCap))
                    ForEach(visible) { row in
                        attentionRow(row)
                    }
                    if rows.count > rowCap && !showAllRows {
                        Button("Show all \(rows.count) profiles") { showAllRows = true }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                    }
                }

                Divider().padding(.vertical, 4)

                Text("Research suggestions")
                    .font(.headline)
                Text("Least-complete real people — likely to reward a research run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(suggestions(), id: \.id) { profile in
                    suggestionRow(profile)
                }
            }
            .padding()
        }
        .task { reload() }
        .onChange(of: appState.treeContentRevision) { _, _ in reload() }
    }

    // MARK: - Rows

    private func attentionRow(_ row: AttentionRow) -> some View {
        Button {
            onOpenProfile(row.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.callout.weight(.semibold))
                        if let year = row.birthYear {
                            Text("b. \(String(year))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(summary(row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Open \(row.name)'s card — review happens there")
    }

    private func summary(_ row: AttentionRow) -> String {
        var parts: [String] = []
        if row.pendingFacts > 0 { parts.append("\(row.pendingFacts) pending fact\(row.pendingFacts == 1 ? "" : "s")") }
        if row.leads > 0 { parts.append("\(row.leads) lead\(row.leads == 1 ? "" : "s")") }
        if row.proposals > 0 { parts.append("\(row.proposals) relationship proposal\(row.proposals == 1 ? "" : "s")") }
        if row.disputes > 0 { parts.append("\(row.disputes) open dispute\(row.disputes == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func suggestionRow(_ profile: Profile) -> some View {
        let comp = appState.snapshot.completeness(for: profile.id)
        return HStack(spacing: 8) {
            Button {
                onOpenProfile(profile.id)
            } label: {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.callout)
                    if let year = profile.birthDate?.bestYear {
                        Text("b. \(String(year))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(comp.score)/\(comp.maximum)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Research") {
                appState.researchProfileID = profile.id
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Open the research configuration for \(profile.displayName)")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Data

    private func reload() {
        guard let db = appState.currentDatabase else { rows = []; return }
        let factCounts = db.pendingFactCountsByProfile()
        let proposalCounts = db.pendingRelationshipCountsByProfile()
        var leadCounts: [String: Int] = [:]
        for lead in (try? db.loadLeads()) ?? []
        where lead.status == .new || lead.status == .investigated {
            leadCounts[lead.profileID, default: 0] += 1
        }
        var disputeCounts: [String: Int] = [:]
        for profile in appState.snapshot.profiles.values where !profile.disputes.isEmpty {
            disputeCounts[profile.id] = profile.disputes.count
        }

        let ids = Set(factCounts.keys)
            .union(proposalCounts.keys)
            .union(leadCounts.keys)
            .union(disputeCounts.keys)
        rows = ids.compactMap { id -> AttentionRow? in
            guard let profile = appState.snapshot.profiles[id] else { return nil }
            let row = AttentionRow(
                id: id,
                name: profile.displayName,
                birthYear: profile.birthDate?.bestYear,
                pendingFacts: factCounts[id] ?? 0,
                leads: leadCounts[id] ?? 0,
                proposals: proposalCounts[id] ?? 0,
                disputes: disputeCounts[id] ?? 0
            )
            return row.total > 0 ? row : nil
        }
        .sorted {
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.id < $1.id
        }
    }

    /// The launcher's ranking, compacted: real people (no placeholder
    /// stubs), least-complete first, capped.
    private func suggestions() -> [Profile] {
        appState.snapshot.profiles.values
            .filter { !isPlaceholderStub($0) }
            .sorted { a, b in
                let ca = appState.snapshot.completeness(for: a.id)
                let cb = appState.snapshot.completeness(for: b.id)
                if ca.score != cb.score { return ca.score < cb.score }
                return a.id < b.id
            }
            .prefix(suggestionCap)
            .map { $0 }
    }

    private func isPlaceholderStub(_ profile: Profile) -> Bool {
        let given = (profile.firstName ?? "").trimmingCharacters(in: .whitespaces)
        return given.isEmpty || given == "?"
            || profile.attributes?.nameStatus == .placeholder
    }
}
