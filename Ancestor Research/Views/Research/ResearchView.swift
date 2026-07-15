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
    /// Lifted to ContentView so research can be started from any tab without
    /// the user being forced into the Research tab. ContentView owns the state;
    /// this view binds to it for display.
    @Bindable var researchVM: ResearchViewModel
    @State private var wholeTreeVM = WholeTreeResearchViewModel()
    @State private var profileSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            if let reviewID = pendingReviewProfileID, showPendingReview {
                PendingFactsReviewView(profileID: reviewID)
            } else if wholeTreeVM.isRunning {
                wholeTreeProgress
            } else if researchVM.isResearching {
                ResearchProgressView(vm: researchVM)
            } else if let result = researchVM.currentResult {
                ClusterReviewView(vm: researchVM, result: result)
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
        .onAppear {
            consumePendingReviewRequest()
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
        return "Triage"
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
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)
            Divider()

            // Profile list — sorted least-complete first so the user can see
            // at a glance which profiles still need attention. The per-row
            // "Research" button has been removed: research is started from
            // the profile popover in the Tree tab so the depth/scope picker
            // sheet appears with smart defaults for each subject.
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

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(AppTypography.cardTitle)
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
                if !comp.missing.isEmpty {
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

            // Review pending facts from a previous run. The Research entry
            // point lives on the Tree tab; this tab surfaces the *triage* action.
            Button("Review") {
                pendingReviewProfileID = profile.id
                showPendingReview = true
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
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
                // everything (most-pending first) so the triage work is at
                // the top of the list, then the existing least-complete-first
                // ordering for the rest.
                let pa = pendingCounts[a.id] ?? 0
                let pb = pendingCounts[b.id] ?? 0
                if pa != pb { return pa > pb }
                let ca = appState.snapshot.completeness(for: a.id)
                let cb = appState.snapshot.completeness(for: b.id)
                if ca.score != cb.score { return ca.score < cb.score }
                return a.displayName < b.displayName
            }
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
}
