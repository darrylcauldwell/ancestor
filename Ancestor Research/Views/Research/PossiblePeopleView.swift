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

    /// Phase 2 (LEAD_DISCOVERY_SPEC). "Research as one person" — kick off a
    /// research run on the cluster's representative lead. The run flows through
    /// the normal review path (findings → accept), so nothing touches the tree
    /// directly. Owner-chosen lead route: the cluster's leads already live in
    /// the firewall queue.
    var onResearch: (Lead) -> Void = { _ in }

    @State private var confident: [LeadDiscoveryEngine.EmergentCluster] = []
    @State private var lowConfidence: [LeadDiscoveryEngine.EmergentCluster] = []
    @State private var totalLeads = 0
    @State private var isLoading = true
    @State private var showLowConfidence = false
    @State private var expanded: Set<String> = []
    /// The ONE member lead currently showing full detail (nil = none). Single
    /// selection by design — see `memberRow`.
    @State private var expandedLeadID: String?
    @State private var usingSemanticModel = false
    @State private var loadingModel = false
    /// Name/place filter across the cluster list — same affordance as the
    /// Findings search (TRIAGE_UX Change 1 pattern). Empty = show everything.
    @State private var searchText = ""
    /// Phase 4 — advisory AI verdicts per cluster id. Annotation only: a
    /// verdict never merges, splits, or moves a cluster.
    @State private var verdicts: [String: ClusterAdjudicator.Verdict] = [:]
    @State private var adjudicating: Set<String> = []
    @State private var adjudicationUnavailable: Set<String> = []

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
                searchBar
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        let visibleC = visible(confident)
                        let visibleL = visible(lowConfidence)
                        if visibleC.isEmpty && visibleL.isEmpty {
                            Text("Nothing matches “\(searchText)”.")
                                .font(AppTypography.cardBody)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        } else {
                            ForEach(visibleC) { clusterCard($0) }

                            if !visibleL.isEmpty {
                                DisclosureGroup(isExpanded: $showLowConfidence) {
                                    ForEach(visibleL) { clusterCard($0) }
                                } label: {
                                    Label("\(visibleL.count) lower-confidence (no birth year)",
                                          systemImage: "questionmark.circle")
                                        .font(AppTypography.cardMeta)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 4)
                            }
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
                Text("\(confident.count) candidate\(confident.count == 1 ? "" : "s") from \(totalLeads) leads — read-only\(usingSemanticModel ? " · semantic" : "")")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            semanticModelControl
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// Opt-in trigger for the real MLX semantic embedder (Phase 3). Only shown
    /// when the embedding modules are linked; downloads a small model on first
    /// use, then re-clusters using semantic similarity instead of the
    /// deterministic trigram fallback. Absent → deterministic is used silently.
    @ViewBuilder
    private var semanticModelControl: some View {
        #if canImport(MLXEmbedders) && canImport(MLX)
        if loadingModel {
            ProgressView().controlSize(.small)
        } else if !usingSemanticModel {
            Button {
                Task {
                    loadingModel = true
                    try? await MLXTextEmbedder.shared.loadModel()
                    loadingModel = false
                    await compute()
                }
            } label: {
                Label("Use semantic model", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        #endif
    }

    /// The embedder the bridge runs on: the real MLX semantic model once loaded,
    /// otherwise the always-available deterministic trigram embedder.
    private func currentEmbedder() async -> any TextEmbedder {
        #if canImport(MLXEmbedders) && canImport(MLX)
        if await MLXTextEmbedder.shared.isAvailable { return MLXTextEmbedder.shared }
        #endif
        return DeterministicTextEmbedder()
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search possible people by name or place…", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .padding([.horizontal, .bottom])
    }

    /// Clusters matching the search — by surname, any member's name, or any
    /// member's place. Empty search shows everything.
    private func visible(_ clusters: [LeadDiscoveryEngine.EmergentCluster]) -> [LeadDiscoveryEngine.EmergentCluster] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return clusters }
        return clusters.filter { cluster in
            cluster.surname.lowercased().contains(needle)
                || cluster.leads.contains {
                    $0.name.lowercased().contains(needle)
                        || ($0.place?.lowercased().contains(needle) ?? false)
                }
        }
    }

    // MARK: - Cluster card

    /// The tree-context line: which profile(s) surfaced this cluster, with
    /// their dates — the frame for judging real-relative vs. namesake — plus a
    /// conservative namesake flag when the eras are egregiously far apart.
    @ViewBuilder
    private func contextLine(_ cluster: LeadDiscoveryEngine.EmergentCluster) -> some View {
        let origins = ClusterContext.origins(for: cluster, in: appState.snapshot.profiles)
        if !origins.isEmpty {
            let names = origins.prefix(2).map { "\($0.name) \($0.lifespanLabel)".trimmingCharacters(in: .whitespaces) }
            let extra = origins.count > 2 ? " +\(origins.count - 2) more" : ""
            Label("Surfaced by \(names.joined(separator: ", "))\(extra)", systemImage: "person.crop.circle.badge.questionmark")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let flag = ClusterContext.namesakeFlag(clusterBirthYear: cluster.birthYear, origins: origins) {
                Label(flag, systemImage: "exclamationmark.triangle")
                    .font(AppTypography.badge)
                    .foregroundStyle(.orange)
            }
        }
    }

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
                        contextLine(cluster)
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
                // Phase 4 narration — deterministic, formatted from lead facts.
                let narration = ClusterAdjudicator.summary(cluster)
                if !narration.isEmpty {
                    Text(narration)
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 22)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cluster.leads) { lead in
                        memberRow(lead, in: cluster)
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 2)

                adjudicationRow(cluster)
                    .padding(.leading, 22)
                    .padding(.top, 2)

                HStack(spacing: 8) {
                    Button {
                        onResearch(cluster.representativeLead)
                    } label: {
                        Label("Research as one person", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        dismissCluster(cluster)
                    } label: {
                        Label("Not a person", systemImage: "xmark")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .controlSize(.small)

                    Spacer()
                }
                .font(AppTypography.controlLabel)
                .padding(.leading, 22)
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Phase 4 — advisory AI adjudication for BORDERLINE clusters (the yearless
    /// ones, where name+place alone grouped the leads). The verdict is a badge
    /// with reasoning; it never restructures anything. Nil result (no model,
    /// unusable reply) → a quiet caption, panel unchanged.
    @ViewBuilder
    private func adjudicationRow(_ cluster: LeadDiscoveryEngine.EmergentCluster) -> some View {
        if let verdict = verdicts[cluster.id] {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                switch verdict.assessment {
                case .plausiblyOnePerson:
                    Label("AI: plausibly one person", systemImage: "person.fill.checkmark")
                        .font(AppTypography.badge)
                        .foregroundStyle(.green)
                case .likelyMultiplePeople:
                    Label("AI: likely multiple people", systemImage: "person.2.fill")
                        .font(AppTypography.badge)
                        .foregroundStyle(.orange)
                }
                Text(verdict.reasoning)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else if adjudicating.contains(cluster.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Asking local model…")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
        } else if adjudicationUnavailable.contains(cluster.id) {
            Text("AI unavailable — load a reasoning model to get a verdict.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.tertiary)
        } else if cluster.birthYear == nil {
            // Only offer on borderline clusters — the confident cohorts don't
            // need a second opinion; the yearless ones are exactly where the
            // "one person or namesakes?" question is live.
            Button {
                adjudicate(cluster)
            } label: {
                Label("Ask AI: one person or several?", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(AppTypography.controlLabel)
        }
    }

    private func adjudicate(_ cluster: LeadDiscoveryEngine.EmergentCluster) {
        adjudicating.insert(cluster.id)
        Task {
            let verdict = await ClusterAdjudicator.adjudicate(cluster)
            adjudicating.remove(cluster.id)
            if let verdict {
                verdicts[cluster.id] = verdict
            } else {
                adjudicationUnavailable.insert(cluster.id)
            }
        }
    }

    /// "Not a person" — dismiss every lead in the cluster so it leaves the
    /// pool and can't re-form (discovery only clusters `.new`/`.investigated`
    /// leads). This IS the discovery negative memory; it uses the existing
    /// lead-dismissal firewall path, nothing touches the tree.
    private func dismissCluster(_ cluster: LeadDiscoveryEngine.EmergentCluster) {
        guard let db = appState.currentDatabase else { return }
        for lead in cluster.leads {
            try? db.upsertLead(lead.with(status: .dismissed, resolvedAt: Date(), resolution: .dismissed))
        }
        withAnimation {
            confident.removeAll { $0.id == cluster.id }
            lowConfidence.removeAll { $0.id == cluster.id }
        }
    }

    /// One member lead. Compact by default; tap to expand the full detail
    /// (years, source, provenance, full evidence) with a per-lead Dismiss.
    /// One row expands at a time — a 43-member cluster must not balloon the
    /// view tree (the Liquid Glass scroll-perf lesson).
    @ViewBuilder
    private func memberRow(_ lead: Lead, in cluster: LeadDiscoveryEngine.EmergentCluster) -> some View {
        let isOpen = expandedLeadID == lead.id
        VStack(alignment: .leading, spacing: 3) {
            Button {
                expandedLeadID = isOpen ? nil : lead.id
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                        Text(lead.name.trimmingCharacters(in: .whitespaces).isEmpty ? "(unnamed)" : lead.name)
                            .font(AppTypography.cardBody)
                        if let place = lead.place, !place.isEmpty {
                            Text("· \(place)")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if !isOpen && !lead.evidence.isEmpty {
                        Text(lead.evidence)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .padding(.leading, 16)
                    }
                }
            }
            .buttonStyle(.plain)

            if isOpen {
                memberDetail(lead, in: cluster)
                    .padding(.leading, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memberDetail(_ lead: Lead, in cluster: LeadDiscoveryEngine.EmergentCluster) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Years + age, whichever the record carried.
            let years: String = {
                var bits: [String] = []
                if let by = lead.birthYear { bits.append("b. ~\(by)") }
                if let dy = lead.deathYear { bits.append("d. \(dy)") }
                if let age = lead.ageAtDeath { bits.append("aged \(age)") }
                if bits.isEmpty, let eff = lead.effectiveBirthYear { bits.append("b. ~\(eff) (implied)") }
                return bits.joined(separator: " · ")
            }()
            if !years.isEmpty {
                Text(years).font(AppTypography.cardMeta)
            }

            // Provenance: which relative's research surfaced this lead, and how.
            let origin = appState.snapshot.profiles[lead.profileID]?.displayName ?? lead.profileID
            Text("From research on \(origin) · \(sourceLabel(lead.source))")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)

            if !lead.evidence.isEmpty {
                Text(lead.evidence)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Button(role: .destructive) {
                dismissLead(lead, in: cluster)
            } label: {
                Label("Dismiss lead", systemImage: "xmark")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.mini)
            .help("This lead is noise — dismiss it from the pool (persisted; it won't resurface)")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func sourceLabel(_ source: LeadSource) -> String {
        switch source {
        case .scoredLead: return "scored record"
        case .householdMember: return "census household"
        case .discovery: return "discovery"
        case .ghostNode: return "ghost node"
        }
    }

    /// Dismiss ONE member lead (same firewall path as everything else) and
    /// update the cluster card in place: coherence + consensus birth recompute
    /// via the engine; a cluster that drops below surfaceable leaves the list.
    /// Any AI verdict for the cluster is cleared — membership changed under it.
    private func dismissLead(_ lead: Lead, in cluster: LeadDiscoveryEngine.EmergentCluster) {
        guard let db = appState.currentDatabase else { return }
        try? db.upsertLead(lead.with(status: .dismissed, resolvedAt: Date(), resolution: .dismissed))
        expandedLeadID = nil
        verdicts.removeValue(forKey: cluster.id)
        adjudicationUnavailable.remove(cluster.id)
        withAnimation {
            let updated = LeadDiscoveryEngine.removingLead(lead.id, from: cluster)
            func replace(in list: inout [LeadDiscoveryEngine.EmergentCluster]) {
                guard let idx = list.firstIndex(where: { $0.id == cluster.id }) else { return }
                if let updated, updated.coherence.isSurfaceable {
                    list[idx] = updated
                } else {
                    list.remove(at: idx)
                }
            }
            replace(in: &confident)
            replace(in: &lowConfidence)
        }
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
        // Origins are now named on the context line below — no bare count here.
        return parts.joined(separator: " · ")
    }

    // MARK: - Compute

    private func compute() async {
        guard let db = appState.currentDatabase else { isLoading = false; return }
        // Cheap DB read on-actor; the O(n²)-within-block clustering runs off
        // the main actor so a large pool never beach-balls the UI.
        let leads = (try? db.loadLeads()) ?? []
        totalLeads = leads.count
        // Deterministic core (Phase 1) then the Phase 3 fuzzy-bridge across
        // surname spelling variants. The embedder is the real MLX semantic
        // model when one is loaded, else the always-available deterministic
        // trigram embedder — both behind the same `TextEmbedder` contract.
        let embedder = await currentEmbedder()
        usingSemanticModel = !(embedder is DeterministicTextEmbedder)
        let clusters = await Task.detached(priority: .userInitiated) {
            let base = LeadDiscoveryEngine.discover(leads: leads).filter { $0.coherence.isSurfaceable }
            // Precompute one vector per cluster from its representative text.
            let texts = base.map { Self.clusterText($0) }
            let vectors = await embedder.embed(texts)
            var vectorByID: [String: [Float]] = [:]
            for (cluster, vec) in zip(base, vectors) { vectorByID[cluster.id] = vec }
            return LeadDiscoveryEngine.bridgeVariantSurnames(
                base,
                vectorFor: { vectorByID[$0.id] ?? [] },
                threshold: 0.5
            )
        }.value
        confident = clusters.filter { $0.birthYear != nil }
        lowConfidence = clusters.filter { $0.birthYear == nil }
        isLoading = false
    }

    /// The text a cluster embeds as — its representative name plus place, the
    /// fields that carry identity signal. `nonisolated` because it runs inside
    /// the detached clustering task (MainActor-default target).
    nonisolated private static func clusterText(_ cluster: LeadDiscoveryEngine.EmergentCluster) -> String {
        let lead = cluster.representativeLead
        return [lead.givenName, lead.surname, lead.place]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
