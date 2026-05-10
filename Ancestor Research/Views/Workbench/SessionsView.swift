import SwiftUI

/// List of past research sessions. Sessions are auto-generated; this view
/// is read-only — no create or edit. Each row shows the session's plain-
/// English summary and (when available) the focus set it was working on.
struct SessionsView: View {
    @Environment(AppState.self) private var appState
    @State private var sessions: [ResearchSession] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Sessions are recorded automatically as you work. Open the project, make changes, come back tomorrow — you'll see what you were doing.")
                )
            } else {
                List {
                    ForEach(sessions) { session in
                        row(for: session)
                    }
                }
            }
        }
        .onAppear { reload() }
        // Reload when the active session bumps its counters — visible if
        // user is switching tabs while working.
        .onChange(of: appState.notes.count) { reload() }
        .onChange(of: appState.questions.count) { reload() }
    }

    private var header: some View {
        HStack {
            Text("\(sessions.count) sessions")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func row(for session: ResearchSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.startedAt, style: .date)
                    .font(AppTypography.cardBody.weight(.medium))
                if session.id == appState.currentSessionID {
                    Text("Active")
                        .font(AppTypography.badge)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                        .foregroundStyle(AnyShapeStyle(Color.accentColor))
                }
                Spacer()
                Text(session.startedAt, style: .time)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            }
            Text(session.summary)
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            if let focusID = session.focusSetID,
               let focus = appState.focusSets.first(where: { $0.id == focusID }) {
                Label(focus.displayTitle, systemImage: "scope")
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        guard let db = appState.currentDatabase else {
            sessions = []
            return
        }
        sessions = (try? db.loadSessions()) ?? []
    }
}
