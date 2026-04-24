import SwiftUI

/// Resolve disputed fields where sources disagree.
struct ConflictResolutionView: View {
    @Environment(AppState.self) private var appState
    let profile: Profile
    let dispute: FieldDispute

    @State private var selectedSourceIndex: Int?
    @State private var manualValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Text("Resolve Dispute")
                .font(.title2)
                .fontWeight(.bold)

            Text("\(profile.displayName) — \(dispute.field.rawValue)")
                .foregroundStyle(.secondary)

            Text(dispute.reason.description)
                .font(.caption)
                .foregroundStyle(.orange)

            Divider()

            // Competing sources
            Text("Sources disagree:")
                .font(.headline)

            ForEach(Array(dispute.competingSources.enumerated()), id: \.offset) { index, source in
                HStack {
                    RadioButton(isSelected: selectedSourceIndex == index) {
                        selectedSourceIndex = index
                        manualValue = ""
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.raw)
                            .font(.body)
                        Text(source.origin.identifier.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                        Text("Added \(source.addedAt.formatted())")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Manual entry option
            HStack {
                RadioButton(isSelected: selectedSourceIndex == nil && !manualValue.isEmpty) {
                    selectedSourceIndex = nil
                }
                TextField("Or enter value manually...", text: $manualValue)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: manualValue) {
                        if !manualValue.isEmpty { selectedSourceIndex = nil }
                    }
            }

            Spacer()

            // Actions
            HStack(spacing: 16) {
                Button("Defer") {
                    // Mark as deferred — come back later
                }
                .keyboardShortcut(.cancelAction)

                Button("Resolve") {
                    // Apply resolution
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSourceIndex == nil && manualValue.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 350)
    }
}

/// Simple radio button view.
private struct RadioButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

nonisolated extension DisputeReason {
    var description: String {
        switch self {
        case .noOverlap: "Date ranges do not overlap"
        case .approximateOverlap: "Both dates are approximate with only partial overlap"
        case .valueMismatch: "Values differ between sources"
        }
    }
}
