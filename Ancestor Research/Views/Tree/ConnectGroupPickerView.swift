import SwiftUI

/// Presented from the disconnected-tree banner's "Connect them?" action. Lists
/// each separate group in the tree — a representative head + member count +
/// a few sample names — so the user can SEE the islands and pick which one to
/// connect, rather than the app guessing an arbitrary anchor. Choosing a group
/// hands its representative to `AddRelationshipView`, where the user picks who
/// it links to.
struct ConnectGroupPickerView: View {
    let summaries: [GraphConnectivity.ComponentSummary]
    let profiles: [String: Profile]
    /// Called with the chosen group's representative profile ID.
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect which group?")
                    .font(AppTypography.cardTitle)
                Text("Your tree is in \(summaries.count) separate groups. Pick the one to connect — then you'll choose who it links to.")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(summaries) { summary in
                        Button { onSelect(summary.representativeID) } label: {
                            groupRow(summary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    @ViewBuilder
    private func groupRow(_ summary: GraphConnectivity.ComponentSummary) -> some View {
        let rep = profiles[summary.representativeID]
        let repYear = rep?.birthDate?.bestYear
        let others = summary.memberIDs
            .filter { $0 != summary.representativeID }
            .compactMap { profiles[$0]?.displayName }
            .prefix(3)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: summary.count > 10 ? "person.3.fill" : "person.2")
                .foregroundStyle(.blue)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text((rep?.displayName ?? "(unnamed)") + (repYear.map { " · b.\($0)" } ?? ""))
                        .font(AppTypography.cardTitle)
                    Spacer()
                    Text("\(summary.count) \(summary.count == 1 ? "person" : "people")")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                }
                if !others.isEmpty {
                    Text("incl. " + others.joined(separator: ", ") + (summary.count > 4 ? ", …" : ""))
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rep?.displayName ?? "unnamed") group, \(summary.count) people")
    }
}
