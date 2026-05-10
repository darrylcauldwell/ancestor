import SwiftUI

/// Cross-entity workbench search. Hits are grouped by kind (Notes →
/// Questions → Hypotheses → Focus sets). Selecting a row opens the
/// matching detail/composer view. The search field auto-focuses on
/// appear and ⌘F refocuses it.
struct SearchView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    @State private var noteToEdit: WorkbenchNote?
    @State private var questionToEdit: OpenQuestion?
    @State private var hypothesisToEdit: Hypothesis?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
        .onAppear { searchFocused = true }
        .sheet(item: $noteToEdit) { note in
            NoteComposerView(initial: note, attachedTo: note.attachedTo)
        }
        .sheet(item: $questionToEdit) { q in
            QuestionComposerView(initial: q)
        }
        .sheet(item: $hypothesisToEdit) { h in
            HypothesisDetailView(hypothesis: h)
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search notes, questions, hypotheses…", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let results = appState.searchWorkbench(query: query)
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView(
                "Search the workbench",
                systemImage: "magnifyingglass",
                description: Text("Find notes, open questions, hypotheses, and focus sets in one place.")
            )
        } else if results.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("Try different terms or check spelling.")
            )
        } else {
            List {
                ForEach(groupedKinds(results), id: \.self) { kindLabel in
                    let group = results.filter { $0.kindLabel == kindLabel }
                    Section(kindLabel) {
                        ForEach(group) { result in
                            Button { open(result) } label: {
                                row(for: result)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func groupedKinds(_ results: [WorkbenchSearchResult]) -> [String] {
        // Preserve groupOrder — Sets reorder, but a manual de-dup keeps it stable.
        var seen: [String] = []
        for r in results.sorted(by: { $0.groupOrder < $1.groupOrder }) {
            if !seen.contains(r.kindLabel) { seen.append(r.kindLabel) }
        }
        return seen
    }

    private func row(for result: WorkbenchSearchResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.systemImage)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(AppTypography.cardBody)
                if !result.snippet.isEmpty {
                    Text(result.snippet)
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func open(_ result: WorkbenchSearchResult) {
        switch result {
        case .note(let n): noteToEdit = n
        case .question(let q): questionToEdit = q
        case .hypothesis(let h): hypothesisToEdit = h
        case .focusSet(let f):
            // No detail sheet for focus sets — promote to active and let the
            // user navigate to the Focus tab themselves.
            appState.setActiveFocusSet(id: f.id)
        }
    }
}
