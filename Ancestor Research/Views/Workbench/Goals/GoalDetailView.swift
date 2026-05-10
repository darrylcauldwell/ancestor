import SwiftUI

/// Read-only detail of a research goal. Resolves attached question and
/// hypothesis IDs against the AppState caches, lets the user attach more
/// (or detach existing) via simple checkbox pickers, and exposes Edit /
/// Delete buttons. Per DESIGN.md §5.16.
struct GoalDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// We hold an ID and re-resolve from disk so external edits (the editor
    /// sheet, attachment changes) are visible after dismissal.
    let goalID: UUID

    @State private var goal: ResearchGoal?
    @State private var editing: Bool = false
    @State private var addingQuestion: Bool = false
    @State private var addingHypothesis: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if let goal {
                    body(for: goal)
                } else {
                    ContentUnavailableView(
                        "Goal not found",
                        systemImage: "questionmark.folder",
                        description: Text("This goal was deleted.")
                    )
                    .padding()
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 560)
        .onAppear(perform: reload)
        .sheet(isPresented: $editing, onDismiss: reload) {
            if let goal {
                GoalEditorView(mode: .edit(goal))
            }
        }
        .sheet(isPresented: $addingQuestion, onDismiss: reload) {
            if let goal {
                GoalQuestionPickerView(goal: goal) { newIDs in
                    var updated = goal
                    updated.questionIDs = newIDs
                    appState.updateGoal(updated)
                }
            }
        }
        .sheet(isPresented: $addingHypothesis, onDismiss: reload) {
            if let goal {
                GoalHypothesisPickerView(goal: goal) { newIDs in
                    var updated = goal
                    updated.hypothesisIDs = newIDs
                    appState.updateGoal(updated)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(goal?.title ?? "Goal")
                .font(.title3).fontWeight(.semibold)
                .lineLimit(2)
            Spacer()
        }
        .padding()
    }

    private func body(for goal: ResearchGoal) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                statusBadge(goal.status)
                Text("\(goal.progress)% complete")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            ProgressView(value: Double(goal.progress) / 100.0)
                .progressViewStyle(.linear)

            if let description = goal.description, !description.isEmpty {
                sectionTitle("Description")
                Text(description)
                    .font(AppTypography.cardBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let focusID = goal.focusSetID,
               let focus = appState.focusSets.first(where: { $0.id == focusID }) {
                sectionTitle("Focus set")
                Label(focus.displayTitle, systemImage: "scope")
                    .font(AppTypography.cardBody)
            }

            questionsSection(goal)
            hypothesesSection(goal)

            sectionTitle("Created")
            Text(goal.createdAt, style: .date)
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            if let completedAt = goal.completedAt {
                sectionTitle("Completed")
                Text(completedAt, style: .date)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func questionsSection(_ goal: ResearchGoal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Questions (\(goal.questionIDs.count))")
                Spacer()
                Button {
                    addingQuestion = true
                } label: {
                    Label("Manage", systemImage: "checklist")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            if attachedQuestions(goal).isEmpty {
                Text("No questions attached.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(attachedQuestions(goal)) { q in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: q.status == .resolved ? "checkmark.circle.fill" : "questionmark.bubble")
                            .foregroundStyle(q.status == .resolved ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.text)
                                .font(AppTypography.cardBody)
                            Text("\(q.priority.displayName) · \(q.status.displayName)")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func hypothesesSection(_ goal: ResearchGoal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Hypotheses (\(goal.hypothesisIDs.count))")
                Spacer()
                Button {
                    addingHypothesis = true
                } label: {
                    Label("Manage", systemImage: "checklist")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            if attachedHypotheses(goal).isEmpty {
                Text("No hypotheses attached.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(attachedHypotheses(goal)) { h in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.claimSummary)
                                .font(AppTypography.cardBody)
                            Text("\(h.confidence.displayName) · \(h.status.displayName)")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let goal {
                Button(role: .destructive) {
                    appState.deleteGoal(id: goal.id)
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.glass)
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button("Edit") {
                editing = true
            }
            .buttonStyle(.glassProminent)
            .disabled(goal == nil)
        }
        .padding()
    }

    private func statusBadge(_ status: GoalStatus) -> some View {
        Text(status.displayName)
            .font(AppTypography.badge)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
            .foregroundStyle(AnyShapeStyle(GoalListView.colour(for: status)))
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func attachedQuestions(_ goal: ResearchGoal) -> [OpenQuestion] {
        let ids = Set(goal.questionIDs)
        return appState.questions.filter { ids.contains($0.id) }
    }

    private func attachedHypotheses(_ goal: ResearchGoal) -> [Hypothesis] {
        let ids = Set(goal.hypothesisIDs)
        return appState.hypotheses.filter { ids.contains($0.id) }
    }

    private func reload() {
        goal = appState.loadGoals().first { $0.id == goalID }
    }
}

/// Sheet that lets the user attach / detach questions to a goal. Shows
/// every unresolved question plus those already attached (so detaching
/// a resolved one is still possible). Closes via Cancel/Save.
struct GoalQuestionPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let goal: ResearchGoal
    let onSave: ([UUID]) -> Void

    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Attach questions")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()
            List {
                ForEach(candidates) { q in
                    Button {
                        toggle(q.id)
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(q.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected.contains(q.id) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(q.text)
                                    .font(AppTypography.cardBody)
                                Text("\(q.priority.displayName) · \(q.status.displayName)")
                                    .font(AppTypography.cardMeta)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(Array(selected))
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 480)
        .onAppear { selected = Set(goal.questionIDs) }
    }

    /// Unresolved questions plus any already-attached ones (even if resolved).
    private var candidates: [OpenQuestion] {
        let attached = Set(goal.questionIDs)
        return appState.questions
            .filter { $0.status != .resolved || attached.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.priority.sortWeight != rhs.priority.sortWeight {
                    return lhs.priority.sortWeight < rhs.priority.sortWeight
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

/// Sheet that lets the user attach / detach hypotheses to a goal. Shows
/// every active hypothesis plus those already attached (so detaching
/// a resolved one is still possible).
struct GoalHypothesisPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let goal: ResearchGoal
    let onSave: ([UUID]) -> Void

    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Attach hypotheses")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()
            List {
                ForEach(candidates) { h in
                    Button {
                        toggle(h.id)
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(h.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected.contains(h.id) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.claimSummary)
                                    .font(AppTypography.cardBody)
                                Text("\(h.confidence.displayName) · \(h.status.displayName)")
                                    .font(AppTypography.cardMeta)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(Array(selected))
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 480)
        .onAppear { selected = Set(goal.hypothesisIDs) }
    }

    private var candidates: [Hypothesis] {
        let attached = Set(goal.hypothesisIDs)
        return appState.hypotheses
            .filter { $0.status == .active || attached.contains($0.id) }
            .sorted { ($0.createdAt) > ($1.createdAt) }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
