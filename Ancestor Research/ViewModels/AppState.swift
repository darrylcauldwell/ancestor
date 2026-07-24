import SwiftUI
import os

/// Root application state — tracks current project and snapshot.
@MainActor @Observable
final class AppState {
    private let sweepLogger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "ConflictSweep")

    /// IMPORT_DEDUPE_SPEC — orphan-stub duplicates found by the last import,
    /// awaiting the user's one-click cleanse decision. nil = nothing to
    /// review (or already handled).
    var importCleanseReview: ImportCleanseReview?
    var currentProject: Project?
    var currentDatabase: ProjectDatabase?

    /// Polls `research_run_requests` for queued rows enqueued by the MCP
    /// `kick_off_research` tool. Created lazily on first project open;
    /// re-bound to each new database via `start()`. Stopped on close.
    private var runRequestWatcher: RunRequestWatcher?

    /// Source registry handed in by ContentView at startup so AppState can
    /// construct a `RunRequestWatcher` without circular dependencies on the
    /// SwiftUI environment. Hands-off after attachment; the registry is
    /// nonisolated (it owns no UI state) so it's safe to retain.
    private var attachedRegistry: SourceRegistry?

    /// One-time hookup called by ContentView on appear. Wires the source
    /// registry into AppState so subsequent `openProject` calls can spawn
    /// the run-request watcher. Idempotent: a second call replaces the
    /// stored registry but leaves any running watcher alone.
    func attachSearchRegistry(_ registry: SourceRegistry) {
        attachedRegistry = registry
        // If a project is already open by the time the registry arrives
        // (rare but possible on hot reload / multi-window), start the
        // watcher now so MCP requests don't hang waiting on the next
        // project switch.
        if currentDatabase != nil, runRequestWatcher == nil {
            startRunRequestWatcher()
        }
    }

    private func startRunRequestWatcher() {
        guard let registry = attachedRegistry else { return }
        if runRequestWatcher == nil {
            runRequestWatcher = RunRequestWatcher(appState: self, registry: registry)
        }
        runRequestWatcher?.start()
    }

    private func stopRunRequestWatcher() {
        runRequestWatcher?.stop()
        runRequestWatcher = nil
    }
    var snapshot: FamilyGraphSnapshot = .empty
    var auditSummary: AuditSummary?
    var availableProjects: [Project] = []
    /// Set to trigger research for a specific profile from the tree view.
    /// Uses whatever mode/scope is currently set on the Research view model.
    var researchProfileID: String?

    /// Richer profile-contextual research trigger. When set, the Research view
    /// applies the supplied mode + scope to its view model THEN starts research
    /// on the named profile — letting research be kicked off from a profile-
    /// detail sheet with mode/scope picked in context rather than over on the
    /// Research tab.
    var researchRequest: ResearchRequest?

    /// Set to a profile to display the research configuration sheet (mode/scope
    /// picker) from anywhere in the app — tree popover, profile detail, etc.
    /// ContentView observes and presents the sheet centrally so the sheet looks
    /// and behaves identically regardless of where research was triggered from.
    var researchConfigProfile: Profile?

    /// Optional pre-selected focus when the sheet is opened from a per-gap
    /// "Research parents / siblings / …" button. Cleared together with
    /// `researchConfigProfile` when the sheet dismisses. Nil for the
    /// generic whole-profile Research entry point. See
    /// RESEARCH_PIPELINE_SPEC §11.4.
    var researchConfigFocus: ResearchFocus?

    /// TRIAGE_UX_DATA_QUALITY_SPEC Change 3b — request to research a LEAD
    /// (a candidate not yet on the tree). Sibling of `researchRequest`: set by
    /// the Triage "Research" action on a lead, observed centrally by
    /// ContentView which drives `ResearchViewModel.startResearch(lead:)` and
    /// surfaces the same progress → review flow as profile research. No config
    /// sheet — lead research uses discover-mode defaults.
    var researchLeadRequest: Lead?

    /// On-demand FamilySearch hint enrichment for one profile (S6b). Set to a
    /// profile id by the tree context menu / profile card; drained in
    /// `ContentView`, which calls `fetchFamilySearchHints(profileID:)`. Sibling
    /// pattern to `researchLeadRequest`.
    var requestFetchFSHints: String?

    /// On-demand FamilySearch enrichment for one profile (S6b): fetch record
    /// hints for the person via the shared FamilySearch tree, route them through
    /// the SAME deterministic scorer + firewall as records search (deduped on
    /// the persona id via the `"<profileID>|<id>"` evidence key), and land the
    /// survivors as leads in Triage. The FS match confidence rides in
    /// `rawFields["fsMatchScore"]` as a §18 ordering signal only — it never
    /// enters a gate. Best-effort; empty when the person isn't in FS's tree.
    func fetchFamilySearchHints(profileID: String) async {
        guard let db = currentDatabase, let registry = attachedRegistry else {
            errorMessage = "Open a project first."
            return
        }
        guard await FamilySearchTokenStore.shared.validAccessToken(environment: .beta) != nil else {
            errorMessage = "Sign in to FamilySearch first (Settings ▸ FamilySearch)."
            return
        }
        do {
            guard let profile = try db.loadProfile(id: profileID) else {
                errorMessage = "Profile not found."
                return
            }
            let snapshot = try db.buildSnapshot()
            let homeChapmanCode = (try? db.loadProjectMeta())?.resolvedHomeChapmanCode ?? ""
            let subject = ResearchSubject.fromProfile(profile, snapshot: snapshot, homeChapmanCode: homeChapmanCode)
            guard let surname = subject.surname, !surname.isEmpty else {
                errorMessage = "This profile has no surname to search FamilySearch with."
                return
            }
            let records = await FamilySearchEnrichmentService(environment: .beta)
                .recordHintsAsSourceRecords(
                    surname: surname, givenName: subject.givenName,
                    birthYear: subject.birthYearFrom, deathYear: subject.deathYearFrom)
            guard !records.isEmpty else {
                successMessage = "No FamilySearch hints for this profile — they may not be in FamilySearch's shared tree."
                return
            }
            let result = FamilySearchHintRouting.route(records: records, subject: subject)
            _ = await ResearchRunService.persist(
                result: result, mode: .extend,
                sourceInfoMap: registry.buildSourceInfoMap(), registry: registry,
                snapshot: snapshot, profileID: profileID, leadToFinalise: nil, db: db)
            let leadCount = result.leads.count
            successMessage = "\(records.count) FamilySearch hint\(records.count == 1 ? "" : "s") reviewed — \(leadCount) new lead\(leadCount == 1 ? "" : "s") in Triage."
            requestSidebarTab = .triage
        } catch {
            errorMessage = "FamilySearch enrichment failed: \(error.localizedDescription)"
        }
    }

    /// Cross-view request: open this profile's Full Detail sheet on the
    /// Tree tab. Set by surfaces that aren't the tree itself — today
    /// the Tasks list's row click. `TreeGraphView` observes via
    /// `.onChange` (and on appear, in case it wasn't visible when the
    /// request was raised), opens the inspector, and clears the
    /// request. Sibling pattern to `researchConfigProfile` /
    /// `researchProfileID` already on this state object.
    var requestOpenProfileDetail: String?

    /// Cross-view request: switch the sidebar to this tab. Set by deep
    /// surfaces that can't reach ContentView's local selection state —
    /// today the profile panel's pending-facts badge (tap → Triage).
    /// ContentView observes via `.onChange` and clears the request.
    /// Sibling pattern to `requestOpenProfileDetail`.
    var requestSidebarTab: SidebarTab?

    /// PROFILE_SOURCES_LEDGER_SPEC Change 5 — a muddle/conflict audit finding
    /// raising "Review records": open the flagged profile's Full Detail with
    /// the Sources & Records ledger expanded and scrolled into view, so the
    /// flag and its remedy (remove the offending record) are one click apart.
    /// Set alongside `requestOpenProfileDetail`; `ProfileDetailView` consumes
    /// it for its own profile and clears it.
    var requestLedgerReviewProfileID: String?

    /// Cross-view request: open the pending-facts review screen for this
    /// profile on the Triage tab. Set together with `requestSidebarTab`
    /// by the profile panel's pending badge so the user lands on the
    /// profile's review cards — not Triage's default profile selector
    /// (whose prominent "Research All" button is a hazardous
    /// mis-click when the user expected review). `ResearchView`
    /// consumes via `.onChange` + `.onAppear` and clears the request.
    var requestPendingReviewProfileID: String?

    /// Cross-view request: open the Triage → Possible People panel scoped to
    /// this profile — set by a profile's "Possible People (N)" section so the
    /// user lands on that person's surfaced candidate clusters. Set together
    /// with `requestSidebarTab = .triage`; `ResearchView` consumes it, flips
    /// the Triage segment to Possible People, and scopes the panel
    /// (POSSIBLE_PEOPLE_CONTEXT_SPEC).
    var requestPossiblePeopleProfileID: String?

    /// PROFILE_LIFECYCLE_SPEC Change 1 — one canonical profile-action set,
    /// surfaced identically in the tree right-click menu AND the profile card.
    /// The card-owned sheet actions (Edit / Timeline / Relationship / Cleanse)
    /// are reached from the context menu by raising this intent (paired with
    /// `requestOpenProfileDetail` so the card is showing); `ProfileDetailView`
    /// observes it for its own profile and performs the sheet, then clears it.
    var pendingCardAction: PendingCardAction?

    /// Sibling intent for the reverse direction — the profile card raising
    /// "Compare with…", which only the tree can present (its picker + canvas).
    /// `TreeGraphView` observes and opens the compare picker for this id.
    var requestCompareProfileID: String?

    /// RETIRE_POPOVER_SPEC Change 1 — Full Detail raising add-relative /
    /// connect-to-existing. The tree owns the add sheets, so the card sets these
    /// intents and `TreeGraphView` observes and presents, mirroring
    /// `requestCompareProfileID`.
    struct AddRelativeRequest: Equatable {
        let profileID: String
        let relation: AutoSuggestService.RelationContext
    }
    var requestAddRelative: AddRelativeRequest?
    var requestConnectExisting: String?

    /// RETIRE_POPOVER_SPEC Change 2 — Full Detail raising branch removal.
    /// The tree owns the staged confirmation dialog (`BranchSelector` +
    /// PendingBranchDelete), so the card raises this and `TreeGraphView`
    /// observes and stages it.
    struct RemoveBranchRequest: Equatable {
        let profileID: String
        let ancestors: Bool
    }
    var requestRemoveBranch: RemoveBranchRequest?

    var isLoading = false
    var loadingMessage: String?
    var errorMessage: String?
    var successMessage: String?

    /// Driven by NewProjectView when the user picks "Start From Scratch", and by
    /// the empty-state placeholder. ContentView watches this to present the wizard sheet.
    var showOnboardingWizard: Bool = false
    /// Briefly populated after the wizard commits — drives the completion toast.
    var onboardingCompletionMessage: String?

    /// PROJECT_ONBOARDING_SPEC Part A — the project SETUP wizard (home region
    /// + local-AI), distinct from the manual family-entry wizard above (which
    /// owns `showOnboardingWizard`). Offered once per project at
    /// create/import/connect via `offerSetupIfNeeded()`; ContentView presents
    /// it as a sheet. Re-runnable from Settings for any project type.
    var showSetupWizard: Bool = false

    /// PROJECT_ONBOARDING_SPEC Part B — the re-openable "Getting Started"
    /// overview (how the pieces fit + what each view is for). Opened from the
    /// toolbar "?", from Settings, and offered at the end of setup. Presented
    /// as a sheet by ContentView, scrolled to the current tab.
    var showGettingStarted: Bool = false
    /// Set by the setup wizard's finish when the user leaves "show me a quick
    /// tour" on; consumed by the setup sheet's onDismiss so the overview opens
    /// AFTER the wizard closes (avoids a two-sheet-at-once transition).
    var pendingGettingStartedTour: Bool = false

    // MARK: - Pending person actions (M16.9 — global keyboard shortcuts)
    //
    // Routed via AppState so Cmd+N, Cmd+Shift+N, and Cmd+E fire from any
    // sidebar tab — not just the Tree. ContentView's keyboard layer publishes
    // an action by setting `pendingPersonAction`; TreeGraphView observes and
    // presents the matching sheet, then clears the action.
    var pendingPersonAction: PendingPersonAction?

    /// Selected profile id from the tree, mirrored on AppState so global
    /// shortcuts (Cmd+E in particular) can read it without reaching into the
    /// TreeViewModel's local state. TreeGraphView keeps it in sync.
    var selectedProfileID: String?

    /// Request the AddPerson sheet from anywhere in the app. Switches to the
    /// tree tab if the caller passes a `selectedTab` binding (ContentView's
    /// shortcut layer does); the sheet is presented by `TreeGraphView` once
    /// it observes the action.
    func requestAddPerson() {
        pendingPersonAction = .add
    }

    /// Request the AddFamily sheet (Cmd+Shift+N).
    func requestAddFamily() {
        pendingPersonAction = .addFamily
    }

    /// Request the EditPerson sheet for the currently-selected profile
    /// (Cmd+E). No-op when nothing is selected, so the shortcut is silent
    /// rather than showing an empty editor.
    func requestEditSelectedPerson() {
        guard let id = selectedProfileID else { return }
        pendingPersonAction = .editSelected(profileID: id)
    }

    /// Clear a pending action — called by TreeGraphView once the sheet has
    /// been presented (or handled). Single-shot semantics so re-pressing the
    /// shortcut re-triggers the sheet even when the value would otherwise be
    /// equal to the current one.
    func clearPendingPersonAction() {
        pendingPersonAction = nil
    }

    // MARK: - Workbench (M8)

    /// Cached workbench content. Refreshed via `loadWorkbench()` whenever a
    /// note or question is created/updated/deleted/resolved.
    var notes: [WorkbenchNote] = []
    var questions: [OpenQuestion] = []
    var focusSets: [FocusSet] = []
    var hypotheses: [Hypothesis] = []

    /// Currently active focus set. Defaults to the most-recently-touched on
    /// load. UI selects, tree filter consumes. Not persisted across app
    /// launches — the most-recent-active record handles that implicitly.
    var activeFocusSetID: UUID?

    /// Whether the Tree's "Focus only" filter is on.
    var focusFilterEnabled: Bool = false

    // MARK: - W4 Sessions

    /// Currently-active session — every mutation increments its counters
    /// and bumps `ended_at`. Sessions naturally "end" by being idle; we
    /// don't write an explicit close event.
    var currentSessionID: UUID?

    /// Set during `openProject` if a previous session is within the resume
    /// window (>30 min and <7 days old, with recorded activity). The
    /// SessionResumeView consumes this; clearing the value dismisses the sheet.
    var resumableSession: ResearchSession?

    /// Drives sidebar visibility — Workbench tab appears once the user has
    /// any workbench content. Mirrors §7.7's "Workbench appears on first
    /// note/question/hypothesis creation."
    var workbenchHasContent: Bool {
        !notes.isEmpty || !questions.isEmpty || !focusSets.isEmpty || !hypotheses.isEmpty
    }

    // MARK: - Progressive Disclosure (M14)

    /// Per DESIGN.md §7.16. Profile count threshold for the "Tasks" sidebar
    /// item to appear. Below this, manual-entry users see only Tree + Settings.
    static let tasksTabAppearsAtProfileCount: Int = 5

    /// `true` iff the current project's source is the Manual data source.
    /// `DataSource` carries associated values for `.gedcom` / `.wikitree`,
    /// so equality is expressed via pattern match.
    private var currentSourceIsManual: Bool {
        guard let source = currentProject?.source else { return false }
        if case .manual = source { return true }
        return false
    }

    /// Whether the Tasks sidebar item should be visible given the current
    /// project state. Always true for non-manual sources (imported trees
    /// can have audit/gap content immediately).
    var tasksTabVisible: Bool {
        if !currentSourceIsManual { return true }
        return snapshot.profiles.count >= Self.tasksTabAppearsAtProfileCount
    }

    /// Whether the project is in "small manual project" mode — used to
    /// activate guidance-flavoured language.
    var isSmallManualProject: Bool {
        currentSourceIsManual &&
            snapshot.profiles.count < Self.tasksTabAppearsAtProfileCount
    }

    // MARK: - Manual save indicator (M17.5)

    /// UserDefaults key for the one-time "Your progress is saved
    /// automatically." toast. Shown once across the lifetime of the app
    /// for any user who's just starting a small manual project — after
    /// they've performed enough actions to demonstrate the lack of a
    /// visible Save button is intentional.
    private static let manualSaveToastShownKey = "manualSaveToastShown"

    /// Has the manual-save toast already fired? Persisted across launches
    /// so the toast never reappears once dismissed.
    private var manualSaveToastShown: Bool {
        get { UserDefaults.standard.bool(forKey: Self.manualSaveToastShownKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.manualSaveToastShownKey) }
    }

    /// Reset the manual-save toast latch. Test-only escape hatch — production
    /// code never calls this.
    func resetManualSaveToastForTesting() {
        UserDefaults.standard.removeObject(forKey: Self.manualSaveToastShownKey)
    }

    /// Check the trigger and surface the toast on the existing successMessage
    /// channel. Called after every manual mutation that persists — addProfile,
    /// addFamily, editProfile. Cheap; does nothing once the toast has fired.
    private func maybeShowManualSaveToast() {
        guard let db = currentDatabase else { return }
        // Count is pulled from the transaction log — every manual mutation
        // creates exactly one transaction, so this is an honest "actions taken"
        // signal. We pull a small bounded slice to avoid scanning the whole
        // log for projects with thousands of imports.
        let txs = (try? db.loadTransactions(limit: 50)) ?? []
        let count = txs.count
        if SaveIndicatorTrigger.shouldShow(
            isSmallManualProject: isSmallManualProject,
            hasShown: manualSaveToastShown,
            transactionCount: count
        ) {
            successMessage = "Your progress is saved automatically."
            manualSaveToastShown = true
        }
    }

    /// Whether the Sourcing sidebar item should be visible. Hidden until
    /// the user has at least one citation entered — until then there's no
    /// integrity story to surface.
    var sourcingTabVisible: Bool {
        snapshot.profiles.values.contains { profile in
            profile.sources.values.contains { sources in
                sources.contains { $0.citation != nil }
            }
        }
    }

    /// Active hypotheses with `.relationship` claims — drives the tree's
    /// dashed-edge uncertainty layer.
    var activeRelationshipHypotheses: [Hypothesis] {
        hypotheses.filter { $0.status == .active }.filter {
            if case .relationship = $0.claim { return true }
            return false
        }
    }

    /// The active FocusSet, if any.
    var activeFocusSet: FocusSet? {
        guard let id = activeFocusSetID else { return nil }
        return focusSets.first { $0.id == id }
    }

    init() {
        refreshProjectList()
    }

    func refreshProjectList() {
        availableProjects = ProjectStore.listProjects(includingArchived: true)
    }

    /// Run audit automatically after any snapshot change.
    func runPostLoadAudit() {
        guard !snapshot.profiles.isEmpty else {
            auditSummary = nil
            return
        }
        let overrides = (try? currentDatabase?.loadAuditRuleOverrides()) ?? []
        auditSummary = AuditEngine.auditGrouped(
            snapshot,
            disabledRuleIDs: Self.disabledAuditRuleIDs(),
            isManualGuidanceMode: isSmallManualProject,
            overrides: overrides
        )
    }

    /// User-disabled audit rules (AuditRulesView writes the AppStorage-backed
    /// "disabledAuditRuleIDs" key). Read here so the maintained `auditSummary`
    /// honours disabled rules — Health now relies solely on this auto-audit, so
    /// the disabled-rule filter that used to live on the manual "Re-run Audit"
    /// button must be applied at the source.
    static func disabledAuditRuleIDs() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "disabledAuditRuleIDs") else { return [] }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }

    // MARK: - Audit rule overrides (M18)

    /// All audit-rule overrides for the current project.
    func loadAuditRuleOverrides() -> [AuditRuleOverride] {
        guard let db = currentDatabase else { return [] }
        return (try? db.loadAuditRuleOverrides()) ?? []
    }

    /// Persist a new or updated override. Triggers a re-audit so the UI
    /// reflects the change immediately.
    @discardableResult
    func upsertAuditRuleOverride(_ override: AuditRuleOverride) -> AuditRuleOverride? {
        guard let db = currentDatabase else { return nil }
        do {
            try db.upsertAuditRuleOverride(override)
            runPostLoadAudit()
            return override
        } catch {
            errorMessage = "Failed to save audit rule override: \(error.localizedDescription)"
            return nil
        }
    }

    func deleteAuditRuleOverride(id: UUID) {
        guard let db = currentDatabase else { return }
        do {
            try db.deleteAuditRuleOverride(id: id)
            runPostLoadAudit()
        } catch {
            errorMessage = "Failed to delete audit rule override: \(error.localizedDescription)"
        }
    }

    /// Convenience: snooze a rule (globally or for one profile) for N days.
    /// If an override already exists, updates its `snoozedUntil`. Else creates one.
    func snoozeAuditRule(ruleID: String, scope: AuditOverrideScope, days: Int = 7) {
        guard let db = currentDatabase else { return }
        let until = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date().addingTimeInterval(TimeInterval(days * 86400))
        let existing = try? db.loadAuditRuleOverride(ruleID: ruleID, scope: scope)
        var override = existing ?? AuditRuleOverride(
            id: UUID(), ruleID: ruleID, scope: scope,
            enabled: true, snoozedUntil: nil, thresholds: [:]
        )
        override.snoozedUntil = until
        upsertAuditRuleOverride(override)
    }

    /// Open the existing "Sample Family" project, or create-and-open it if
    /// none exists yet. Reviewer-friendly entry point: lets App Store reviewers
    /// (and first-time users) explore every feature without supplying their
    /// own GEDCOM or WikiTree credentials. The sample tree is a real
    /// persistent Manual project — Settings, Audit, Workbench, and the
    /// onboarding flow all behave identically to a normal project.
    func openSampleProject() {
        let sampleName = "Sample Family"

        // Reuse if it already exists.
        if let existing = availableProjects.first(where: { $0.name == sampleName }) {
            openProject(existing)
            return
        }

        isLoading = true
        loadingMessage = "Building sample tree..."
        errorMessage = nil

        do {
            let (project, db) = try ProjectStore.createProject(name: sampleName, source: .manual)
            currentProject = project
            currentDatabase = db

            // Populate via DemoDataGenerator — same fictional Ashford family used
            // by the screenshot tooling. "Open Sample Tree" creates a real project.
            let (demoProfiles, demoRelationships) = DemoDataGenerator.generate()
            try db.addFamily(
                profiles: Array(demoProfiles.values),
                relationships: demoRelationships,
                source: .manual
            )

            snapshot = try db.buildSnapshot()
            // CONFLICT_LAYER_SPEC CL2 (T-C trigger): one-shot v41 backfill,
            // then the standing sweep (high-water-skippable). Both are
            // idempotent; latent DS-15/DS-26-shaped damage in existing
            // trees becomes visible on first launch after the migration.
            runConflictSweep(backfillFirst: true)
            runPostLoadAudit()
            loadWorkbench()
            ensureSession()
            refreshProjectList()
        } catch {
            errorMessage = "Failed to load sample tree: \(error.localizedDescription)"
        }

        isLoading = false
        loadingMessage = nil
    }

    func openProject(_ project: Project) {
        isLoading = true
        loadingMessage = "Opening project..."
        errorMessage = nil

        // Corruption gate (M14). Don't auto-restore — surface the error
        // so the user can pick a backup explicitly in Settings → Backups.
        let sqlitePath = ProjectStore.projectsDirectory
            .appendingPathComponent("\(project.id.uuidString).sqlite").path
        if !BackupService.isReadable(sqlitePath: sqlitePath) {
            errorMessage = "Database appears to be corrupted. Restore from a backup in Settings → Backups."
            isLoading = false
            loadingMessage = nil
            return
        }

        do {
            let (proj, db) = try ProjectStore.openProject(project.id)
            currentProject = proj
            currentDatabase = db
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
            loadWorkbench()
            ensureSession()
            startRunRequestWatcher()

            // Best-effort backup snapshot (M14). Silent on failure so a
            // disk-full or permission glitch never blocks the user from
            // working with their project.
            try? BackupService.snapshotBackup(projectID: proj.id)
        } catch {
            errorMessage = "Failed to open project: \(error.localizedDescription)"
        }
        isLoading = false
        loadingMessage = nil
    }

    /// CONFLICT_LAYER_SPEC CL2 — run the standing conflict sweep.
    /// `force` bypasses the unchanged-project skip (manual scan,
    /// post-apply batches). Rebuilds the snapshot when disputes changed so
    /// the profile dispute sections and audit count refresh.
    func runConflictSweep(force: Bool = false, backfillFirst: Bool = false) {
        guard let db = currentDatabase else { return }
        do {
            var touched = 0
            if backfillFirst,
               let backfill = try ConflictSweep.backfillIfNeeded(db: db, snapshot: snapshot) {
                touched += backfill.disputesTouched
            }
            let report = try ConflictSweep.run(db: db, snapshot: snapshot, force: force)
            touched += report.disputesTouched
            if touched > 0 {
                snapshot = try db.buildSnapshot()
            }
        } catch {
            // Sweep failure must never block project work — surfaced as a
            // log line, not an error sheet. Detection-completeness is
            // restored on the next successful sweep (idempotent).
            sweepLogger.error("Conflict sweep failed: \(error.localizedDescription)")
        }
    }

    /// Restore a backup over the current project's SQLite file and re-open
    /// it. Called from Settings → Backups.
    func restoreBackup(_ backup: BackupInfo) {
        guard let project = currentProject else { return }
        do {
            // Close the live database first so GRDB releases the file
            // handle before we overwrite it.
            stopRunRequestWatcher()
            currentDatabase = nil
            try BackupService.restore(projectID: project.id, from: backup)
            openProject(project)
            successMessage = "Backup restored."
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Session lifecycle

    /// Called when opening a project. If the most-recent session is still
    /// within the idle threshold, continue using it. Otherwise: surface the
    /// resumable summary (if it has activity and is within 7 days) and start
    /// a fresh session. Per DESIGN.md §7.7.6.
    private func ensureSession() {
        guard let db = currentDatabase else { return }
        do {
            if let active = try db.loadActiveSession() {
                currentSessionID = active.id
                if let focusID = active.focusSetID {
                    activeFocusSetID = focusID
                }
                resumableSession = nil
                return
            }
            // No live session — capture a resumable one (if any) before
            // starting a fresh one, so the UI can surface "welcome back".
            resumableSession = try db.loadResumableSession()
            let new = try db.startSession(focusSetID: activeFocusSetID)
            currentSessionID = new.id
        } catch {
            errorMessage = "Failed to start session: \(error.localizedDescription)"
        }
    }

    /// Increment a counter on the current session. Cheap; ignored when no
    /// session is active (e.g. tests that don't go through openProject).
    private func recordSessionEvent(_ event: SessionEvent) {
        guard let db = currentDatabase, let id = currentSessionID else { return }
        try? db.recordSessionEvent(event, sessionID: id)
    }

    /// Continue the resumable session (used by SessionResumeView). Activates
    /// its focus set if any, switches focus filter on, and clears the
    /// resumable pointer so the sheet dismisses.
    func continueResumableSession() {
        guard let resumable = resumableSession else { return }
        if let focusID = resumable.focusSetID {
            activeFocusSetID = focusID
            focusFilterEnabled = true
        }
        resumableSession = nil
    }

    /// Dismiss the resume prompt without acting on it.
    func dismissResumableSession() {
        resumableSession = nil
    }

    // MARK: - Workbench loading

    /// Refresh the cached notes + questions + focus sets arrays. Cheap —
    /// the volume is small per project and we don't paginate.
    func loadWorkbench() {
        guard let db = currentDatabase else {
            notes = []
            questions = []
            focusSets = []
            hypotheses = []
            activeFocusSetID = nil
            return
        }
        notes = (try? db.loadNotes()) ?? []
        questions = (try? db.loadQuestions()) ?? []
        focusSets = (try? db.loadFocusSets()) ?? []
        hypotheses = (try? db.loadHypotheses()) ?? []
        // Default active set: most-recently-touched (already first in the array).
        // Preserve current selection if still present, else fall back.
        if let current = activeFocusSetID, focusSets.contains(where: { $0.id == current }) {
            // keep
        } else {
            activeFocusSetID = focusSets.first?.id
        }
    }

    // MARK: - Notes

    func createNote(
        content: String, tag: NoteTag, attachedTo: NoteAttachment,
        sensitive: Bool = false
    ) {
        guard let db = currentDatabase else { return }
        let note = WorkbenchNote(
            id: UUID(), content: content, tag: tag, attachedTo: attachedTo,
            createdAt: Date(), updatedAt: Date(), sensitive: sensitive
        )
        do {
            try db.addNote(note)
            recordSessionEvent(.noteCreated)
            loadWorkbench()
        } catch {
            errorMessage = "Failed to create note: \(error.localizedDescription)"
        }
    }

    func updateNote(_ note: WorkbenchNote) {
        guard let db = currentDatabase else { return }
        do {
            try db.updateNote(note)
            loadWorkbench()
        } catch {
            errorMessage = "Failed to update note: \(error.localizedDescription)"
        }
    }

    func deleteNote(id: UUID) {
        guard let db = currentDatabase else { return }
        do {
            try db.deleteNote(id: id)
            loadWorkbench()
        } catch {
            errorMessage = "Failed to delete note: \(error.localizedDescription)"
        }
    }

    /// Notes attached to a specific profile. Read-through to the DB so we
    /// don't filter the cached array (cheaper for small N anyway).
    func notesForProfile(_ profileID: String) -> [WorkbenchNote] {
        guard let db = currentDatabase else { return [] }
        return (try? db.loadNotes(attachedToKind: "profile", id: profileID)) ?? []
    }

    /// Notes attached to a specific hypothesis.
    func notesForHypothesis(_ id: UUID) -> [WorkbenchNote] {
        guard let db = currentDatabase else { return [] }
        return (try? db.loadNotes(attachedToKind: "hypothesis", id: id.uuidString)) ?? []
    }

    /// Notes attached to a specific question.
    func notesForQuestion(_ id: UUID) -> [WorkbenchNote] {
        guard let db = currentDatabase else { return [] }
        return (try? db.loadNotes(attachedToKind: "question", id: id.uuidString)) ?? []
    }

    // MARK: - Questions

    func createQuestion(
        text: String,
        profileIDs: [String] = [],
        priority: QuestionPriority = .medium,
        promotedFrom: QuestionOrigin? = nil
    ) {
        guard let db = currentDatabase else { return }
        let question = OpenQuestion(
            id: UUID(), text: text, profileIDs: profileIDs,
            priority: priority, status: .open,
            triedSources: nil, promotedFrom: promotedFrom,
            createdAt: Date(), resolvedAt: nil, resolution: nil
        )
        do {
            try db.addQuestion(question)
            recordSessionEvent(.questionCreated)
            loadWorkbench()
        } catch {
            errorMessage = "Failed to create question: \(error.localizedDescription)"
        }
    }

    func updateQuestion(_ question: OpenQuestion) {
        guard let db = currentDatabase else { return }
        do {
            try db.updateQuestion(question)
            loadWorkbench()
        } catch {
            errorMessage = "Failed to update question: \(error.localizedDescription)"
        }
    }

    func resolveQuestion(id: UUID, resolution: String?) {
        guard let db = currentDatabase else { return }
        do {
            try db.resolveQuestion(id: id, resolution: resolution)
            recordSessionEvent(.questionResolved)
            loadWorkbench()
        } catch {
            errorMessage = "Failed to resolve question: \(error.localizedDescription)"
        }
    }

    func deleteQuestion(id: UUID) {
        guard let db = currentDatabase else { return }
        do {
            try db.deleteQuestion(id: id)
            loadWorkbench()
        } catch {
            errorMessage = "Failed to delete question: \(error.localizedDescription)"
        }
    }

    // MARK: - Focus sets (W3)

    @discardableResult
    func createFocusSet(title: String?, profileIDs: [String] = []) -> FocusSet? {
        guard let db = currentDatabase else { return nil }
        let now = Date()
        let set = FocusSet(
            id: UUID(),
            title: title?.trimmingCharacters(in: .whitespaces).isEmpty == true ? nil : title,
            profileIDs: profileIDs,
            createdAt: now,
            lastActiveAt: now
        )
        do {
            try db.addFocusSet(set)
            loadWorkbench()
            // Newly-created focus set becomes active automatically.
            activeFocusSetID = set.id
            return set
        } catch {
            errorMessage = "Failed to create focus set: \(error.localizedDescription)"
            return nil
        }
    }

    func updateFocusSet(_ set: FocusSet) {
        guard let db = currentDatabase else { return }
        do {
            try db.updateFocusSet(set)
            loadWorkbench()
        } catch {
            errorMessage = "Failed to update focus set: \(error.localizedDescription)"
        }
    }

    func deleteFocusSet(id: UUID) {
        guard let db = currentDatabase else { return }
        do {
            try db.deleteFocusSet(id: id)
            if activeFocusSetID == id { activeFocusSetID = nil }
            loadWorkbench()
        } catch {
            errorMessage = "Failed to delete focus set: \(error.localizedDescription)"
        }
    }

    /// Mark a focus set active — bumps lastActiveAt, updates selection,
    /// and records the choice on the current session so resume can restore it.
    func setActiveFocusSet(id: UUID) {
        guard let db = currentDatabase else { return }
        do {
            try db.touchFocusSet(id: id)
            activeFocusSetID = id
            if let sid = currentSessionID {
                try? db.updateSessionFocus(sessionID: sid, focusSetID: id)
            }
            loadWorkbench()
        } catch {
            errorMessage = "Failed to set active focus: \(error.localizedDescription)"
        }
    }

    /// Add a profile to the active focus set. No-op if no active set.
    func addProfileToActiveFocus(_ profileID: String) {
        guard var set = activeFocusSet else { return }
        guard !set.profileIDs.contains(profileID) else { return }
        set.profileIDs.append(profileID)
        set.lastActiveAt = Date()
        updateFocusSet(set)
    }

    /// Remove a profile from the active focus set.
    func removeProfileFromActiveFocus(_ profileID: String) {
        guard var set = activeFocusSet else { return }
        set.profileIDs.removeAll { $0 == profileID }
        set.lastActiveAt = Date()
        updateFocusSet(set)
    }

    /// `true` iff the given profile is in the active focus set.
    func isInActiveFocus(_ profileID: String) -> Bool {
        activeFocusSet?.profileIDs.contains(profileID) ?? false
    }

    // MARK: - Hard delete (M14)

    /// Permanently remove a profile and all its associated data. Removes
    /// the on-disk attachment files for any attachments owned by this
    /// profile before clearing the DB rows. Irreversible.
    func hardDeleteProfile(id: String) {
        guard let db = currentDatabase, let projectID = currentProject?.id else { return }
        do {
            // Walk attachments first so we can clean their on-disk files.
            let attachments = (try? db.loadAttachmentsForProfile(id)) ?? []
            try db.hardDeleteProfile(id: id)
            for attachment in attachments {
                let fileURL = ProjectStore.absoluteURL(for: attachment, in: projectID)
                try? FileManager.default.removeItem(at: fileURL)
                let thumbURL = ProjectStore.thumbnailsDirectory(for: projectID)
                    .appendingPathComponent("\(attachment.id.uuidString).jpg")
                try? FileManager.default.removeItem(at: thumbURL)
            }
            // Reload snapshot so the now-removed profile disappears from the tree.
            snapshot = (try? db.buildSnapshot()) ?? snapshot
            successMessage = "Permanently removed."
        } catch {
            errorMessage = "Failed to remove profile: \(error.localizedDescription)"
        }
    }

    // MARK: - Attachments (M13)

    /// Attachments belonging to a profile + its life events + its field sources.
    func attachmentsForProfile(_ profileID: String) -> [Attachment] {
        guard let db = currentDatabase else { return [] }
        return (try? db.loadAttachmentsForProfile(profileID)) ?? []
    }

    /// Attachments matching a specific target (profile / lifeEvent / fieldSource).
    func attachments(for target: AttachmentTarget) -> [Attachment] {
        guard let db = currentDatabase else { return [] }
        return (try? db.loadAttachments(for: target)) ?? []
    }

    @discardableResult
    func addAttachment(_ attachment: Attachment) -> Attachment? {
        guard let db = currentDatabase else { return nil }
        do {
            try db.addAttachment(attachment)
            return attachment
        } catch {
            errorMessage = "Failed to add attachment: \(error.localizedDescription)"
            return nil
        }
    }

    func updateAttachment(_ attachment: Attachment) {
        guard let db = currentDatabase else { return }
        do {
            try db.updateAttachment(attachment)
        } catch {
            errorMessage = "Failed to update attachment: \(error.localizedDescription)"
        }
    }

    /// Delete an attachment from the DB and remove the underlying file
    /// (and its thumbnail) from disk.
    func deleteAttachment(id: UUID) {
        guard let db = currentDatabase, let projectID = currentProject?.id else { return }
        // Look it up first so we can remove the on-disk file too.
        let attachment = (try? db.loadAttachments())?.first { $0.id == id }
        do {
            try db.deleteAttachment(id: id)
            if let attachment {
                let url = ProjectStore.absoluteURL(for: attachment, in: projectID)
                try? FileManager.default.removeItem(at: url)
                let thumbURL = ProjectStore.thumbnailsDirectory(for: projectID)
                    .appendingPathComponent("\(id.uuidString).jpg")
                try? FileManager.default.removeItem(at: thumbURL)
            }
        } catch {
            errorMessage = "Failed to delete attachment: \(error.localizedDescription)"
        }
    }

    // MARK: - Research Goals (M13)

    /// All research goals for the current project. Sorted newest first by the DB.
    func loadGoals() -> [ResearchGoal] {
        guard let db = currentDatabase else { return [] }
        return (try? db.loadResearchGoals()) ?? []
    }

    @discardableResult
    func createGoal(
        title: String,
        description: String? = nil,
        focusSetID: UUID? = nil
    ) -> ResearchGoal? {
        guard let db = currentDatabase else { return nil }
        let goal = ResearchGoal(
            id: UUID(), title: title, description: description,
            status: .active, progress: 0,
            questionIDs: [], hypothesisIDs: [],
            focusSetID: focusSetID,
            createdAt: Date(), completedAt: nil
        )
        do {
            try db.addResearchGoal(goal)
            return goal
        } catch {
            errorMessage = "Failed to create goal: \(error.localizedDescription)"
            return nil
        }
    }

    func updateGoal(_ goal: ResearchGoal) {
        guard let db = currentDatabase else { return }
        do {
            try db.updateResearchGoal(goal)
        } catch {
            errorMessage = "Failed to update goal: \(error.localizedDescription)"
        }
    }

    func deleteGoal(id: UUID) {
        guard let db = currentDatabase else { return }
        do {
            try db.deleteResearchGoal(id: id)
        } catch {
            errorMessage = "Failed to delete goal: \(error.localizedDescription)"
        }
    }

    // MARK: - Life Events (M12)

    /// Read-through to the DB. Keeps the cache surface lean — there are
    /// typically &lt;20 life events per profile.
    func lifeEventsForProfile(_ profileID: String) -> [LifeEvent] {
        guard let db = currentDatabase else { return [] }
        return (try? db.loadLifeEvents(profileID: profileID)) ?? []
    }

    @discardableResult
    func createLifeEvent(
        profileID: String,
        type: LifeEventType,
        date: GenealogicalDate? = nil,
        endDate: GenealogicalDate? = nil,
        location: String? = nil,
        locationCode: String? = nil,
        description: String? = nil,
        details: LifeEventDetails? = nil,
        sources: [FieldSource] = [],
        confidence: FactConfidence = .standard,
        sensitive: Bool = false
    ) -> LifeEvent? {
        guard let db = currentDatabase else { return nil }
        let event = LifeEvent(
            id: UUID(), profileID: profileID, type: type,
            date: date, endDate: endDate,
            location: location, locationCode: locationCode,
            description: description,
            details: details,
            sources: sources, confidence: confidence,
            createdByTransactionID: nil,
            sensitive: sensitive
        )
        do {
            try db.addLifeEvent(event)
            return event
        } catch {
            errorMessage = "Failed to create life event: \(error.localizedDescription)"
            return nil
        }
    }

    func updateLifeEvent(_ event: LifeEvent) {
        guard let db = currentDatabase else { return }
        do {
            try db.updateLifeEvent(event)
        } catch {
            errorMessage = "Failed to update life event: \(error.localizedDescription)"
        }
    }

    func deleteLifeEvent(id: UUID) {
        guard let db = currentDatabase else { return }
        do {
            try db.deleteLifeEvent(id: id)
        } catch {
            errorMessage = "Failed to delete life event: \(error.localizedDescription)"
        }
    }

    // MARK: - Hypotheses (W5)

    @discardableResult
    func createHypothesis(
        claim: HypothesisClaim,
        confidence: HypothesisConfidence = .speculation,
        reasoning: String,
        supporting: [String] = [],
        contradicting: [String] = []
    ) -> Hypothesis? {
        guard let db = currentDatabase else { return nil }
        let h = Hypothesis(
            id: UUID(),
            claim: claim,
            confidence: confidence,
            reasoning: reasoning,
            supportingEvidence: supporting,
            contradictingEvidence: contradicting,
            status: .active,
            createdAt: Date(),
            resolvedAt: nil,
            dismissalReason: nil
        )
        do {
            try db.addHypothesis(h)
            recordSessionEvent(.hypothesisCreated)
            loadWorkbench()
            return h
        } catch {
            errorMessage = "Failed to create hypothesis: \(error.localizedDescription)"
            return nil
        }
    }

    func updateHypothesis(_ h: Hypothesis) {
        guard let db = currentDatabase else { return }
        do {
            try db.updateHypothesis(h)
            loadWorkbench()
        } catch {
            errorMessage = "Failed to update hypothesis: \(error.localizedDescription)"
        }
    }

    func deleteHypothesis(id: UUID) {
        guard let db = currentDatabase else { return }
        do {
            try db.deleteHypothesis(id: id)
            loadWorkbench()
        } catch {
            errorMessage = "Failed to delete hypothesis: \(error.localizedDescription)"
        }
    }

    /// Dismiss with a preserved reason — DESIGN.md §5.11 says "the reason is
    /// preserved so the same claim isn't re-hypothesised in a future session."
    func dismissHypothesis(id: UUID, reason: String) {
        guard var h = hypotheses.first(where: { $0.id == id }) else { return }
        h.status = .dismissed
        h.resolvedAt = Date()
        h.dismissalReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : reason
        updateHypothesis(h)
    }

    /// Result of a promote attempt — used by the UI to show success or
    /// surface the reason it couldn't go through.
    enum PromoteResult: Sendable {
        case success
        case unsupported(String)   // identityMatch and similar — needs user action
        case failed(String)
    }

    /// Promote a hypothesis to a fact in the tree. Per DESIGN.md §5.11:
    ///  - `.relationship` → addRelationship
    ///  - `.fieldValue` → editProfile
    ///  - `.identityMatch` → not yet supported (merge flow is future work)
    ///  - `.existence` → addProfile (caller must wire relationships separately)
    @discardableResult
    func promoteHypothesis(id: UUID) -> PromoteResult {
        guard var h = hypotheses.first(where: { $0.id == id }) else {
            return .failed("Hypothesis not found.")
        }

        switch h.claim {
        case .relationship(let fromID, let toID, let type, let role):
            // Validate both endpoints exist before committing.
            guard snapshot.profiles[fromID] != nil, snapshot.profiles[toID] != nil else {
                return .failed("One of the linked profiles is missing — edit the hypothesis or add the profile first.")
            }
            let rel = Relationship(
                id: UUID(), from: fromID, to: toID,
                type: type, role: role,
                subtype: type == .parent ? .biological : .unknown,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil
            )
            addRelationship(rel)

        case .fieldValue(let profileID, let field, let value):
            guard snapshot.profiles[profileID] != nil else {
                return .failed("Subject profile is missing.")
            }
            // Date fields go through editProfile's dateChanges path.
            let profile = snapshot.profiles[profileID]!
            switch field {
            case .birthDate:
                editProfile(
                    id: profileID, changes: [],
                    dateChanges: [(field, profile.birthDate, GenealogicalDate.parsePreview(value).parsed)],
                    source: .manualMemory
                )
            case .deathDate:
                editProfile(
                    id: profileID, changes: [],
                    dateChanges: [(field, profile.deathDate, GenealogicalDate.parsePreview(value).parsed)],
                    source: .manualMemory
                )
            default:
                editProfile(
                    id: profileID,
                    changes: [(field, stringValue(of: field, on: profile), value)],
                    dateChanges: [],
                    source: .manualMemory
                )
            }

        case .identityMatch:
            return .unsupported("Identity-match promotion needs the merge flow, which lands with M9. Dismiss the hypothesis with reasoning instead.")

        case .existence(let description, _):
            // Create a placeholder-ish profile from the description text.
            // Caller is expected to wire relationships separately afterwards.
            let parts = description.split(separator: " ", maxSplits: 1).map(String.init)
            let profile = Profile(
                id: UUID().uuidString,
                externalIDs: [:],
                firstName: parts.first,
                lastName: parts.count > 1 ? parts[1] : nil,
                gender: nil,
                attributes: nil,
                birthDate: nil, birthLocation: nil,
                deathDate: nil, deathLocation: nil,
                bio: "Created from hypothesis: \(description)",
                isDeleted: false, sources: [:], disputes: [:]
            )
            addProfile(profile, source: .manualMemory, relatedTo: nil)
        }

        h.status = .promoted
        h.resolvedAt = Date()
        updateHypothesis(h)
        recordSessionEvent(.hypothesisPromoted)
        return .success
    }

    // MARK: - Workbench search (W6)

    /// Cross-entity workbench search. Notes go through the SQLite FTS index
    /// for relevance ranking when the DB is available; questions, hypotheses,
    /// and focus sets use the pure-Swift `WorkbenchSearch` substring path.
    /// Empty query returns []. Per DESIGN.md §7.7.5.
    func searchWorkbench(query: String) -> [WorkbenchSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // Notes via FTS for ranked relevance; fall back to substring if the
        // DB isn't open (tests, edge cases).
        let noteHits: [WorkbenchSearchResult]
        if let db = currentDatabase, let ftsHits = try? db.searchNotes(query: trimmed) {
            noteHits = ftsHits.map(WorkbenchSearchResult.note)
        } else {
            let needle = trimmed.lowercased()
            noteHits = notes.filter { WorkbenchSearch.matchesNote($0, needle: needle) }
                .map(WorkbenchSearchResult.note)
        }

        // Other types — substring match on cached arrays.
        let other = WorkbenchSearch.matches(
            query: trimmed,
            notes: [],   // already handled above
            questions: questions,
            hypotheses: hypotheses,
            focusSets: focusSets
        )

        return noteHits + other
    }

    /// Read a string-valued profile field. Date fields aren't supported here —
    /// callers route those through `editProfile`'s `dateChanges` path.
    private func stringValue(of field: ProfileField, on profile: Profile) -> String? {
        switch field {
        case .firstName: return profile.firstName
        case .middleName: return profile.middleName
        case .lastName: return profile.lastName
        case .marriedSurname: return profile.marriedSurname
        case .nickName: return profile.nickName
        case .mothersMaidenName: return profile.mothersMaidenName
        case .gender: return profile.gender?.rawValue
        case .birthLocation: return profile.birthLocation
        case .deathLocation: return profile.deathLocation
        case .bio: return profile.bio
        // Non-scalar fields have no single-string projection (like the date
        // cases below) — callers route name-form edits through their own path.
        case .birthDate, .deathDate, .nameForms: return nil
        }
    }

    /// Create a new project and immediately import data from its source.
    func createAndImportProject(name: String, source: DataSource) {
        isLoading = true
        errorMessage = nil

        do {
            let (project, db) = try ProjectStore.createProject(name: name, source: source)
            currentProject = project
            currentDatabase = db

            switch source {
            case .gedcom(let path):
                try importGEDCOM(path: path, db: db)
                // PROJECT_ONBOARDING_SPEC Part A — offer setup after a GEDCOM
                // import. No-ops if the import raised a cleanse review (they
                // must not both present); that project reaches setup via
                // Settings → Re-run setup.
                offerSetupIfNeeded()
            case .wikitree:
                // WikiTree credentials are entered separately in Settings
                // For now, create the project — user connects via Settings.
                // Setup is offered when connectWikiTree first succeeds.
                snapshot = .empty
            case .manual:
                // Empty project — the family wizard shows first (NewProjectView
                // sets showOnboardingWizard); setup is offered on its dismiss.
                snapshot = .empty
            }

            refreshProjectList()
        } catch {
            errorMessage = "Failed to create project: \(error.localizedDescription)"
        }

        isLoading = false
        loadingMessage = nil
    }

    /// Import a GEDCOM file into the current database.
    private func importGEDCOM(path: String, db: ProjectDatabase) throws {
        loadingMessage = "Parsing GEDCOM file..."
        let parseResult = try GEDCOMParser.parse(fileAt: path)

        // Guard: GEDCOM import into a non-empty project would silently
        // duplicate profiles. The spec (DESIGN.md §7.5.11) calls for an
        // ImportMergeView duplicate-detection flow; that's deferred. Until
        // then, refuse the import rather than corrupt the tree. New projects
        // (the only path that reaches here today) have an empty snapshot
        // so this guard never fires for current users.
        let existingCount = (try? db.buildSnapshot().profiles.count) ?? 0
        guard existingCount == 0 else {
            throw GEDCOMImportError.targetNotEmpty(
                existingCount: existingCount,
                incomingCount: parseResult.individualCount
            )
        }

        loadingMessage = "Saving \(parseResult.individualCount) profiles..."
        let transaction = try db.importSnapshot(parseResult.snapshot, source: path)
        // CONFLICT_LAYER_SPEC CL2 (T-C trigger): post-import sweep —
        // imported trees surface their latent contradictions immediately.
        _ = try? ConflictSweep.run(db: db, snapshot: try db.buildSnapshot(), force: true)

        loadingMessage = "Building tree..."
        snapshot = try db.buildSnapshot()

        loadingMessage = "Running audit..."
        runPostLoadAudit()

        // IMPORT_DEDUPE_SPEC — flag orphan-stub duplicates left by the
        // export (Ancestry's merge tool strips a duplicate's family links
        // but leaves the record). Surfaced for one-click review; empty
        // stubs are safe to remove (they carry no data), non-empty ones
        // route to the Compare/merge flow.
        // Change 6 — the same two detectors that back the on-demand scan run
        // at import: zero-edge orphan stubs AND single-spouse-edge phantom
        // spouses (the four-wife Keyworth shape), so the guided cards appear
        // in the post-import summary with no Audit-tab spelunking.
        let stubCandidates = OrphanStubDetector.candidates(in: snapshot)
        let phantomCandidates = phantomSpouseCandidatesToReview()
        if !stubCandidates.isEmpty || !phantomCandidates.isEmpty {
            importCleanseReview = ImportCleanseReview(
                candidates: stubCandidates, phantomSpouseCandidates: phantomCandidates)
        }

        // Update project metadata with refresh time
        if var project = currentProject {
            project = Project(
                id: project.id,
                name: project.name,
                source: project.source,
                homePersonID: project.homePersonID,
                createdAt: project.createdAt,
                lastRefreshed: transaction.completedAt
            )
            try db.saveProjectMeta(project)
            currentProject = project
        }

        if !parseResult.warnings.isEmpty {
            print("GEDCOM import warnings:")
            for warning in parseResult.warnings {
                print("  \(warning)")
            }
        }
    }

    /// Import a GEDZip (.gdz) container — GEDCOM 7.0 + bundled media — into
    /// a new project. The archive's `gedcom.ged` is parsed via the existing
    /// `GEDCOMParser`; staged media files are copied into the new project's
    /// per-project media directory so attachments survive the round-trip.
    ///
    /// Returns the new project ID on success so the picker can refresh +
    /// (optionally) open it. We deliberately don't auto-create `Attachment`
    /// rows here — matching staged media files back to OBJE records is
    /// non-trivial and the v1 product requirement is "the files survive the
    /// round-trip"; users can re-attach via the existing UI if needed.
    @discardableResult
    func importGEDZip(from archiveURL: URL) -> UUID? {
        isLoading = true
        loadingMessage = "Reading GEDZip archive..."
        errorMessage = nil
        defer {
            isLoading = false
            loadingMessage = nil
        }

        do {
            let result = try GEDZipReader.read(from: archiveURL)
            // The reader hands us a staging dir we own — make sure we tear
            // it down whatever happens after this point.
            defer { try? FileManager.default.removeItem(at: result.mediaStagingDir) }

            // Use the .gdz filename (sans extension) as the project name.
            let projectName = archiveURL.deletingPathExtension().lastPathComponent
            let (project, db) = try ProjectStore.createProject(
                name: projectName.isEmpty ? "Imported GEDZip" : projectName,
                source: .gedcom(path: archiveURL.path)
            )

            loadingMessage = "Parsing GEDCOM..."
            let parseResult = GEDCOMParser.parse(content: result.gedcomText)

            loadingMessage = "Saving \(parseResult.individualCount) profiles..."
            _ = try db.importSnapshot(parseResult.snapshot, source: archiveURL.path)

            // Copy staged media files into the new project's media dir,
            // preserving the relative path under `media/`.
            let mediaDest = ProjectStore.mediaDirectory(for: project.id)
            let stagingMediaRoot = result.mediaStagingDir.appendingPathComponent("media")
            for src in result.mediaFiles {
                // Compute the path relative to `media/` in the staging dir.
                // If the archive nests the payload one level deep the
                // reader returns the resolved root, so we strip from that.
                let stagingPath = src.path
                let prefix = stagingMediaRoot.path
                let nestedPrefix = result.mediaStagingDir.appendingPathComponent("media").path
                let relPath: String
                if stagingPath.hasPrefix(prefix) {
                    relPath = String(stagingPath.dropFirst(prefix.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                } else if stagingPath.hasPrefix(nestedPrefix) {
                    relPath = String(stagingPath.dropFirst(nestedPrefix.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                } else {
                    relPath = src.lastPathComponent
                }
                guard !relPath.isEmpty else { continue }
                let dest = mediaDest.appendingPathComponent(relPath)
                try? FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try? FileManager.default.copyItem(at: src, to: dest)
            }

            refreshProjectList()
            return project.id
        } catch {
            errorMessage = "GEDZip import failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Import a GEDCOM file as suggestions rather than facts (M22).
    ///
    /// Differs from `importGEDCOM` in that it does **not** require an
    /// empty target. Profiles only present in the import are added
    /// directly; profiles that match an existing person produce
    /// `.fieldValue` hypotheses on the workbench instead of overwriting
    /// the existing tree. Used by the picker's "Import GEDCOM as
    /// suggestions" entry point — see DESIGN.md §13 "Collaboration
    /// Extensions: Import corrections as suggestions."
    func importGEDCOMAsCorrections(from url: URL) {
        guard let db = currentDatabase else {
            errorMessage = "Open a project first before importing corrections."
            return
        }
        isLoading = true
        loadingMessage = "Parsing GEDCOM file..."
        errorMessage = nil
        defer {
            isLoading = false
            loadingMessage = nil
        }

        do {
            let parseResult = try GEDCOMParser.parse(fileAt: url.path)
            let existing = (try? db.buildSnapshot()) ?? .empty
            let sourceLabel = url.lastPathComponent

            loadingMessage = "Comparing with existing tree..."
            let result = ImportAsCorrectionsEngine.diff(
                importedSnapshot: parseResult.snapshot,
                existingSnapshot: existing,
                sourceLabel: sourceLabel
            )

            // Persist novel profiles directly. We use addFamily with no
            // relationships per profile to keep the existing transaction
            // shape; the relationships from the imported snapshot are
            // not currently re-attached because they may reference
            // overlapping profiles whose IDs differ between the two
            // snapshots. A future M will wire that up.
            if !result.newProfiles.isEmpty {
                loadingMessage = "Adding \(result.newProfiles.count) new profiles..."
                _ = try db.addFamily(
                    profiles: result.newProfiles,
                    relationships: [],
                    source: .gedcom
                )
            }

            // Persist hypotheses to the workbench.
            for h in result.hypotheses {
                try db.addHypothesis(h)
            }

            // Refresh derived state.
            snapshot = (try? db.buildSnapshot()) ?? snapshot
            loadWorkbench()
            runPostLoadAudit()

            successMessage = "Imported \(result.newProfiles.count) new profiles + \(result.hypotheses.count) hypotheses (workbench)."

            if !parseResult.warnings.isEmpty {
                print("GEDCOM import warnings:")
                for warning in parseResult.warnings {
                    print("  \(warning)")
                }
            }
        } catch {
            errorMessage = "Import as corrections failed: \(error.localizedDescription)"
        }
    }

    func deleteProject(_ id: UUID) {
        do {
            try ProjectStore.deleteProject(id)
            if currentProject?.id == id {
                stopRunRequestWatcher()
                currentProject = nil
                currentDatabase = nil
                snapshot = .empty
            }
            refreshProjectList()
        } catch {
            errorMessage = "Failed to delete project: \(error.localizedDescription)"
        }
    }

    func archiveProject(_ id: UUID) {
        do {
            try ProjectStore.archiveProject(id)
            if currentProject?.id == id {
                stopRunRequestWatcher()
                currentProject = nil
                currentDatabase = nil
                snapshot = .empty
            }
            refreshProjectList()
        } catch {
            errorMessage = "Failed to archive project: \(error.localizedDescription)"
        }
    }

    func unarchiveProject(_ id: UUID) {
        do {
            try ProjectStore.unarchiveProject(id)
            refreshProjectList()
        } catch {
            errorMessage = "Failed to unarchive project: \(error.localizedDescription)"
        }
    }

    func closeProject() {
        stopRunRequestWatcher()
        currentProject = nil
        currentDatabase = nil
        snapshot = .empty
    }

    // MARK: - WikiTree

    private var wikiTreeClient = WikiTreeClient()

    /// Validate WikiTree credentials without side effects on the project list.
    /// Used by `NewProjectView` to confirm a login works **before** creating
    /// a SQLite project file — previously a failed login still produced an
    /// empty project shell with no UI to retry the credentials (Task #56).
    /// Throws on auth failure; returns silently on success. The client's
    /// session cookie persists, so the subsequent full `connectWikiTree`
    /// call won't re-prompt the user but will simply re-login as part of
    /// the import flow (cheap; one extra HTTP round trip).
    func validateWikiTreeLogin(email: String, password: String) async throws {
        _ = try await wikiTreeClient.login(email: email, password: password)
    }

    /// Connect to WikiTree and fetch ancestor tree from a seed profile.
    /// Single getAncestors call — much more efficient than watchlist + batch.
    func connectWikiTree(email: String, password: String, seedProfileID: String = "") async {
        isLoading = true
        loadingMessage = "Logging in to WikiTree..."
        errorMessage = nil
        successMessage = nil

        do {
            let user = try await wikiTreeClient.login(email: email, password: password)
            loadingMessage = "Logged in as \(user.name). Fetching watchlist..."

            let (profiles, relationships) = try await wikiTreeClient.fetchWatchlistTree { message in
                Task { @MainActor in
                    self.loadingMessage = message
                }
            }

            if profiles.isEmpty {
                errorMessage = "WikiTree returned 0 profiles. Check your watchlist has profiles."
                isLoading = false
                loadingMessage = nil
                return
            }

            let profileDict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            let importSnapshot = FamilyGraphSnapshot(profiles: profileDict, relationships: relationships)

            guard let db = currentDatabase else {
                errorMessage = "No database — create a project first."
                isLoading = false
                loadingMessage = nil
                return
            }

            loadingMessage = "Saving \(profiles.count) profiles, \(relationships.count) relationships..."
            let transaction = try db.importSnapshot(importSnapshot, source: "wikitree://\(user.name)")

            loadingMessage = "Building tree..."
            snapshot = try db.buildSnapshot()

            loadingMessage = "Running audit..."
            runPostLoadAudit()

            if var project = currentProject {
                project = Project(
                    id: project.id, name: project.name, source: project.source,
                    homePersonID: project.homePersonID,
                    createdAt: project.createdAt, lastRefreshed: transaction.completedAt
                )
                try db.saveProjectMeta(project)
                currentProject = project
            }

            let auditCount = auditSummary?.total ?? 0
            successMessage = "Imported \(profiles.count) profiles, \(relationships.count) relationships. Audit found \(auditCount) items."
            // PROJECT_ONBOARDING_SPEC Part A — offer setup once the WikiTree
            // tree has landed.
            offerSetupIfNeeded()
        } catch {
            errorMessage = "WikiTree error: \(error.localizedDescription)"
        }

        isLoading = false
        loadingMessage = nil
    }

    /// Refresh from WikiTree — superseded by refreshWikiTreeWithDiff().
    /// Kept as a direct refresh for cases where diff is not needed.
    func refreshWikiTree() async {
        await refreshWikiTreeWithDiff()
    }

    // MARK: - Refresh with Diff

    /// Pending diff waiting for user to accept or reject.
    var pendingDiff: DiffEngine.DiffResult?
    var pendingSnapshot: FamilyGraphSnapshot?

    /// Refresh from WikiTree — fetch new data and show diff before committing.
    func refreshWikiTreeWithDiff() async {
        guard case .wikitree = currentProject?.source else { return }
        isLoading = true
        loadingMessage = "Refreshing from WikiTree..."
        errorMessage = nil

        do {
            let (profiles, relationships) = try await wikiTreeClient.fetchWatchlistTree { message in
                Task { @MainActor in
                    self.loadingMessage = message
                }
            }

            let profileDict = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            let newSnapshot = FamilyGraphSnapshot(profiles: profileDict, relationships: relationships)

            // Compute diff
            let diff = DiffEngine.diff(old: snapshot, new: newSnapshot)

            if diff.isEmpty {
                // No changes — nothing to do
                loadingMessage = nil
                isLoading = false
                return
            }

            // Store pending diff for user review
            pendingDiff = diff
            pendingSnapshot = newSnapshot
        } catch {
            errorMessage = "Refresh error: \(error.localizedDescription)"
        }

        isLoading = false
        loadingMessage = nil
    }

    /// Accept the pending diff and commit changes to the database.
    func acceptPendingDiff() {
        guard let newSnapshot = pendingSnapshot else { return }
        guard let db = currentDatabase else { return }

        do {
            // Persist the new snapshot to the database
            let transaction = try db.importSnapshot(newSnapshot, source: "wikitree://refresh")

            // Rebuild snapshot from database (ensures consistency)
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()

            if var project = currentProject {
                project = Project(
                    id: project.id, name: project.name, source: project.source,
                    homePersonID: project.homePersonID,
                    createdAt: project.createdAt, lastRefreshed: transaction.completedAt
                )
                try db.saveProjectMeta(project)
                currentProject = project
            }
        } catch {
            errorMessage = "Failed to save refresh: \(error.localizedDescription)"
        }

        pendingDiff = nil
        pendingSnapshot = nil
    }

    /// Reject the pending diff — keep current data.
    func rejectPendingDiff() {
        pendingDiff = nil
        pendingSnapshot = nil
    }

    // MARK: - Undo

    /// Undo the most recent transaction.
    func undoLastTransaction() {
        guard let db = currentDatabase else { return }

        do {
            let transactions = try db.loadTransactions(limit: 1)
            guard let latest = transactions.first else {
                errorMessage = "Nothing to undo."
                return
            }

            switch latest.undoStrategy {
            case .structural:
                // Delete all entities created by this transaction
                try db.undoStructural(transactionID: latest.id)
            case .replay:
                // Reverse each FieldChange
                try db.undoReplay(transactionID: latest.id)
            }

            // Record the undo as its own transaction
            let undoTx = Transaction(
                id: UUID(),
                kind: .undo(ofTransactionID: latest.id),
                undoStrategy: .replay,
                startedAt: Date(),
                completedAt: Date(),
                changeCount: latest.changeCount,
                profileCount: latest.profileCount
            )
            try db.saveTransaction(undoTx)

            // Rebuild snapshot
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
        } catch {
            errorMessage = "Undo failed: \(error.localizedDescription)"
        }
    }

    /// Export current project to GEDCOM file. Pulls in attachments from
    /// the open database so OBJE blocks reference each profile's media.
    /// - Parameter excludeSensitive: M14 §7.15.2. When true, OBJE blocks
    ///   for attachments tied to sensitive life events are dropped.
    func exportGEDCOM(to path: String, excludeSensitive: Bool = false) {
        guard !snapshot.profiles.isEmpty else {
            errorMessage = "No data to export."
            return
        }
        do {
            let attachments = (try? currentDatabase?.loadAttachments()) ?? []
            let lifeEvents = (try? currentDatabase?.loadAllLifeEvents()) ?? []
            let result = try GEDCOMExporter.export(
                snapshot,
                to: path,
                attachments: attachments,
                lifeEvents: lifeEvents,
                excludeSensitive: excludeSensitive
            )
            if !result.dropped.isEmpty {
                print("GEDCOM export — dropped data:")
                for item in result.dropped {
                    print("  \(item)")
                }
            }
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - HTML export (M21)

    /// Export the current project as a folder of static HTML files. The
    /// recipient opens `index.html` in any browser and clicks through the
    /// tree — no JavaScript or app required. Per DESIGN.md §13.
    func exportHTML(to directoryURL: URL, excludeLiving: Bool, excludeSensitive: Bool) {
        guard !snapshot.profiles.isEmpty else {
            errorMessage = "No data to export."
            return
        }
        let lifeEvents: [LifeEvent] = (try? currentDatabase?.loadAllLifeEvents()) ?? []
        let request = HTMLExporter.ExportRequest(
            snapshot: snapshot,
            lifeEvents: lifeEvents,
            projectName: currentProject?.name ?? "Family Tree",
            excludeLiving: excludeLiving,
            excludeSensitive: excludeSensitive
        )
        let result = HTMLExporter.export(request)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for file in result.files {
                let url = directoryURL.appendingPathComponent(file.relativePath)
                try file.contents.write(to: url, atomically: true, encoding: .utf8)
            }
            successMessage = "Exported \(result.files.count) HTML files."
        } catch {
            errorMessage = "HTML export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Project archive (.ancestor)

    /// Export the current project to a `.ancestor` archive at the given URL.
    func exportProjectArchive(to url: URL) {
        guard let projectID = currentProject?.id else {
            errorMessage = "No project open to export."
            return
        }
        do {
            try ProjectArchive.export(projectID: projectID, to: url)
        } catch {
            errorMessage = "Archive export failed: \(error.localizedDescription)"
        }
    }

    /// Export a specific project (need not be the open one) to a
    /// `.ancestor` archive. Used by the project picker's per-row menu.
    func exportProjectArchive(projectID: UUID, to url: URL) {
        do {
            try ProjectArchive.export(projectID: projectID, to: url)
        } catch {
            errorMessage = "Archive export failed: \(error.localizedDescription)"
        }
    }

    /// Import a `.ancestor` archive into a new project. Refreshes the
    /// project list on success. Returns the imported project ID for
    /// callers that want to open it immediately.
    @discardableResult
    func importProjectArchive(from url: URL) -> UUID? {
        do {
            let id = try ProjectArchive.importArchive(from: url)
            refreshProjectList()
            return id
        } catch {
            errorMessage = "Archive import failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Manual Entry

    /// Add a single profile, optionally linked to an existing person.
    func addProfile(
        _ profile: Profile,
        source: SourceOrigin,
        relatedTo: (profileID: String, type: RelationshipType, role: ParentRole?, subtype: RelationshipSubtype)? = nil
    ) {
        guard let db = currentDatabase else { return }
        do {
            let tx = try db.addProfile(profile, source: source)
            recordSessionEvent(.profileAdded)
            recordSessionEvent(.transactionRecorded(tx.id))

            // Create relationship if specified
            if let related = relatedTo {
                let rel = Relationship(
                    id: UUID(),
                    from: related.profileID,
                    to: profile.id,
                    type: related.type,
                    role: related.role,
                    subtype: related.subtype,
                    marriageDate: nil,
                    marriageLocation: nil,
                    divorceDate: nil
                )
                let relTx = try db.addRelationship(rel)
                recordSessionEvent(.transactionRecorded(relTx.id))
            }

            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
            maybeShowManualSaveToast()
        } catch {
            errorMessage = "Failed to add person: \(error.localizedDescription)"
        }
    }

    /// Add a family group — parents, children, and relationships in one transaction.
    func addFamily(
        profiles: [Profile],
        relationships: [Relationship],
        source: SourceOrigin
    ) {
        guard let db = currentDatabase else { return }
        do {
            let tx = try db.addFamily(profiles: profiles, relationships: relationships, source: source)
            for _ in profiles { recordSessionEvent(.profileAdded) }
            recordSessionEvent(.transactionRecorded(tx.id))
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
            maybeShowManualSaveToast()
        } catch {
            errorMessage = "Failed to add family: \(error.localizedDescription)"
        }
    }

    /// Edit fields on an existing profile.
    ///
    /// `sourceByField` (M17.2) lets callers attach a different `SourceOrigin`
    /// to each changed field — used by EditPersonView's per-field source
    /// picker. When nil (the back-compat default), every change uses the
    /// single `source` argument as before. When provided, fields without an
    /// explicit override fall back to `source`. Internally this is dispatched
    /// as one db.editProfile call per unique source so the existing
    /// transaction model stays simple.
    func editProfile(
        id: String,
        changes: [(field: ProfileField, oldValue: String?, newValue: String?)],
        dateChanges: [(field: ProfileField, oldDate: GenealogicalDate?, newDate: GenealogicalDate?)] = [],
        source: SourceOrigin,
        sourceByField: [ProfileField: SourceOrigin]? = nil
    ) {
        guard let db = currentDatabase else { return }
        do {
            if let perField = sourceByField {
                // Group both string and date changes by their effective source.
                // Stable iteration order so undo history is deterministic.
                var groups: [SourceOrigin: (
                    changes: [(field: ProfileField, oldValue: String?, newValue: String?)],
                    dateChanges: [(field: ProfileField, oldDate: GenealogicalDate?, newDate: GenealogicalDate?)]
                )] = [:]
                for change in changes {
                    let origin = perField[change.field] ?? source
                    groups[origin, default: ([], [])].changes.append(change)
                }
                for change in dateChanges {
                    let origin = perField[change.field] ?? source
                    groups[origin, default: ([], [])].dateChanges.append(change)
                }
                // Each group becomes its own manualEdit transaction so the
                // SQLite source rows carry the correct origin per field.
                for (origin, group) in groups {
                    let tx = try db.editProfile(
                        profileID: id,
                        changes: group.changes,
                        dateChanges: group.dateChanges,
                        source: origin
                    )
                    recordSessionEvent(.transactionRecorded(tx.id))
                }
                if !groups.isEmpty {
                    recordSessionEvent(.profileEdited)
                }
            } else {
                let tx = try db.editProfile(
                    profileID: id,
                    changes: changes,
                    dateChanges: dateChanges,
                    source: source
                )
                recordSessionEvent(.profileEdited)
                recordSessionEvent(.transactionRecorded(tx.id))
            }
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
            maybeShowManualSaveToast()
        } catch {
            errorMessage = "Failed to edit profile: \(error.localizedDescription)"
        }
    }

    /// Record an alternative value for a field that already has imported sources.
    /// Adds a competing FieldSource without changing the column value, so the
    /// existing value remains alongside the user's alternative.
    func recordAlternativeFact(
        profileID: String,
        field: ProfileField,
        rawValue: String,
        source: SourceOrigin
    ) {
        guard let db = currentDatabase else { return }
        do {
            // nil = identical alternative already on file (idempotent no-op).
            if let tx = try db.recordAlternativeFact(
                profileID: profileID, field: field,
                rawValue: rawValue, source: source
            ) {
                recordSessionEvent(.transactionRecorded(tx.id))
            }
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
        } catch {
            errorMessage = "Failed to record alternative: \(error.localizedDescription)"
        }
    }

    /// Remove an applied evidence record from a profile — the ledger's
    /// per-record removal (PROFILE_SOURCES_LEDGER_SPEC Change 3). Reverts the
    /// record's absorption directionally, feeds rejection memory, then
    /// rebuilds the snapshot and force-sweeps so any dispute still justified
    /// by surviving evidence is re-derived (and dissolved ones stay gone).
    @discardableResult
    func removeAppliedRecord(_ evidence: EvidenceRecord) -> RecordRemovalReport? {
        guard let db = currentDatabase else { return nil }
        do {
            let report = try db.removeAppliedRecord(evidence)
            if let tx = report.transactionID {
                recordSessionEvent(.transactionRecorded(tx))
            }
            snapshot = try db.buildSnapshot()
            runConflictSweep(force: true)
            runPostLoadAudit()
            return report
        } catch {
            errorMessage = "Failed to remove record: \(error.localizedDescription)"
            return nil
        }
    }

    /// Attach (or update) a structured citation and evidence-quality rating
    /// on the most-recent `field_sources` row matching (profileID, field,
    /// origin). Per DESIGN.md §5.12, citations layer onto an existing source
    /// rather than replacing it — the raw value stays untouched. Called by
    /// AddPersonView/EditPersonView after save when the user has filled in
    /// the optional citation form.
    func attachCitation(
        profileID: String,
        field: ProfileField,
        origin: SourceOrigin,
        citation: Citation?,
        quality: EvidenceQuality?
    ) {
        guard let db = currentDatabase else { return }
        do {
            try db.updateFieldSourceCitation(
                profileID: profileID,
                field: field,
                origin: origin,
                citation: citation,
                quality: quality
            )
            snapshot = try db.buildSnapshot()
        } catch {
            errorMessage = "Failed to attach citation: \(error.localizedDescription)"
        }
    }

    // MARK: - Field disputes (M16.14)

    /// Persist a resolution onto a disputed field and rebuild the snapshot
    /// so the disputed UI clears. Mirrors the editProfile / addProfile
    /// pattern — wraps the write in a transaction so undo replays it.
    func resolveDispute(
        profileID: String,
        field: ProfileField,
        resolution: DisputeResolution
    ) {
        guard let db = currentDatabase else { return }
        do {
            let tx = try db.resolveFieldDispute(
                profileID: profileID,
                field: field,
                resolution: resolution
            )
            recordSessionEvent(.transactionRecorded(tx.id))
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
        } catch {
            errorMessage = "Failed to resolve dispute: \(error.localizedDescription)"
        }
    }

    /// Soft-delete a profile (hide from tree, preserve in DB).
    func softDeleteProfile(id: String) {
        guard let db = currentDatabase else { return }
        do {
            let tx = try db.softDeleteProfiles(ids: [id])
            recordSessionEvent(.transactionRecorded(tx.id))
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
        } catch {
            errorMessage = "Failed to remove person: \(error.localizedDescription)"
        }
    }

    /// Soft-delete a profile and all ancestors or all descendants.
    func softDeleteBranch(rootID: String, ancestors: Bool) {
        guard let db = currentDatabase else { return }
        do {
            var ids = [rootID]
            if ancestors {
                ids += snapshot.ancestorsOf(rootID, depth: 50).map(\.id)
            } else {
                ids += snapshot.descendantsOf(rootID, depth: 50).map(\.id)
            }
            let tx = try db.softDeleteProfiles(ids: ids)
            recordSessionEvent(.transactionRecorded(tx.id))
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
        } catch {
            errorMessage = "Failed to remove branch: \(error.localizedDescription)"
        }
    }

    /// Add a relationship between two existing profiles.
    func addRelationship(_ rel: Relationship) {
        guard let db = currentDatabase else { return }
        do {
            let tx = try db.addRelationship(rel)
            recordSessionEvent(.transactionRecorded(tx.id))
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
        } catch {
            errorMessage = "Failed to add relationship: \(error.localizedDescription)"
        }
    }

    /// When a REAL parent is established for a child, retire the blank
    /// placeholder the sibling shortcut created — replacing it, and carrying
    /// every sibling that shared it onto the real parent — instead of letting
    /// the two pile up (owner report 2026-07-15: research-found parents
    /// stacked behind blank placeholders, hiding the real ones on the canvas
    /// and leaving 4-parent tangles). Call AFTER the real parent edge to
    /// `childID` has been added. No-op when the child has no placeholder
    /// parent. Replaces ONE placeholder per call (role-matched, else any), so
    /// establishing a father then a mother cleanly retires both blanks.
    func reconcilePlaceholderParent(childID: String, realParentID: String, role: ParentRole) {
        // Capture everything up front — each mutation rebuilds the snapshot.
        let placeholders = snapshot.parentsOf(childID).filter {
            $0.attributes?.nameStatus == .placeholder
        }
        guard !placeholders.isEmpty else { return }

        func placeholderRole(_ pid: String) -> ParentRole? {
            snapshot.relationships.first {
                $0.type == .parent && $0.from == pid && $0.to == childID
            }?.role
        }
        let victim = placeholders.first { placeholderRole($0.id) == role } ?? placeholders[0]

        // Every child that shared this blank parent moves onto the real one.
        let sharedChildIDs = snapshot.childrenOf(victim.id).map(\.id)
        let victimEdgeIDs = snapshot.relationships
            .filter { $0.type == .parent && $0.from == victim.id }
            .map(\.id)
        let alreadyRealChildren = Set(snapshot.childrenOf(realParentID).map(\.id))

        for cid in sharedChildIDs where !alreadyRealChildren.contains(cid) {
            addRelationship(Relationship(
                id: UUID(), from: realParentID, to: cid,
                type: .parent, role: role, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        }
        for eid in victimEdgeIDs { removeRelationship(id: eid) }
        softDeleteProfile(id: victim.id)
    }

    /// Repairs an "excess / placeholder parents" finding for `childID` (audit
    /// rule `excessParentEdges`) by absorbing every blank stub parent into the
    /// child's real (named) parents: each sibling that shared a stub is re-homed
    /// onto the child's real parents, then the stubs are unlinked and
    /// soft-deleted. Planning is pure (`PlaceholderParentRepair.plan`); this
    /// only applies it through the transactional mutators. No-op when there's
    /// nothing to absorb into — the legitimate unknown-couple case, not this bug.
    func repairExcessPlaceholderParents(for childID: String) {
        guard let db = currentDatabase,
              let plan = PlaceholderParentRepair.plan(childID: childID, snapshot: snapshot)
        else { return }

        // Apply every DB write first, then rebuild the snapshot and re-audit
        // exactly ONCE. Going through addRelationship/removeRelationship/
        // softDeleteProfile individually rebuilds the snapshot and runs a full
        // 218-profile audit per call — a ~10-write repair beachballed the app
        // (owner report 2026-07-16). One rebuild + one audit at the end fixes it.
        do {
            for r in plan.rehome {
                let tx = try db.addRelationship(Relationship(
                    id: UUID(), from: r.parentID, to: r.childID,
                    type: .parent, role: r.role, subtype: .biological,
                    marriageDate: nil, marriageLocation: nil, divorceDate: nil))
                recordSessionEvent(.transactionRecorded(tx.id))
            }
            for eid in plan.removeEdgeIDs {
                let tx = try db.removeRelationship(id: eid)
                recordSessionEvent(.transactionRecorded(tx.id))
            }
            if !plan.deleteStubIDs.isEmpty {
                let tx = try db.softDeleteProfiles(ids: plan.deleteStubIDs)
                recordSessionEvent(.transactionRecorded(tx.id))
            }
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
        } catch {
            errorMessage = "Failed to repair placeholder parents: \(error.localizedDescription)"
        }
    }

    /// Remove a relationship.
    func removeRelationship(id: UUID) {
        guard let db = currentDatabase else { return }
        do {
            let tx = try db.removeRelationship(id: id)
            recordSessionEvent(.transactionRecorded(tx.id))
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
        } catch {
            errorMessage = "Failed to remove relationship: \(error.localizedDescription)"
        }
    }

    /// Restore a soft-deleted profile.
    func restoreDeletedProfile(id: String) {
        guard let db = currentDatabase else { return }
        do {
            let tx = try db.restoreProfiles(ids: [id])
            recordSessionEvent(.transactionRecorded(tx.id))
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
        } catch {
            errorMessage = "Failed to restore person: \(error.localizedDescription)"
        }
    }

    /// Commit the onboarding wizard's output: persist the family group, set the
    /// home person, and show a completion toast. Called from OnboardingWizardView.
    /// `source` is wired from `SourceDefaults` via the wizard builder rather
    /// than hardcoded — see `OnboardingWizardBuilder.Result.defaultSource`.
    func completeOnboarding(
        profiles: [Profile],
        relationships: [Relationship],
        homePersonID: String,
        source: SourceOrigin = .manualMemory
    ) {
        guard let db = currentDatabase else { return }
        do {
            let tx = try db.addFamily(profiles: profiles, relationships: relationships, source: source)
            recordSessionEvent(.transactionRecorded(tx.id))
            for _ in profiles { recordSessionEvent(.profileAdded) }
            try db.setHomePerson(id: homePersonID)
            if var project = currentProject {
                project = Project(
                    id: project.id, name: project.name, source: project.source,
                    homePersonID: homePersonID,
                    createdAt: project.createdAt, lastRefreshed: project.lastRefreshed
                )
                try db.saveProjectMeta(project)
                currentProject = project
            }
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
            onboardingCompletionMessage = "Wizard complete — \(profiles.count) people added."
        } catch {
            errorMessage = "Failed to build tree: \(error.localizedDescription)"
        }
    }

    // MARK: - PROJECT_ONBOARDING_SPEC Part A — setup wizard lifecycle

    /// Set the project's home Chapman anchor (Step 1). Mutates a copy of the
    /// current project so every other field is preserved, then persists via
    /// the full-row `saveProjectMeta` (the same pattern the Settings home-county
    /// picker uses; there is no targeted db setter for this column). An empty
    /// code clears the anchor (back to per-profile derivation).
    func setHomeChapmanCode(_ code: String?) {
        guard let db = currentDatabase, var project = currentProject else { return }
        let cleaned = code?.trimmingCharacters(in: .whitespaces)
        project.homeChapmanCode = (cleaned?.isEmpty == false) ? cleaned : nil
        do {
            try db.saveProjectMeta(project)
            currentProject = project
        } catch {
            errorMessage = "Could not set home region: \(error.localizedDescription)"
        }
    }

    /// Offer the setup wizard once per project. Called at the end of each
    /// project create/import/connect path — NOT on `openProject`, so existing
    /// projects (which predate the marker and read as incomplete) are never
    /// ambushed on open. Won't fire while another onboarding-shaped sheet is
    /// up (the family wizard or the GEDCOM import-cleanse review), so the two
    /// never collide; those cases fall back to Settings → Re-run setup.
    func offerSetupIfNeeded() {
        guard let db = currentDatabase,
              (try? db.isSetupComplete()) == false,
              !showOnboardingWizard, importCleanseReview == nil
        else { return }
        showSetupWizard = true
    }

    /// The setup wizard finished (completed or skipped) — mark it done so it is
    /// never auto-offered again, and dismiss.
    func finishSetup() {
        if let db = currentDatabase {
            try? db.markSetupComplete(at: Date())
        }
        showSetupWizard = false
    }

    /// Re-run the setup wizard from Settings, for ANY project type, ignoring
    /// the completed marker (an explicit user request, not the once-per-project
    /// auto-offer).
    func rerunSetup() {
        showSetupWizard = true
    }

    /// Set the home person for the current project. Mutates a COPY of the
    /// project so every other field survives — the earlier memberwise-init
    /// rebuild dropped homeChapmanCode / archivedAt / expansionPolicy, so
    /// setting a home person (e.g. the setup wizard's Step 3, or the "Set as
    /// Home Person" context actions) silently wiped the home region and
    /// expansion policy. `db.setHomePerson` is a targeted UPDATE; the
    /// `saveProjectMeta` keeps the in-memory `currentProject` in sync.
    func setHomePerson(id: String) {
        guard let db = currentDatabase, var project = currentProject else { return }
        project.homePersonID = id
        do {
            try db.setHomePerson(id: id)
            try db.saveProjectMeta(project)
            currentProject = project
        } catch {
            errorMessage = "Failed to set home person: \(error.localizedDescription)"
        }
    }

    /// One-click fix for the `MarriedSurnameFromSpouseRule` finding — record a
    /// woman's married surname (derived from her linked spouse) so research
    /// pivots her death / probate / burial searches to it. Human-confirmed via
    /// the Tasks button; provenance tagged `manual.derived`.
    func setMarriedSurname(profileID: String, surname: String) {
        guard let db = currentDatabase,
              let profile = snapshot.profiles[profileID] else { return }
        do {
            _ = try db.editProfile(
                profileID: profileID,
                changes: [(.marriedSurname, profile.marriedSurname, surname)],
                dateChanges: [],
                source: SourceOrigin(identifier: "manual.derived"))
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
            successMessage = "Recorded married surname '\(surname)' — research will now search her death and probate records under it."
        } catch {
            errorMessage = "Could not set married surname: \(error.localizedDescription)"
        }
    }

    /// Fill an EMPTY birth year on `profileID` from a linked relative's census
    /// age. Written as a `.calculated` (CAL, ±1) date so its provenance reads
    /// "derived from the census", not an asserted precise date. Gap-fill only —
    /// refuses if a birth year already exists, so the Tasks one-click can never
    /// stomp known data even on a stale finding.
    func setBirthYearFromCensus(profileID: String, year: Int, censusYear: Int, sourceID: String?) {
        guard let db = currentDatabase,
              let profile = snapshot.profiles[profileID],
              profile.birthDate?.bestYear == nil else { return }
        do {
            let newDate = GenealogicalDate(parsing: "CAL \(year)")
            _ = try db.editProfile(
                profileID: profileID,
                changes: [],
                dateChanges: [(.birthDate, nil, newDate)],
                source: SourceOrigin(identifier: sourceID ?? "census.\(censusYear)"))
            snapshot = try db.buildSnapshot()
            runPostLoadAudit()
            successMessage = "Set \(profile.displayName)'s birth year to ~\(year) (calculated from the \(censusYear) census)."
        } catch {
            errorMessage = "Could not set birth year: \(error.localizedDescription)"
        }
    }
}

/// Errors raised by `AppState.importGEDCOM`. Currently just one case —
/// future ImportMergeView (DESIGN.md §7.5.11) will replace this with a
/// merge dialog rather than throwing.
nonisolated enum GEDCOMImportError: LocalizedError {
    case targetNotEmpty(existingCount: Int, incomingCount: Int)

    var errorDescription: String? {
        switch self {
        case .targetNotEmpty(let existing, let incoming):
            return "This project already has \(existing) profiles. " +
                "Importing \(incoming) GEDCOM profiles into a non-empty " +
                "tree would duplicate data. Future versions will offer a " +
                "merge dialog; for now, import into a fresh project instead."
        }
    }
}

/// Person-action requests routed from the global keyboard shortcut layer to
/// the TreeGraphView. M16.9. Equatable so SwiftUI can `.onChange` against the
/// optional value without bouncing on identical resets.
nonisolated enum PendingPersonAction: Equatable, Sendable {
    case add
    case addFamily
    case editSelected(profileID: String)
}

/// PROFILE_LIFECYCLE_SPEC Change 1 — the profile-card-owned actions that the
/// tree context menu raises via `AppState.pendingCardAction`. Kept minimal:
/// only the actions whose UI lives inside `ProfileDetailView` (its sheets /
/// edit mode). Research, Compare, Focus, and Set-as-Home route through their
/// own existing intents.
nonisolated enum ProfileCardAction: Equatable, Sendable {
    case edit, timeline, relationship, cleanse
}

nonisolated struct PendingCardAction: Equatable, Sendable {
    let profileID: String
    let action: ProfileCardAction
}
