import SwiftUI

/// Launch-time prompt shown when there's a recent session within the resume
/// window (>30 min ago and <7 days old, with recorded activity). Mirrors
/// DESIGN.md §7.7.6 — turns the app from a tree editor into a research
/// tool you can return to.
struct SessionResumeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let session: ResearchSession
    /// Caller switches the sidebar selection when "Continue" is chosen.
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "hand.wave.fill")
                    .font(.title)
                    .foregroundStyle(AnyShapeStyle(Color.accentColor))
                    .accessibilityHidden(true)
                Text("Welcome back")
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Text("Last session — \(session.startedAt, style: .date) at \(session.startedAt, style: .time)")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)

            Text(session.summary)
                .font(AppTypography.cardBody)

            if let focusID = session.focusSetID,
               let focus = appState.focusSets.first(where: { $0.id == focusID }) {
                Label("Focus: \(focus.displayTitle)", systemImage: "scope")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }

            if !openItemsLine.isEmpty {
                Divider()
                Text("Still open:")
                    .font(AppTypography.cardMeta.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(openItemsLine)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }

            // M13 §5.16 — surface active research goals so users see where
            // they were heading when they return to the app.
            let activeGoals = activeResearchGoals
            if !activeGoals.isEmpty {
                Divider()
                Text("Active goals (\(activeGoals.count))")
                    .font(AppTypography.cardMeta.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(activeGoals) { goal in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(goal.title)
                                    .font(AppTypography.cardBody)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(goal.progress)%")
                                    .font(AppTypography.cardMeta)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            ProgressView(value: Double(goal.progress) / 100.0)
                                .progressViewStyle(.linear)
                            Text(openQuestionsLine(for: goal))
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            HStack {
                Button("Just open the tree") {
                    appState.dismissResumableSession()
                    dismiss()
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Continue from where you left off") {
                    appState.continueResumableSession()
                    onContinue()
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 280)
    }

    /// Active research goals, sorted with most-recently-created first. Per
    /// DESIGN.md §5.16 — surface "where am I trying to get to?" on resume.
    private var activeResearchGoals: [ResearchGoal] {
        appState.loadGoals()
            .filter { $0.status == .active }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// "3 questions still open" / "1 question still open" / "no open questions".
    private func openQuestionsLine(for goal: ResearchGoal) -> String {
        let attached = Set(goal.questionIDs)
        let openCount = appState.questions
            .filter { attached.contains($0.id) && $0.status != .resolved }
            .count
        switch openCount {
        case 0: return "no open questions"
        case 1: return "1 question still open"
        default: return "\(openCount) questions still open"
        }
    }

    /// One-liner of currently open questions, capped at 3, used to remind
    /// the user where they were stuck.
    private var openItemsLine: String {
        let openText = appState.questions
            .filter { $0.status == .open || $0.status == .inProgress }
            .sorted { lhs, rhs in
                if lhs.priority.sortWeight != rhs.priority.sortWeight {
                    return lhs.priority.sortWeight < rhs.priority.sortWeight
                }
                return lhs.createdAt > rhs.createdAt
            }
            .prefix(3)
            .map { $0.text }
        guard !openText.isEmpty else { return "" }
        return openText.joined(separator: " · ")
    }
}
