import SwiftUI

/// Sheet UI for the relationship calculator. User picks a "From" and a "To"
/// profile; we display the kinship label plus the path through the lowest
/// common ancestor as a list of names.
///
/// Pre-fills "From" with the project's home person and "To" with the optional
/// `initialTargetID` (typically the currently-selected profile).
struct RelationshipCalculatorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var fromID: String?
    @State private var toID: String?

    init(initialFromID: String? = nil, initialTargetID: String? = nil) {
        _fromID = State(initialValue: initialFromID)
        _toID = State(initialValue: initialTargetID)
    }

    private var snapshot: FamilyGraphSnapshot { appState.snapshot }

    private var description: Description? {
        guard let from = fromID, let to = toID else { return nil }
        return RelationshipCalculator.describe(from: from, to: to, snapshot: snapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pickers
                    if let desc = description {
                        Divider()
                        result(desc)
                    } else if fromID != nil && toID != nil {
                        Divider()
                        Text("One of the selected profiles is missing.")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Relationship Calculator")
                .font(.title3).fontWeight(.semibold)
            Text("Compare two people in your tree to see how they're related.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("From")
                    .font(AppTypography.controlLabel)
                    .foregroundStyle(.secondary)
                ProfilePickerField(label: "From", snapshot: snapshot, selectedID: $fromID)
            }

            HStack {
                Spacer()
                Button {
                    swap(&fromID, &toID)
                } label: {
                    Label("Swap", systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(fromID == nil && toID == nil)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("To")
                    .font(AppTypography.controlLabel)
                    .foregroundStyle(.secondary)
                ProfilePickerField(label: "To", snapshot: snapshot, selectedID: $toID)
            }
        }
    }

    @ViewBuilder
    private func result(_ desc: Description) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Relationship")
                    .font(AppTypography.controlLabel)
                    .foregroundStyle(.secondary)
                Text(desc.label)
                    .font(.title2).fontWeight(.semibold)
            }

            if !desc.path.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Path")
                        .font(AppTypography.controlLabel)
                        .foregroundStyle(.secondary)
                    ForEach(Array(desc.path.enumerated()), id: \.offset) { index, id in
                        HStack(spacing: 6) {
                            Image(systemName: "person.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            if let profile = snapshot.profiles[id] {
                                Text(profile.displayName)
                                    .font(AppTypography.cardBody)
                                if let year = profile.birthDate?.bestYear {
                                    Text("b. \(String(year))")
                                        .font(AppTypography.cardMeta)
                                        .foregroundStyle(.tertiary)
                                }
                            } else {
                                Text(id)
                                    .font(AppTypography.cardBody)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.leading, CGFloat(min(index, desc.path.count - 1 - index)) * 8)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }
}
