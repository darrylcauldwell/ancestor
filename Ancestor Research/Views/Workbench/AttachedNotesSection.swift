import SwiftUI

/// Inline notes section reusable across detail views (profile inspector,
/// hypothesis detail, question composer). Loads notes for the given
/// attachment via the supplied closure, renders a tappable list, and
/// surfaces a "New" button that opens NoteComposerView pre-attached.
///
/// The loader closure is passed in so callers don't all have to import
/// `NoteAttachment`-aware logic — they just say `appState.notesForX(id)`.
struct AttachedNotesSection: View {
    @Environment(AppState.self) private var appState
    let attachedTo: NoteAttachment
    let load: () -> [WorkbenchNote]

    @State private var showingComposer: Bool = false
    @State private var editingNote: WorkbenchNote?
    /// The view re-reads `load()` whenever the cached notes count changes
    /// — that's how we pick up new + deleted notes without a published
    /// observable on every detail view.
    @State private var refreshTrigger: Int = 0

    var body: some View {
        let notes = load()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notes")
                    .font(AppTypography.cardMeta.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    showingComposer = true
                } label: {
                    Label("New", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            if notes.isEmpty {
                Text("No notes attached.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(notes) { note in
                    Button {
                        editingNote = note
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(note.tag.displayName)
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .glassEffect(.regular, in: .capsule)
                                Spacer()
                                Text(note.updatedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            LinkAwareNoteText(content: note.content, snapshot: appState.snapshot) { profile in
                                appState.researchProfileID = profile.id
                            }
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .id(refreshTrigger)
        .onChange(of: appState.notes.count) { refreshTrigger &+= 1 }
        .sheet(isPresented: $showingComposer) {
            NoteComposerView(initial: nil, attachedTo: attachedTo)
        }
        .sheet(item: $editingNote) { note in
            NoteComposerView(initial: note, attachedTo: note.attachedTo)
        }
    }
}
