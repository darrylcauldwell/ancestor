import SwiftUI

/// Triage landing — review pending clusters / leads from past research runs,
/// trigger whole-tree research, or jump into per-profile pending-facts review.
///
/// Per-profile research itself is now kicked off contextually from the tree
/// popover (which presents `ResearchConfigSheet` with mode/scope + a live
/// progress sheet). This tab is the place results land for the user to act on,
/// not where individual runs are started — that's why the depth/scope pickers
/// and per-row "Research" button have been removed.
struct ResearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry
    @Environment(ReviewWindowBroker.self) private var reviewWindowBroker
    @Environment(\.openWindow) private var openWindow
    /// Lifted to ContentView so research can be started from any tab without
    /// the user being forced into the Research tab. ContentView owns the state;
    /// this view binds to it for display.
    @Bindable var researchVM: ResearchViewModel
    @State private var wholeTreeVM = WholeTreeResearchViewModel()
    /// Which sidebar tab this instance serves (owner direction
    /// 2026-07-15): .triage renders the Research Findings queue as its
    /// resting state; .research renders the launcher (profiles ranked by
    /// gaps). Higher-priority states (pending review, live run, cluster
    /// review) render in both.
    enum Role { case triage, research }
    var role: Role = .triage

    @State private var profileSearchText = ""
    /// How many profiles the FreeBMD citation audit flags — drives the
    /// "Backfill FreeBMD links" affordance. A DB scan, so computed off the
    /// tree-content revision, never per render.
    @State private var freeBMDGapCount = 0

    var body: some View {
        VStack(spacing: 0) {
            if let reviewID = pendingReviewProfileID, showPendingReview {
                // Exit affordance lives HERE: PendingFactsReviewView has
                // none of its own, and an empty pending list left the user
                // trapped (owner report 2026-07-15).
                HStack {
                    Spacer()
                    Button("Done") {
                        showPendingReview = false
                        pendingReviewProfileID = nil
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
                .padding([.horizontal, .top])
                PendingFactsReviewView(profileID: reviewID)
            } else if wholeTreeVM.isRunning {
                wholeTreeProgress
            } else if researchVM.isResearching {
                ResearchProgressView(vm: researchVM)
            } else if let result = researchVM.currentResult {
                // Exit affordance for the Triage drill-down — same trap as the
                // PendingFactsReviewView header above: the review renders
                // whenever the shared VM carries a result (including after tab
                // switches), and ClusterReviewView's own "New Research" button
                // doesn't read as "back to the queue" (owner report 2026-07-17,
                // Annie Cauldwell). reset() clears only in-memory UI state;
                // accept/discard decisions are already persisted as they're made.
                if role == .triage || researchVM.selectedProfile != nil {
                HStack {
                    if role == .triage {
                        Button {
                            researchVM.reset()
                        } label: {
                            Label("Back to queue", systemImage: "chevron.left")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                    Spacer()
                    // Re-research this same person without leaving the review
                    // (owner request 2026-07-24 — applying an anchor record
                    // like Lily May's 1907 birth sharpens the next run, but the
                    // old flow dead-ended at "Back to queue", forcing a manual
                    // re-search). Runs on the FRESH profile from the just-
                    // rebuilt snapshot, so the records you applied are in play.
                    if let researchID = researchVM.selectedProfile?.id {
                        Button {
                            Task {
                                guard let fresh = appState.snapshot.profiles[researchID] else { return }
                                await researchVM.startResearch(
                                    profile: fresh,
                                    snapshot: appState.snapshot,
                                    registry: registry
                                )
                            }
                        } label: {
                            Label("Re-research", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Research this person again — picks up records you just applied")
                    }
                    // Pop the review out into its own movable window so the
                    // tree stays navigable here (owner request 2026-07-21 —
                    // a thin subject like Mrs Bown is judged from her
                    // family's profiles). Profile reviews only: lead-only
                    // reviews have no profileID to key the window on.
                    if let popOutID = researchVM.selectedProfile?.id {
                        Button {
                            reviewWindowBroker.stageHandoff(profileID: popOutID, result: result)
                            openWindow(id: "record-review", value: popOutID)
                            // This window returns to its resting state and
                            // shows the tree — the whole point of popping out.
                            researchVM.reset()
                            appState.requestSidebarTab = .tree
                        } label: {
                            Label("Open in Window", systemImage: "macwindow.on.rectangle")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Move this review to its own window and free this one for the tree")
                    }
                }
                .padding([.horizontal, .top])
                }
                ClusterReviewView(vm: researchVM, result: result)
            } else if role == .triage {
                // Triage's resting state IS the queue. Drill-down sets the
                // VM quartet, so the currentResult branch above renders the
                // per-profile review; vm.reset() lands back here. A segmented
                // control switches between the per-record Findings queue and
                // the read-only Possible People panel (LEAD_DISCOVERY_SPEC
                // Phase 1) — two views of the same lead pool.
                triageResting
            } else {
                profileSelector
            }
        }
        .navigationTitle(navigationTitle)
        // Research-trigger onChange handlers live on ContentView so they fire
        // regardless of which tab is currently visible — letting the profile-
        // detail sheet kick off a run without forcing a tab switch.
        //
        // Pending-review deep link (profile panel's pending badge): consume
        // on change AND on appear — the request is usually raised while this
        // tab isn't instantiated yet, so `.onChange` alone would miss it.
        .onChange(of: appState.requestPendingReviewProfileID) { _, _ in
            consumePendingReviewRequest()
        }
        .onChange(of: appState.requestPossiblePeopleProfileID) { _, _ in
            consumePossiblePeopleRequest()
        }
        .onAppear {
            consumePendingReviewRequest()
            consumePossiblePeopleRequest()
            reloadPendingCounts()
        }
        // Returning from a per-profile review (accept/reject changed counts)
        // refreshes the selector's badges and ordering.
        .onChange(of: showPendingReview) { _, showing in
            if !showing { reloadPendingCounts() }
        }
    }

    private func consumePendingReviewRequest() {
        guard let requested = appState.requestPendingReviewProfileID else { return }
        appState.requestPendingReviewProfileID = nil
        pendingReviewProfileID = requested
        showPendingReview = true
    }

    /// Deep-link from a profile's "Possible People (N)" section: land on the
    /// Possible People panel scoped to that person (POSSIBLE_PEOPLE_CONTEXT_SPEC).
    private func consumePossiblePeopleRequest() {
        guard let requested = appState.requestPossiblePeopleProfileID else { return }
        appState.requestPossiblePeopleProfileID = nil
        possiblePeopleScopeProfileID = requested
        triageMode = .people
    }

    /// One GROUP-BY query for all profiles' pending-review counts — drives
    /// the row badges and the needs-review-first sort. An overnight watcher
    /// campaign can queue findings across dozens of profiles; without this
    /// the selector was an unmarked list of 200+ names.
    private func reloadPendingCounts() {
        pendingCounts = appState.currentDatabase?.pendingFactCountsByProfile() ?? [:]
    }

    private var navigationTitle: String {
        if researchVM.isResearching {
            return "Researching \(researchVM.selectedProfile?.displayName ?? "")..."
        }
        if researchVM.currentResult != nil {
            return "Review: \(researchVM.selectedProfile?.displayName ?? "")"
        }
        return role == .triage ? "Triage" : "Research"
    }

    // MARK: - Profile Selector

    private var profileSelector: some View {
        VStack(spacing: 0) {
            // Toolbar: profile filter + whole-tree research entry. Depth/Scope
            // pickers used to live here but are now part of `ResearchConfigSheet`
            // shown when the user kicks off research from the tree popover —
            // per-run settings travel with the run instead of being sticky on
            // this tab.
            HStack(spacing: 12) {
                TextField("Filter profiles…", text: $profileSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)

                Spacer()

                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Review everything recent research runs found — clusters, leads, conflicts — reconstructed from the database.")

                Button("Research All") {
                    // Confirmation-gated: a whole-tree run is hours long and
                    // consumes daily source budgets (FreeBMD especially) —
                    // it must never start from a single accidental click.
                    // (Live incident 2026-07-14: the button sits where the
                    // pending-review screen's "Refresh" renders, and a user
                    // expecting review kicked off a 212-profile run.)
                    showResearchAllConfirmation = true
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(appState.snapshot.profiles.isEmpty)
                .help("Run research across every profile in the tree (long-running).")
                .confirmationDialog(
                    "Research all \(appState.snapshot.profiles.count) profiles?",
                    isPresented: $showResearchAllConfirmation
                ) {
                    Button("Start Whole-Tree Research") {
                        Task {
                            await wholeTreeVM.start(
                                snapshot: appState.snapshot,
                                registry: registry,
                                database: appState.currentDatabase
                            )
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This runs for a long time and consumes daily source budgets (FreeBMD allows one careful pass per day). You can cancel mid-run.")
                }

                // FREEBMD_CITATION_BACKFILL_SPEC Change 4 — a scoped, throttled
                // backfill of the entry links the citation audit flags. Reuses
                // the whole-tree engine (breaker-aware pipeline + Change 3
                // enrichment), auto-continuing over just the flagged profiles.
                // Shown only when there's a gap and no run is active.
                if freeBMDGapCount > 0 && !wholeTreeVM.isRunning {
                    Button("Backfill FreeBMD links (\(freeBMDGapCount))") {
                        let ids = Set(appState.freeBMDCitationGapFindings().map(\.profileID))
                        Task {
                            await wholeTreeVM.start(
                                snapshot: appState.snapshot,
                                registry: registry,
                                database: appState.currentDatabase,
                                restrictedTo: ids,
                                autoContinue: true)
                            freeBMDGapCount = appState.freeBMDCitationGapFindings().count
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Re-research the \(freeBMDGapCount) profile(s) whose applied FreeBMD records lack a direct entry link, one at a time, to capture the links. Gentle on FreeBMD — the pipeline's daily budget and circuit-breaker apply; cancellable mid-run.")
                }
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)
            .task(id: appState.treeContentRevision) {
                freeBMDGapCount = appState.freeBMDCitationGapFindings().count
            }
            Divider()

            // Profile list — the research launcher: real people ranked
            // least-complete first, placeholder stubs demoted. Per-row
            // "Research" opens the config sheet with smart defaults
            // (reinstated 2026-07-15 — review lives in Research Findings,
            // so this page's one job is starting research).
            let profiles = filteredProfiles
            if profiles.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to triage", systemImage: "checklist.checked")
                } description: {
                    Text(appState.snapshot.profiles.isEmpty
                         ? "Import data or build a tree to begin."
                         : "No profiles match your filter.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(profiles) { profile in
                            profileRow(profile)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private func profileRow(_ profile: Profile) -> some View {
        let comp = appState.snapshot.completeness(for: profile.id)

        let isStub = Self.isPlaceholderStub(profile)
        let name = profile.displayName.trimmingCharacters(in: .whitespaces)
        let title = (name.isEmpty || name == "?") ? "(unnamed placeholder)" : name

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(AppTypography.cardTitle)
                    if isStub {
                        Text("placeholder")
                            .font(AppTypography.badge)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(.capsule)
                            .foregroundStyle(.secondary)
                            .help("Created to hold a relationship (e.g. a mother's maiden name from a birth index). Research can recover the given name and dates.")
                    }
                    if let year = profile.birthDate?.bestYear {
                        Text("b. \(String(year))")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                    if let year = profile.deathDate?.bestYear {
                        Text("d. \(String(year))")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                }
                if isStub {
                    Text("Holds a relationship — created from record evidence. Research it to recover the given name and dates.")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.secondary)
                } else if !comp.missing.isEmpty {
                    Text("Missing: \(comp.missing.map(\.shortLabel).joined(separator: ", "))")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Pending-review badge — the row-level signal for "this profile
            // has findings waiting". Same styling as the profile panel's
            // badge so the two surfaces read as one system.
            if let pending = pendingCounts[profile.id], pending > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(pending) to review")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.18))
                .foregroundStyle(.orange)
                .clipShape(.capsule)
                .accessibilityLabel("\(pending) findings to review")
            }

            Text("\(comp.score)/\(comp.maximum)")
                .font(AppTypography.cardMeta)
                .foregroundStyle(comp.score == comp.maximum ? .green : .orange)

            // This list is the RESEARCH launcher (owner direction
            // 2026-07-15: review lives in Research Findings; this page is
            // "profiles with gaps that need research"). Review appears
            // only when the profile actually has pending items — an
            // always-on Review button led into an empty view.
            if let pending = pendingCounts[profile.id], pending > 0 {
                Button("Review") {
                    pendingReviewProfileID = profile.id
                    showPendingReview = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            Button("Research") {
                appState.researchConfigProfile = profile
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .help("Open the research sheet for this profile with smart defaults.")
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var filteredProfiles: [Profile] {
        appState.snapshot.profiles.values
            .filter { profile in
                if profileSearchText.isEmpty { return true }
                return profile.displayName.localizedCaseInsensitiveContains(profileSearchText)
            }
            .sorted { a, b in
                // Needs-review first: profiles with pending facts outrank
                // everything (most-pending first). Then REAL people before
                // placeholder stubs — a surname-only mother materialised
                // from a GRO maiden-name field is connective tissue, not
                // the next research subject; ranking stubs above named
                // ancestors made the list read as broken (owner feedback
                // 2026-07-15). Then least-complete-first, then name.
                let pa = pendingCounts[a.id] ?? 0
                let pb = pendingCounts[b.id] ?? 0
                if pa != pb { return pa > pb }
                let stubA = Self.isPlaceholderStub(a)
                let stubB = Self.isPlaceholderStub(b)
                if stubA != stubB { return !stubA }
                let ca = appState.snapshot.completeness(for: a.id)
                let cb = appState.snapshot.completeness(for: b.id)
                if ca.score != cb.score { return ca.score < cb.score }
                // Final tiebreak on the stable unique id, NOT just displayName.
                // `sorted()` isn't stable and the source is `profiles.values`
                // (an unordered dictionary re-enumerated on every snapshot
                // rebuild). Profiles sharing a display name — common among
                // placeholder stubs ("Unknown", "?", bare surnames) — used to
                // tie on every key and shuffle positions on each 3s refresh
                // ("continually reordering", owner report 2026-07-16). Ordering
                // by id makes the comparator a strict total order, so the list
                // is identical across rebuilds unless the data actually changes.
                if a.displayName != b.displayName { return a.displayName < b.displayName }
                return a.id < b.id
            }
    }

    /// A structural placeholder: no given name and no dates — typically a
    /// surname-only parent/spouse stub materialised from record evidence
    /// (mother's maiden name on a GRO index, a marriage partner surname),
    /// or a fully unnamed relationship holder.
    private static func isPlaceholderStub(_ profile: Profile) -> Bool {
        let noGivenName = (profile.firstName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || profile.firstName == "?"
        return noGivenName && profile.birthDate == nil && profile.deathDate == nil
    }

    // MARK: - Whole-Tree Progress

    private var wholeTreeProgress: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Whole-Tree Research")
                        .font(AppTypography.popoverTitle)
                    Text(wholeTreeVM.progressSummary)
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.secondary)
                    if let profile = wholeTreeVM.currentProfile {
                        Text("Current: \(profile.displayName)")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if wholeTreeVM.waitingForReview {
                    Button("Continue") { wholeTreeVM.continueToNext() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
                Button("Cancel") { wholeTreeVM.cancel() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .padding()
            Divider()

            if wholeTreeVM.waitingForReview, let result = wholeTreeVM.currentResult {
                ClusterReviewView(vm: researchVM, result: result)
            } else {
                ProgressView("Researching \(wholeTreeVM.currentProfile?.displayName ?? "")...")
                    .frame(maxHeight: .infinity)
            }

            if let reason = wholeTreeVM.stopReason, !wholeTreeVM.isRunning {
                Text("Stopped: \(reason)")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.orange)
                    .padding()
            }
        }
    }

    // MARK: - Pending facts review (shared with deterministic pipeline)

    @State private var showPendingReview = false
    @State private var pendingReviewProfileID: String?

    // MARK: - Research All confirmation

    @State private var showResearchAllConfirmation = false

    // MARK: - Pending-review counts (Triage selector badges + sort)

    @State private var pendingCounts: [String: Int] = [:]

    // MARK: - Campaign review (CAMPAIGN_REVIEW_SPEC Change 6)

    // MARK: - Triage resting state (Findings queue ↔ Possible People)

    /// Which triage surface is showing. `.findings` is the per-record review
    /// queue (`BulkReviewView`); `.people` is the read-only discovery panel
    /// (`PossiblePeopleView`, LEAD_DISCOVERY_SPEC Phase 1).
    private enum TriageMode: String, CaseIterable {
        case findings = "Findings"
        case people = "Possible People"
    }
    @State private var triageMode: TriageMode = .findings
    /// Set by the profile deep-link to scope the Possible People panel to one
    /// person; nil = the full pool. Cleared when the user switches to Findings.
    @State private var possiblePeopleScopeProfileID: String?

    private var triageResting: some View {
        VStack(spacing: 0) {
            Picker("Triage mode", selection: $triageMode) {
                ForEach(TriageMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch triageMode {
            case .findings:
                BulkReviewView(
                    vm: researchVM,
                    onOpenProfileReview: { profile, result in
                        researchVM.appDatabase = appState.currentDatabase
                        researchVM.selectedProfile = profile
                        researchVM.currentResult = result
                    },
                    onDone: nil
                )
            case .people:
                if let scopeID = possiblePeopleScopeProfileID {
                    scopedPossiblePeopleHeader(scopeID)
                }
                PossiblePeopleView(
                    onResearch: { lead in
                        Task { @MainActor in
                            researchVM.appDatabase = appState.currentDatabase
                            await researchVM.startResearch(
                                lead: lead,
                                snapshot: appState.snapshot,
                                registry: registry
                            )
                        }
                    },
                    scope: possiblePeopleScopeProfileID.map { .profile($0) } ?? .all
                )
                // Re-instantiate the panel when the scope changes so it
                // recomputes for the new person / the full pool.
                .id(possiblePeopleScopeProfileID ?? "all")
            }
        }
        // Switching to Findings clears any profile scope so returning to
        // Possible People shows the full pool again.
        .onChange(of: triageMode) { _, mode in
            if mode == .findings { possiblePeopleScopeProfileID = nil }
        }
    }

    /// Banner shown when the panel is scoped to one profile via the deep-link —
    /// names the person and offers a one-tap return to the full pool.
    @ViewBuilder
    private func scopedPossiblePeopleHeader(_ profileID: String) -> some View {
        let name = appState.snapshot.profiles[profileID]?.displayName ?? "this person"
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            Text("Scoped to \(name)")
                .font(AppTypography.cardMeta)
            Spacer()
            Button {
                possiblePeopleScopeProfileID = nil
            } label: {
                Label("Show all", systemImage: "xmark.circle")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

}
