import SwiftUI

// MARK: - Unified Task Model
//
// Per DESIGN.md §7.7.10: a single sortable, filterable list that aggregates
// everything the user might want to act on next. Four input streams:
//   1. Audit issues (errors / warnings / info)
//   2. Gap items (profiles with missing fields)
//   3. Open questions (workbench questions)
//   4. Tentative facts — FieldSource with confidence == .tentative, plus
//      LifeEvent with confidence == .tentative
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
        }
    }

    var category: TaskCategory {
        switch self {
        case .auditIssue: return .audit
        case .gap: return .gap
        case .openQuestion: return .question
        case .tentativeField, .tentativeLifeEvent: return .tentative
        }
    }

    var profileName: String {
        switch self {
        case .auditIssue(let r): return r.profileName
        case .gap(_, let name, _): return name
        case .openQuestion(let q): return q.profileIDs.isEmpty ? "—" : "Question"
        case .tentativeField(_, let name, _, _, _): return name
        case .tentativeLifeEvent(_, let name): return name
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
        }
    }

    /// Sort key — lower comes first. Tier ordering:
    ///   0 audit error • 1 audit warning • 2 high-priority question •
    ///   3 gap with no name/birth • 4 other gap • 5 medium question •
    ///   6 tentative field • 7 tentative life event • 8 low question •
    ///   9 audit info
    var sortKey: Int {
        switch self {
        case .auditIssue(let r):
            switch r.severity {
            case .error: return 0
            case .warning: return 1
            case .info: return 9
            }
        case .openQuestion(let q):
            switch q.priority {
            case .high: return 2
            case .medium: return 5
            case .low: return 8
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
            return critical ? 3 : 4
        case .tentativeField: return 6
        case .tentativeLifeEvent: return 7
        }
    }
}

nonisolated enum TaskCategory: String, CaseIterable, Identifiable {
    case audit, gap, question, tentative

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .audit: return "Audit"
        case .gap: return "Gaps"
        case .question: return "Questions"
        case .tentative: return "Tentative"
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
        lifeEvents: [LifeEvent]
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
    @State private var searchText = ""
    @State private var lifeEvents: [LifeEvent] = []
    @AppStorage("disabledAuditRuleIDs") private var disabledRuleIDsData: Data = Data()
    /// M16.10 — when on, the list collapses by profile name with a section
    /// header per person (sections sorted by max severity in the section).
    /// Persisted via AppStorage so the choice survives app launches.
    @AppStorage("tasksGroupByProfile") private var groupByProfile: Bool = false

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
            lifeEvents: lifeEvents
        )
    }

    private var filteredTasks: [UnifiedTask] {
        var tasks = allTasks
        if let category {
            tasks = tasks.filter { $0.category == category }
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
        }
    }

    // MARK: - Top toolbar

    private var toolbar: some View {
        HStack {
            Button {
                let disabled = (try? JSONDecoder().decode(Set<String>.self, from: disabledRuleIDsData)) ?? []
                auditVM.runAudit(snapshot: appState.snapshot, disabledRuleIDs: disabled)
                reloadLifeEvents()
            } label: {
                Label("Re-run Audit", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glassProminent)
            .disabled(appState.snapshot.profiles.isEmpty)

            Spacer()

            if let summary = effectiveSummary {
                HStack(spacing: 12) {
                    severityBadge(.error, count: summary.errors.count)
                    severityBadge(.warning, count: summary.warnings.count)
                    severityBadge(.info, count: summary.info.count)
                }
            }

            Picker("Category", selection: $category) {
                Text("All").tag(nil as TaskCategory?)
                ForEach(TaskCategory.allCases) { c in
                    HStack(spacing: 4) {
                        Text(c.displayName)
                        Text("(\(count(in: c)))").foregroundStyle(.secondary)
                    }
                    .tag(c as TaskCategory?)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)

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
                .frame(width: 150)
        }
        .padding()
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
                                TaskRow(task: task)
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
                        TaskRow(task: task)
                    }
                }
                .padding()
            }
        }
    }

    private func severityBadge(_ severity: Severity, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: severity.iconName)
                .foregroundStyle(severity.color)
                .accessibilityHidden(true)
            Text("\(count)").font(.caption).fontWeight(.semibold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(severity.rawValue) issues")
    }

    private func reloadLifeEvents() {
        guard let db = appState.currentDatabase else {
            lifeEvents = []
            return
        }
        lifeEvents = (try? db.loadAllLifeEvents()) ?? []
    }
}

// MARK: - Row

/// One row in the Tasks list. Branches on `task.category` for the trailing
/// action button — promote to question for audit, per-field promote menu
/// for gaps, "Open" for questions, and a placeholder "Resolve" stub for
/// tentative facts (no-op for now).
private struct TaskRow: View {
    let task: UnifiedTask
    @Environment(AppState.self) private var appState

    /// M19 — pair of profiles for the comparison sheet, set when the user
    /// taps "Compare" on a duplicateDetection audit row.
    @State private var comparePair: ComparePair?

    private struct ComparePair: Identifiable {
        let id = UUID()
        let leftID: String
        let rightID: String
    }

    var body: some View {
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
    }

    private var iconColor: Color {
        switch task {
        case .auditIssue(let r): return r.severity.color
        case .gap: return .orange
        case .openQuestion: return .accentColor
        case .tentativeField, .tentativeLifeEvent: return .purple
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
                // M19 — duplicateDetection rows get a Compare action that
                // opens the candidate side-by-side. The candidate ID rides
                // on `relatedProfileIDs` populated by the rule.
                if r.ruleID == "duplicateDetection",
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
        }
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
