import SwiftUI

/// Open-questions list: grouped by status (open → in-progress → blocked →
/// resolved), sorted by priority within each group. Each row shows the
/// question text, the related profiles, and tried sources if any.
struct QuestionsView: View {
    @Environment(AppState.self) private var appState
    @State private var showingComposer: Bool = false
    @State private var editing: OpenQuestion?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if appState.questions.isEmpty {
                ContentUnavailableView(
                    "No questions yet",
                    systemImage: "questionmark.bubble",
                    description: Text("Capture what you're trying to figure out — Audit and Gaps items can be promoted here in one click.")
                )
            } else {
                List {
                    ForEach(QuestionStatus.allCases, id: \.self) { status in
                        let group = grouped[status] ?? []
                        if !group.isEmpty {
                            Section(status.displayName) {
                                ForEach(group) { question in
                                    Button { editing = question } label: {
                                        row(for: question)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing) {
                                        if question.status != .resolved {
                                            Button("Resolve") {
                                                appState.resolveQuestion(id: question.id, resolution: nil)
                                            }
                                            .tint(.green)
                                        }
                                        Button(role: .destructive) {
                                            appState.deleteQuestion(id: question.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingComposer) {
            QuestionComposerView(initial: nil)
        }
        .sheet(item: $editing) { q in
            QuestionComposerView(initial: q)
        }
    }

    private var grouped: [QuestionStatus: [OpenQuestion]] {
        Dictionary(grouping: appState.questions) { $0.status }
            .mapValues { questions in
                questions.sorted { lhs, rhs in
                    if lhs.priority.sortWeight != rhs.priority.sortWeight {
                        return lhs.priority.sortWeight < rhs.priority.sortWeight
                    }
                    return lhs.createdAt > rhs.createdAt
                }
            }
    }

    private var header: some View {
        HStack {
            Text("\(appState.questions.count) questions")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showingComposer = true
            } label: {
                Label("New question", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func row(for question: OpenQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(question.priority.displayName)
                    .font(AppTypography.badge)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
                Spacer()
                Text(question.createdAt, style: .relative)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            }
            Text(question.text)
                .font(AppTypography.cardBody)
            if !question.profileIDs.isEmpty {
                Text(profileNames(question.profileIDs))
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
            if let tried = question.triedSources, !tried.isEmpty {
                Label(tried, systemImage: "magnifyingglass")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private func profileNames(_ ids: [String]) -> String {
        ids.compactMap { appState.snapshot.profiles[$0]?.displayName }.joined(separator: ", ")
    }
}
