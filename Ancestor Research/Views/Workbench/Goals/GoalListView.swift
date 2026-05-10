import SwiftUI

/// Lists every research goal for the current project. Each row shows a
/// status badge, progress bar, and counts of attached questions and
/// hypotheses. Tapping a row opens the detail view; the "+ New goal"
/// button opens the editor in add mode. Per DESIGN.md §5.16.
struct GoalListView: View {
    @Environment(AppState.self) private var appState

    @State private var goals: [ResearchGoal] = []
    @State private var addingGoal: Bool = false
    @State private var detailGoal: ResearchGoal?

    var body: some View {
        VStack(spacing: 0) {
            header
            if goals.isEmpty {
                ContentUnavailableView(
                    "No research goals yet",
                    systemImage: "target",
                    description: Text("Capture long-term objectives — they organise questions, hypotheses, and focus sets across months and years.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(goals) { goal in
                        Button { detailGoal = goal } label: {
                            card(for: goal)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .onAppear { reload() }
        .sheet(isPresented: $addingGoal, onDismiss: reload) {
            GoalEditorView(mode: .add)
        }
        .sheet(item: $detailGoal, onDismiss: reload) { goal in
            GoalDetailView(goalID: goal.id)
        }
    }

    private var header: some View {
        HStack {
            Text("\(goals.count) \(goals.count == 1 ? "goal" : "goals")")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                addingGoal = true
            } label: {
                Label("New goal", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func card(for goal: ResearchGoal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                statusBadge(goal.status)
                Spacer()
                Text("\(goal.progress)%")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(goal.title)
                .font(AppTypography.cardTitle)
                .lineLimit(2)
            ProgressView(value: Double(goal.progress) / 100.0)
                .progressViewStyle(.linear)
            HStack(spacing: 12) {
                Label(questionCountLabel(goal), systemImage: "questionmark.bubble")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Label(hypothesisCountLabel(goal), systemImage: "lightbulb")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                if let focusID = goal.focusSetID,
                   let focus = appState.focusSets.first(where: { $0.id == focusID }) {
                    Label(focus.displayTitle, systemImage: "scope")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    private func statusBadge(_ status: GoalStatus) -> some View {
        Text(status.displayName)
            .font(AppTypography.badge)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
            .foregroundStyle(AnyShapeStyle(GoalListView.colour(for: status)))
    }

    private func questionCountLabel(_ goal: ResearchGoal) -> String {
        let n = goal.questionIDs.count
        return n == 1 ? "1 question" : "\(n) questions"
    }

    private func hypothesisCountLabel(_ goal: ResearchGoal) -> String {
        let n = goal.hypothesisIDs.count
        return n == 1 ? "1 hypothesis" : "\(n) hypotheses"
    }

    nonisolated static func colour(for status: GoalStatus) -> Color {
        switch status {
        case .active: return .green
        case .paused: return .orange
        case .completed: return .blue
        case .abandoned: return .secondary
        }
    }

    private func reload() {
        goals = appState.loadGoals()
    }
}
