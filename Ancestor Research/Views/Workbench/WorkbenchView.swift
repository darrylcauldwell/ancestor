import SwiftUI

/// Sidebar peer to Tree, Audit, Research, etc. Hosts the W1+W2 sub-views
/// (Notes, Questions). Future W phases plug in additional tabs:
/// W3 Focus, W4 Sessions, W5 Hypotheses.
struct WorkbenchView: View {
    @Environment(AppState.self) private var appState
    @State private var section: Section = .notes
    @State private var goalsExpanded: Bool = true

    enum Section: String, CaseIterable, Identifiable {
        case focus = "Focus"
        case hypotheses = "Hypotheses"
        case hunches = "Hunches"
        case questions = "Questions"
        case notes = "Notes"
        case sessions = "Sessions"
        case search = "Search"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .focus: return "scope"
            case .hypotheses: return "lightbulb"
            case .hunches: return "lightbulb.max"
            case .notes: return "note.text"
            case .questions: return "questionmark.bubble"
            case .sessions: return "clock.arrow.circlepath"
            case .search: return "magnifyingglass"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            goalsHeader
                .padding(.horizontal)
                .padding(.top)
            Divider()
                .padding(.top, 8)
            sectionPicker
                .padding(.horizontal)
                .padding(.top, 8)
            Divider()
                .padding(.top, 8)
            switch section {
            case .focus: FocusView()
            case .hypotheses: HypothesesView()
            case .hunches: UserHunchesView(subjectID: appState.selectedProfileID)
            case .questions: QuestionsView()
            case .notes: NotesView()
            case .sessions: SessionsView()
            case .search: SearchView()
            }
        }
        .navigationTitle("Workbench")
        // ⌘F focuses the workbench search (per DESIGN.md §7.7.5 keyboard
        // shortcut). Implemented as a hidden background button so the
        // shortcut is registered without occupying any space.
        .background {
            Button {
                section = .search
            } label: {
                EmptyView()
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
        }
    }

    private var sectionPicker: some View {
        Picker("", selection: $section) {
            ForEach(Section.allCases) { s in
                Label(s.rawValue, systemImage: s.systemImage).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// M13 Research Goals — collapsible section pinned to the top of the
    /// Workbench view. Per DESIGN.md §5.16 "Goals appear as a section at
    /// the top of the Workbench view."
    private var goalsHeader: some View {
        DisclosureGroup(isExpanded: $goalsExpanded) {
            GoalListView()
        } label: {
            Label("Research goals", systemImage: "target")
                .font(.headline)
        }
    }
}
