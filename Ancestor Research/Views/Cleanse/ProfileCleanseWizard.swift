import SwiftUI

/// CLEANSE_WIZARD_SPEC §3 — sequential one-finding-at-a-time wizard.
///
/// Two entry points share this view:
///   - `.singleProfile(id)` — Cleanse button on profile detail
///   - `.allProfiles`       — Cleanse-all from Settings, depth-first
///
/// The queue is generated once when the sheet appears. Resolving a finding
/// advances the cursor; the engine\u{2019}s re-evaluation only runs when the user
/// reopens the wizard, per the spec\u{2019}s "no mid-flight re-evaluation" rule.
@MainActor
struct ProfileCleanseWizard: View {

    enum Mode: Sendable {
        case singleProfile(String)
        case allProfiles
    }

    let mode: Mode

    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss

    /// Flat (profile, finding) queue. Built once on appear; the cursor walks
    /// linearly. Skipping just advances; applying mutates the database and
    /// then advances. Marking unresolvable writes the flag and advances.
    @State private var queue: [QueueItem] = []
    @State private var cursor: Int = 0
    @State private var errorMessage: String?
    @State private var actionsApplied: Int = 0

    // Per-finding ephemeral UI state, reset whenever the cursor advances.
    @State private var freeformLocationText: String = ""
    @State private var selectedQuarter: String = "Q1"
    @State private var selectedProposalIDs: Set<String> = []

    private var engine: CleanseEngine? {
        guard let db = appState.currentDatabase else { return nil }
        return CleanseEngine(
            database: db,
            snapshot: { appState.snapshot },
            sourceInfoMap: registry.buildSourceInfoMap()
        )
    }

    private var currentItem: QueueItem? {
        guard cursor < queue.count else { return nil }
        return queue[cursor]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let item = currentItem {
                CleanseFindingStep(
                    profile: item.profile,
                    finding: item.finding,
                    freeformText: $freeformLocationText,
                    selectedQuarter: $selectedQuarter,
                    selectedProposalIDs: $selectedProposalIDs,
                    onApplyMatch: { entry in
                        runAction(.applyLocationMatch(entry), on: item.finding)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()

                Divider()
                actionBar(for: item.finding)
            } else {
                completionState
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear(perform: rebuildQueue)
        .alert(
            "Couldn\u{2019}t apply",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: {
                Button("OK") { errorMessage = nil }
            },
            message: {
                Text(errorMessage ?? "")
            }
        )
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.title3)
                    .fontWeight(.semibold)
                if !queue.isEmpty {
                    Text("Finding \(min(cursor + 1, queue.count)) of \(queue.count)")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var headerTitle: String {
        switch mode {
        case .singleProfile(let id):
            return appState.snapshot.profiles[id]?.displayName ?? "Cleanse"
        case .allProfiles:
            return "Cleanse all profiles"
        }
    }

    // MARK: - Action bar

    @ViewBuilder
    private func actionBar(for finding: CleanseFinding) -> some View {
        HStack {
            Button("Mark unresolvable") {
                runAction(.markUnresolvable, on: finding)
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            Spacer()

            Button("Skip") {
                runAction(.skip, on: finding)
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            applyButton(for: finding)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func applyButton(for finding: CleanseFinding) -> some View {
        switch finding {
        case .ambiguousLocation:
            // Apply happens via tap-to-pick on the candidate rows inside
            // CleanseFindingStep — the action bar doesn\u{2019}t need an extra button.
            Text("Pick a candidate above")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.tertiary)

        case .unmatchedLocation:
            Button("Save edit") {
                runAction(.applyLocationFreeform(freeformLocationText), on: finding)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .disabled(freeformLocationText.trimmingCharacters(in: .whitespaces).isEmpty)

        case .unconfirmedLocation(_, _, let match):
            Button("Confirm match") {
                runAction(.applyLocationMatch(match), on: finding)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)

        case .missingParentFromBirthRecord(_, let proposals):
            Button("Accept selected") {
                let chosen = proposals.filter { selectedProposalIDs.contains($0.id) }
                runAction(.applyProposedRelatives(chosen), on: finding)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .disabled(selectedProposalIDs.isEmpty)

        case .bareYearDate:
            Button("Apply quarter") {
                runAction(.applyBareYearQuarter(selectedQuarter), on: finding)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)

        case .givenNameContainsMiddle(_, _, let first, let middle):
            Button("Apply split") {
                runAction(.applyGivenMiddleSplit(first: first, middle: middle), on: finding)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
    }

    // MARK: - Completion

    @ViewBuilder
    private var completionState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(actionsApplied == 0 ? "Nothing to cleanse" : "All done")
                .font(.title3)
                .fontWeight(.semibold)
            Text(completionSubtitle)
                .font(AppTypography.cardBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Close") { dismiss() }
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var completionSubtitle: String {
        if queue.isEmpty {
            return "No outstanding findings for this scope. Profiles look clean."
        }
        if actionsApplied == 0 {
            return "You skipped every finding. Reopen the wizard any time to revisit them."
        }
        return "Applied \(actionsApplied) of \(queue.count) findings. Skipped findings will reappear next time."
    }

    // MARK: - Queue management

    private func rebuildQueue() {
        guard let engine else {
            queue = []
            return
        }
        switch mode {
        case .singleProfile(let id):
            guard let profile = appState.snapshot.profiles[id] else {
                queue = []
                return
            }
            queue = engine.findings(for: id).map { QueueItem(profile: profile, finding: $0) }
        case .allProfiles:
            queue = engine.findingsForAllProfiles().flatMap { entry in
                entry.findings.map { QueueItem(profile: entry.profile, finding: $0) }
            }
        }
        cursor = 0
        resetPerFindingState(for: queue.first?.finding)
    }

    private func runAction(_ action: CleanseAction, on finding: CleanseFinding) {
        guard let engine else { return }
        do {
            try engine.apply(action, to: finding)
            // Refresh the snapshot so downstream views (and any in-queue
            // findings that read profile state) see the latest data. Skip
            // and markUnresolvable don\u{2019}t mutate the profile but doing the
            // refresh unconditionally keeps the wizard\u{2019}s mental model simple.
            if let db = appState.currentDatabase {
                appState.snapshot = (try? db.buildSnapshot()) ?? appState.snapshot
            }
            if case .skip = action {} else {
                actionsApplied += 1
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        advance()
    }

    private func advance() {
        cursor += 1
        resetPerFindingState(for: currentItem?.finding)
    }

    private func resetPerFindingState(for finding: CleanseFinding?) {
        switch finding {
        case .unmatchedLocation(_, let raw, _)?:
            freeformLocationText = raw
        default:
            freeformLocationText = ""
        }
        selectedQuarter = "Q1"
        if case .bareYearDate(_, _, _, let available?)? = finding {
            selectedQuarter = available
        }
        if case .missingParentFromBirthRecord(_, let proposals)? = finding {
            // Pre-select all proposals by default; the user uses checkboxes
            // to deselect any they want to skip.
            selectedProposalIDs = Set(proposals.map(\.id))
        } else {
            selectedProposalIDs = []
        }
    }
}

private struct QueueItem: Identifiable {
    let profile: Profile
    let finding: CleanseFinding
    var id: String { "\(profile.id):\(finding.id)" }
}

/// Sheet-item wrapper used by callers that present the wizard via
/// `.sheet(item:)` instead of `.sheet(isPresented:)`. The wrapped mode\u{2019}s
/// identifier makes the wrapper Identifiable for SwiftUI.
struct CleansePresentation: Identifiable, Hashable, Sendable {
    let id: String
    let mode: ProfileCleanseWizard.Mode

    static func singleProfile(_ profileID: String) -> CleansePresentation {
        .init(id: "profile:\(profileID)", mode: .singleProfile(profileID))
    }

    static let allProfiles = CleansePresentation(id: "all", mode: .allProfiles)

    static func == (lhs: CleansePresentation, rhs: CleansePresentation) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
