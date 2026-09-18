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

    // #EV29 — the row type and its ordering live in `AttentionLadder`, a pure
    // view-free ladder, so "one firewall fact outranks sixty leads" is a test
    // and not a closure buried in a private nested struct.
    @State private var rows: [AttentionLadder.Item] = []
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
                    // #EV29 — the fold must never swallow gated work (open
                    // disputes, pending facts, proposals). Ordering alone
                    // would only relocate the burial from row 40 to row 16.
                    let cap = AttentionLadder.visibleCount(rows, cap: rowCap)
                    let visible = showAllRows ? rows : Array(rows.prefix(cap))
                    // Lazy because the gated band is uncapped by design and
                    // every row wears `.glassEffect` (memory
                    // feedback_swiftui_viewtree_liquidglass_perf).
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(visible) { row in
                            attentionRow(row)
                        }
                    }
                    if rows.count > visible.count {
                        Button("Show all \(rows.count) profiles") { showAllRows = true }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                    }
                }

                Divider().padding(.vertical, 4)

                Text("Research suggestions")
                    .font(.headline)
                Text("Least-complete real people, plus evidence-driven prompts — likely to reward a research run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(suggestions()) { suggestion in
                    suggestionRow(suggestion)
                }
            }
            .padding()
        }
        .task { reload() }
        .onChange(of: appState.treeContentRevision) { _, _ in reload() }
    }

    // MARK: - Rows

    private func attentionRow(_ row: AttentionLadder.Item) -> some View {
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
                        // SC-6 follow-up (review M7): the queued work exists
                        // but its person isn't in the tree — say so rather
                        // than hiding the row (the old silent drop).
                        if row.isOffSnapshot {
                            Text("not in tree")
                                .font(.caption)
                                .foregroundStyle(.orange)
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
        .help(row.isOffSnapshot
            ? "\(row.name) is not in the tree (soft-deleted?) — restore it via Settings ▸ Deleted People to review this work"
            : "Open \(row.name)'s card — review happens there")
    }

    private func summary(_ row: AttentionLadder.Item) -> String {
        var parts: [String] = []
        if row.pendingFacts > 0 { parts.append("\(row.pendingFacts) pending fact\(row.pendingFacts == 1 ? "" : "s")") }
        if row.leads > 0 { parts.append("\(row.leads) lead\(row.leads == 1 ? "" : "s")") }
        if row.proposals > 0 { parts.append("\(row.proposals) relationship proposal\(row.proposals == 1 ? "" : "s")") }
        if row.disputes > 0 { parts.append("\(row.disputes) open dispute\(row.disputes == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// One row of the "Research suggestions" section: a person, why they
    /// rank (completeness gaps), and any evidence-derived research prompts.
    private struct Suggestion: Identifiable {
        let profile: Profile
        /// #HR3 follow-up (review C6): `.research` audit findings the
        /// completeness engine does NOT mirror (fertilityGap shortfall, …).
        let researchReasons: [String]
        var id: String { profile.id }
    }

    private func suggestionRow(_ suggestion: Suggestion) -> some View {
        let profile = suggestion.profile
        let comp = appState.snapshot.completeness(for: profile.id)
        return HStack(spacing: 8) {
            Button {
                onOpenProfile(profile.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
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
                    // #HR3 — the reasons behind the ranking. This is where the
                    // retired Health research prompts (missing birth date,
                    // missing parents, …) surface now; the completeness engine
                    // already carries them, no audit findings needed.
                    if !comp.missing.isEmpty {
                        Text("Missing: \(comp.missing.map(\.shortLabel).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // #HR3 follow-up (review C6) — the exception: research
                    // prompts derived from applied EVIDENCE (fertilityGap's
                    // "1911: she stated 8 born alive, 6 in tree") have no
                    // completeness mirror and this row is their only home.
                    ForEach(suggestion.researchReasons, id: \.self) { reason in
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
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
            // #EV29 — a RESOLVED dispute is not attention. Counting it kept
            // settled profiles in the router forever AND inflated their rank,
            // pushing genuinely-unreviewed firewall rows below the fold — and
            // broke this view's own "a row disappears when its queues empty"
            // contract above. Every other surface already filters this way
            // (SharedProfileLayout's conflict strip, HealthTriage).
            let open = AttentionLadder.openDisputeCount(profile.disputes)
            if open > 0 { disputeCounts[profile.id] = open }
        }

        let ids = Set(factCounts.keys)
            .union(proposalCounts.keys)
            .union(leadCounts.keys)
            .union(disputeCounts.keys)
        // SC-6 follow-up (review M7): queued work attached to a profile the
        // snapshot doesn't carry (soft-deleted after a run minted leads or
        // facts — soft-delete doesn't cascade to those queues — or an MCP
        // submission against an unknown id) must STILL render. Resolve names
        // from the soft-deleted rows; anything else gets a labelled
        // placeholder, never a silent drop.
        var softDeleted: [String: Profile] = [:]
        if ids.contains(where: { appState.snapshot.profiles[$0] == nil }) {
            for profile in (try? db.loadDeletedProfiles()) ?? [] {
                softDeleted[profile.id] = profile
            }
        }
        rows = AttentionLadder.rows(
            ids: ids,
            pendingFacts: factCounts,
            leads: leadCounts,
            proposals: proposalCounts,
            disputes: disputeCounts,
            onSnapshot: { id in
                appState.snapshot.profiles[id].map { (name: $0.displayName, birthYear: $0.birthDate?.bestYear) }
            },
            offSnapshot: { id in
                softDeleted[id].map { (name: $0.displayName, birthYear: $0.birthDate?.bestYear) }
            }
        )
    }

    /// The launcher's ranking, compacted: real people (no placeholder
    /// stubs), least-complete first, capped — PLUS, always, anyone carrying
    /// an evidence-derived `.research` audit finding.
    ///
    /// #HR3 follow-up (review C6): the recategorisation moved `.research`
    /// findings out of Health onto this surface, but only the completeness
    /// mirror actually rendered — fertilityGap's children shortfall (no
    /// completeness mirror) rendered NOWHERE in-app. The unmirrored prompts
    /// now ride the rows, and their people join the list even at 7/7
    /// (`WorkbenchResearchPrompts` holds the testable selection + ranking).
    private func suggestions() -> [Suggestion] {
        let summary = appState.auditSummary
        let reasons = WorkbenchResearchPrompts.unmirroredReasons(
            in: (summary?.errors ?? []) + (summary?.warnings ?? []) + (summary?.info ?? []))
        let candidates = appState.snapshot.profiles.values.filter { !isPlaceholderStub($0) }
        var scores: [String: Int] = [:]
        for profile in candidates {
            scores[profile.id] = appState.snapshot.completeness(for: profile.id).score
        }
        let ranked = WorkbenchResearchPrompts.rankedIDs(
            completenessScores: scores,
            flagged: Set(reasons.keys).intersection(scores.keys),
            cap: suggestionCap)
        return ranked.compactMap { id in
            appState.snapshot.profiles[id].map {
                Suggestion(profile: $0, researchReasons: reasons[id] ?? [])
            }
        }
    }

    private func isPlaceholderStub(_ profile: Profile) -> Bool {
        let given = (profile.firstName ?? "").trimmingCharacters(in: .whitespaces)
        return given.isEmpty || given == "?"
            || profile.attributes?.nameStatus == .placeholder
    }
}
