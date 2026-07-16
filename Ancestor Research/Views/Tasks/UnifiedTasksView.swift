import SwiftUI

// MARK: - Unified Task Model
//
// Per DESIGN.md §7.13: a single sortable, filterable list that aggregates
// everything the user might want to act on next. Five input streams:
//   1. Audit issues (errors / warnings / info)
//   2. Gap items (profiles with missing fields)
//   3. Open questions (workbench questions)
//   4. Tentative facts — FieldSource with confidence == .tentative, plus
//      LifeEvent with confidence == .tentative
//   5. Active leads (status new / investigating / investigated) —
//      engine-discovered person-shaped gaps awaiting research or a
//      promote/dismiss decision.
//
// The data layer is pure/nonisolated so the aggregator is trivially testable
// without touching the view or the database.

/// One actionable item in the unified Tasks list. Heterogeneous by design —
/// the view branches on `category` for the trailing action button, but the
/// list rendering itself is uniform.
nonisolated enum UnifiedTask: Identifiable {
    case auditIssue(AuditResult)
    case gap(profileID: String, profileName: String, completeness: ProfileCompleteness)
    case openQuestion(OpenQuestion)
    case tentativeField(profileID: String, profileName: String, field: ProfileField, value: String, source: FieldSource)
    case tentativeLifeEvent(LifeEvent, profileName: String)
    case lead(Lead)

    var id: String {
        switch self {
        case .auditIssue(let r):
            return "audit:\(r.id.uuidString)"
        case .gap(let pid, _, _):
            return "gap:\(pid)"
        case .openQuestion(let q):
            return "question:\(q.id.uuidString)"
        case .tentativeField(let pid, _, let field, _, let source):
            // Source.addedAt distinguishes multiple tentative sources on the same field.
            return "tentative-field:\(pid):\(field.rawValue):\(source.addedAt.timeIntervalSince1970)"
        case .tentativeLifeEvent(let e, _):
            return "tentative-event:\(e.id.uuidString)"
        case .lead(let lead):
            return "lead:\(lead.id)"
        }
    }

    var category: TaskCategory {
        switch self {
        case .auditIssue: return .audit
        case .gap: return .gap
        case .openQuestion: return .question
        case .tentativeField, .tentativeLifeEvent: return .tentative
        case .lead: return .lead
        }
    }

    var profileName: String {
        switch self {
        case .auditIssue(let r): return r.profileName
        case .gap(_, let name, _): return name
        case .openQuestion(let q): return q.profileIDs.isEmpty ? "—" : "Question"
        case .tentativeField(_, let name, _, _, _): return name
        case .tentativeLifeEvent(_, let name): return name
        case .lead(let lead): return lead.name
        }
    }

    /// Profile ID this task is anchored to, when the row should be
    /// clickable to open that profile's Full Detail. Nil when the task
    /// has no single owning profile — `openQuestion` rows that aren't
    /// attached to anyone fall into this bucket and stay non-navigable.
    var targetProfileID: String? {
        switch self {
        case .auditIssue(let r): return r.profileID
        case .gap(let pid, _, _): return pid
        case .openQuestion(let q): return q.profileIDs.first
        case .tentativeField(let pid, _, _, _, _): return pid
        case .tentativeLifeEvent(let e, _): return e.profileID
        // Leads are pinned to the profile that generated them (the
        // profile whose research surfaced the candidate), not to the
        // lead's own non-existent profile.
        case .lead(let lead): return lead.profileID
        }
    }

    /// One-line summary of the task. View renders this as the secondary line.
    var summary: String {
        switch self {
        case .auditIssue(let r):
            // Strip the leading profile name to avoid duplication with the header.
            var msg = r.message
            if msg.hasPrefix(r.profileName) {
                msg = String(msg.dropFirst(r.profileName.count))
                if msg.hasPrefix(" — ") { msg = String(msg.dropFirst(3)) }
                else if msg.hasPrefix(" ") { msg = String(msg.dropFirst(1)) }
            }
            return msg.prefix(1).uppercased() + msg.dropFirst()
        case .gap(_, _, let comp):
            let labels = comp.missing.map { check -> String in
                switch check {
                case .field(let f): return f.rawValue
                case .hasParents: return "parents"
                }
            }
            return "Missing: \(labels.joined(separator: ", "))"
        case .openQuestion(let q):
            return q.text
        case .tentativeField(_, _, let field, let value, _):
            return "\(field.rawValue): \(value)"
        case .tentativeLifeEvent(let e, _):
            let parts = [e.type.displayName, e.description, e.location].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.joined(separator: " — ")
        case .lead(let lead):
            var bits: [String] = []
            if let rel = lead.relationship { bits.append(rel) }
            if let year = lead.birthYear { bits.append("b. ~\(year)") }
            bits.append(lead.evidence)
            return bits.joined(separator: " · ")
        }
    }

    /// SF Symbol for the leading icon. Tints come from the view (audit issues
    /// share the existing severity colour; everything else uses the accent).
    var systemImage: String {
        switch self {
        case .auditIssue(let r):
            switch r.severity {
            case .error: return "xmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        case .gap: return "rectangle.portrait.and.arrow.right"
        case .openQuestion: return "questionmark.bubble"
        case .tentativeField, .tentativeLifeEvent: return "wand.and.stars"
        case .lead(let lead):
            switch lead.status {
            case .new: return "sparkle"
            case .investigating: return "arrow.triangle.2.circlepath"
            case .investigated: return "checkmark.circle"
            case .promoted: return "person.badge.plus"
            case .dismissed: return "xmark.circle"
            }
        }
    }

    /// Sort key — lower comes first. Tier ordering:
    ///   0 audit error • 1 audit warning • 2 high-priority question •
    ///   3 gap with no name/birth • 4 investigated lead (decision needed) •
    ///   5 other gap • 6 new lead (research available) •
    ///   7 medium question • 8 tentative field • 9 tentative life event •
    ///   10 low question • 11 audit info • 12 investigating lead (in flight)
    var sortKey: Int {
        switch self {
        case .auditIssue(let r):
            switch r.severity {
            case .error: return 0
            case .warning: return 1
            case .info: return 11
            }
        case .openQuestion(let q):
            switch q.priority {
            case .high: return 2
            case .medium: return 7
            case .low: return 10
            }
        case .gap(_, _, let comp):
            // Gap with no name or no birth is high-signal — surface above
            // ordinary gaps.
            let critical = comp.missing.contains { check in
                switch check {
                case .field(.firstName), .field(.birthDate): return true
                default: return false
                }
            }
            return critical ? 3 : 5
        case .lead(let lead):
            switch lead.status {
            // Engine has finished researching this lead and is waiting on
            // the user's promote/dismiss call — highest-actionable lead state.
            case .investigated: return 4
            // Engine found a candidate; user can kick off research.
            case .new: return 6
            // Already in flight — visible but inert; sink to the bottom.
            case .investigating: return 12
            // .promoted / .dismissed never reach the aggregator; ranked
            // last defensively so a programming error doesn't crash sort.
            case .promoted, .dismissed: return Int.max
            }
        case .tentativeField: return 8
        case .tentativeLifeEvent: return 9
        }
    }
}

nonisolated enum TaskCategory: String, CaseIterable, Identifiable {
    case audit, gap, question, tentative, lead

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .audit: return "Audit"
        case .gap: return "Gaps"
        case .question: return "Questions"
        case .tentative: return "Tentative"
        case .lead: return "Leads"
        }
    }
}

extension TaskCategory {
    /// Tint colour used by the filter chips — matches the row icon
    /// colour each category uses in `TaskRow.iconColor` so the chip
    /// and the row read as the same family.
    @MainActor var chipColor: Color {
        switch self {
        case .audit: return .red          // Severity colour (errors dominate visually)
        case .gap: return .orange
        case .question: return .accentColor
        case .tentative: return .purple
        case .lead: return .blue          // Matches `.new` lead icon — most common lead state
        }
    }
}

// MARK: - Aggregator
//
// Pure function: takes the inputs, returns a sorted [UnifiedTask]. No
// side effects, no isolation — the tests bite directly on this.

nonisolated enum UnifiedTaskAggregator {
    static func aggregate(
        snapshot: FamilyGraphSnapshot,
        auditSummary: AuditSummary?,
        questions: [OpenQuestion],
        lifeEvents: [LifeEvent],
        leads: [Lead] = []
    ) -> [UnifiedTask] {
        var tasks: [UnifiedTask] = []

        // 1. Audit issues — flatten errors + warnings + info.
        if let summary = auditSummary {
            for r in summary.errors { tasks.append(.auditIssue(r)) }
            for r in summary.warnings { tasks.append(.auditIssue(r)) }
            for r in summary.info { tasks.append(.auditIssue(r)) }
        }

        // 2. Gaps — one task per profile with completeness < maximum.
        for profile in snapshot.profiles.values where !profile.isDeleted {
            let comp = snapshot.completeness(for: profile.id)
            if comp.score < comp.maximum {
                tasks.append(.gap(
                    profileID: profile.id,
                    profileName: profile.displayName.isEmpty ? profile.id : profile.displayName,
                    completeness: comp
                ))
            }
        }

        // 3. Open questions — only `.open` status. inProgress / blocked /
        // resolved are filtered out (resolved is the obvious one; the others
        // are intentionally hidden so the list stays actionable).
        for q in questions where q.status == .open {
            tasks.append(.openQuestion(q))
        }

        // 4. Tentative facts.
        // 4a. Tentative FieldSources on profiles. Multiple tentative sources
        // for the same field produce multiple tasks (the user wants to see
        // each one).
        for profile in snapshot.profiles.values where !profile.isDeleted {
            for (field, sources) in profile.sources {
                for source in sources where source.confidence == .tentative {
                    tasks.append(.tentativeField(
                        profileID: profile.id,
                        profileName: profile.displayName.isEmpty ? profile.id : profile.displayName,
                        field: field,
                        value: source.raw,
                        source: source
                    ))
                }
            }
        }

        // 4b. Tentative LifeEvents.
        for event in lifeEvents where event.confidence == .tentative {
            let name = snapshot.profiles[event.profileID]?.displayName ?? event.profileID
            tasks.append(.tentativeLifeEvent(event, profileName: name))
        }

        // 5. Active leads — engine-discovered candidates awaiting research
        // or a promote/dismiss decision. Promoted / dismissed leads are
        // terminal and not surfaced; `.new` and `.investigated` get
        // action buttons; `.investigating` shows in-flight state
        // without action.
        for lead in leads where lead.status == .new
            || lead.status == .investigating
            || lead.status == .investigated {
            tasks.append(.lead(lead))
        }

        // Sort by tier then by profile name for stable ordering.
        tasks.sort { lhs, rhs in
            if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
            return lhs.profileName < rhs.profileName
        }
        return tasks
    }
}

// MARK: - Grouping (M16.10)

/// Pure helpers behind the Tasks view's "group by profile" toggle. Kept as a
/// `nonisolated enum` namespace so tests can drive the grouping without
/// spinning up SwiftUI.
nonisolated enum UnifiedTaskGrouping {
    /// One bucket of tasks belonging to a single profile name. The view
    /// renders each as a `Section` with the name as the header.
    struct Group {
        let profileName: String
        let tasks: [UnifiedTask]
    }

    /// Bucket the given tasks by exact `profileName` match (no fuzzy / case
    /// folding — distinct strings stay distinct). Within each bucket, the
    /// caller-supplied order is preserved (so the existing tier sort survives).
    /// Sections are then sorted by the most-severe task in each, falling back
    /// to alphabetical name for tie-breaks.
    static func groupedByProfile(_ tasks: [UnifiedTask]) -> [Group] {
        // Preserve first-seen order so sort stability is independent of
        // dictionary iteration order.
        var buckets: [String: [UnifiedTask]] = [:]
        var order: [String] = []
        for task in tasks {
            let name = task.profileName
            if buckets[name] == nil {
                order.append(name)
            }
            buckets[name, default: []].append(task)
        }

        let groups = order.map { name in
            Group(profileName: name, tasks: buckets[name] ?? [])
        }

        // Sort by max severity within the group (lower sortKey == more
        // severe per the existing UnifiedTask scale), then by name for
        // determinism.
        return groups.sorted { lhs, rhs in
            let lMax = lhs.tasks.map(\.sortKey).min() ?? Int.max
            let rMax = rhs.tasks.map(\.sortKey).min() ?? Int.max
            if lMax != rMax { return lMax < rMax }
            return lhs.profileName < rhs.profileName
        }
    }
}

// MARK: - View

/// Unified Tasks screen — DESIGN.md §7.7.10. Replaces the standalone Audit
/// tab. Audit issues, gaps, questions, and tentative facts share one list
/// with category filters.
struct UnifiedTasksView: View {
    @Environment(AppState.self) private var appState
    @State private var auditVM = AuditViewModel()
    @State private var category: TaskCategory?
    /// Sub-filter within the Audit category: a specific audit rule ID (e.g.
    /// "excessParentEdges"). Only meaningful while `category == .audit`; cleared
    /// whenever the top-level category changes.
    @State private var auditRuleFilter: String?
    @State private var searchText = ""
    @State private var lifeEvents: [LifeEvent] = []
    @State private var leads: [Lead] = []
    @AppStorage("disabledAuditRuleIDs") private var disabledRuleIDsData: Data = Data()
    /// M16.10 — when on, the list collapses by profile name with a section
    /// header per person (sections sorted by max severity in the section).
    /// Persisted via AppStorage so the choice survives app launches.
    @AppStorage("tasksGroupByProfile") private var groupByProfile: Bool = false

    /// Callback fired when the user clicks Research on a lead row. Owned
    /// by ContentView so the closure stays alongside the rest of the
    /// research-progress sheet wiring.
    let onResearchLead: (Lead) -> Void

    /// Callback fired when the user clicks the label area of a task row
    /// (anywhere outside the trailing action buttons). Receives the
    /// task's `targetProfileID` so the caller can switch to the Tree
    /// tab and open that profile's Full Detail.
    let onOpenProfile: (String) -> Void

    /// The summary used for aggregation — VM result if the user has run the
    /// audit, else the auto-audit cached on AppState.
    private var effectiveSummary: AuditSummary? {
        auditVM.summary ?? appState.auditSummary
    }

    private var allTasks: [UnifiedTask] {
        UnifiedTaskAggregator.aggregate(
            snapshot: appState.snapshot,
            auditSummary: effectiveSummary,
            questions: appState.questions,
            lifeEvents: lifeEvents,
            leads: leads
        )
    }

    private var filteredTasks: [UnifiedTask] {
        var tasks = allTasks
        if let category {
            tasks = tasks.filter { $0.category == category }
        }
        if category == .audit, let ruleID = auditRuleFilter {
            tasks = tasks.filter {
                if case .auditIssue(let r) = $0 { return r.ruleID == ruleID }
                return false
            }
        }
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            tasks = tasks.filter {
                $0.profileName.lowercased().contains(needle) ||
                $0.summary.lowercased().contains(needle)
            }
        }
        return tasks
    }

    private func count(in category: TaskCategory) -> Int {
        allTasks.filter { $0.category == category }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .navigationTitle("Tasks")
        .onAppear {
            // Pull the auto-audit if we haven't run one ourselves yet.
            if auditVM.summary == nil, let auto = appState.auditSummary {
                auditVM.summary = auto
            }
            reloadLifeEvents()
            reloadLeads()
        }
    }

    // MARK: - Top toolbar

    /// Two-row toolbar. Row 1: actions (Re-run, group toggle, search).
    /// Row 2: coloured filter chips. Splitting the rows lets the chips
    /// breathe (six fit naturally) without competing with the search
    /// field for horizontal space.
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            actionRow
            chipRow
        }
        .padding()
    }

    private var actionRow: some View {
        HStack {
            Button {
                rerunAudit()
            } label: {
                Label("Re-run Audit", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glassProminent)
            .disabled(appState.snapshot.profiles.isEmpty)

            Spacer()

            // M16.10 — toggle between flat list and grouped-by-profile.
            Button {
                groupByProfile.toggle()
            } label: {
                Image(systemName: groupByProfile ? "list.bullet.indent" : "list.bullet")
                    .accessibilityHidden(true)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help(groupByProfile
                  ? "Group by profile (on) — click to switch to a flat list"
                  : "Group by profile (off) — click to bucket tasks under each person")
            .accessibilityLabel(groupByProfile ? "Switch to flat list" : "Group tasks by profile")
            .accessibilityHint(groupByProfile
                  ? "Group by profile is on. Activate to switch to a flat list."
                  : "Group by profile is off. Activate to bucket tasks under each person.")

            TextField("Search...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
    }

    /// Chip-style filter row. "All" lives at the left; each category
    /// chip carries its own colour and a count badge. Tapping a chip
    /// selects it as the sole filter; tapping "All" (or the selected
    /// chip again) clears the filter. Wraps naturally to a second line
    /// at narrow window widths via `FlowLayout`.
    private var chipRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                FilterChip(
                    label: "All",
                    count: allTasks.count,
                    tint: .accentColor,
                    isSelected: category == nil
                ) {
                    category = nil
                    auditRuleFilter = nil
                }
                ForEach(TaskCategory.allCases) { c in
                    FilterChip(
                        label: c.displayName,
                        count: count(in: c),
                        tint: c.chipColor,
                        isSelected: category == c
                    ) {
                        category = (category == c) ? nil : c
                        auditRuleFilter = nil
                    }
                }
            }

            // Second-level chips: when Audit is selected, break it down by rule
            // so common findings ("Excess or Placeholder Parents", "Missing
            // Parents", …) are one tap away. Ordered by frequency.
            if category == .audit, !auditRuleChips.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(auditRuleChips, id: \.id) { chip in
                        FilterChip(
                            label: chip.name,
                            count: chip.count,
                            tint: .red.opacity(0.75),
                            isSelected: auditRuleFilter == chip.id
                        ) {
                            auditRuleFilter = (auditRuleFilter == chip.id) ? nil : chip.id
                        }
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    /// Distinct audit rules present in the current results, with friendly names
    /// and counts — the data behind the Audit sub-chip row.
    private var auditRuleChips: [(id: String, name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for task in allTasks where task.category == .audit {
            if case .auditIssue(let r) = task { counts[r.ruleID, default: 0] += 1 }
        }
        let nameByID = Dictionary(
            AuditRules.builtIn.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        return counts
            .map { (id: $0.key, name: nameByID[$0.key] ?? $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if auditVM.isRunning {
            ProgressView("Running audit...").frame(maxHeight: .infinity)
        } else if filteredTasks.isEmpty {
            ContentUnavailableView {
                Label("Nothing to do", systemImage: "checkmark.circle")
            } description: {
                Text(appState.snapshot.profiles.isEmpty
                     ? "Import data to surface tasks."
                     : "No tasks match the current filters.")
            }
        } else if groupByProfile {
            // Sectioned by profile, sections sorted by max severity within.
            ScrollView {
                LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                    ForEach(UnifiedTaskGrouping.groupedByProfile(filteredTasks), id: \.profileName) { group in
                        Section {
                            ForEach(group.tasks) { task in
                                TaskRow(task: task, onResearchLead: onResearchLead, onLeadChanged: reloadLeads, onAuditChanged: rerunAudit, onOpenProfile: onOpenProfile)
                            }
                        } header: {
                            HStack {
                                Text(group.profileName)
                                    .font(AppTypography.cardTitle)
                                Text("\(group.tasks.count)")
                                    .font(AppTypography.badge)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(.rect(cornerRadius: 8))
                        }
                    }
                }
                .padding()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredTasks) { task in
                        TaskRow(task: task, onResearchLead: onResearchLead, onLeadChanged: reloadLeads, onAuditChanged: rerunAudit, onOpenProfile: onOpenProfile)
                    }
                }
                .padding()
            }
        }
    }

    /// Re-run the audit and reload derived rows. Used by the Re-run button and
    /// after any in-row action that mutates the graph (e.g. the placeholder
    /// repair), so the list reflects the new state instead of the stale summary
    /// the last run cached on the view model.
    private func rerunAudit() {
        let disabled = (try? JSONDecoder().decode(Set<String>.self, from: disabledRuleIDsData)) ?? []
        auditVM.runAudit(snapshot: appState.snapshot, disabledRuleIDs: disabled)
        reloadLifeEvents()
        reloadLeads()
    }

    private func reloadLifeEvents() {
        guard let db = appState.currentDatabase else {
            lifeEvents = []
            return
        }
        lifeEvents = (try? db.loadAllLifeEvents()) ?? []
    }

    private func reloadLeads() {
        guard let db = appState.currentDatabase else {
            leads = []
            return
        }
        leads = (try? db.loadLeads()) ?? []
    }
}

// MARK: - Row

/// One row in the Tasks list. Branches on `task.category` for the trailing
/// action button — promote to question for audit, per-field promote menu
/// for gaps, "Open" for questions, and a placeholder "Resolve" stub for
/// tentative facts (no-op for now).
private struct TaskRow: View {
    let task: UnifiedTask
    let onResearchLead: (Lead) -> Void
    /// Called after a lead is dismissed inline so the parent reloads the
    /// list and the row disappears.
    let onLeadChanged: () -> Void
    /// Called after an in-row action mutates the graph (e.g. the placeholder
    /// repair) so the parent re-runs the audit and the row refreshes.
    let onAuditChanged: () -> Void
    let onOpenProfile: (String) -> Void
    @Environment(AppState.self) private var appState

    /// M19 — pair of profiles for the comparison sheet, set when the user
    /// taps "Compare" on a duplicateDetection audit row.
    @State private var comparePair: ComparePair?

    private struct ComparePair: Identifiable {
        let id = UUID()
        let leftID: String
        let rightID: String
    }

    /// The profile whose parent links are being reviewed in the sheet.
    @State private var reviewParentsTarget: ReviewTarget?
    /// The profile for which the "Link spouse" sheet is open.
    @State private var linkSpouseTarget: ReviewTarget?

    private struct ReviewTarget: Identifiable {
        let id = UUID()
        let profileID: String
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Label area is a click target — opens the task's owning
            // profile in the Tree tab's Full Detail sheet. Trailing
            // action buttons (Promote, Snooze, Research, Dismiss) stay
            // independent — SwiftUI's nested-button handling routes the
            // tap to whichever Button is hit directly.
            Button(action: openProfile) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: task.systemImage)
                        .foregroundStyle(iconColor)
                        .font(.body)
                        .frame(width: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.profileName).font(AppTypography.cardTitle)
                        Text(displaySummary).font(AppTypography.cardBody).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(task.targetProfileID == nil)
            .help(task.targetProfileID == nil
                  ? "No profile to open"
                  : "Open this person's profile")

            Spacer()

            trailingAction
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .sheet(item: $comparePair) { pair in
            CompareProfilesView(
                leftProfileID: pair.leftID,
                rightProfileID: pair.rightID
            )
        }
        .sheet(item: $reviewParentsTarget) { target in
            ReviewParentsView(profileID: target.profileID, onChanged: onAuditChanged)
        }
        .sheet(item: $linkSpouseTarget) { target in
            AddRelationshipView(anchorID: target.profileID, initialKind: .spouse)
        }
    }

    private func openProfile() {
        guard let pid = task.targetProfileID else { return }
        onOpenProfile(pid)
    }

    /// Remove every spouse edge where the profile is its own spouse (the
    /// `selfSpouse` audit finding). Normally exactly one edge.
    private func removeSelfSpouse(_ profileID: String) {
        let selfEdges = appState.snapshot.relationships.filter {
            $0.type == .spouse && $0.from == profileID && $0.to == profileID
        }
        for edge in selfEdges { appState.removeRelationship(id: edge.id) }
    }

    private var iconColor: Color {
        switch task {
        case .auditIssue(let r): return r.severity.color
        case .gap: return .orange
        case .openQuestion: return .accentColor
        case .tentativeField, .tentativeLifeEvent: return .purple
        case .lead(let lead):
            switch lead.status {
            case .new: return .blue
            case .investigating: return .secondary
            case .investigated: return .orange
            case .promoted: return .green
            case .dismissed: return .secondary
            }
        }
    }

    /// Prefer the guidance-flavoured message when the project is in
    /// small-manual mode and the rule supplied one (M16.6).
    private var displaySummary: String {
        if case .auditIssue(let r) = task,
           appState.isSmallManualProject,
           let guidance = r.guidanceMessage {
            return guidance
        }
        return task.summary
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch task {
        case .auditIssue(let r):
            HStack(spacing: 6) {
                // Phase 1 — universal baseline: every audit row can jump to the
                // person's profile to fix the details (edit dates, add missing
                // fields, correct names). The row body opens it too, but an
                // explicit action makes the fix path discoverable.
                Button { openProfile() } label: {
                    Label("Open to fix", systemImage: "pencil")
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
                .disabled(task.targetProfileID == nil)
                .help("Open this person's profile to edit the details")
                .accessibilityHint("Open this person's profile to edit the details")

                // Duplicate-shaped findings get a Compare action that opens the
                // candidate side-by-side (Compare offers Merge). The candidate ID
                // rides on `relatedProfileIDs` populated by the rule.
                if r.ruleID == "duplicateDetection" || r.ruleID == "orphanStub",
                   let candidateID = r.relatedProfileIDs?.first,
                   appState.snapshot.profiles[candidateID] != nil,
                   appState.snapshot.profiles[r.profileID] != nil {
                    Button {
                        comparePair = ComparePair(leftID: r.profileID, rightID: candidateID)
                    } label: {
                        Label("Compare", systemImage: "rectangle.split.2x1")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .help("View both profiles side by side")
                    .accessibilityHint("View both profiles side by side")
                }

                // Excess/placeholder parents — one-click absorb of the blank
                // stub parents into the real ones, re-homing shared siblings.
                // Driven by the finding's own `relatedProfileIDs` (the junk stubs
                // the rule flagged) so the button and the rule's wording can
                // never disagree; the George-Wheeldon all-named case has no
                // related IDs, so it correctly shows no button.
                if r.ruleID == "excessParentEdges",
                   r.relatedProfileIDs?.isEmpty == false {
                    Button {
                        appState.repairExcessPlaceholderParents(for: r.profileID)
                        onAuditChanged()
                    } label: {
                        Label("Remove placeholders", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.mini)
                    .help("Absorb the blank placeholder parents into the real parents and re-home any siblings that shared them")
                    .accessibilityHint("Absorb the blank placeholder parents into the real parents and re-home shared siblings")
                } else if r.ruleID == "excessParentEdges" {
                    // All-named excess (no stubs to auto-strip) — a human picks
                    // which parent is wrong. Opens a sheet to unlink one.
                    Button {
                        reviewParentsTarget = ReviewTarget(profileID: r.profileID)
                    } label: {
                        Label("Review parents", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .help("Review this person's parent links and remove the incorrect or duplicate one")
                    .accessibilityHint("Review this person's parent links and remove the incorrect or duplicate one")
                }

                // Phase 2 — structural rules reuse the relationship-review path.
                // Two biological parents in the same role → review + unlink one.
                if r.ruleID == "parentsPerRole" {
                    Button {
                        reviewParentsTarget = ReviewTarget(profileID: r.profileID)
                    } label: {
                        Label("Review parents", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .help("Review this person's parent links and remove the duplicate")
                    .accessibilityHint("Review this person's parent links and remove the duplicate")
                }

                // Self-spouse → one-click removal of the erroneous self-link.
                if r.ruleID == "selfSpouse" {
                    Button {
                        removeSelfSpouse(r.profileID)
                        onAuditChanged()
                    } label: {
                        Label("Remove self-link", systemImage: "minus.circle")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.mini)
                    .help("Remove the erroneous link where this person is their own spouse")
                    .accessibilityHint("Remove the erroneous self-spouse link")
                }

                // Phase 5 — married surname without a linked spouse → open Add
                // Relationship pre-set to Spouse so research can pivot to the
                // married surname once the spouse is linked.
                if r.ruleID == "unlinkedSpouseForFemaleSubject" {
                    Button {
                        linkSpouseTarget = ReviewTarget(profileID: r.profileID)
                    } label: {
                        Label("Link spouse", systemImage: "person.2.badge.plus")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.mini)
                    .help("Link this person's spouse so research can find records under the married surname")
                    .accessibilityHint("Link this person's spouse")
                }

                // Phase 3 — gap-category findings (missing parents, dates,
                // locations, end-of-line) get a direct pipeline kickoff.
                if r.category == .gap {
                    Button {
                        if let p = appState.snapshot.profiles[r.profileID] {
                            appState.researchConfigProfile = p
                        }
                    } label: {
                        Label("Research", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .help("Run the research pipeline to find the missing details")
                    .accessibilityHint("Run the research pipeline to find the missing details")
                }

                Button {
                    promoteAudit(r)
                } label: {
                    Label("Promote", systemImage: "questionmark.bubble")
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
                .help("Add as an open question on the workbench")
                .accessibilityHint("Add as an open question on the workbench")

                // M18 — per-profile snooze inline action. Defaults to
                // .profile(id:) since "snooze for this person" is the more
                // frequent use case; the global variant lives in Settings.
                Button {
                    snoozeAuditForProfile(r)
                } label: {
                    Label("Snooze 7d", systemImage: "moon.zzz")
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
                .help("Silence this rule for this person for 7 days")
                .accessibilityHint("Silence this rule for this person for 7 days")
            }

        case .gap(_, _, let comp):
            // One menu entry per missing check. Mirrors the existing
            // GapsPlaceholderView promote flow.
            if let profile = profileForGap {
                Menu {
                    ForEach(comp.missing, id: \.self) { check in
                        Button("Promote \"\(shortLabel(check))\"") {
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

        case .openQuestion:
            // V1: no in-place "Open" handler (would need a binding to the
            // sidebar's selectedTab). Leaving the row click for the workbench.
            EmptyView()

        case .tentativeField, .tentativeLifeEvent:
            // Resolve is a no-op placeholder for v1. The user upgrades the
            // confidence via the profile editor (M12 Q-track).
            EmptyView()

        case .lead(let lead):
            // `.new` and `.investigated` get Research + Dismiss;
            // `.investigating` shows a spinner and no buttons.
            switch lead.status {
            case .new, .investigated:
                HStack(spacing: 6) {
                    Button {
                        onResearchLead(lead)
                    } label: {
                        Label("Research", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.mini)
                    .help("Run the research pipeline against this lead")

                    Button {
                        dismissLead(lead)
                    } label: {
                        Label("Dismiss", systemImage: "xmark")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .controlSize(.mini)
                    .help("Dismiss this lead — not relevant")
                }
            case .investigating:
                ProgressView()
                    .controlSize(.small)
            case .promoted, .dismissed:
                // Never reach the aggregator, but render nothing if they do.
                EmptyView()
            }
        }
    }

    /// Constructs a dismissed copy of the lead and persists it via the
    /// project database (no `LeadStore` actor hop — direct save matches
    /// the existing in-app write pattern for this surface).
    private func dismissLead(_ lead: Lead) {
        guard let db = appState.currentDatabase else { return }
        let dismissed = Lead(
            id: lead.id, profileID: lead.profileID,
            name: lead.name, surname: lead.surname, givenName: lead.givenName,
            birthYear: lead.birthYear, deathYear: lead.deathYear,
            relationship: lead.relationship, source: lead.source,
            status: .dismissed, evidence: lead.evidence,
            createdAt: lead.createdAt,
            investigatedAt: lead.investigatedAt,
            resolvedAt: Date(), resolution: .dismissed
        )
        // upsertLead, not saveLead — saveLead is INSERT OR IGNORE and the
        // dismissal silently no-ops for existing rows (CAMPAIGN_REVIEW_SPEC
        // Change 1): the lead reappeared as .new on the next reload.
        try? db.upsertLead(dismissed)
        onLeadChanged()
    }

    private var profileForGap: Profile? {
        guard case .gap(let pid, _, _) = task else { return nil }
        return appState.snapshot.profiles[pid]
    }

    private func shortLabel(_ check: CompletenessCheck) -> String {
        switch check {
        case .field(let f):
            switch f {
            case .firstName: return "name"
            case .middleName: return "middle"
            case .lastName: return "surname"
            case .marriedSurname: return "married"
            case .nickName: return "nickname"
            case .mothersMaidenName: return "mother's maiden"
            case .gender: return "gender"
            case .birthDate: return "birth"
            case .birthLocation: return "b.loc"
            case .deathDate: return "death"
            case .deathLocation: return "d.loc"
            case .bio: return "bio"
            case .nameForms: return "variants"
            }
        case .hasParents: return "parents"
        }
    }

    /// Mirrors AuditPlaceholderView.promoteToQuestion — keep them in lockstep.
    private func promoteAudit(_ result: AuditResult) {
        let priority: QuestionPriority = switch result.severity {
        case .error: .high
        case .warning: .medium
        case .info: .low
        }
        var msg = result.message
        if msg.hasPrefix(result.profileName) {
            msg = String(msg.dropFirst(result.profileName.count))
            if msg.hasPrefix(" — ") { msg = String(msg.dropFirst(3)) }
            else if msg.hasPrefix(" ") { msg = String(msg.dropFirst(1)) }
        }
        let stripped = msg.prefix(1).uppercased() + msg.dropFirst()
        let text = "\(result.profileName): \(stripped)"
        appState.createQuestion(
            text: text,
            profileIDs: [result.profileID],
            priority: priority,
            promotedFrom: .fromAudit(ruleID: result.ruleID)
        )
        appState.successMessage = "Added to workbench questions."
    }

    /// M18 — silence this rule for this profile for 7 days. Calls into the
    /// AppState helper which persists the override and re-runs the audit, so
    /// the row drops out of the Tasks list on the next aggregator pass.
    private func snoozeAuditForProfile(_ result: AuditResult) {
        appState.snoozeAuditRule(
            ruleID: result.ruleID,
            scope: .profile(id: result.profileID),
            days: 7
        )
        appState.successMessage = "Snoozed for 7 days."
    }

    /// Mirrors GapsPlaceholderView.promoteGap — keep them in lockstep.
    private func promoteGap(profile: Profile, check: CompletenessCheck) {
        let text: String
        let origin: QuestionOrigin
        switch check {
        case .field(let field):
            text = "\(profile.displayName): missing \(field.rawValue)"
            origin = .fromGap(profileID: profile.id, field: field)
        case .hasParents:
            text = "\(profile.displayName): missing parents"
            origin = .fromGap(profileID: profile.id, field: .firstName)
        }
        appState.createQuestion(
            text: text,
            profileIDs: [profile.id],
            priority: .medium,
            promotedFrom: origin
        )
        appState.successMessage = "Added to workbench questions."
    }
}

// MARK: - Review parents sheet

/// Lists a profile's parent links so the user can unlink an incorrect or
/// duplicate one — the manual counterpart to the placeholder auto-repair, for
/// the all-named excess-parents case (e.g. George Wheeldon's three named
/// parents, a probable bad merge). Reads the snapshot live, so removing an edge
/// updates the list in place; `onChanged` re-runs the audit behind the sheet.
private struct ReviewParentsView: View {
    let profileID: String
    let onChanged: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var parentEdges: [(edgeID: UUID, parent: Profile?, role: ParentRole?)] {
        appState.snapshot.relationships
            .filter { $0.type == .parent && $0.to == profileID }
            .map { (edgeID: $0.id, parent: appState.snapshot.profiles[$0.from], role: $0.role) }
    }

    private var subjectName: String {
        appState.snapshot.profiles[profileID]?.displayName ?? "this person"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Review parents").font(.title2).fontWeight(.semibold)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Close")
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(subjectName) has \(parentEdges.count) parents recorded — a person has at most two. Remove the incorrect or duplicate ones. This unlinks the parent from \(subjectName); it does not delete the parent's profile.")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(parentEdges, id: \.edgeID) { edge in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(parentLabel(edge.parent))
                                    .font(AppTypography.cardTitle)
                                let meta = [roleLabel(edge.role), birthLabel(edge.parent)]
                                    .compactMap { $0 }
                                if !meta.isEmpty {
                                    Text(meta.joined(separator: " · "))
                                        .font(AppTypography.cardMeta)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                appState.removeRelationship(id: edge.edgeID)
                                onChanged()
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .help("Unlink this parent from \(subjectName)")
                        }
                        .padding(12)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 440, minHeight: 360)
    }

    private func parentLabel(_ p: Profile?) -> String {
        guard let p else { return "(missing profile)" }
        let name = p.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "(blank placeholder)" : name
    }

    private func roleLabel(_ r: ParentRole?) -> String? {
        switch r {
        case .father: return "Father"
        case .mother: return "Mother"
        default: return nil
        }
    }

    private func birthLabel(_ p: Profile?) -> String? {
        guard let original = p?.birthDate?.original, !original.isEmpty else { return nil }
        return "b. \(original)"
    }
}

// MARK: - Filter chip

/// Coloured chip used for the Tasks category filter row. Selected state
/// flips the capsule fill to the tint colour; unselected state shows a
/// subtle outline so the chips still read as a row of toggles.
private struct FilterChip: View {
    let label: String
    let count: Int
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(AppTypography.controlLabel.weight(.semibold))
                Text("\(count)")
                    .font(AppTypography.badge)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : tint.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isSelected ? tint : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.clear : tint.opacity(0.55), lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.white : tint)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(count) items")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - FlowLayout

/// File-scoped to avoid clashing with sibling `FlowLayout` types in
/// `FocusComposerView.swift` and `LinkAwareNoteText.swift` — each view
/// keeps its own minimal copy rather than introducing a shared layout
/// module before the abstraction has earned it.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let totalHeight = rows.reduce(CGFloat.zero) { acc, row in
            acc + row.height
        } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(widest, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.view.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct PlacedItem {
        let view: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        var items: [PlacedItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            let needsBreak = !rows[rows.count - 1].items.isEmpty
                && rows[rows.count - 1].width + spacing + size.width > maxWidth
            if needsBreak {
                rows.append(Row())
            }
            let idx = rows.count - 1
            if !rows[idx].items.isEmpty {
                rows[idx].width += spacing
            }
            rows[idx].items.append(PlacedItem(view: sub, size: size))
            rows[idx].width += size.width
            rows[idx].height = max(rows[idx].height, size.height)
        }
        return rows
    }
}
