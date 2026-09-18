import SwiftUI

/// Health view — the tree's data-quality home. Runs the audit rules and
/// displays errors / warnings / info grouped by severity, with
/// Issues/Apply-gaps and severity filters, the conflict sweep,
/// import-duplicate scan, and the open-disputes list. `.research` findings
/// (missing-X, completeness — "go research this person") are NOT shown here:
/// Health is for defects and apply-gaps; research prompts live in the
/// Workbench suggestions (Health recategorisation #HR2). Wired to the `.health` sidebar tab. (Formerly the tab-less
/// AuditPlaceholderView.)
struct HealthView: View {
    /// Navigate to a finding's profile (Tree → Full Detail). Injected by
    /// ContentView; nil disables the affordance in previews.
    var onOpenProfile: ((String) -> Void)? = nil
    /// Open a finding's profile straight in the editor.
    var onEditProfile: ((String) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry
    @State private var auditVM = AuditViewModel()
    @State private var openDisputeCount: Int?
    @State private var openDisputeRows: [DisputeRow] = []
    /// Presented when the user taps "Resolve…" on a folded-in conflict row —
    /// same `ConflictResolutionView` the profile uses (reuses `DisputeSheetItem`).
    @State private var resolvingDispute: DisputeSheetItem?
    /// Per-audit-rule filter chip selection (e.g. "marriedSurnameFromSpouse").
    /// nil = all rules. Restores the per-issue-type filtering that lived in the
    /// Tasks tab before audit moved to Health.
    @State private var ruleFilter: String?

    /// A pending "compare two possible-duplicate profiles" sheet — the
    /// actionable resolution for a `duplicateDetection` finding (side-by-side,
    /// with CompareProfilesView's own merge-safety confirmation; never a
    /// one-click merge).
    struct ComparePair: Identifiable {
        let id = UUID()
        let leftID: String
        let rightID: String
    }
    @State private var comparePair: ComparePair?

    /// A just-completed FreeBMD enrichment — drives the launchpad dialog
    /// (research now / open profile) instead of a dead-end "OK".
    struct EnrichResult: Identifiable {
        let id = UUID()
        let profileID: String
        let profileName: String
        let count: Int
    }
    @State private var enrichResult: EnrichResult?

    /// Census-backfill proposals — birth years for a census subject's linked
    /// relatives, mined tree-wide. Computed once on appear (the scan reads
    /// evidence per profile, too heavy to recompute per render).
    @State private var backfillProposals: [CensusBackfill.Proposal] = []
    /// Sentinel `ruleFilter` value for the synthetic "Census backfill" chip
    /// (these aren't AuditResults, so they need their own filter slot).
    private let censusBackfillFilterID = "__censusBackfill"

    /// Death-age backfill proposals — birth years derived from a profile's firm
    /// death date + the matching death-index record's age at death, mined
    /// tree-wide. Computed once on appear (reads evidence per profile).
    @State private var deathAgeProposals: [DeathAgeBackfillProposal] = []
    /// Sentinel `ruleFilter` value for the synthetic "Death-age backfill" chip.
    private let deathAgeBackfillFilterID = "__deathAgeBackfill"
    /// Census corroboration proposals — relatives whose recorded birth year
    /// is unsourced but agrees with an applied household roster; one click
    /// cites the census on the existing value. Computed once on appear.
    @State private var censusCorroborations: [CensusBackfill.Proposal] = []
    /// Sentinel `ruleFilter` value for the synthetic "Cite census" chip.
    private let censusCiteFilterID = "__censusCite"
    /// Contradictory-facts findings — profiles whose stored evidence holds
    /// mutually exclusive `fact` verdicts the exclusivity pass would demote
    /// (DECISION_CORE_PAIR follow-up). Computed once on appear (reads
    /// evidence per profile).
    @State private var contradictoryFindings: [ContradictoryFactsAudit.Finding] = []
    /// Per-profile last research-completion date (the Gaps view's freshness
    /// feed), loaded once on open. Drives the Research button's "Research" vs
    /// "Re-research (Nd ago)" label so a recently-searched profile isn't
    /// re-hammered blindly (scope-I follow-up 2026-08-12).
    @State private var researchDates: [String: Date] = [:]
    /// Census years each profile's `censusUnabsorbed` household row already
    /// offers, keyed by profile. Feeds `AuditFixButton.bulkAddSuppressed` so a
    /// `censusRelationship` finding on the same year doesn't add a SECOND bulk
    /// add for the same schedule. Built with the household sweep in
    /// `syncAuditSummary`, so it is bounded to the profiles that raised one.
    @State private var censusHouseholdYears: [String: Set<Int>] = [:]
    /// Sentinel `ruleFilter` value for the synthetic "Contradictory facts" chip.
    private let contradictoryFactsFilterID = "__contradictoryFacts"
    /// Sentinel `ruleFilter` value for the synthetic "Conflicts" chip — the
    /// folded-in open field-disputes (sources disagreeing with a stored value).
    private let disputeConflictFilterID = "__disputes"
    /// Sentinel `ruleFilter` value for the "⚡ Quick wins" chip (#HR4) — the
    /// whole merged list filtered to one-click rows, ladder order preserved.
    private let quickWinsFilterID = "__quickWins"

    var body: some View {
        VStack(spacing: 0) {
            // Single toolbar row: sweeps + dispute status on the left, the two
            // filter axes + search on the right. One control per axis — the
            // severity counts ARE the severity filter, and disputes are a pill
            // matching them, so nothing is shown twice.
            HStack(spacing: 12) {
                // Secondary sweeps tucked into a menu — run occasionally, so
                // they don't need to sit out on the bar competing for space.
                Menu {
                    Button {
                        // Conflict layer CL2 — manual conflict sweep.
                        // Refresh the ROWS as well as the count: the ladder,
                        // the Conflicts chip and the dispute rows all read
                        // `openDisputeRows`, so refreshing only the count
                        // showed "12 conflicts" in the pill with no conflict
                        // rows anywhere in the list (review 2026-08-25).
                        appState.runConflictSweep(force: true)
                        reloadDisputes()
                    } label: {
                        Label("Scan for Conflicts", systemImage: "exclamationmark.triangle")
                    }
                    Button {
                        appState.scanForImportDuplicates()
                    } label: {
                        Label("Find Import Duplicates", systemImage: "person.2.slash")
                    }
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(appState.snapshot.profiles.isEmpty)

                if let count = openDisputeCount, count > 0 {
                    disputesPill(count: count)
                }

                Spacer()

                // Category as two toggle pills matching the severity counts: one
                // button per category carrying its own name + count, tap to filter,
                // tap again to clear (the cleared state IS "all", so no separate
                // All button). Same interaction as the severity pills beside it.
                HStack(spacing: 8) {
                    categoryFilterPill(.issue, label: "Issues", count: auditVM.categoryCount(.issue))
                    categoryFilterPill(.gap, label: "Apply gaps", count: auditVM.categoryCount(.gap))
                }
                .accessibilityLabel("Filter by category")

                if auditVM.summary != nil {
                    HStack(spacing: 8) {
                        severityFilterPill(.error, count: auditVM.severityCount(.error))
                        severityFilterPill(.warning, count: auditVM.severityCount(.warning))
                        severityFilterPill(.info, count: auditVM.severityCount(.info))
                    }
                    .accessibilityLabel("Filter by severity")
                }

                TextField("Search...", text: $auditVM.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
            }
            .padding()

            Divider()

            // Open field-disputes are no longer a siloed parallel list — they're
            // folded into the issues list below as `Conflicts` rows (each with a
            // Resolve button). The pill above just filters to them.

            // Results
            if auditVM.isRunning {
                ProgressView("Running audit...")
                    .frame(maxHeight: .infinity)
            } else if let summary = auditVM.summary {
                // The ladder is computed ONCE per body pass and threaded to
                // every consumer (empty gate, chips, rows) — it was being
                // re-derived four times, and its K3 registry runs the census
                // reconciler for censusRelationship rows (review 2026-08-25).
                let ladder = mergedLadder
                let rows = filteredRows(from: ladder)
                // Empty-state gate is the ROW set, not filteredResults: the
                // synthetic rows (open disputes, contradictory facts, census/
                // death-age backfills, corroborations) are not AuditResults,
                // and post-#HR2 a curated tree routinely has zero audit rows
                // while those still need action — "No Issues" must not hide
                // them (nor dead-end the Conflicts pill).
                // The chip is only ONE of four narrowing axes — the search
                // box and the category/severity pills also feed
                // `filteredResults`. Saying "All cleared" when a pill is what
                // emptied the list would assert the tree is clean while
                // unfixed rows sit behind the filter (review 2026-08-25).
                let narrowedByFacets = !auditVM.searchText.isEmpty
                    || auditVM.filterSeverity != nil || auditVM.filterCategory != nil
                if rows.isEmpty {
                    if ruleFilter == nil && !narrowedByFacets {
                        ContentUnavailableView {
                            Label("No Issues", systemImage: "checkmark.circle")
                        } description: {
                            Text("Checked \(summary.profilesChecked) profiles.")
                        }
                    } else {
                        // Either a filter the user just emptied (the ⚡ queue
                        // is MEANT to be cleared) or a facet with no matches.
                        // Never a blank pane with no way back, and the exit
                        // clears every axis so it honours its own label.
                        ContentUnavailableView {
                            Label(narrowedByFacets ? "No matches" : "All cleared",
                                  systemImage: narrowedByFacets
                                      ? "line.3.horizontal.decrease.circle" : "checkmark.circle")
                        } description: {
                            Text(narrowedByFacets
                                 ? "No findings match the active filters — others are hidden behind them."
                                 : "Nothing left in this filter.")
                        } actions: {
                            Button("Show all findings") {
                                ruleFilter = nil
                                auditVM.filterSeverity = nil
                                auditVM.filterCategory = nil
                                auditVM.searchText = ""
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                } else {
                    ruleFilterChips(ladder: ladder)
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(rows) { row in
                                switch row {
                                case .duplicateCluster(let cluster):
                                    duplicateClusterRow(cluster)
                                case .censusBackfill(let proposal):
                                    censusBackfillRow(proposal)
                                case .deathAgeBackfill(let proposal):
                                    deathAgeBackfillRow(proposal)
                                case .censusCorroboration(let proposal):
                                    censusCorroborationRow(proposal)
                                case .contradictoryFacts(let finding):
                                    contradictoryFactsRow(finding)
                                case .finding(let result):
                                    findingRow(result)
                                case .dispute(let row):
                                    disputeRow(row)
                                }
                            }
                        }
                        .padding()
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Audit", systemImage: "checkmark.shield")
                } description: {
                    Text("Press Run Audit to check your tree for errors and gaps.")
                }
            }
        }
        .navigationTitle("Health")
        .sheet(item: $comparePair, onDismiss: {
            // A merge or a "Not a duplicate" dismissal inside the sheet re-runs
            // the audit on AppState; re-sync the view model's copy so the row
            // drops off immediately (onAppear won't re-fire on sheet close).
            refreshAudit()
        }) { pair in
            CompareProfilesView(leftProfileID: pair.leftID, rightProfileID: pair.rightID,
                                fromDuplicateReview: true)
        }
        // A completed enrichment is a launchpad, not a dead end: research now to
        // see if the mother's maiden name opens new doors, or open the profile.
        .confirmationDialog(
            enrichResult.map { "Enriched \($0.count) FreeBMD link\($0.count == 1 ? "" : "s") for \($0.profileName)" } ?? "",
            isPresented: Binding(get: { enrichResult != nil },
                                 set: { if !$0 { enrichResult = nil } }),
            titleVisibility: .visible,
            presenting: enrichResult
        ) { result in
            Button("Research \(result.profileName)") {
                // Opens the research mode/scope sheet for them — chase the MMN
                // straight into parent inference.
                appState.researchProfileID = result.profileID
                enrichResult = nil
            }
            Button("Open \(result.profileName)") {
                onOpenProfile?(result.profileID)
                enrichResult = nil
            }
            Button("Done", role: .cancel) { enrichResult = nil }
        } message: { _ in
            Text("The mother's maiden name may unlock new parents — research to see if it opens doors.")
        }
        .onAppear {
            // Always show the latest maintained summary. AppState keeps
            // `auditSummary` current after every mutation (import, edit, cleanse,
            // snooze), so this is free — no per-open recompute needed to be up to
            // date, which is why there's no manual "Re-run Audit" button.
            // Show the maintained summary with the DB-derived FreeBMD
            // citation-gap findings (Change 2) folded in — computed here, once
            // per open, off the hot audit path.
            syncAuditSummary()
            backfillProposals = appState.censusBackfillProposals()
            deathAgeProposals = appState.deathAgeBackfillProposals()
            censusCorroborations = appState.censusCorroborationProposals()
            contradictoryFindings = appState.contradictoryFactsFindings()
            reloadDisputes()
            researchDates = appState.lastResearchCompletions()
        }
        // Disputes close by routes this view never sees — un-applying a record,
        // an MCP write, a resolution taken on the profile in another window —
        // and the list was only ever reloaded on appear and on the sheet's
        // dismissal. So a dispute resolved elsewhere kept its Resolve affordance
        // here (owner dogfood 2026-08-25: a tree-wide read returned 66 open
        // disputes with Emma not among them, while this list still offered to
        // resolve hers). Same revision signal every other live list uses.
        .onChange(of: appState.treeContentRevision) { _, _ in
            reloadDisputes()
        }
        .sheet(item: $resolvingDispute, onDismiss: {
            // Resolving writes through AppState.resolveDispute (re-runs the audit);
            // reload the open rows + count so the resolved conflict drops off.
            reloadDisputes()
        }) { item in
            ConflictResolutionView(profile: item.profile, dispute: item.dispute)
        }
    }

    /// The open-dispute rows and their pill count — always read together, so a
    /// refresh can never leave "12 conflicts" in the pill with no rows behind it.
    private func reloadDisputes() {
        openDisputeRows = (try? appState.currentDatabase?.allOpenDisputes()) ?? []
        openDisputeCount = try? appState.currentDatabase?.openDisputeCount()
    }

    /// Promote an audit issue to an OpenQuestion. The question text mirrors
    /// the audit message; provenance is recorded via QuestionOrigin.fromAudit
    /// so the workbench can surface where the question came from. Maps audit
    /// severity to question priority (error → high, warning → medium, info → low).
    // MARK: - Duplicate grouping

    enum HealthRow: Identifiable {
        case finding(AuditResult)
        case duplicateCluster(DuplicateCluster)
        case censusBackfill(CensusBackfill.Proposal)
        case deathAgeBackfill(DeathAgeBackfillProposal)
        case censusCorroboration(CensusBackfill.Proposal)
        case contradictoryFacts(ContradictoryFactsAudit.Finding)
        case dispute(DisputeRow)
        var id: String {
            switch self {
            case .finding(let r): return "f:\(r.id)"
            case .duplicateCluster(let c): return "d:\(c.id)"
            case .censusBackfill(let p): return "b:\(p.id)"
            case .deathAgeBackfill(let p): return "da:\(p.id)"
            case .censusCorroboration(let p): return "cc:\(p.id)"
            case .contradictoryFacts(let f): return "cf:\(f.id)"
            case .dispute(let row): return "disp:\(row.id)"
            }
        }
    }

    /// Open disputes as rows. Ordering is the ladder's job (#HR4):
    /// correction/conflict disputes pin to the very top, cosmetic
    /// refinement/note disputes band as blue judgement rows.
    private var disputeRows: [HealthRow] {
        openDisputeRows.map { HealthRow.dispute($0) }
    }

    struct DuplicateCluster: Identifiable {
        let id: String
        let names: [String]
        let profileIDs: [String]
        let pairs: [(String, String)]
    }

    /// One keyed, ladder-sorted row for everything the unfiltered Health list
    /// holds — findings (duplicate pairs collapsed to ONE row per identity
    /// cluster, owner request 2026-07-25), open disputes, and the synthetic
    /// proposal rows. Sorted by `HealthTriage`: pinned conflicts → red →
    /// amber → blue, one-clicks leading each band, rules alphabetical, people
    /// alphabetical, run-stable tiebreak.
    ///
    /// Every consumer derives from THIS array, so the chip counts and the
    /// visible rows are the same data by construction — and the K3 registry
    /// (which reads the snapshot per row) runs once per body pass.
    private var mergedLadder: [LadderRow] {
        let findings = auditVM.filteredResults
        let dupes = findings.filter { $0.ruleID == "duplicateDetection" }
        let others = findings.filter { $0.ruleID != "duplicateDetection" }
        var rows: [HealthRow] = disputeRows
        rows += contradictoryFindings.map { HealthRow.contradictoryFacts($0) }
        rows += backfillProposals.map { HealthRow.censusBackfill($0) }
        rows += deathAgeProposals.map { HealthRow.deathAgeBackfill($0) }
        rows += censusCorroborations.map { HealthRow.censusCorroboration($0) }
        rows += duplicateClusters(from: dupes).map { HealthRow.duplicateCluster($0) }
        rows += others.map { HealthRow.finding($0) }
        return rows
            .map { LadderRow(key: triageKey(for: $0), row: $0) }
            .sorted { $0.key < $1.key }
    }

    struct LadderRow: Identifiable {
        let key: HealthTriage.Key
        let row: HealthRow
        var id: String { row.id }
    }

    /// The active chip applied to the merged ladder — order preserved, so
    /// every filtered view is still worst-first.
    private func filteredRows(from ladder: [LadderRow]) -> [HealthRow] {
        let matching: (LadderRow) -> Bool
        switch ruleFilter {
        case nil:
            return ladder.map(\.row)
        case quickWinsFilterID:
            matching = { $0.key.quickWinRank == 0 }
        case censusBackfillFilterID:
            matching = { if case .censusBackfill = $0.row { true } else { false } }
        case deathAgeBackfillFilterID:
            matching = { if case .deathAgeBackfill = $0.row { true } else { false } }
        case censusCiteFilterID:
            matching = { if case .censusCorroboration = $0.row { true } else { false } }
        case contradictoryFactsFilterID:
            matching = { if case .contradictoryFacts = $0.row { true } else { false } }
        case disputeConflictFilterID:
            matching = { if case .dispute = $0.row { true } else { false } }
        case let rule?:
            // A real rule chip. Duplicate findings live inside cluster rows,
            // so that chip matches the cluster type rather than a ruleID.
            if rule == "duplicateDetection" {
                matching = { if case .duplicateCluster = $0.row { true } else { false } }
            } else {
                matching = { if case .finding(let r) = $0.row { r.ruleID == rule } else { false } }
            }
        }
        return ladder.filter(matching).map(\.row)
    }

    private func triageKey(for row: HealthRow) -> HealthTriage.Key {
        let hasDB = appState.currentDatabase != nil
        switch row {
        case .finding(let r):
            return HealthTriage.findingKey(r, snapshot: appState.snapshot, hasDatabase: hasDB)
        case .duplicateCluster(let c):
            return HealthTriage.duplicateClusterKey(firstName: c.names.first, clusterID: c.id)
        case .censusBackfill(let p):
            return HealthTriage.proposalKey(label: "Census backfill", personName: p.targetName, id: "b:\(p.id)")
        case .deathAgeBackfill(let p):
            return HealthTriage.proposalKey(label: "Death-age backfill", personName: p.profileName, id: "da:\(p.id)")
        case .censusCorroboration(let p):
            return HealthTriage.proposalKey(label: "Cite census", personName: p.targetName, id: "cc:\(p.id)")
        case .contradictoryFacts(let f):
            return HealthTriage.contradictoryFactsKey(
                personName: f.profileName, profileID: f.profileID,
                demotableCount: f.demotable.count)
        case .dispute(let d):
            return HealthTriage.disputeKey(
                severity: d.severity, kind: d.kind, field: d.field,
                entityID: d.entityID, rowID: d.id,
                personName: appState.snapshot.profiles[d.entityID]?.displayName)
        }
    }

    private func duplicateClusters(from results: [AuditResult]) -> [DuplicateCluster] {
        var parent: [String: String] = [:]
        func root(_ x: String) -> String {
            var r = x
            while let p = parent[r], p != r { r = p }
            return r
        }
        func union(_ a: String, _ b: String) {
            parent[a] = parent[a] ?? a
            parent[b] = parent[b] ?? b
            let ra = root(a), rb = root(b)
            if ra != rb { parent[ra] = rb }
        }
        var allPairs: [(String, String)] = []
        for r in results {
            guard let other = r.relatedProfileIDs?.first else { continue }
            union(r.profileID, other)
            allPairs.append((r.profileID, other))
        }
        var members: [String: Set<String>] = [:]
        for id in parent.keys { members[root(id), default: []].insert(id) }
        var pairsByRoot: [String: [(String, String)]] = [:]
        for (a, b) in allPairs { pairsByRoot[root(a), default: []].append((a, b)) }
        return members.map { rootID, ids in
            let names = ids.compactMap { appState.snapshot.profiles[$0]?.displayName }
                .filter { !$0.isEmpty }.sorted()
            // Cluster identity = smallest member id, NOT the union-find root
            // (which depends on iteration order) — keeps the ladder's
            // tiebreak, scroll position and SwiftUI identity run-stable.
            return DuplicateCluster(id: ids.min() ?? rootID, names: names,
                                    profileIDs: Array(ids), pairs: pairsByRoot[rootID] ?? [])
        }
        .sorted { ($0.names.first ?? "") < ($1.names.first ?? "") }
    }

    @ViewBuilder
    private func duplicateClusterRow(_ cluster: DuplicateCluster) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.2.slash")
                .foregroundStyle(.orange)
                .font(.body)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(cluster.names.first ?? "Possible duplicates")
                    .font(AppTypography.cardTitle)
                Text("\(cluster.profileIDs.count) profiles look like possible duplicates: \(cluster.names.joined(separator: ", "))")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if let pair = cluster.pairs.first {
                Button {
                    comparePair = ComparePair(leftID: pair.0, rightID: pair.1)
                } label: {
                    Label(cluster.pairs.count == 1 ? "Compare" : "Compare (\(cluster.pairs.count))",
                          systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Compare these profiles side by side, one pair at a time — merge only true duplicates")
                // Inline false-positive exit for the unambiguous case: a
                // 2-person cluster IS one pair, so "Not a duplicate" needs
                // no compare detour. N-person clusters stay pair-at-a-time
                // through Compare (each pair is its own judgement).
                if cluster.pairs.count == 1 {
                    Button {
                        appState.dismissDuplicatePair(pair.0, pair.1)
                        refreshAudit()
                    } label: {
                        Label("Not a duplicate", systemImage: "person.2.slash")
                    }
                    .buttonStyle(.glass).controlSize(.mini)
                    .help("Record that \(cluster.names.joined(separator: " and ")) are two different people — this pair stops being flagged; other possible duplicates keep surfacing")
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func censusBackfillRow(_ p: CensusBackfill.Proposal) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.text.rectangle")
                .foregroundStyle(.blue)
                .font(.body)
                .frame(width: 24)
            quickWinBadge
            VStack(alignment: .leading, spacing: 3) {
                Text(p.targetName)
                    .font(AppTypography.cardTitle)
                Text(backfillDetail(p))
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button {
                appState.absorbCensusForRelative(p)
                backfillProposals.removeAll { $0.targetProfileID == p.targetProfileID }
                refreshAudit()
            } label: {
                Label("Absorb census", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.glassProminent).controlSize(.mini)
            .help("Copy the \(String(p.censusYear)) census onto \(p.targetName) — birth year, birthplace, residence and occupation, cited to the census")
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    /// Human summary of what a census backfill will land — the fields the record
    /// actually carries for this member.
    private func backfillDetail(_ p: CensusBackfill.Proposal) -> String {
        var parts: [String] = []
        if let y = p.estimatedBirthYear { parts.append("birth ~\(String(y))") }
        if let occ = p.memberRecord.occupation, !occ.isEmpty { parts.append(occ.lowercased()) }
        if let place = p.memberRecord.birthPlace, !place.isEmpty { parts.append("born \(place)") }
        let has = parts.isEmpty ? "census details" : parts.joined(separator: " · ")
        return "In \(p.targetName == p.memberRecord.common.name ? "a" : "the") \(String(p.censusYear)) census as \(p.relationshipLabel) — \(has) available to backfill"
    }

    @ViewBuilder
    private func deathAgeBackfillRow(_ p: DeathAgeBackfillProposal) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.blue)
                .font(.body)
                .frame(width: 24)
            quickWinBadge
            VStack(alignment: .leading, spacing: 3) {
                Text(p.profileName)
                    .font(AppTypography.cardTitle)
                Text(deathAgeDetail(p))
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button {
                appState.setBirthYearFromDeathAge(p)
                deathAgeProposals.removeAll { $0.profileID == p.profileID }
                refreshAudit()
            } label: {
                Label("Set birth ~\(String(p.estimatedBirthYear))", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.glassProminent).controlSize(.mini)
            .help("Set \(p.profileName)'s birth year to ~\(String(p.estimatedBirthYear)), calculated from age \(String(p.ageAtDeath)) at their \(String(p.deathYear)) death registration")
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    /// Human summary of a death-age backfill — age at death + registration year,
    /// plus the district when the matched index entry carries one.
    private func deathAgeDetail(_ p: DeathAgeBackfillProposal) -> String {
        var s = "Died \(String(p.deathYear)) aged \(String(p.ageAtDeath))"
        if let d = p.district, !d.isEmpty { s += " (\(d))" }
        return s + " → calculated birth year ~\(String(p.estimatedBirthYear))"
    }

    @ViewBuilder
    private func censusCorroborationRow(_ p: CensusBackfill.Proposal) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.blue)
                .font(.body)
                .frame(width: 24)
            quickWinBadge
            VStack(alignment: .leading, spacing: 3) {
                Text(p.targetName)
                    .font(AppTypography.cardTitle)
                Text("Birth year \(p.estimatedBirthYear.map { "~\(String($0))" } ?? "on record") is unsourced — the applied \(String(p.censusYear)) census household (as \(p.relationshipLabel)) agrees with it")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button {
                appState.citeCensusOnRelative(p)
                censusCorroborations.removeAll { $0.targetProfileID == p.targetProfileID }
                refreshAudit()
            } label: {
                Label("Cite census", systemImage: "checkmark.seal")
            }
            .buttonStyle(.glassProminent).controlSize(.mini)
            .help("Attach the \(String(p.censusYear)) census as evidence for \(p.targetName)'s existing birth year — the value doesn't change; it becomes evidence-backed instead of an uncited import.")
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func contradictoryFactsRow(_ f: ContradictoryFactsAudit.Finding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .font(.body)
                .frame(width: 24)
            if !f.demotable.isEmpty {
                quickWinBadge
            }
            Button {
                onOpenProfile?(f.profileID)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.profileName)
                        .font(AppTypography.cardTitle)
                    Text("\(f.demotions.count) accepted fact\(f.demotions.count == 1 ? "" : "s") contradict each other (\(f.slotSummary)) — a person holds at most one of each; none is corroborated enough to stand")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    // Applied rows are reported but never auto-demoted:
                    // reducing the evidence under a fact that is already on the
                    // profile says the TREE is wrong, which is the user's call.
                    if !f.appliedHeldBack.isEmpty {
                        Text("\(f.appliedHeldBack.count) of \(f.appliedHeldBack.count == 1 ? "these is" : "them are") already applied to the tree and will be left alone — decide \(f.appliedHeldBack.count == 1 ? "that one" : "those") yourself")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button {
                appState.demoteContradictoryFacts(f)
                contradictoryFindings.removeAll { $0.id == f.id }
                refreshAudit()
            } label: {
                Label("Demote \(f.demotable.count) to leads", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.glassProminent).controlSize(.mini)
            .disabled(f.demotable.isEmpty)
            .help(f.demotable.isEmpty
                  ? "Every contested fact here is already applied to the tree. Open the profile and remove the wrong one yourself — demoting the evidence under an applied fact is a judgement about the tree, not a cleanup."
                  : "Demote these \(f.demotable.count) contested facts to reviewable leads — the same deterministic rules a re-research run would apply. Nothing is deleted, and you can promote the right one from Triage. Records already applied to the tree are left untouched.")
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    /// #HR4 — the green bolt worn by every one-click row. Membership comes
    /// from the same registry as the ladder's K3 and the ⚡ chip, so badge,
    /// sort and chip can never disagree.
    private var quickWinBadge: some View {
        Label("1-click", systemImage: "bolt.fill")
            .font(AppTypography.badge)
            .foregroundStyle(.green)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.green.opacity(0.12), in: .capsule)
            .help("Deterministic fix — one click, undoable")
    }

    @ViewBuilder
    private func findingRow(_ result: AuditResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.severity.iconName)
                .foregroundStyle(result.severity.color)
                .font(.body)
                .frame(width: 24)
                .accessibilityLabel("Severity \(result.severity.rawValue)")
            if HealthTriage.isOneClickFinding(
                result, snapshot: appState.snapshot,
                hasDatabase: appState.currentDatabase != nil) {
                quickWinBadge
            }
            // Clicking the finding jumps to the profile it is about
            // (Tree → Full Detail) so it can be investigated in context.
            Button {
                onOpenProfile?(result.profileID)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.profileName)
                        .font(AppTypography.cardTitle)
                    Text(strippedMessage(result))
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpenProfile == nil)
            .help("Open \(result.profileName) in the tree")

            fixButton(for: result)

            Button {
                onEditProfile?(result.profileID)
            } label: {
                Label("Edit Profile", systemImage: "pencil")
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .disabled(onEditProfile == nil)
            .help("Edit \(result.profileName)")

            Button {
                promoteToQuestion(result)
            } label: {
                Label("Add Question", systemImage: "questionmark.bubble")
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .help("Track this as a research question — it appears in the Tasks tab to look into later")
            .accessibilityHint("Add this finding as an open research question that appears in the Tasks tab")

            // Escape hatch for a false positive: silence THIS rule for THIS
            // profile so it stops re-firing every re-audit (owner report
            // 2026-08-06 — a census-unabsorbed finding that couldn't be
            // resolved or cleared). Re-enable from the audit-rule overrides UI.
            Button {
                appState.dismissAuditFinding(ruleID: result.ruleID, profileID: result.profileID)
                syncAuditSummary()
            } label: {
                Label("Dismiss", systemImage: "bell.slash")
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .help("Dismiss this finding for \(result.profileName) — it won't re-appear after re-audit. Re-enable it in Settings → Audit Rules.")
            .accessibilityHint("Silence this finding for this person")
        }
        if result.ruleID == "censusRelationship", result.severity == .info {
            censusReconciliationDetail(for: result)
        }
        if result.ruleID == "censusUnabsorbed" {
            censusHouseholdDetail(for: result)
        }
        if result.ruleID == "parishFamilyUnabsorbed" {
            parishFamilyDetail(for: result)
        }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    /// The census-household absorption row for a `censusUnabsorbed` finding — the
    /// SAME `CensusHouseholdFixRow` the profile card shows, hosted here so the
    /// Load-household / Add-N action (and its roster preview) is available in the
    /// Health tab without a click-through into the profile. Bounded: only the
    /// (few) censusUnabsorbed rows re-derive the proposal, reusing the exact
    /// stored-evidence read the finding itself used.
    @ViewBuilder private func censusHouseholdDetail(for result: AuditResult) -> some View {
        if let db = appState.currentDatabase,
           let profile = appState.snapshot.profiles[result.profileID],
           let evidence = try? db.loadEvidenceForProfile(result.profileID),
           let proposal = appState.censusHouseholdProposal(for: profile, evidence: evidence) {
            CensusHouseholdFixRow(
                profile: profile, proposal: proposal,
                onChanged: { refreshAudit() },
                reviewInProfile: { onOpenProfile?(result.profileID) })
            .padding(.leading, 34)
        }
    }

    /// The parish-family absorb row for a `parishFamilyUnabsorbed` finding — the
    /// SAME `ParishFamilyFixRow` the profile card shows, hosted here so the
    /// (tree-mutating) add, routed to the profile for context, is available from
    /// the Health tab without a click-through.
    @ViewBuilder private func parishFamilyDetail(for result: AuditResult) -> some View {
        if let db = appState.currentDatabase,
           let profile = appState.snapshot.profiles[result.profileID],
           let evidence = try? db.loadEvidenceForProfile(result.profileID),
           let proposal = appState.parishFamilyProposal(for: profile, evidence: evidence) {
            ParishFamilyFixRow(
                profile: profile, proposal: proposal,
                onChanged: { refreshAudit() },
                reviewInProfile: { onOpenProfile?(result.profileID) })
            .padding(.leading, 34)
        }
    }

    // MARK: - Conflict (open dispute) row

    /// A folded-in open dispute: sources disagreeing with a stored value. Reads
    /// as an issue row (name + plain-language "X says A, Y says B"), but its fix
    /// is "Resolve…" — pick a value — never "Research" (a conflict isn't a gap;
    /// researching it would only pile on more competing values).
    @ViewBuilder
    private func disputeRow(_ row: DisputeRow) -> some View {
        let name = appState.snapshot.profiles[row.entityID]?.displayName ?? row.entityID
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(disputeSeverityColor(row.severity))
                .font(.body)
                .frame(width: 24)
                .accessibilityLabel("Conflict severity \(row.severity?.rawValue ?? "unknown")")
            Button {
                onOpenProfile?(row.entityID)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name).font(AppTypography.cardTitle)
                        Text(prettyField(row.field))
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                        // `.none` is a stored default, not a grade — printing
                        // the literal word "none" as a severity badge says
                        // nothing (review 2026-08-25).
                        if let sev = row.severity, sev != .none {
                            Text(sev.rawValue)
                                .font(AppTypography.badge)
                                .foregroundStyle(disputeSeverityColor(sev))
                        }
                        // Mirrors the gate EXACTLY — which ignores
                        // severity (a cosmetic refinement blocks its field
                        // too) and does NOT refuse on a deferred dispute.
                        // Deliberately independent of the pin (review
                        // 2026-08-25: the pin is about urgency, this is about
                        // machinery).
                        if HealthTriage.blocksAutoApproval(
                            kind: row.kind, field: row.field, resolution: row.resolution) {
                            Label(HealthTriage.autoApprovalBadgeText(
                                    kind: row.kind, fieldLabel: prettyField(row.field)),
                                  systemImage: "nosign")
                                .font(AppTypography.badge)
                                .foregroundStyle(.red)
                                .help("MCP auto-approval refuses while this dispute is open — resolving it unblocks the machinery. (Deferring does not: the gate only clears on a real resolution.)")
                        }
                    }
                    Text(disputeMessage(row))
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpenProfile == nil)
            .help("Open \(name) in the tree")

            if disputeIsInlineResolvable(row) {
                Button {
                    startResolving(row)
                } label: {
                    Label("Resolve…", systemImage: "checkmark.circle.badge.questionmark")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Choose which value is correct — a conflict is a decision only you can make")
            } else {
                // Timeline / structural conflicts (a census implying an impossible
                // age, a spouse-surname mismatch) aren't a value-pick — they're
                // resolved by editing the underlying record. Open the profile,
                // where that edit lives. (`ConflictResolutionView` handles only
                // .fieldValue.)
                Button {
                    onOpenProfile?(row.entityID)
                } label: {
                    Label("Open profile", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .disabled(onOpenProfile == nil)
                .help("This conflict is resolved by editing the record on \(name)'s profile")
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    /// A dispute is resolvable inline (value-picker sheet) only when it's a
    /// field-value conflict on a real profile field — the only kind
    /// `ConflictResolutionView` accepts — AND at least one of its competing
    /// values is still attested. Timeline/spouse/parent kinds are edited on the
    /// profile instead, and so is a value dispute whose every candidate has been
    /// discarded: a picker with nothing left to pick is a dead end.
    private func disputeIsInlineResolvable(_ row: DisputeRow) -> Bool {
        isFieldValueDispute(row) && !liveCompetingSources(row).isEmpty
    }

    private func isFieldValueDispute(_ row: DisputeRow) -> Bool {
        row.kind == .fieldValue && ProfileField(rawValue: row.field) != nil
    }

    /// The row's competing values re-derived against what the profile CURRENTLY
    /// attests (see `DisputeSheetItem.liveCompetingSources`). Structural kinds
    /// keep their stored snapshot — their field keys are not `field_sources`
    /// fields, so there is nothing live to re-derive them from.
    private func liveCompetingSources(_ row: DisputeRow) -> [FieldSource] {
        guard isFieldValueDispute(row),
              let field = ProfileField(rawValue: row.field),
              let profile = appState.snapshot.profiles[row.entityID]
        else { return row.competingSources }
        // EV11 follow-up (review C4): the producer discriminates which rowless
        // competitors may survive — see `liveCompetingSources`.
        return DisputeSheetItem.liveCompetingSources(
            stored: row.competingSources, attested: profile.sources[field] ?? [],
            detectedBy: row.detectedBy)
    }

    /// Open the same `ConflictResolutionView` the profile uses for a value dispute.
    private func startResolving(_ row: DisputeRow) {
        guard let profile = appState.snapshot.profiles[row.entityID],
              let field = ProfileField(rawValue: row.field) else { return }
        let dispute = profile.disputes[field] ?? FieldDispute(
            field: field, reason: row.reason, competingSources: row.competingSources,
            detectedAt: row.detectedAt, resolution: row.resolution,
            kind: row.kind, severity: row.severity, detectedBy: row.detectedBy)
        resolvingDispute = DisputeSheetItem(profile: profile, dispute: dispute)
    }

    /// Plain-language conflict: competing values grouped by value, each tagged
    /// with which sources assert it — "“1 Jan 1999” (GEDCOM, you)  vs  “2000-04-07” (Probate)".
    private func disputeMessage(_ row: DisputeRow) -> String {
        var origins: [String: Set<String>] = [:]
        var order: [String] = []
        for source in liveCompetingSources(row) {
            let value = source.raw.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if origins[value] == nil { order.append(value) }
            origins[value, default: []].insert(prettyOrigin(source.origin.identifier))
        }
        let parts = order.map { value -> String in
            let who = origins[value]?.sorted().joined(separator: ", ") ?? ""
            return who.isEmpty ? "“\(value)”" : "“\(value)” (\(who))"
        }
        return parts.isEmpty ? "Sources disagree on this value." : parts.joined(separator: "  vs  ")
    }

    private func disputeSeverityColor(_ severity: DiscrepancySeverity?) -> Color {
        switch severity ?? .none {
        case .correction: .red
        case .conflict: .orange
        case .refinement: .blue
        case .note, .none: .secondary
        }
    }

    /// Friendly field label for a dispute row header.
    private func prettyField(_ field: String) -> String {
        switch field {
        case "birthDate": "Birth date"
        case "deathDate": "Death date"
        case "birthLocation": "Birthplace"
        case "deathLocation": "Death place"
        case "spouse": "Spouse"
        default: field
        }
    }

    /// Friendly source label for a competing-value provenance identifier.
    private func prettyOrigin(_ identifier: String) -> String {
        if identifier.hasPrefix("manual") { return "you" }
        switch identifier {
        case "gedcom": return "GEDCOM"
        case "freebmd": return "FreeBMD"
        case "freecen": return "FreeCen"
        case "freereg": return "FreeREG"
        case "familysearch": return "FamilySearch"
        case "findagrave": return "Find a Grave"
        case "probate": return "Probate"
        case "cwgc": return "CWGC"
        case "tree": return "tree"
        default: return identifier.prefix(1).uppercased() + identifier.dropFirst()
        }
    }

    // MARK: - Census reconciliation detail panel

    private struct TreeRelativeChip: Identifiable {
        let id: String
        let name: String
        let relation: String
    }

    /// The rich panel beneath a census missing-relatives finding: the subject's
    /// current tree relatives (tappable to open), then each census household
    /// classified row-by-row — who is the subject, who is already in the tree,
    /// who conflicts, who is missing (with a per-row Add), and who is not family.
    @ViewBuilder
    private func censusReconciliationDetail(for result: AuditResult) -> some View {
        if let subject = appState.snapshot.profiles[result.profileID] {
            let recons = CensusRelationshipReconciler.reconciliations(for: subject, in: appState.snapshot)
            let relatives = currentTreeRelatives(of: result.profileID)
            VStack(alignment: .leading, spacing: 10) {
                if !relatives.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Already in the tree").font(AppTypography.badge).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(relatives) { rel in
                                    Button { onOpenProfile?(rel.id) } label: {
                                        Text("\(rel.name) · \(rel.relation)")
                                            .font(AppTypography.cardMeta)
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(Color.secondary.opacity(0.12), in: .capsule)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(onOpenProfile == nil)
                                    .help("Open \(rel.name) in the tree")
                                }
                            }
                        }
                    }
                }
                ForEach(Array(recons.enumerated()), id: \.offset) { _, recon in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recon.censusYear.map { "\(String($0)) census household" } ?? "Census household")
                            .font(AppTypography.badge).foregroundStyle(.secondary)
                        ForEach(Array(recon.entries.enumerated()), id: \.offset) { _, entry in
                            censusRosterRow(entry, subjectID: result.profileID, censusYear: recon.censusYear)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func censusRosterRow(_ entry: CensusRelationshipReconciler.CensusReconciliation.RosterEntry,
                                 subjectID: String, censusYear: Int?) -> some View {
        HStack(spacing: 8) {
            Text(entry.member.name).font(AppTypography.cardMeta)
            Text(entry.member.relationship).font(AppTypography.cardMeta).foregroundStyle(.secondary)
            if let age = entry.member.age {
                Text("age \(String(age))").font(AppTypography.cardMeta).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            censusRosterStatus(entry, subjectID: subjectID, censusYear: censusYear)
        }
    }

    @ViewBuilder
    private func censusRosterStatus(_ entry: CensusRelationshipReconciler.CensusReconciliation.RosterEntry,
                                    subjectID: String, censusYear: Int?) -> some View {
        switch entry.status {
        case .subject:
            rosterBadge("this person", "person.fill", .secondary)
        case .inTree(let pid):
            Button { onOpenProfile?(pid) } label: { rosterBadge("in tree", "checkmark.circle.fill", .green) }
                .buttonStyle(.plain).disabled(onOpenProfile == nil)
        case .contradiction(let tid, let treeRelation):
            Button { onOpenProfile?(tid) } label: {
                rosterBadge("conflicts · tree says \(relationWord(treeRelation, sex: entry.member.sex))",
                            "exclamationmark.triangle.fill", .orange)
            }
            .buttonStyle(.plain).disabled(onOpenProfile == nil)
            .help("The census makes this a \(relationWord(entry.censusRelation, sex: entry.member.sex)); the tree records a \(relationWord(treeRelation, sex: entry.member.sex)). Open to reconcile.")
        case .missing:
            if let relation = entry.censusRelation {
                Button {
                    appState.addCensusRelative(subjectID: subjectID, member: entry.member,
                                               relation: relation, censusYear: censusYear)
                    refreshAudit()
                } label: {
                    Label("Add \(relationWord(relation, sex: entry.member.sex))", systemImage: "person.badge.plus")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Create \(entry.member.name) and link as \(subjectName(subjectID))\(relationWord(relation, sex: entry.member.sex)), citing the census")
            }
        case .inLawOfSpouse(let spouseID, let kind):
            let spouseName = appState.snapshot.profiles[spouseID]?.displayName ?? "spouse"
            let word = kind == .mother ? "mother" : "father"
            let surname = entry.member.name.split(separator: " ").last.map(String.init)
            Button {
                appState.addSpouseParentFromInLaw(subjectID: subjectID, spouseID: spouseID,
                                                  member: entry.member, kind: kind, censusYear: censusYear)
                refreshAudit()
            } label: {
                Label("Add \(spouseName)'s \(word)\(surname.map { " (\($0))" } ?? "")",
                      systemImage: "person.badge.plus")
            }
            .buttonStyle(.glassProminent).controlSize(.mini)
            .help("Create \(entry.member.name), link as \(spouseName)'s \(word), and record \(spouseName)'s maiden name\(surname.map { " (\($0))" } ?? "") — all from this census line")
        case .unlinkedInTree(let existingID):
            let name = appState.snapshot.profiles[existingID]?.displayName ?? "existing profile"
            Button {
                if let relation = entry.censusRelation {
                    appState.linkCensusRelative(subjectID: subjectID, existingID: existingID,
                                                relation: relation, censusYear: censusYear)
                    refreshAudit()
                }
            } label: {
                Label("Link \(name)", systemImage: "link")
            }
            .buttonStyle(.glassProminent).controlSize(.mini)
            .help("\(name) is already in the tree — link them as \(subjectName(subjectID))\(relationWord(entry.censusRelation, sex: entry.member.sex)) instead of adding a duplicate")
        case .nearMatch(let existingID, let reason):
            // A PROPOSAL, and the weakest one this engine makes: the forename does
            // not agree — only surname, household role, sex and birth year do.
            //
            // EV18, 2026-08-26. This was a single `.glassProminent` "Same as X?"
            // button, which read as the recommended action for an identity nobody
            // had established, and it was the only answer on offer. William
            // Gladwin's 1871 Whittington schedule lists a son "John H Gladwin"
            // (b. 1861, Unstone) against the tree's "Thomas H Gladwin" (b. 1861,
            // Unstone); an adversarial review put "same boy" at about 70% and
            // ruled DO NOT MERGE. Over-splitting is recoverable by the user,
            // over-merging is not — so both answers are offered, neither is
            // prominent, and the split is spelled out rather than implied by
            // walking away.
            let name = appState.snapshot.profiles[existingID]?.displayName ?? "existing profile"
            HStack(spacing: 6) {
                rosterBadge("possibly \(name)", "questionmark.circle", .orange)
                if let relation = entry.censusRelation {
                    Button("Same person") {
                        appState.linkCensusRelative(subjectID: subjectID, existingID: existingID,
                                                    relation: relation, censusYear: censusYear)
                        refreshAudit()
                    }
                    .buttonStyle(.glass).controlSize(.mini)
                    .help("Treat this row as \(name) and complete any missing edge to them. The census spells the forename differently, but \(reason).")
                    Button("Add separately") {
                        appState.addCensusRelative(subjectID: subjectID, member: entry.member,
                                                   relation: relation, censusYear: censusYear)
                        refreshAudit()
                    }
                    .buttonStyle(.glass).controlSize(.mini)
                    .help("\(entry.member.name) has not been linked to anyone. If they are a different person from \(name), create them as \(subjectName(subjectID))\(relationWord(relation, sex: entry.member.sex)) in their own right, citing the census.")
                }
            }
        case .outOfScope:
            rosterBadge("not family", "minus.circle", .secondary)
        }
    }

    private func rosterBadge(_ text: String, _ systemImage: String, _ color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(AppTypography.badge)
            .foregroundStyle(color)
    }

    /// "Samuel Wheeldon's " (possessive, trailing space) or a neutral fallback.
    private func subjectName(_ subjectID: String) -> String {
        appState.snapshot.profiles[subjectID].map { "\($0.displayName)'s " } ?? "the subject's "
    }

    /// The subject's current tree relatives as tappable chips.
    private func currentTreeRelatives(of subjectID: String) -> [TreeRelativeChip] {
        let snap = appState.snapshot
        var out: [TreeRelativeChip] = []
        for p in snap.parentsOf(subjectID) {
            out.append(.init(id: p.id, name: p.displayName, relation: relationWord(.parent, sex: sexString(p))))
        }
        for p in snap.spousesOf(subjectID) {
            out.append(.init(id: p.id, name: p.displayName, relation: "spouse"))
        }
        for p in snap.siblingsOf(subjectID) {
            out.append(.init(id: p.id, name: p.displayName, relation: relationWord(.sibling, sex: sexString(p))))
        }
        for p in snap.childrenOf(subjectID) {
            out.append(.init(id: p.id, name: p.displayName, relation: relationWord(.child, sex: sexString(p))))
        }
        return out
    }

    private func sexString(_ p: Profile) -> String? {
        switch p.gender {
        case .male: return "M"
        case .female: return "F"
        default: return nil
        }
    }

    /// Gender-aware relationship noun for a census relation.
    private func relationWord(_ relation: CensusRelation?, sex: String?) -> String {
        let s = (sex ?? "").uppercased()
        let male = s.hasPrefix("M"), female = s.hasPrefix("F")
        switch relation {
        case .parent:  return male ? "father" : (female ? "mother" : "parent")
        case .child:   return male ? "son" : (female ? "daughter" : "child")
        case .sibling: return male ? "brother" : (female ? "sister" : "sibling")
        case .spouse:  return "spouse"
        case .none:    return "relative"
        }
    }

    /// One chip per distinct rule present, with counts, so the list can be
    /// narrowed to a single issue type (e.g. married-surname-missing) — the
    /// per-issue-type filtering that used to live in Tasks.
    /// Worst severity per rule id, for tinting the filter chips (error > warning
    /// > info). Plain (non-ViewBuilder) so the loop is legal.
    private var worstSeverityByRule: [String: Severity] {
        var out: [String: Severity] = [:]
        for r in auditVM.filteredResults {
            if let cur = out[r.ruleID], cur.rank >= r.severity.rank { continue }
            out[r.ruleID] = r.severity
        }
        return out
    }

    @ViewBuilder private func ruleFilterChips(ladder: [LadderRow]) -> some View {
        // The ⚡ count is derived from the SAME ladder the rows come from, so
        // the chip's N and the rows it reveals can never disagree.
        let quickWinCount = ladder.count { $0.key.quickWinRank == 0 }
        let counts = Dictionary(grouping: auditVM.filteredResults, by: { $0.ruleID })
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
        // Worst severity per rule → tints its chip, so the filter bar reads as a
        // severity legend rather than a wall of identical grey capsules: a .info
        // gap ("Missing bio") shows blue, an amber warning shows orange, an error
        // shows red — the severity is legible before you even select the chip.
        let severityByRule = worstSeverityByRule
        // The bar must render whenever a filter is ACTIVE (it carries the only
        // way back), or whenever any chip would be offered — including the ⚡
        // and Conflicts chips, which the old gate ignored (review 2026-08-25:
        // a single-rule list of one-click findings hid its own clearance mode).
        if ruleFilter != nil || counts.count > 1 || quickWinCount > 0
            || !openDisputeRows.isEmpty
            || !backfillProposals.isEmpty || !deathAgeProposals.isEmpty
            || !contradictoryFindings.isEmpty || !censusCorroborations.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ruleChip(label: "All (\(auditVM.filteredResults.count))", selected: ruleFilter == nil) {
                        ruleFilter = nil
                    }
                    // #HR4 — the opportunistic-session mode: one tap turns the
                    // list into a pure clearance queue, still worst-first.
                    if quickWinCount > 0 || ruleFilter == quickWinsFilterID {
                        ruleChip(label: "⚡ Quick wins (\(quickWinCount))",
                                 selected: ruleFilter == quickWinsFilterID) {
                            ruleFilter = (ruleFilter == quickWinsFilterID) ? nil : quickWinsFilterID
                        }
                    }
                    ForEach(counts, id: \.key) { rule, count in
                        ruleChip(label: "\(prettyRule(rule)) (\(count))", severity: severityByRule[rule], selected: ruleFilter == rule) {
                            ruleFilter = (ruleFilter == rule) ? nil : rule
                        }
                    }
                    if !backfillProposals.isEmpty {
                        ruleChip(label: "Census backfill (\(backfillProposals.count))",
                                 selected: ruleFilter == censusBackfillFilterID) {
                            ruleFilter = (ruleFilter == censusBackfillFilterID) ? nil : censusBackfillFilterID
                        }
                    }
                    if !deathAgeProposals.isEmpty {
                        ruleChip(label: "Death-age backfill (\(deathAgeProposals.count))",
                                 selected: ruleFilter == deathAgeBackfillFilterID) {
                            ruleFilter = (ruleFilter == deathAgeBackfillFilterID) ? nil : deathAgeBackfillFilterID
                        }
                    }
                    if !contradictoryFindings.isEmpty {
                        ruleChip(label: "Contradictory facts (\(contradictoryFindings.count))",
                                 severity: .warning,
                                 selected: ruleFilter == contradictoryFactsFilterID) {
                            ruleFilter = (ruleFilter == contradictoryFactsFilterID) ? nil : contradictoryFactsFilterID
                        }
                    }
                    if !censusCorroborations.isEmpty {
                        ruleChip(label: "Cite census (\(censusCorroborations.count))",
                                 selected: ruleFilter == censusCiteFilterID) {
                            ruleFilter = (ruleFilter == censusCiteFilterID) ? nil : censusCiteFilterID
                        }
                    }
                    if !openDisputeRows.isEmpty {
                        ruleChip(label: "Conflicts (\(openDisputeRows.count))",
                                 severity: .warning,
                                 selected: ruleFilter == disputeConflictFilterID) {
                            ruleFilter = (ruleFilter == disputeConflictFilterID) ? nil : disputeConflictFilterID
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, 4)
        }
    }

    /// A filter chip. `severity` tints it by the worst finding the rule holds
    /// (blue = info, orange = warning, red = error); nil (the "All" and synthetic
    /// backfill chips) falls back to the accent colour.
    @ViewBuilder private func ruleChip(label: String, severity: Severity? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        let tint = severity?.color ?? Color.accentColor
        Button(action: action) {
            HStack(spacing: 5) {
                if let severity {
                    Circle().fill(severity.color).frame(width: 6, height: 6)
                }
                Text(label)
                    .font(AppTypography.badge)
                    .foregroundStyle(selected ? tint : .primary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? tint.opacity(0.22) : tint.opacity(0.10), in: .capsule)
            .overlay {
                if selected { Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
    }

    /// "marriedSurnameFromSpouse" → "Married surname from spouse".
    /// Delegates to HealthTriage so the chip label and the ladder's K4 sort
    /// label are the same string by construction.
    private func prettyRule(_ id: String) -> String {
        HealthTriage.prettyRule(id)
    }

    /// The one-click fix for a finding whose rule has one — married surname,
    /// census-derived birth year, placeholder-parent cleanup. Rules that need a
    /// human choice (which parent to unlink, etc.) have no button here and are
    /// fixed via Edit or in the profile.
    /// Shared per-rule fix switch — see `AuditFixButton`. Health passes its
    /// compare-sheet and FreeBMD-enrich launchpad closures; the profile
    /// card's Health strip uses the same component with fallbacks.
    @ViewBuilder private func fixButton(for r: AuditResult) -> some View {
        AuditFixButton(
            result: r,
            lastResearched: researchDates[r.profileID],
            householdRowYears: censusHouseholdYears[r.profileID] ?? [],
            onFixed: { refreshAudit() },
            onCompare: { left, right in comparePair = ComparePair(leftID: left, rightID: right) },
            onEnriched: { profileID, profileName, count in
                enrichResult = EnrichResult(profileID: profileID, profileName: profileName, count: count)
            }
        )
    }

    /// AppState's fix methods re-run the audit and refresh `auditSummary`;
    /// re-sync the view model so the fixed finding drops off the list.
    private func refreshAudit() {
        syncAuditSummary()
    }

    /// Set the displayed summary to the maintained base with the DB-derived
    /// FreeBMD citation-gap findings (Change 2) folded in. Used by both onAppear
    /// and every refresh, so the gaps stay visible after an enrich/merge/dismiss
    /// rather than vanishing on the next reset.
    private func syncAuditSummary() {
        guard let base = appState.auditSummary else { auditVM.summary = nil; return }
        // Injected findings bypass AuditEngine's per-profile mute, so honour a
        // "Dismiss for this person" override here too (owner report 2026-08-06).
        func kept(_ results: [AuditResult]) -> [AuditResult] {
            results.filter { !appState.isAuditFindingMuted(ruleID: $0.ruleID, profileID: $0.profileID) }
        }
        let citationGaps = kept(appState.freeBMDCitationGapFindings())      // info
        let parentUnlocks = kept(appState.censusParentUnlockFindings())     // warning
        let censusUnabsorbed = kept(appState.censusUnabsorbedFindings())    // warning
        censusHouseholdYears = householdYears(for: censusUnabsorbed)
        let parishUnabsorbed = kept(appState.parishFamilyUnabsorbedFindings()) // warning
        // Evidence the app names but can't act on — the net under the offers,
        // so a proposal that never forms is a work item rather than silence.
        let kinUnreadable = kept(appState.parishKinUnreadableFindings())     // warning
        // Unapplied census leads holding un-absorbed kin (EV2). Deduped
        // against censusUnabsorbed: once a household has been APPLIED the
        // absorbed sweep owns it, and both firing would show one household
        // twice under two rules.
        //
        // EV2 follow-up (review M5): the dedup keys on (profile, census YEAR),
        // never on profile alone — the two rules cover different records, so a
        // profile's applied 1871 household must not silence its 1891 lead
        // household. `censusHouseholdYears` was set from the applied sweep's
        // proposals just above, so the year map costs nothing extra here.
        let censusLeadAttention = Self.dedupedCensusLeadAttention(
            kept(appState.censusLeadAttentionFindings()),
            absorbedYears: censusHouseholdYears)
        guard !citationGaps.isEmpty || !parentUnlocks.isEmpty
            || !censusUnabsorbed.isEmpty || !parishUnabsorbed.isEmpty
            || !kinUnreadable.isEmpty || !censusLeadAttention.isEmpty else {
            auditVM.summary = base; return
        }
        auditVM.summary = AuditSummary(
            errors: base.errors,
            warnings: base.warnings + parentUnlocks + censusUnabsorbed
                + parishUnabsorbed + kinUnreadable
                + censusLeadAttention.filter { $0.severity == .warning },
            info: base.info + citationGaps
                + censusLeadAttention.filter { $0.severity != .warning },
            total: base.total + citationGaps.count + parentUnlocks.count
                + censusUnabsorbed.count + parishUnabsorbed.count + kinUnreadable.count
                + censusLeadAttention.count,
            profilesChecked: base.profilesChecked)
    }

    /// Which census year each `censusUnabsorbed` finding covers. The finding
    /// itself carries the year only inside its prose message, so the proposal is
    /// re-derived — the same read that produced the finding, over the handful of
    /// profiles that raised one.
    private func householdYears(for findings: [AuditResult]) -> [String: Set<Int>] {
        guard let db = appState.currentDatabase else { return [:] }
        var out: [String: Set<Int>] = [:]
        for finding in findings {
            guard let profile = appState.snapshot.profiles[finding.profileID],
                  let evidence = try? db.loadEvidenceForProfile(finding.profileID),
                  let proposal = appState.censusHouseholdProposal(for: profile, evidence: evidence)
            else { continue }
            out[finding.profileID, default: []].insert(proposal.censusYear)
        }
        return out
    }

    /// EV2 follow-up (review M5): drop a `censusLeadUnabsorbed` finding only
    /// when the applied sweep already reported the SAME household — same
    /// profile AND same census year (`absorbedYears` is `householdYears(for:)`
    /// over the applied sweep's findings). The profile-keyed version silenced
    /// every other year's lead household — the applied 1871 census muted the
    /// 1891 lead naming an unrecorded sibling, re-creating the exact EV2
    /// silence this rule was written to end. `censusLeadContradiction`
    /// findings are never dropped: the applied sweep reports missing kin,
    /// never roster-vs-tree clashes, so there is nothing for a clash finding
    /// to be a duplicate of.
    nonisolated static func dedupedCensusLeadAttention(
        _ findings: [AuditResult], absorbedYears: [String: Set<Int>]
    ) -> [AuditResult] {
        findings.filter { finding in
            guard finding.ruleID == CensusLeadAttentionAudit.unabsorbedRuleID,
                  let years = absorbedYears[finding.profileID],
                  let year = censusLeadYear(in: finding.message)
            else { return true }
            // A message the year can't be read from keeps its finding —
            // showing a household twice beats silencing it.
            return !years.contains(year)
        }
    }

    /// The census year a `CensusLeadAttentionAudit` message names. The finding
    /// carries its year only in prose ("…'s 1891 census lead names…"), so the
    /// dedup reads it back out — coupled to that producer's fixed message
    /// format, which both of its rules share.
    nonisolated static func censusLeadYear(in message: String) -> Int? {
        guard let range = message.range(
            of: #"\b\d{4} census lead\b"#, options: .regularExpression)
        else { return nil }
        return Int(message[range].prefix(4))
    }

    private func promoteToQuestion(_ result: AuditResult) {
        let priority: QuestionPriority = switch result.severity {
        case .error: .high
        case .warning: .medium
        case .info: .low
        }
        let text = "\(result.profileName): \(strippedMessage(result))"
        appState.createQuestion(
            text: text,
            profileIDs: [result.profileID],
            priority: priority,
            promotedFrom: .fromAudit(ruleID: result.ruleID)
        )
        appState.successMessage = "Added to workbench questions."
    }

    /// Strip the profile name from the start of the message to avoid duplication with the header.
    private func strippedMessage(_ result: AuditResult) -> String {
        var msg = result.message
        if msg.hasPrefix(result.profileName) {
            msg = String(msg.dropFirst(result.profileName.count))
            // Remove leading separator: " — ", " - ", " "
            if msg.hasPrefix(" — ") {
                msg = String(msg.dropFirst(3))
            } else if msg.hasPrefix(" ") {
                msg = String(msg.dropFirst(1))
            }
        }
        // Capitalize first letter
        return msg.prefix(1).uppercased() + msg.dropFirst()
    }

    /// Open-disputes status as a pill matching the severity counts. Tapping it
    /// filters the issues list to the folded-in `Conflicts` rows (and back);
    /// ringed while that filter is active.
    private func disputesPill(count: Int) -> some View {
        let active = ruleFilter == disputeConflictFilterID
        return Button {
            ruleFilter = active ? nil : disputeConflictFilterID
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("\(count) conflict\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .overlay(
                Capsule().strokeBorder(active ? Color.orange : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) open conflicts")
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .help(active ? "Show all issues" : "Show only the \(count) source conflicts")
    }

    /// A category (Issues / Gaps) as a single toggle pill carrying its name +
    /// count — tap to filter, tap again to clear. Mirrors `severityFilterPill`
    /// so both filter axes behave identically; the cleared state is "all", so
    /// there is no separate All button. The other category dims while a filter
    /// is active.
    private func categoryFilterPill(_ category: AuditCategory, label: String, count: Int) -> some View {
        let selected = auditVM.filterCategory == category
        let filtering = auditVM.filterCategory != nil
        return Button {
            auditVM.filterCategory = selected ? nil : category
        } label: {
            Text("\(label) (\(count))")
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                .overlay(
                    Capsule().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                .opacity(!filtering || selected ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) \(label)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(selected
              ? "Showing only \(label). Tap to show all findings."
              : "Show only \(label)")
    }

    /// A severity count that IS the severity filter: tap to show only that
    /// level, tap again to clear. Replaces the old display-only badge + separate
    /// severity Picker (one control per axis, no duplication). When a filter is
    /// active the other levels dim, so the current filter state reads at a glance.
    private func severityFilterPill(_ severity: Severity, count: Int) -> some View {
        let selected = auditVM.filterSeverity == severity
        let filtering = auditVM.filterSeverity != nil
        return Button {
            auditVM.filterSeverity = selected ? nil : severity
        } label: {
            HStack(spacing: 4) {
                Image(systemName: severity.iconName)
                    .foregroundStyle(severity.color)
                    .accessibilityHidden(true)
                Text("\(count)")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .overlay(
                Capsule().strokeBorder(selected ? severity.color : Color.clear, lineWidth: 2)
            )
            .opacity(!filtering || selected ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(severity.rawValue)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(selected
              ? "Showing only \(severity.rawValue). Tap to show all severities."
              : "Show only \(severity.rawValue)")
    }
}

nonisolated extension Severity {
    var iconName: String {
        switch self {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    /// error > warning > info — for picking the worst severity in a group
    /// (e.g. tinting a rule's filter chip by the most serious finding it holds).
    var rank: Int {
        switch self {
        case .error: 2
        case .warning: 1
        case .info: 0
        }
    }
}
