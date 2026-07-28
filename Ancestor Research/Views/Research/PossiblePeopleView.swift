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

    /// What slice of the pool to show. `.all` is the full Triage panel;
    /// `.profile(id)` shows only clusters that person's research surfaced —
    /// what the profile-detail deep-link opens (POSSIBLE_PEOPLE_CONTEXT_SPEC).
    enum Scope: Equatable { case all, profile(String) }
    var scope: Scope = .all

    /// How the `.all` panel organises clusters — flat by coherence, or in
    /// sections under the tree person who surfaced them. Ignored when scoped
    /// to a single profile (already one person's clusters).
    enum Grouping: String, CaseIterable, Identifiable {
        case coherence = "By coherence"
        case byPerson = "By person"
        var id: String { rawValue }
    }
    @State private var grouping: Grouping = .coherence

    /// Category B — clusters proposing a NEW relative to attach, grouped by kin
    /// role. Elevated above the same-person candidates so discovery signal
    /// (inferred parents, census household members) is never buried under
    /// namesake noise — the exact failure that hid a profile's parent leads at
    /// the bottom of the yearless fold.
    @State private var relatives: [LeadDiscoveryEngine.EmergentCluster] = []
    /// Category A — same-person candidates whose era is plausibly the subject's.
    /// The main list, ranked most-on-target first.
    @State private var candidates: [LeadDiscoveryEngine.EmergentCluster] = []
    /// Category A — candidates flagged as a distant-era namesake. The clearest
    /// noise; parked behind a fold, not lost.
    @State private var namesakes: [LeadDiscoveryEngine.EmergentCluster] = []
    /// Category A — yearless candidates (era can't be placed). The existing
    /// lower-confidence fold.
    @State private var lowConfidence: [LeadDiscoveryEngine.EmergentCluster] = []
    @State private var totalLeads = 0
    @State private var isLoading = true
    @State private var showLowConfidence = false
    @State private var showNamesakes = false
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
            } else if relatives.isEmpty && candidates.isEmpty && namesakes.isEmpty && lowConfidence.isEmpty {
                ContentUnavailableView {
                    Label("No candidates yet", systemImage: "person.2.slash")
                } description: {
                    Text("Coherent people emerge from the lead pool as research accumulates leads. Run research to generate more.")
                }
            } else {
                header
                searchBar
                if scope == .all {
                    Picker("Group", selection: $grouping) {
                        ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        let vRel = visible(relatives)
                        let vCand = visible(candidates)
                        let vName = visible(namesakes)
                        let vLow = visible(lowConfidence)
                        if vRel.isEmpty && vCand.isEmpty && vName.isEmpty && vLow.isEmpty {
                            Text("Nothing matches “\(searchText)”.")
                                .font(AppTypography.cardBody)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        } else {
                            // Signal first, always — the relatives to add sit
                            // above the same-person candidates regardless of the
                            // A-side grouping mode.
                            relativesSection(vRel)

                            if scope == .all && grouping == .byPerson {
                                byPersonList(vCand + vName + vLow)
                            } else {
                                ForEach(vCand) { clusterCard($0) }
                                namesakesFold(vName)
                                lowConfidenceFold(vLow)
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
                Text(headerSummary)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            semanticModelControl
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// "2 relatives to add · 5 possible matches from 90 leads" — leads with the
    /// signal (relatives) first, so the count reflects the split, not one pile.
    private var headerSummary: String {
        var parts: [String] = []
        if !relatives.isEmpty {
            parts.append("\(relatives.count) relative\(relatives.count == 1 ? "" : "s") to add")
        }
        let matches = candidates.count
        parts.append("\(matches) possible match\(matches == 1 ? "" : "es")")
        var summary = parts.joined(separator: " · ")
        summary += " from \(totalLeads) leads — read-only"
        if usingSemanticModel { summary += " · semantic" }
        return summary
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

    // MARK: - By-person grouping

    /// Clusters sectioned by the tree person who surfaced them. A cluster with
    /// several origins appears under EACH (owner decision) — the cross-relative
    /// connection is the point. Clusters with no resolvable origin fall into an
    /// "Unattached" section, last.
    @ViewBuilder
    private func byPersonList(_ clusters: [LeadDiscoveryEngine.EmergentCluster]) -> some View {
        let sections = byPersonSections(clusters)
        ForEach(sections, id: \.title) { section in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(section.title)
                        .font(AppTypography.cardTitle)
                    Text("\(section.clusters.count)")
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 4)
                ForEach(section.clusters) { clusterCard($0) }
            }
        }
    }

    private func byPersonSections(
        _ clusters: [LeadDiscoveryEngine.EmergentCluster]
    ) -> [(title: String, clusters: [LeadDiscoveryEngine.EmergentCluster])] {
        var buckets: [String: [LeadDiscoveryEngine.EmergentCluster]] = [:]
        var titleForKey: [String: String] = [:]
        var unattached: [LeadDiscoveryEngine.EmergentCluster] = []
        for cluster in clusters {
            let origins = ClusterContext.origins(for: cluster, in: appState.snapshot.profiles)
            if origins.isEmpty {
                unattached.append(cluster)
                continue
            }
            for origin in origins {
                let title = "\(origin.name) \(origin.lifespanLabel)".trimmingCharacters(in: .whitespaces)
                titleForKey[origin.id] = title
                buckets[origin.id, default: []].append(cluster)
            }
        }
        var sections = buckets
            .map { (title: titleForKey[$0.key] ?? $0.key, clusters: $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if !unattached.isEmpty {
            sections.append((title: "Unattached", clusters: unattached))
        }
        return sections
    }

    // MARK: - Signal / noise sections

    /// Category B — "Relatives to add", grouped by kin role. Each role is a
    /// small labelled sub-section; clusters render with the same card so
    /// "Research as one person" still routes through the review path. This is
    /// the section that lifts inferred parents / household members out of the
    /// namesake pile where they used to sink (yearless → bottom fold). Empty →
    /// nothing rendered.
    @ViewBuilder
    private func relativesSection(_ clusters: [LeadDiscoveryEngine.EmergentCluster]) -> some View {
        if !clusters.isEmpty {
            let byRole = Dictionary(grouping: clusters) { cluster -> LeadKind.RelativeRole in
                if case .relative(let role) = LeadKind.classify(cluster.leads) { return role }
                return .parent   // unreachable: this bucket only holds .relative clusters
            }
            let roles = byRole.keys.sorted { $0.sortOrder < $1.sortOrder }
            VStack(alignment: .leading, spacing: 6) {
                Label("Relatives to add", systemImage: "person.badge.plus")
                    .font(AppTypography.cardTitle)
                Text("Discovered people who aren’t in the tree yet — the leads worth acting on.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                ForEach(roles, id: \.self) { role in
                    let group = byRole[role] ?? []
                    HStack(spacing: 6) {
                        Image(systemName: role.systemImage)
                            .foregroundStyle(.secondary)
                        Text(role.sectionTitle)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                        Text("\(group.count)")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                    ForEach(group) { clusterCard($0) }
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            Divider().padding(.vertical, 4)
        }
    }

    /// Category A noise — distant-era namesakes, parked behind a collapsed fold.
    /// The count tells the user how much was set aside so nothing is silently
    /// hidden.
    @ViewBuilder
    private func namesakesFold(_ clusters: [LeadDiscoveryEngine.EmergentCluster]) -> some View {
        if !clusters.isEmpty {
            DisclosureGroup(isExpanded: $showNamesakes) {
                ForEach(clusters) { clusterCard($0) }
            } label: {
                Label("\(clusters.count) likely namesake\(clusters.count == 1 ? "" : "s") (different era)",
                      systemImage: "person.fill.questionmark")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    /// Category A — yearless candidates, the existing lower-confidence fold.
    @ViewBuilder
    private func lowConfidenceFold(_ clusters: [LeadDiscoveryEngine.EmergentCluster]) -> some View {
        if !clusters.isEmpty {
            DisclosureGroup(isExpanded: $showLowConfidence) {
                ForEach(clusters) { clusterCard($0) }
            } label: {
                Label("\(clusters.count) lower-confidence (no birth year)",
                      systemImage: "questionmark.circle")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
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
            relatives.removeAll { $0.id == cluster.id }
            candidates.removeAll { $0.id == cluster.id }
            namesakes.removeAll { $0.id == cluster.id }
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
            replace(in: &relatives)
            replace(in: &candidates)
            replace(in: &namesakes)
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
        // Scope: the panel shows everything; a profile deep-link shows only the
        // clusters that person's research surfaced.
        let scoped: [LeadDiscoveryEngine.EmergentCluster]
        switch scope {
        case .all:
            scoped = clusters
        case .profile(let id):
            scoped = clusters.filter { c in c.leads.contains { $0.profileID == id } }
        }
        // Split the pool. Category B (relatives to add) is elevated whole;
        // category A (same-person candidates) splits into plausible matches
        // (ranked by era proximity to the surfacing profile), distant-era
        // namesakes (parked), and yearless (the existing low-confidence fold).
        let profiles = appState.snapshot.profiles
        var rel: [LeadDiscoveryEngine.EmergentCluster] = []
        var ranked: [(cluster: LeadDiscoveryEngine.EmergentCluster, distance: Int)] = []
        var namesakeClusters: [LeadDiscoveryEngine.EmergentCluster] = []
        var yearless: [LeadDiscoveryEngine.EmergentCluster] = []
        for cluster in scoped {
            if case .relative = LeadKind.classify(cluster.leads) {
                rel.append(cluster)
                continue
            }
            guard cluster.birthYear != nil else { yearless.append(cluster); continue }
            let origins = ClusterContext.origins(for: cluster, in: profiles)
            if ClusterContext.namesakeFlag(clusterBirthYear: cluster.birthYear, origins: origins) != nil {
                namesakeClusters.append(cluster)
            } else {
                let distance = ClusterContext.eraDistance(clusterBirthYear: cluster.birthYear, origins: origins) ?? Int.max
                ranked.append((cluster, distance))
            }
        }
        relatives = rel
        candidates = ranked.sorted { $0.distance < $1.distance }.map(\.cluster)
        namesakes = namesakeClusters
        lowConfidence = yearless
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
