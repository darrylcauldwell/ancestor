import SwiftUI

/// Timeline view for a profile — shows life events chronologically with citations.
struct ProfileTimelineView: View {
    let biography: Biography
    @State private var expandedCitations: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Narrative
                Text(biography.narrative)
                    .font(AppTypography.cardBody)
                    .textSelection(.enabled)
                    .padding(.bottom, 8)

                Divider()

                // Timeline
                Text("Timeline")
                    .font(AppTypography.popoverTitle)

                ForEach(biography.timeline) { entry in
                    timelineRow(entry)
                }
            }
            .padding()
        }
    }

    private func timelineRow(_ entry: TimelineEntry) -> some View {
        let isExpanded = expandedCitations.contains(entry.id)

        return HStack(alignment: .top, spacing: 12) {
            // Year column
            VStack {
                Text(entry.year.map(String.init) ?? "?")
                    .font(AppTypography.cardTitle)
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }

            // Event dot
            Circle()
                .fill(eventColor(entry.label))
                .frame(width: 10, height: 10)
                .padding(.top, 5)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.label)
                        .font(AppTypography.cardMeta)
                        .fontWeight(.semibold)
                        .foregroundStyle(eventColor(entry.label))

                    Spacer()

                    Text(entry.sourceID.uppercased())
                        .font(AppTypography.sourceBadge)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)

                    Button {
                        if isExpanded {
                            expandedCitations.remove(entry.id)
                        } else {
                            expandedCitations.insert(entry.id)
                        }
                    } label: {
                        Image(systemName: "quote.opening")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text(entry.description)
                    .font(AppTypography.cardBody)

                if isExpanded {
                    Text(entry.citation.full)
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func eventColor(_ label: String) -> Color {
        switch label.lowercased() {
        case "birth", "baptism": return .green
        case "death", "burial": return .red
        case "marriage": return .pink
        case "census": return .blue
        case "military": return .orange
        case "probate": return .purple
        default: return .secondary
        }
    }
}
