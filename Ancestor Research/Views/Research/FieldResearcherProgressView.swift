import SwiftUI

#if !FIELD_RESEARCHER_DISABLED

/// Live progress panel for a Field Researcher session.
/// Shows turn count, findings stream, cost tracking, and stop button.
struct FieldResearcherProgressView: View {
    let profileName: String
    @Binding var isRunning: Bool
    @Binding var status: String
    @Binding var findingsCount: Int
    @Binding var cost: Double
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // Profile header
            VStack(spacing: 4) {
                Text("Field Researcher")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Text(profileName)
                    .font(AppTypography.popoverTitle)
            }

            if isRunning {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
            }

            // Status
            Text(status)
                .font(AppTypography.cardBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Stats
            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text("\(findingsCount)")
                        .font(AppTypography.popoverTitle)
                    Text("Findings")
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 2) {
                    Text(String(format: "$%.2f", cost))
                        .font(AppTypography.popoverTitle)
                        .foregroundStyle(costColor)
                    Text("Cost")
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                }
            }

            if isRunning {
                Button("Stop") { onStop() }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var costColor: Color {
        if cost > 1.0 { return .red }
        if cost > 0.5 { return .orange }
        return .secondary
    }
}

#endif
