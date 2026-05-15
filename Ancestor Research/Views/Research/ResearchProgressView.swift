import SwiftUI

/// Live progress display during a research pipeline run.
/// Shows source status cards, iteration progress, and result counts.
struct ResearchProgressView: View {
    @Bindable var vm: ResearchViewModel
    @State private var elapsedSeconds: Int = 0

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
                    // 5-minute clock — visible in dev builds per §6.1
                    let minutes = elapsedSeconds / 60
                    let seconds = elapsedSeconds % 60
                    Text(String(format: "%d:%02d / 5:00", minutes, seconds))
                        .font(AppTypography.cardMeta)
                        .monospacedDigit()
                        .foregroundStyle(elapsedSeconds > 300 ? .red : .secondary)
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
        // Drive the 5-minute soft-deadline clock. Starts when the view
        // appears, stops when it goes away (or when research completes —
        // we leave the final reading visible after isResearching flips).
        .task(id: vm.isResearching) {
            if vm.isResearching {
                elapsedSeconds = 0
                while !Task.isCancelled && vm.isResearching {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled && vm.isResearching {
                        elapsedSeconds += 1
                    }
                }
            }
        }
        #endif
    }

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

