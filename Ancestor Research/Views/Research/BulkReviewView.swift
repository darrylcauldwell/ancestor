import SwiftUI

/// DB-backed bulk review of campaign findings (CAMPAIGN_REVIEW_SPEC
/// Change 6). Rebuilt from the unwired prototype: fed by
/// `CampaignReviewService` reconstruction over PERSISTED state (an overnight
/// watcher campaign, a whole-tree run, any past runs) instead of an
/// in-memory `[String: ResearchResult]` nothing ever constructed.
///
/// Per finding: friction tier (kept, tested `FrictionTier.route` seam),
/// the PERSISTED convergence level of the fact values the cluster asserts,
/// and the profile's open-dispute state — scoped per profile via
/// `openDisputes(profileID:)`, not the old project-wide count that flipped
/// every finding to .conflict at once. Campaign-window leads appear as their
/// own reviewable section (Promote/Dismiss — trustworthy after Change 1).
/// The Review drill-down hydrates the existing per-profile ClusterReviewView
/// through the owner-supplied callback (the VM quartet is set by
/// ResearchView, which owns the VM).
struct BulkReviewView: View {
    @Environment(AppState.self) private var appState
    @Bindable var vm: ResearchViewModel
    let onOpenProfileReview: (Profile, ResearchResult) -> Void
    /// Nil when the queue IS the tab's resting state (Triage) — there is
    /// nowhere to go 'back' to, so no Done button renders.
    let onDone: (() -> Void)?

    @State private var isLoading = true
    @State private var windowStart: Date = .distantPast
    /// When true, the watermark window is ignored for THIS visit — the
    /// user asked to see already-reviewed history. Never clears the
    /// stored watermark.
    @State private var showAllHistory = false
    @State private var findings: [CampaignFinding] = []
    @State private var campaignLeads: [CampaignLeadRow] = []
    /// TRIAGE_UX_DATA_QUALITY_SPEC Change 3a — dismissed leads are persisted,
    /// not deleted; this bucket surfaces them for Restore. Collapsed by default.
    @State private var dismissedLeads: [CampaignLeadRow] = []
    @State private var showDismissed = false
    @State private var failedEntries: [CampaignReviewService.CampaignEntry] = []
    @State private var filterTier: FrictionTier?
    /// TRIAGE_UX_DATA_QUALITY_SPEC Change 1 — name filter across findings,
    /// leads and failures. Empty = show everything.
    @State private var searchText = ""
    @State private var processedCount = 0
    @State private var showAcceptAllConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView("Reconstructing research findings…")
                    .frame(maxHeight: .infinity)
            } else if findings.isEmpty && campaignLeads.isEmpty && failedEntries.isEmpty && dismissedLeads.isEmpty {
                ContentUnavailableView {
                    Label("All Clear", systemImage: "checkmark.circle")
                } description: {
                    Text(showAllHistory
                        ? "No research findings at all — run research to generate some."
                        : "Nothing new since you marked findings reviewed (\(windowStart.formatted(date: .abbreviated, time: .shortened))).")
                } actions: {
                    if !showAllHistory {
                        Button("Show earlier findings") {
                            showAllHistory = true
                            Task { await load() }
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            } else {
                searchBar
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        let visibleF = visibleFindings
                        let visibleL = visibleLeads
                        let visibleFail = visibleFailures
                        if visibleF.isEmpty && visibleL.isEmpty && visibleFail.isEmpty {
                            // Search filtered everything out — say so rather
                            // than showing a blank list.
                            Text("Nothing matches “\(searchText)”.")
                                .font(AppTypography.cardBody)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        } else {
                            ForEach(visibleF) { finding in
                                findingCard(finding)
                            }
                            // Emit lead/failure rows DIRECTLY into the LazyVStack
                            // — one lazy child per row — instead of wrapping them
                            // in a VStack "section". Wrapped, the whole section was
                            // a single lazy child, so every lead row (each with a
                            // Liquid Glass backdrop) rendered at once the moment it
                            // scrolled into view — the scroll-down beachball on the
                            // "New leads from research" list (owner report,
                            // 2026-07-16). Flattened, only visible rows render.
                            if !visibleL.isEmpty && filterTier == nil {
                                sectionHeader("New leads from research")
                                ForEach(visibleL) { row in
                                    leadRow(row)
                                }
                            }
                            if !visibleFail.isEmpty && filterTier == nil {
                                sectionHeader("Research skipped / failed")
                                ForEach(visibleFail) { entry in
                                    failureRow(entry)
                                }
                            }
                            // Change 3a — dismissed leads, collapsed by default,
                            // each restorable. Kept at the very bottom, out of
                            // the way, but not lost.
                            let visibleDismissed = self.visibleDismissed
                            if !visibleDismissed.isEmpty && filterTier == nil {
                                dismissedHeader(count: visibleDismissed.count)
                                if showDismissed {
                                    ForEach(visibleDismissed) { row in
                                        dismissedLeadRow(row)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Research Findings")
                    .font(AppTypography.popoverTitle)
                Text("Findings since \(windowStart.formatted(date: .abbreviated, time: .shortened))")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ForEach(FrictionTier.allCases, id: \.self) { tier in
                let count = findings.filter { $0.tier == tier }.count
                if count > 0 {
                    frictionBadge(tier, count: count)
                }
            }

            if processedCount > 0 {
                Text("\(processedCount) processed")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }

            let confirmations = findings.filter { $0.tier == .confirmation }
            if !confirmations.isEmpty {
                Button("Accept \(confirmations.count) confirmations") {
                    showAcceptAllConfirmation = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .confirmationDialog(
                    "Apply \(confirmations.count) single-record confirmed clusters?",
                    isPresented: $showAcceptAllConfirmation
                ) {
                    Button("Apply all") { acceptAllConfirmations() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Each writes its record's facts to the profile with citations (fill-empty-fields overwrite policy). Conflicts and corrections stay for individual review.")
                }
            }

            Button("Mark reviewed") {
                try? appState.currentDatabase?.setCampaignReviewHighWater(Date())
                if let onDone {
                    onDone()
                } else {
                    showAllHistory = false
                    Task { await load() }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Sets the review watermark to now — Research Findings starts from this point next time.")

            if let onDone {
                Button("Done") { onDone() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
        }
        .padding()
    }

    // MARK: - Loading

    private var visibleFindings: [CampaignFinding] {
        let tierFiltered = filterTier.map { tier in findings.filter { $0.tier == tier } } ?? findings
        let searched = tierFiltered.filter { matchesSearch($0.profileName) || matchesSearch($0.summary) }
        return searched.sorted {
            if $0.tier.sortOrder != $1.tier.sortOrder { return $0.tier.sortOrder < $1.tier.sortOrder }
            // Stable total-order tiebreak on the unique id — same reasoning as
            // ResearchView.filteredProfiles: `sorted()` isn't stable, so
            // findings sharing a tier + profileName would shuffle on each
            // refresh without a unique final key.
            if $0.profileName != $1.profileName { return $0.profileName < $1.profileName }
            return $0.id < $1.id
        }
    }

    // MARK: - TRIAGE_UX_DATA_QUALITY_SPEC Change 1 — search

    /// True when the field is empty (everything shows) or `text` contains the
    /// query, case/diacritic-insensitively.
    private func matchesSearch(_ text: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }

    /// Leads whose target profile OR own name matches the search — so "Abraham"
    /// finds both findings ABOUT Abraham and leads FOR Abraham.
    private var visibleLeads: [CampaignLeadRow] {
        campaignLeads.filter { matchesSearch($0.profileName) || matchesSearch($0.lead.name) }
    }

    private var visibleFailures: [CampaignReviewService.CampaignEntry] {
        failedEntries.filter {
            matchesSearch(appState.snapshot.profiles[$0.profileID]?.displayName ?? $0.profileID)
        }
    }

    private var visibleDismissed: [CampaignLeadRow] {
        dismissedLeads.filter { matchesSearch($0.profileName) || matchesSearch($0.lead.name) }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search findings and leads by name…", text: $searchText)
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
        .padding([.horizontal, .top])
    }

    @MainActor
    private func load() async {
        defer { isLoading = false }
        guard let db = appState.currentDatabase else { return }

        // Window: the persisted watermark, else the last 7 days — wide
        // enough to cover an overnight campaign without sweeping all of
        // history on first open.
        windowStart = showAllHistory
            ? .distantPast
            : (try? db.campaignReviewHighWater()).flatMap { $0 }
                ?? Date().addingTimeInterval(-7 * 24 * 3600)

        let entries = CampaignReviewService.campaignEntries(since: windowStart, db: db)
        failedEntries = entries.filter { $0.failed > 0 && $0.completed == 0 }

        var newFindings: [CampaignFinding] = []
        var newLeads: [CampaignLeadRow] = []
        var newDismissed: [CampaignLeadRow] = []

        for entry in entries {
            guard let profile = appState.snapshot.profiles[entry.profileID] else { continue }
            guard let result = CampaignReviewService.reconstructResult(
                profileID: entry.profileID, db: db, snapshot: appState.snapshot) else { continue }

            let persisted = (try? db.loadEvidenceConvergence(profileID: entry.profileID)) ?? []
            // Per-profile conflict scope (NOT the old project-wide count).
            let openDisputeCount = (try? db.openDisputes(profileID: entry.profileID).count) ?? 0

            // Itemize the evidence-backed tiers; ROLL UP lead-only
            // (correction-tier) clusters into one row per profile. A
            // haystack profile (no identity anchor) legitimately carries
            // hundreds of non-co-clustering candidate records — a run's
            // per-profile review screen absorbs that; a flat cross-profile
            // list drowns in it (live finding: 2,558 correction rows,
            // mostly single-record Annies).
            // Adjudicated records (applied/kept or discarded) no longer
            // need review — route and count on the LIVE remainder so the
            // list shrinks as the user works it. The drill-down still
            // shows adjudicated records dimmed in place (live-run parity).
            let adjudicated = (try? db.adjudicatedEvidenceRecordIDs(
                profileID: entry.profileID)) ?? []

            var leadOnlyClusters = 0
            var leadOnlyRecords = 0
            for cluster in result.clusters {
                let live = cluster.records.filter { !adjudicated.contains($0.record.id) }
                if live.isEmpty { continue }  // fully adjudicated
                let hasFacts = live.contains { $0.verdict == .fact }
                let tier = FrictionTier.route(
                    hasImpossible: live.contains { $0.verdict == .impossible },
                    hasFacts: hasFacts,
                    recordCount: live.count,
                    // A profile-level open dispute only escalates clusters
                    // that ASSERT facts — lead-only clusters have no stake
                    // in a field dispute and must stay in the rollup.
                    hasConflictSignal: openDisputeCount > 0 && hasFacts
                )
                if tier == .correction {
                    leadOnlyClusters += 1
                    leadOnlyRecords += live.count
                    continue
                }
                let recordNoun = live.count == 1 ? "record" : "records"
                newFindings.append(CampaignFinding(
                    id: "\(entry.profileID)|\(cluster.id)",
                    profileID: entry.profileID,
                    profileName: profile.displayName,
                    tier: tier,
                    summary: "\(cluster.displayName) — \(live.count) \(recordNoun)",
                    convergence: CampaignReviewService.convergenceLevel(for: cluster, persisted: persisted),
                    openDisputeCount: openDisputeCount,
                    cluster: cluster,
                    profile: profile,
                    result: result
                ))
            }
            if leadOnlyClusters > 0 {
                newFindings.append(CampaignFinding(
                    id: "\(entry.profileID)|lead-only-rollup",
                    profileID: entry.profileID,
                    profileName: profile.displayName,
                    tier: .correction,
                    summary: "\(leadOnlyClusters) candidate clusters (\(leadOnlyRecords) lead-grade records, no confirmed identity) — review in profile",
                    convergence: nil,
                    openDisputeCount: openDisputeCount,
                    cluster: nil,
                    profile: profile,
                    result: result
                ))
            }

            let windowLeads = ((try? db.loadLeads(profileID: entry.profileID)) ?? [])
                .filter { $0.createdAt >= windowStart }
            newDismissed.append(contentsOf: windowLeads
                .filter { $0.status == .dismissed }
                .map { CampaignLeadRow(lead: $0, profileName: profile.displayName) })
            let leads = windowLeads
                .filter { $0.status == .new || $0.status == .investigated }
            newLeads.append(contentsOf: leads.map {
                CampaignLeadRow(lead: $0, profileName: profile.displayName)
            })
        }

        findings = newFindings
        campaignLeads = newLeads
        dismissedLeads = newDismissed
    }

    // MARK: - Finding card

    private func findingCard(_ finding: CampaignFinding) -> some View {
        HStack(spacing: 10) {
            frictionIcon(finding.tier)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
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

            // Persisted evidence-chain strength for the values this cluster
            // asserts (Change 3's table, surfaced).
            if let convergence = finding.convergence {
                convergenceBadge(convergence)
            }

            // Per-profile open-conflict state — the finding's profile has
            // unresolved disputes the CL ladder couldn't rule on.
            if finding.openDisputeCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(finding.openDisputeCount) open")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(.capsule)
                .help("Open disputes on this profile — resolve in the per-profile review.")
            }

            Button("Review") {
                processedCount += 1
                onOpenProfileReview(finding.profile, finding.result)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func convergenceBadge(_ level: ConvergenceLevel) -> some View {
        let (label, color): (String, Color) = switch level {
        case .confirmed:      ("3+ independent", .green)
        case .probable:       ("2 independent", .green)
        case .possible:       ("2 sources", .blue)
        case .singleSource:   ("single source", .secondary)
        case .uncorroborated: ("uncorroborated", .secondary)
        }
        return HStack(spacing: 3) {
            Image(systemName: "link")
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(.capsule)
        .help("Persisted evidence-chain strength for this cluster's confirmed values.")
    }

    // MARK: - Leads section

    /// A section title emitted as a direct child of the list's LazyVStack.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.cardTitle)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One "new lead" row. A top-level function (not nested in a section
    /// VStack) so the caller can place it directly in the LazyVStack for
    /// per-row lazy rendering.
    private func leadRow(_ row: CampaignLeadRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "signpost.right")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.lead.name)  ·  for \(row.profileName)")
                    .font(AppTypography.cardBody)
                Text(row.lead.evidence)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Promote") { promote(row) }
                .buttonStyle(.glass)
                .controlSize(.small)
            Button("Dismiss") { dismiss(row) }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    /// One "skipped / failed" row — same lazy-child rationale as `leadRow`.
    private func failureRow(_ entry: CampaignReviewService.CampaignEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.octagon")
                .foregroundStyle(.red)
            Text(appState.snapshot.profiles[entry.profileID]?.displayName ?? entry.profileID)
                .font(AppTypography.cardBody)
            Text(entry.lastError ?? "failed")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    // MARK: - Change 3a — dismissed leads

    /// Tappable "Dismissed leads (n)" disclosure header.
    private func dismissedHeader(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: showDismissed ? "chevron.down" : "chevron.right")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            Text("Dismissed leads (\(count))")
                .font(AppTypography.cardTitle)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 12)
        .contentShape(Rectangle())
        .onTapGesture { showDismissed.toggle() }
    }

    /// A dismissed lead — dimmed, with a Restore action that returns it to the
    /// active queue.
    private func dismissedLeadRow(_ row: CampaignLeadRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "signpost.right")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.lead.name)  ·  for \(row.profileName)")
                    .font(AppTypography.cardBody)
                Text(row.lead.evidence)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Restore") { restore(row) }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Return this lead to the active queue.")
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .opacity(0.6)
    }

    // MARK: - Actions

    private func acceptAllConfirmations() {
        // Confirmation tier = single-record clusters whose record is a
        // sandwich .fact — the friction model's batch-review grade. Hydrate
        // the VM per profile and reuse the canonical apply path.
        let confirmations = findings.filter { $0.tier == .confirmation }
        for finding in confirmations {
            guard let cluster = finding.cluster else { continue }
            vm.appDatabase = appState.currentDatabase
            vm.selectedProfile = finding.profile
            vm.currentResult = finding.result
            vm.applyCluster(cluster, into: appState)
            processedCount += 1
        }
        findings.removeAll { finding in confirmations.contains { $0.id == finding.id } }
        vm.reset()
    }

    private func promote(_ row: CampaignLeadRow) {
        guard let db = appState.currentDatabase else { return }
        guard (try? db.promoteLeadToProfile(row.lead)) != nil else { return }
        if let snap = try? db.buildSnapshot() { appState.snapshot = snap }
        campaignLeads.removeAll { $0.id == row.id }
        processedCount += 1
    }

    private func dismiss(_ row: CampaignLeadRow) {
        guard let db = appState.currentDatabase else { return }
        let dismissed = Lead(
            id: row.lead.id, profileID: row.lead.profileID,
            name: row.lead.name, surname: row.lead.surname, givenName: row.lead.givenName,
            birthYear: row.lead.birthYear, deathYear: row.lead.deathYear,
            relationship: row.lead.relationship, source: row.lead.source,
            status: .dismissed, evidence: row.lead.evidence,
            createdAt: row.lead.createdAt, investigatedAt: row.lead.investigatedAt,
            resolvedAt: Date(), resolution: .dismissed
        )
        try? db.upsertLead(dismissed)
        campaignLeads.removeAll { $0.id == row.id }
        // Change 3a — move into the dismissed bucket instead of vanishing, so
        // it stays restorable in this session without a reload.
        dismissedLeads.append(CampaignLeadRow(lead: dismissed, profileName: row.profileName))
        processedCount += 1
    }

    /// Change 3a — restore a dismissed lead to the active queue.
    private func restore(_ row: CampaignLeadRow) {
        guard let db = appState.currentDatabase else { return }
        let restored = Lead(
            id: row.lead.id, profileID: row.lead.profileID,
            name: row.lead.name, surname: row.lead.surname, givenName: row.lead.givenName,
            birthYear: row.lead.birthYear, deathYear: row.lead.deathYear,
            relationship: row.lead.relationship, source: row.lead.source,
            status: .new, evidence: row.lead.evidence,
            createdAt: row.lead.createdAt, investigatedAt: row.lead.investigatedAt,
            resolvedAt: nil, resolution: nil
        )
        try? db.upsertLead(restored)
        dismissedLeads.removeAll { $0.id == row.id }
        campaignLeads.append(CampaignLeadRow(lead: restored, profileName: row.profileName))
    }

    // MARK: - Badges

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

// MARK: - Row types

private struct CampaignFinding: Identifiable {
    let id: String
    let profileID: String
    let profileName: String
    let tier: FrictionTier
    let summary: String
    let convergence: ConvergenceLevel?
    let openDisputeCount: Int
    /// nil for the per-profile lead-only rollup row — drill-down reviews
    /// the whole profile; only itemized findings carry a specific cluster.
    let cluster: LifeCluster?
    let profile: Profile
    let result: ResearchResult
}

private struct CampaignLeadRow: Identifiable {
    var id: String { lead.id }
    let lead: Lead
    let profileName: String
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

    /// CL3 (DS-14) — pure routing, extracted so the .conflict tier's
    /// reachability is testable. Conflict wins over everything; the rest
    /// preserves the pre-CL3 mapping.
    static func route(
        hasImpossible: Bool, hasFacts: Bool,
        recordCount: Int, hasConflictSignal: Bool
    ) -> FrictionTier {
        if hasImpossible || hasConflictSignal { return .conflict }
        if !hasFacts { return .correction }
        if recordCount <= 1 { return .confirmation }
        return .refinement
    }

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
