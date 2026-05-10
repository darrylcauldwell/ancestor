import SwiftUI

/// Per-profile research view — the primary product.
/// Select a profile → choose mode → run pipeline → review clusters → accept facts.
struct ResearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry
    @State private var researchVM = ResearchViewModel()
    @State private var wholeTreeVM = WholeTreeResearchViewModel()
    @State private var profileSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            #if !FIELD_RESEARCHER_DISABLED
            if frIsRunning {
                FieldResearcherProgressView(
                    profileName: frProfileName,
                    isRunning: $frIsRunning,
                    status: $frStatus,
                    findingsCount: $frFindingsCount,
                    cost: $frCost,
                    onStop: { frIsRunning = false }
                )
            } else if let reviewID = pendingReviewProfileID, showPendingReview {
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
            #else
            // Field Researcher compiled out — direct path through the
            // deterministic research pipeline; no API-key flow.
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
            #endif
        }
        .navigationTitle(navigationTitle)
        .onChange(of: appState.researchProfileID) { _, profileID in
            guard let profileID,
                  let profile = appState.snapshot.profiles[profileID] else { return }
            appState.researchProfileID = nil
            Task {
                researchVM.appDatabase = appState.currentDatabase
                await researchVM.startResearch(
                    profile: profile,
                    snapshot: appState.snapshot,
                    registry: registry
                )
            }
        }
    }

    private var navigationTitle: String {
        if researchVM.isResearching {
            return "Researching \(researchVM.selectedProfile?.displayName ?? "")..."
        }
        if researchVM.currentResult != nil {
            return "Review: \(researchVM.selectedProfile?.displayName ?? "")"
        }
        return "Research"
    }

    // MARK: - Profile Selector

    private var profileSelector: some View {
        VStack(spacing: 0) {
            // Search + mode selector
            HStack(spacing: 12) {
                TextField("Search profiles...", text: $profileSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)

                Picker("Mode", selection: $researchVM.selectedMode) {
                    Text("Verify").tag(ResearchMode.verify)
                    Text("Extend").tag(ResearchMode.extend)
                    Text("Discover").tag(ResearchMode.discover)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Spacer()

                modeDescription

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
            }
            .padding()
            Divider()

            // Profile list
            let profiles = filteredProfiles
            if profiles.isEmpty {
                ContentUnavailableView {
                    Label("Research", systemImage: "magnifyingglass")
                } description: {
                    Text(appState.snapshot.profiles.isEmpty
                         ? "Import data to begin research."
                         : "No profiles match your search.")
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
        let searchable = isSearchable(profile)

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
                if !searchable {
                    Text("Not searchable (born after 1930)")
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Text("\(comp.score)/\(comp.maximum)")
                .font(AppTypography.cardMeta)
                .foregroundStyle(comp.score == comp.maximum ? .green : .orange)

            #if !FIELD_RESEARCHER_DISABLED
            if frVisible {
                Button(frIsRunning ? "Researching..." : "Field Research") {
                    startFieldResearch(profile: profile)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(frIsRunning || !searchable)

                if !DemoDataGenerator.isDemoMode {
                    Button("Review") {
                        pendingReviewProfileID = profile.id
                        showPendingReview = true
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
            #else
            // Review-pending-facts is shared between FR and the deterministic
            // pipeline; keep it visible.
            if !DemoDataGenerator.isDemoMode {
                Button("Review") {
                    pendingReviewProfileID = profile.id
                    showPendingReview = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            #endif

            Button("Research") {
                Task {
                    researchVM.appDatabase = appState.currentDatabase
                    await researchVM.startResearch(
                        profile: profile,
                        snapshot: appState.snapshot,
                        registry: registry
                    )
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .disabled(!searchable)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func isSearchable(_ profile: Profile) -> Bool {
        guard let birthYear = profile.birthDate?.earliest else { return true }
        return birthYear <= 1930
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

    // MARK: - Field Researcher Integration
    #if !FIELD_RESEARCHER_DISABLED
    @AppStorage("fieldResearcherEnabled") private var frEnabled = false
    @State private var frIsRunning = false
    @State private var frStatus = ""
    @State private var frFindingsCount = 0
    @State private var frCost = 0.0
    @State private var frProfileName = ""

    /// Whether the Field Researcher UI should be visible.
    /// Always true in demo mode so reviewers can see the full interface.
    private var frVisible: Bool {
        frEnabled || DemoDataGenerator.isDemoMode
    }

    private func startFieldResearch(profile: Profile) {
        // In demo mode, run a simulated session without API key or database
        if DemoDataGenerator.isDemoMode {
            startDemoFieldResearch(profile: profile)
            return
        }

        guard let apiKey = SettingsPlaceholderView.loadAPIKey(), !apiKey.isEmpty else {
            frStatus = "No API key — configure in Settings"
            return
        }
        guard let db = appState.currentDatabase else { return }

        frIsRunning = true
        frProfileName = profile.displayName
        frStatus = "Starting..."
        frFindingsCount = 0
        frCost = 0
        showPendingReview = false

        Task {
            let api = ClaudeAPIClient(
                apiKey: apiKey,
                model: UserDefaults.standard.string(forKey: "fieldResearcherModel") ?? "claude-sonnet-4-20250514"
            )
            let budget = UserDefaults.standard.double(forKey: "fieldResearcherBudget")
            let service = FieldResearcherService(
                api: api, db: db, snapshot: appState.snapshot,
                sourceInfoMap: registry.buildSourceInfoMap(),
                sessionBudget: budget > 0 ? budget : 0.50
            )

            let result = await service.research(profileID: profile.id)
            frIsRunning = false
            frFindingsCount = result.findings.count + result.narrativeFindings.count
            frCost = result.cost
            frStatus = "\(frFindingsCount) findings, \(result.leads.count) leads — $\(String(format: "%.2f", result.cost))"

            // Transition to pending facts review
            if frFindingsCount > 0 {
                pendingReviewProfileID = profile.id
                showPendingReview = true
            }
        }
    }

    /// Simulated Field Researcher session for demo mode.
    /// Shows realistic progress animation without calling the Claude API.
    private func startDemoFieldResearch(profile: Profile) {
        frIsRunning = true
        frProfileName = profile.displayName
        frStatus = "Building context..."
        frFindingsCount = 0
        frCost = 0
        showPendingReview = false

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            frStatus = "Turn 1/8 — reasoning..."
            try? await Task.sleep(for: .seconds(2))

            frFindingsCount = 1
            frCost = 0.03
            frStatus = "Turn 2/8 — reasoning..."
            try? await Task.sleep(for: .seconds(2))

            frFindingsCount = 2
            frCost = 0.07
            frStatus = "Turn 3/8 — reasoning..."
            try? await Task.sleep(for: .seconds(1.5))

            frFindingsCount = 3
            frCost = 0.11
            frStatus = "Turn 4/8 — reasoning..."
            try? await Task.sleep(for: .seconds(1.5))

            frFindingsCount = 4
            frCost = 0.14

            frIsRunning = false
            frStatus = "4 findings, 1 lead — $0.14 (demo)"
        }
    }
    #endif

    private var modeDescription: some View {
        Group {
            switch researchVM.selectedMode {
            case .verify:
                Text("Check existing data against sources")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
            case .extend:
                Text("Fill missing facts (deaths, marriages)")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
            case .discover:
                Text("Broad search from scratch")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
