import SwiftUI

/// Live progress display during a research pipeline run.
/// Shows source status cards, iteration progress, and result counts.
struct ResearchProgressView: View {
    @Bindable var vm: ResearchViewModel
    @State private var clockTick: Int = 0  // forces 1-Hz re-render of dev clocks

    /// Per-phase latency budgets used by the dev-build dual-clock display.
    /// Iteration loop is bounded ~5 min; the optional prose-extraction
    /// phase runs MLX inference over 5+ multi-thousand-token pages and
    /// realistically takes 20+ minutes on Qwen 2.5 14B.
    private static let iterationBudgetSeconds: Int = 300
    private static let proseBudgetSeconds: Int = 1200

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Profile being researched
            if let profile = vm.selectedProfile {
                VStack(spacing: 4) {
                    Text("Researching")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                    Text(profile.displayName)
                        .font(AppTypography.popoverTitle)
                    Text(vm.selectedMode.rawValue.capitalized)
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)

                    #if DEBUG
                    phaseClocks
                        .id(clockTick)  // re-evaluate on each tick
                    #endif
                }
            }

            // Progress indicator — only spin while the pipeline is actually
            // running. Previously this rendered unconditionally, so the wheel
            // kept spinning after the title flipped to "Research complete"
            // and the user thought the run was stuck.
            if vm.isResearching {
                ProgressView()
                    .controlSize(.large)
            }

            if let message = vm.progressMessage {
                Text(message)
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
            }

            // Source status cards
            if !vm.sourceStatuses.isEmpty {
                VStack(spacing: 8) {
                    Text("Sources")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ], spacing: 8) {
                        ForEach(vm.sourceStatuses) { status in
                            sourceStatusCard(status)
                        }
                    }
                    .frame(maxWidth: 500)
                }
            }

            // Live activity feed — newest first, ~6 lines visible, scrollable.
            // Render unconditionally so the user sees the panel even before
            // the first event arrives (previously the panel popped in after
            // first event, which made it feel like nothing was happening).
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Activity")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                    Text("(\(vm.recentActivity.count))")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.tertiary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if vm.recentActivity.isEmpty {
                            Text("Waiting for sources to report…")
                                .font(AppTypography.badge)
                                .foregroundStyle(.tertiary)
                                .italic()
                        } else {
                            ForEach(Array(vm.recentActivity.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(AppTypography.badge)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxWidth: 500, minHeight: 80, maxHeight: 140)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
                // ScrollView doesn't clip to its glassEffect shape by
                // default — without this clipShape the activity rows
                // beyond row 6 spilled past the 140pt cap and rendered
                // on top of the sheet's footer.
                .clipShape(.rect(cornerRadius: 8))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        #if DEBUG
        // Drive the dual-phase clocks. Ticks once per second while the
        // run is active; each tick bumps `clockTick`, which the clocks'
        // `.id(clockTick)` modifier observes to recompute their elapsed
        // durations from `vm.iterationPhaseStart` and `vm.prosePhaseStart`.
        // Single timer feeds both clocks so they stay in lockstep.
        .task(id: vm.isResearching) {
            if vm.isResearching {
                clockTick = 0
                while !Task.isCancelled && vm.isResearching {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled && vm.isResearching {
                        clockTick &+= 1
                    }
                }
            }
        }
        #endif
    }

    #if DEBUG
    /// Dual-phase soft-deadline clocks visible in dev builds. Iteration
    /// loop has its own budget (~5 min); prose extraction (Discover/All
    /// only) has a separate ~20 min budget so the user can tell
    /// at a glance which phase is over time, rather than seeing one
    /// combined clock that's red whenever prose extraction runs.
    @ViewBuilder
    private var phaseClocks: some View {
        VStack(spacing: 2) {
            if let start = vm.iterationPhaseStart {
                let end = vm.iterationPhaseEnd ?? Date()
                let elapsed = Int(end.timeIntervalSince(start))
                clockRow(
                    label: "Iter",
                    elapsed: elapsed,
                    budget: Self.iterationBudgetSeconds
                )
            }
            if let start = vm.prosePhaseStart {
                let end = vm.prosePhaseEnd ?? Date()
                let elapsed = Int(end.timeIntervalSince(start))
                clockRow(
                    label: "Prose",
                    elapsed: elapsed,
                    budget: Self.proseBudgetSeconds
                )
            }
        }
    }

    private func clockRow(label: String, elapsed: Int, budget: Int) -> some View {
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        let budgetMinutes = budget / 60
        let budgetSeconds = budget % 60
        return Text(
            String(
                format: "%@ %d:%02d / %d:%02d",
                label, minutes, seconds, budgetMinutes, budgetSeconds
            )
        )
        .font(AppTypography.cardMeta)
        .monospacedDigit()
        .foregroundStyle(elapsed > budget ? .red : .secondary)
    }
    #endif

    private func sourceStatusCard(_ status: ResearchViewModel.SourceStatus) -> some View {
        HStack(spacing: 8) {
            statusIcon(status.state)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayName)
                    .font(AppTypography.cardBody)
                    .lineLimit(1)
                if let reason = status.reason {
                    // One-line preview — full text on hover via .help() —
                    // so a verbose error body (e.g. an HTML 500 payload) can't
                    // explode the card height and break grid alignment.
                    Text(reason)
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(reason)
                }
            }

            Spacer()

            if status.resultCount > 0 {
                Text("\(status.resultCount)")
                    .font(AppTypography.cardMeta)
                    .fontWeight(.semibold)
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    @ViewBuilder
    private func statusIcon(_ state: ResearchViewModel.SourceState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        case .searching:
            ProgressView()
                .controlSize(.small)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

