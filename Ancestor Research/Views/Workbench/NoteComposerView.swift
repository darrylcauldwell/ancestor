import SwiftUI

/// Sheet for creating or editing a note. Used by NotesView (project-wide list)
/// and ProfileDetailView's inline notes section. Caller passes the attachment
/// — composer doesn't let users move a note across attachments.
struct NoteComposerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// nil → creating a new note. Non-nil → editing.
    let initial: WorkbenchNote?
    let attachedTo: NoteAttachment

    @State private var content: String = ""
    @State private var tag: NoteTag = .observation
    @State private var sensitive: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(initial == nil ? "New note" : "Edit note")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Tag", selection: $tag) {
                        ForEach(NoteTag.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextEditor(text: $content)
                        .font(AppTypography.cardBody)
                        .frame(minHeight: 200)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    Text("Markdown supported. `[[Profile Name]]` becomes a clickable link.")
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)

                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Sensitive", isOn: $sensitive)
                        Text("Excluded from shared exports when the global filter is on.")
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    }

                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Preview")
                                .font(AppTypography.badge)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            LinkAwareNoteText(content: content, snapshot: appState.snapshot) { _ in
                                // Preview only — taps are inert in the composer.
                            }
                            .font(AppTypography.cardBody)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(initial == nil ? "Create" : "Save") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 460)
        .onAppear {
            if let initial {
                content = initial.content
                tag = initial.tag
                sensitive = initial.sensitive
            }
        }
    }

    private func save() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = initial {
            var updated = existing
            updated.content = trimmed
            updated.tag = tag
            updated.sensitive = sensitive
            appState.updateNote(updated)
        } else {
            appState.createNote(
                content: trimmed, tag: tag, attachedTo: attachedTo,
                sensitive: sensitive
            )
        }
        dismiss()
    }
}
