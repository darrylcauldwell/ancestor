import SwiftUI

/// Chronological view of one profile's life — the single view that turns
/// "a database of facts" into "a story of a person." Per DESIGN.md §7.8.
///
/// Reads from the live AppState snapshot + workbench arrays; renders rows
/// produced by `TimelineBuilder`. Hypothetical events render in italic
/// muted styling per §7.7.7.
struct ProfileTimelineView: View {
    @Environment(AppState.self) private var appState
    let profileID: String

    private var events: [TimelineEvent] {
        TimelineBuilder.build(
            profileID: profileID,
            snapshot: appState.snapshot,
            notes: appState.notes,
            hypotheses: appState.hypotheses,
            questions: appState.questions,
            lifeEvents: appState.lifeEventsForProfile(profileID)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let profile = appState.snapshot.profiles[profileID] {
                    Text(profile.displayName)
                        .font(.title3).fontWeight(.semibold)
                }
                if events.isEmpty {
                    ContentUnavailableView(
                        "No timeline yet",
                        systemImage: "calendar",
                        description: Text("Add a birth or death date, mark a marriage, or attach a workbench note to this person.")
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(events) { event in
                        row(for: event)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Timeline")
    }

    private func row(for event: TimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Year column — fixed width so dots align cleanly.
            VStack(alignment: .trailing) {
                Text(event.date?.bestYear.map(String.init) ?? "—")
                    .font(AppTypography.cardMeta.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .italic(event.isHypothetical)
            }
            .frame(width: 50, alignment: .trailing)

            // Connector dot.
            Circle()
                .fill(eventColor(event.kind))
                .frame(width: 10, height: 10)
                .padding(.top, 5)
                .opacity(event.isHypothetical ? 0.5 : 1.0)

            // Content.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(AppTypography.cardBody.weight(.semibold))
                        .foregroundStyle(eventColor(event.kind))
                        .italic(event.isHypothetical)
                    Spacer()
                    if event.isHypothetical {
                        Image(systemName: "lightbulb")
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    }
                }
                if !event.description.isEmpty {
                    Text(event.description)
                        .font(AppTypography.cardBody)
                        .italic(event.isHypothetical)
                        .foregroundStyle(event.isHypothetical ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
                if !event.sources.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(event.sources, id: \.raw) { src in
                            Text(src.origin.identifier.uppercased())
                                .font(AppTypography.badge)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .glassEffect(.regular, in: .capsule)
                        }
                    }
                }
                if let citation = event.sources.first?.citation, !citation.isEmpty {
                    Text(citation.formatted)
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func eventColor(_ kind: TimelineEvent.Kind) -> Color {
        switch kind {
        case .birth: return .green
        case .death: return .red
        case .marriage: return .pink
        case .divorce: return .orange
        case .note: return .blue
        case .hypothesis: return .purple
        case .openQuestion: return .yellow
        case .lifeEvent: return .teal
        }
    }
}
