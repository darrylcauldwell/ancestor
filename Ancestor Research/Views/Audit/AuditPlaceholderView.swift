import SwiftUI

/// Health view — the tree's data-quality home. Runs the audit rules and
/// displays errors / warnings / info grouped by severity, with Issues/Gaps and
/// severity filters, the conflict sweep, import-duplicate scan, and the open-
/// disputes list. Wired to the `.health` sidebar tab. (Formerly the tab-less
/// AuditPlaceholderView.)
struct HealthView: View {
    /// Navigate to a finding's profile (Tree → Full Detail). Injected by
    /// ContentView; nil disables the affordance in previews.
    var onOpenProfile: ((String) -> Void)? = nil
    /// Open a finding's profile straight in the editor.
    var onEditProfile: ((String) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @State private var auditVM = AuditViewModel()
    @State private var openDisputeCount: Int?
    @State private var showDisputeList = false
    @State private var openDisputeRows: [DisputeRow] = []
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
                        // CONFLICT_LAYER_SPEC CL2 — manual conflict sweep;
                        // refreshes the live open-dispute count.
                        appState.runConflictSweep(force: true)
                        openDisputeCount = try? appState.currentDatabase?.openDisputeCount()
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
                    categoryFilterPill(.gap, label: "Gaps", count: auditVM.categoryCount(.gap))
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
            .onAppear {
                openDisputeCount = try? appState.currentDatabase?.openDisputeCount()
            }

            Divider()

            // CONFLICT_LAYER_SPEC CL2 AC6 — open-disputes list: severity
            // desc, rows deep-link to the owning profile's resolution UI.
            if showDisputeList && !openDisputeRows.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(openDisputeRows.sorted {
                            ($0.severity ?? .none).rawValue > ($1.severity ?? .none).rawValue
                        }) { row in
                            Button {
                                appState.selectedProfileID = row.entityID
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(appState.snapshot.profiles[row.entityID]?.displayName ?? row.entityID)
                                            .font(AppTypography.cardTitle)
                                        Text("\(row.kind.rawValue) · \(row.field)\(row.severity.map { " · \($0.rawValue)" } ?? "")")
                                            .font(AppTypography.cardMeta)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 260)
                Divider()
            }

            // Results
            if auditVM.isRunning {
                ProgressView("Running audit...")
                    .frame(maxHeight: .infinity)
            } else if let summary = auditVM.summary {
                if auditVM.filteredResults.isEmpty {
                    ContentUnavailableView {
                        Label("No Issues", systemImage: "checkmark.circle")
                    } description: {
                        Text("Checked \(summary.profilesChecked) profiles.")
                    }
                } else {
                    ruleFilterChips
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(displayRows) { row in
                                switch row {
                                case .duplicateCluster(let cluster):
                                    duplicateClusterRow(cluster)
                                case .censusBackfill(let proposal):
                                    censusBackfillRow(proposal)
                                case .deathAgeBackfill(let proposal):
                                    deathAgeBackfillRow(proposal)
                                case .finding(let result):
                                    findingRow(result)
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
        .sheet(item: $comparePair) { pair in
            CompareProfilesView(leftProfileID: pair.leftID, rightProfileID: pair.rightID)
        }
        .onAppear {
            // Always show the latest maintained summary. AppState keeps
            // `auditSummary` current after every mutation (import, edit, cleanse,
            // snooze), so this is free — no per-open recompute needed to be up to
            // date, which is why there's no manual "Re-run Audit" button.
            if let auto = appState.auditSummary { auditVM.summary = auto }
            backfillProposals = appState.censusBackfillProposals()
            deathAgeProposals = appState.deathAgeBackfillProposals()
        }
    }

    /// Promote an audit issue to an OpenQuestion. The question text mirrors
    /// the audit message; provenance is recorded via QuestionOrigin.fromAudit
    /// so the workbench can surface where the question came from. Maps audit
    /// severity to question priority (error → high, warning → medium, info → low).
    /// Findings after applying the per-rule chip filter (on top of the
    /// category/severity/search filters AuditViewModel already applies).
    private var shownResults: [AuditResult] {
        guard let rule = ruleFilter else { return auditVM.filteredResults }
        return auditVM.filteredResults.filter { $0.ruleID == rule }
    }

    // MARK: - Duplicate grouping

    enum HealthRow: Identifiable {
        case finding(AuditResult)
        case duplicateCluster(DuplicateCluster)
        case censusBackfill(CensusBackfill.Proposal)
        case deathAgeBackfill(DeathAgeBackfillProposal)
        var id: String {
            switch self {
            case .finding(let r): return "f:\(r.id)"
            case .duplicateCluster(let c): return "d:\(c.id)"
            case .censusBackfill(let p): return "b:\(p.id)"
            case .deathAgeBackfill(let p): return "da:\(p.id)"
            }
        }
    }

    struct DuplicateCluster: Identifiable {
        let id: String
        let names: [String]
        let profileIDs: [String]
        let pairs: [(String, String)]
    }

    /// Display rows: non-duplicate findings as-is, plus ONE grouped row per
    /// identity cluster of duplicate-pair findings (union-find over the pairs),
    /// so a person appearing in several pairwise rows collapses to a single
    /// entry (owner request 2026-07-25).
    private var displayRows: [HealthRow] {
        // The synthetic census-backfill chip shows only those rows.
        if ruleFilter == censusBackfillFilterID {
            return backfillProposals.map { HealthRow.censusBackfill($0) }
        }
        if ruleFilter == deathAgeBackfillFilterID {
            return deathAgeProposals.map { HealthRow.deathAgeBackfill($0) }
        }
        let results = shownResults
        let dupes = results.filter { $0.ruleID == "duplicateDetection" }
        let others = results.filter { $0.ruleID != "duplicateDetection" }
        var rows: [HealthRow] = []
        // Backfill proposals surface at the top of the unfiltered view.
        if ruleFilter == nil {
            rows += backfillProposals.map { HealthRow.censusBackfill($0) }
            rows += deathAgeProposals.map { HealthRow.deathAgeBackfill($0) }
        }
        rows += duplicateClusters(from: dupes).map { HealthRow.duplicateCluster($0) }
        rows += others.map { HealthRow.finding($0) }
        return rows
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
            return DuplicateCluster(id: rootID, names: names,
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
    private func findingRow(_ result: AuditResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.severity.iconName)
                .foregroundStyle(result.severity.color)
                .font(.body)
                .frame(width: 24)
                .accessibilityLabel("Severity \(result.severity.rawValue)")
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
        }
        if result.ruleID == "censusRelationship", result.severity == .info {
            censusReconciliationDetail(for: result)
        }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
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
    @ViewBuilder private var ruleFilterChips: some View {
        let counts = Dictionary(grouping: auditVM.filteredResults, by: { $0.ruleID })
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
        if counts.count > 1 || !backfillProposals.isEmpty || !deathAgeProposals.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ruleChip(label: "All (\(auditVM.filteredResults.count))", selected: ruleFilter == nil) {
                        ruleFilter = nil
                    }
                    ForEach(counts, id: \.key) { rule, count in
                        ruleChip(label: "\(prettyRule(rule)) (\(count))", selected: ruleFilter == rule) {
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
                }
                .padding(.horizontal)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private func ruleChip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(AppTypography.badge)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    /// "marriedSurnameFromSpouse" → "Married surname from spouse".
    private func prettyRule(_ id: String) -> String {
        var out = ""
        for ch in id {
            if ch.isUppercase && !out.isEmpty { out.append(" ") }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst().lowercased()
    }

    /// The one-click fix for a finding whose rule has one — married surname,
    /// census-derived birth year, placeholder-parent cleanup. Rules that need a
    /// human choice (which parent to unlink, etc.) have no button here and are
    /// fixed via Edit or in the profile.
    @ViewBuilder private func fixButton(for r: AuditResult) -> some View {
        switch r.ruleID {
        case "marriedSurnameFromSpouse":
            if let her = appState.snapshot.profiles[r.profileID],
               let s = MarriedSurnameFromSpouseRule.suggestion(for: her, in: appState.snapshot) {
                Button {
                    appState.setMarriedSurname(profileID: r.profileID, surname: s.marriedSurname)
                    refreshAudit()
                } label: {
                    Label("Set “\(s.marriedSurname)”", systemImage: "person.badge.plus")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Record \(s.marriedSurname) as her married surname so research finds her death and probate records")
            }
        case "censusAgeBirthYear":
            if let t = appState.snapshot.profiles[r.profileID],
               let s = CensusAgeBirthYearRule.suggestion(for: t, in: appState.snapshot) {
                Button {
                    appState.setBirthYearFromCensus(profileID: r.profileID, year: s.year, censusYear: s.censusYear, sourceID: s.sourceID)
                    refreshAudit()
                } label: {
                    Label("Set birth year ~\(String(s.year))", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
            }
        case "duplicateDetection":
            if let otherID = r.relatedProfileIDs?.first {
                Button {
                    comparePair = ComparePair(leftID: r.profileID, rightID: otherID)
                } label: {
                    Label("Compare", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Compare the two profiles side by side and merge only if they are truly the same person")
            }
        case "givenNameContainsMiddle":
            if let p = appState.snapshot.profiles[r.profileID],
               let split = p.impliedGivenMiddleSplit {
                Button {
                    appState.applyGivenMiddleSplit(profileID: r.profileID)
                    refreshAudit()
                } label: {
                    Label("Split to “\(split.first)” + “\(split.middle)”", systemImage: "textformat.abc")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Move the extra word out of the given name and into the middle name")
            }
        case "missingCoParent":
            if let coID = r.relatedProfileIDs?.first, let co = appState.snapshot.profiles[coID] {
                Button {
                    appState.addCoParent(childID: r.profileID, coParentID: coID)
                    refreshAudit()
                } label: {
                    Label("Add \(co.displayName)", systemImage: "person.badge.plus")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Link \(co.displayName) as the other parent — matching this child's siblings")
            }
        case "excessParentEdges" where r.relatedProfileIDs?.isEmpty == false:
            Button {
                appState.repairExcessPlaceholderParents(for: r.profileID)
                refreshAudit()
            } label: {
                Label("Remove placeholders", systemImage: "wand.and.stars")
            }
            .buttonStyle(.glassProminent).controlSize(.mini)
            .help("Absorb the blank placeholder parents into the real parents and re-home shared siblings")
        case "censusRelationship" where r.severity == .info:
            // Per-row Add lives in the detail panel below; the header only offers
            // a bulk "Add all" when there is more than one to take at once.
            let missingCount = appState.snapshot.profiles[r.profileID].map { subject in
                CensusRelationshipReconciler.findings(for: subject, in: appState.snapshot)
                    .filter { $0.kind == .missing }.count
            } ?? 0
            if missingCount > 1 {
                Button {
                    appState.addMissingCensusRelatives(for: r.profileID)
                    refreshAudit()
                } label: {
                    Label("Add all \(missingCount)", systemImage: "person.2.badge.plus")
                }
                .buttonStyle(.glassProminent).controlSize(.mini)
                .help("Create all \(missingCount) census relatives missing from the tree and link them, citing the census")
            }
        default:
            EmptyView()
        }
    }

    /// AppState's fix methods re-run the audit and refresh `auditSummary`;
    /// re-sync the view model so the fixed finding drops off the list.
    private func refreshAudit() {
        if let s = appState.auditSummary { auditVM.summary = s }
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

    /// Open-disputes status as a pill matching the severity counts, so the bar
    /// reads as one coherent set rather than a stray orange text link. Toggles
    /// the inline dispute list; ringed while the list is open.
    private func disputesPill(count: Int) -> some View {
        Button {
            showDisputeList.toggle()
            if showDisputeList {
                openDisputeRows = (try? appState.currentDatabase?.allOpenDisputes()) ?? []
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("\(count) dispute\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .overlay(
                Capsule().strokeBorder(showDisputeList ? Color.orange : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) open disputes")
        .accessibilityAddTraits(showDisputeList ? [.isSelected] : [])
        .help(showDisputeList ? "Hide the open-disputes list" : "Show the \(count) open disputes")
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
}

/// Gaps view — profiles missing key data, filterable by missing field.
struct GapsPlaceholderView: View {
    @Environment(AppState.self) private var appState
    @State private var filterCheck: CompletenessCheck?
    @State private var searchText = ""

    /// All distinct missing checks across all incomplete profiles, with counts.
    private var availableFilters: [(check: CompletenessCheck, count: Int)] {
        var counts: [String: (check: CompletenessCheck, count: Int)] = [:]
        for profile in appState.snapshot.profiles.values {
            let comp = appState.snapshot.completeness(for: profile.id)
            for check in comp.missing {
                let key = check.label
                if let existing = counts[key] {
                    counts[key] = (check: existing.check, count: existing.count + 1)
                } else {
                    counts[key] = (check: check, count: 1)
                }
            }
        }
        return counts.values.sorted { $0.count > $1.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Summary + filter bar
            if !appState.snapshot.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        gapSummary
                        Spacer()
                        TextField("Search...", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    // Field filter buttons
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            filterButton(label: "All", check: nil, count: totalIncomplete)

                            ForEach(availableFilters, id: \.check.label) { filter in
                                filterButton(
                                    label: filter.check.shortLabel.capitalized,
                                    check: filter.check,
                                    count: filter.count
                                )
                            }
                        }
                    }
                }
                .padding()
                Divider()
            }

            // List
            let gaps = filteredProfiles
            if gaps.isEmpty {
                ContentUnavailableView {
                    Label("No Gaps", systemImage: "checkmark.circle")
                } description: {
                    Text(appState.snapshot.profiles.isEmpty
                         ? "Import data to see gaps."
                         : filterCheck != nil
                            ? "No profiles missing this field."
                            : "All profiles are complete.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(gaps) { profile in
                            let comp = appState.snapshot.completeness(for: profile.id)
                            let ratio = comp.maximum > 0 ? Double(comp.score) / Double(comp.maximum) : 0
                            HStack(spacing: 10) {
                                // Severity indicator
                                Image(systemName: ratio > 0.5 ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ratio > 0.5 ? .orange : .red)
                                    .font(.body)
                                    .frame(width: 24)
                                    .accessibilityLabel(ratio > 0.5 ? "Partial completeness" : "Severely incomplete")

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(profile.displayName)
                                            .font(AppTypography.cardTitle)
                                        if let year = profile.birthDate?.bestYear {
                                            Text("b. \(String(year))")
                                                .font(AppTypography.cardMeta)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text("Missing: \(comp.missing.map(\.shortLabel).joined(separator: ", "))")
                                        .font(AppTypography.cardBody)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("\(comp.score)/\(comp.maximum)")
                                    .font(AppTypography.cardTitle)
                                    .foregroundStyle(comp.score == 0 ? .red : .orange)

                                Button("Research") {
                                    appState.researchProfileID = profile.id
                                }
                                .buttonStyle(.glass)
                                .controlSize(.mini)
                                // Per-profile promote: turn the missing-field
                                // checks into one OpenQuestion per gap with
                                // QuestionOrigin.fromGap. Menu shows one entry
                                // per missing check so the user can be selective.
                                Menu {
                                    ForEach(comp.missing, id: \.self) { check in
                                        Button("Promote \"\(check.shortLabel)\"") {
                                            promoteGap(profile: profile, check: check)
                                        }
                                    }
                                } label: {
                                    Label("Promote", systemImage: "questionmark.bubble")
                                }
                                .menuStyle(.borderlessButton)
                                .controlSize(.mini)
                                .help("Add a missing field as a workbench question")
                                .accessibilityHint("Add a missing field as a workbench question")
                            }
                            .padding(12)
                            .glassEffect(.regular, in: .rect(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Gaps (\(filteredProfiles.count) incomplete)")
    }

    // MARK: - Filter Button

    private func filterButton(label: String, check: CompletenessCheck?, count: Int) -> some View {
        let isActive = (filterCheck?.label == check?.label)
        return Button {
            if isActive {
                filterCheck = nil
            } else {
                filterCheck = check
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(AppTypography.cardMeta)
                    .fontWeight(isActive ? .bold : .regular)
                Text("\(count)")
                    .font(AppTypography.badge)
                    .foregroundStyle(isActive ? .primary : .tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func isActiveFilter(_ check: CompletenessCheck) -> Bool {
        filterCheck?.label == check.label
    }

    // MARK: - Data

    private var totalIncomplete: Int {
        appState.snapshot.profiles.values.filter {
            let c = appState.snapshot.completeness(for: $0.id)
            return c.score < c.maximum
        }.count
    }

    private var filteredProfiles: [Profile] {
        appState.snapshot.profiles.values
            .filter { profile in
                let comp = appState.snapshot.completeness(for: profile.id)
                guard comp.score < comp.maximum else { return false }
                if let filter = filterCheck {
                    guard comp.missing.contains(where: { $0.label == filter.label }) else { return false }
                }
                if !searchText.isEmpty {
                    guard profile.displayName.localizedCaseInsensitiveContains(searchText) else { return false }
                }
                return true
            }
            .sorted {
                appState.snapshot.completeness(for: $0.id).score <
                    appState.snapshot.completeness(for: $1.id).score
            }
    }

    /// Promote a missing-field gap to an OpenQuestion, recording the field
    /// in `QuestionOrigin.fromGap` so the workbench shows where it came from.
    private func promoteGap(profile: Profile, check: CompletenessCheck) {
        let text: String
        let origin: QuestionOrigin
        switch check {
        case .field(let field):
            text = "\(profile.displayName): missing \(field.rawValue)"
            origin = .fromGap(profileID: profile.id, field: field)
        case .hasParents:
            text = "\(profile.displayName): missing parents"
            // hasParents isn't a ProfileField — reuse fromGap with a
            // sentinel field. firstName is the closest "identity" field.
            origin = .fromGap(profileID: profile.id, field: .firstName)
        }
        appState.createQuestion(
            text: text, profileIDs: [profile.id],
            priority: .medium, promotedFrom: origin
        )
        appState.successMessage = "Added to workbench questions."
    }

    private var gapSummary: some View {
        let total = appState.snapshot.profiles.count
        let incomplete = totalIncomplete
        let complete = total - incomplete
        return HStack(spacing: 8) {
            Text("\(complete)/\(total) complete")
                .font(AppTypography.cardBody)
                .fontWeight(.semibold)
                .foregroundStyle(incomplete == 0 ? .green : .secondary)
            if total > 0 {
                let pct = Int(Double(complete) / Double(total) * 100)
                Text("\(pct)%")
                    .font(AppTypography.cardMeta)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
            }
        }
    }

    private func completenessBar(_ comp: ProfileCompleteness) -> some View {
        let ratio = comp.maximum > 0 ? Double(comp.score) / Double(comp.maximum) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 4)
                    .fill(ratio >= 1.0 ? Color.green : (ratio > 0.5 ? .orange : .red))
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(height: 8)
    }
}
