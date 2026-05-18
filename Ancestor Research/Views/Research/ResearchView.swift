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
                    Task {
                        await wholeTreeVM.start(
                            snapshot: appState.snapshot,
                            registry: registry,
                            database: appState.currentDatabase
                        )
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(appState.snapshot.profiles.isEmpty)
                .help("Run research across every profile in the tree (long-running).")
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
                // Sort by completeness (least complete first)
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
}
