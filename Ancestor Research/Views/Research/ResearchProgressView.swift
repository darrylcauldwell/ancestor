import SwiftUI

/// Live progress display during a research pipeline run.
/// Shows source status cards, iteration progress, and result counts.
struct ResearchProgressView: View {
    @Bindable var vm: ResearchViewModel

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
                }
            }

            // Progress indicator
            ProgressView()
                .controlSize(.large)

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

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func sourceStatusCard(_ status: ResearchViewModel.SourceStatus) -> some View {
        HStack(spacing: 8) {
            statusIcon(status.state)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayName)
                    .font(AppTypography.cardBody)
                    .lineLimit(1)
                if let reason = status.reason {
                    Text(reason)
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)
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
