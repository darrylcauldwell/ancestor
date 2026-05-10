import SwiftUI

/// Per-profile audit trail timeline showing every change to this profile.
struct ProfileHistoryView: View {
    let profile: Profile
    let transactions: [Transaction]
    let fieldChanges: [FieldChange]
    var onUndo: ((UUID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.headline)

            if relevantChanges.isEmpty {
                Text("No changes recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(relevantChanges) { change in
                            changeRow(change)
                        }
                    }
                }
            }
        }
        .padding()
    }

    /// Filter changes relevant to this profile.
    private var relevantChanges: [FieldChange] {
        fieldChanges
            .filter { $0.entityID == profile.id }
            .sorted { ($0.id.uuidString) > ($1.id.uuidString) }
    }

    private func changeRow(_ change: FieldChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .accessibilityHidden(true)

                Text(fieldLabel(change.field))
                    .font(.caption)
                    .fontWeight(.semibold)

                Spacer()

                Text(change.source.identifier.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
            }

            HStack(spacing: 8) {
                if let old = change.oldValue {
                    Text(old)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .strikethrough()
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("changed to")
                Text(change.newValue)
                    .font(.caption2)
                    .foregroundStyle(.green)
            }

            if let reason = change.reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Find the transaction for this change
            if let tx = transactions.first(where: { $0.id == change.transactionID }) {
                HStack {
                    Text(tx.summary)
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Spacer()
                    if let onUndo {
                        Button("Undo") {
                            onUndo(tx.id)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                    }
                }
            }

            Divider()
        }
    }

    private func fieldLabel(_ field: ChangeField) -> String {
        switch field {
        case .profile(let pf): pf.rawValue
        case .relationship(let rf): rf.rawValue
        }
    }
}
