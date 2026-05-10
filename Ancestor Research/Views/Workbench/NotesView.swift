import SwiftUI

/// Project-wide notes list with create/edit/delete. Shows the tag, attachment
/// (clickable in W6), and updated time. New notes default to a `.observation`
/// tagged note attached to the project.
struct NotesView: View {
    @Environment(AppState.self) private var appState
    @State private var showingComposer: Bool = false
    @State private var editing: WorkbenchNote?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if appState.notes.isEmpty {
                ContentUnavailableView(
                    "No notes yet",
                    systemImage: "note.text",
                    description: Text("Capture observations, todos, and source-log entries as you research.")
                )
            } else {
                List {
                    ForEach(appState.notes) { note in
                        Button {
                            editing = note
                        } label: {
                            row(for: note)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                appState.deleteNote(id: note.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingComposer) {
            NoteComposerView(initial: nil, attachedTo: .project)
        }
        .sheet(item: $editing) { note in
            NoteComposerView(initial: note, attachedTo: note.attachedTo)
        }
    }

    private var header: some View {
        HStack {
            Text("\(appState.notes.count) notes")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showingComposer = true
            } label: {
                Label("New note", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func row(for note: WorkbenchNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(note.tag.displayName)
                    .font(AppTypography.badge)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
                Text(attachmentSummary(note.attachedTo))
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(note.updatedAt, style: .relative)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            }
            LinkAwareNoteText(content: note.content, snapshot: appState.snapshot) { profile in
                appState.researchProfileID = profile.id
            }
            .font(AppTypography.cardBody)
        }
    }

    private func attachmentSummary(_ a: NoteAttachment) -> String {
        switch a {
        case .project: return "Project"
        case .profile(let id):
            return appState.snapshot.profiles[id]?.displayName ?? "Profile"
        case .relationship: return "Relationship"
        case .hypothesis: return "Hypothesis"
        case .question: return "Question"
        }
    }
}
