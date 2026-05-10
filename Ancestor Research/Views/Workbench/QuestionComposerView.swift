import SwiftUI

/// Sheet for creating or editing a question. Supports priority, status,
/// related profiles (typed in by id for now — full picker comes with W3),
/// tried sources, and resolution notes when status is .resolved.
struct QuestionComposerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let initial: OpenQuestion?

    @State private var text: String = ""
    @State private var priority: QuestionPriority = .medium
    @State private var status: QuestionStatus = .open
    @State private var triedSources: String = ""
    @State private var resolution: String = ""
    @State private var profileIDs: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(initial == nil ? "New question" : "Edit question")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Question")
                    TextField("What are you trying to figure out?", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)

                    sectionTitle("Priority")
                    Picker("Priority", selection: $priority) {
                        ForEach(QuestionPriority.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    sectionTitle("Status")
                    Picker("Status", selection: $status) {
                        ForEach(QuestionStatus.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    relatedProfilesSection

                    sectionTitle("Tried sources")
                    TextEditor(text: $triedSources)
                        .font(AppTypography.cardBody)
                        .frame(minHeight: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    Text("Record sources you've already checked — saves you time later.")
                        .font(AppTypography.badge)
                        .foregroundStyle(.tertiary)

                    if status == .resolved {
                        sectionTitle("Resolution")
                        TextEditor(text: $resolution)
                            .font(AppTypography.cardBody)
                            .frame(minHeight: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }

                    // Notes can only attach to a question that already exists.
                    // For new questions the user creates the question first,
                    // re-opens it, and attaches notes from there.
                    if let existing = initial {
                        Divider()
                        AttachedNotesSection(
                            attachedTo: .question(id: existing.id),
                            load: { appState.notesForQuestion(existing.id) }
                        )
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
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 540, minHeight: 540)
        .onAppear {
            if let q = initial {
                text = q.text
                priority = q.priority
                status = q.status
                triedSources = q.triedSources ?? ""
                resolution = q.resolution ?? ""
                profileIDs = q.profileIDs
            }
        }
    }

    private var relatedProfilesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Related profiles")
            if profileIDs.isEmpty {
                Text("None yet — add profiles via right-click in the tree (later W phase).")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    ForEach(profileIDs, id: \.self) { id in
                        let name = appState.snapshot.profiles[id]?.displayName ?? id
                        HStack(spacing: 4) {
                            Text(name)
                                .font(AppTypography.cardMeta)
                            Button {
                                profileIDs.removeAll { $0 == id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(name) from this question")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func save() {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let trimmedTried = triedSources.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRes = resolution.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = initial {
            var q = existing
            q.text = trimmedText
            q.priority = priority
            q.status = status
            q.triedSources = trimmedTried.isEmpty ? nil : trimmedTried
            q.profileIDs = profileIDs
            if status == .resolved {
                q.resolvedAt = q.resolvedAt ?? Date()
                q.resolution = trimmedRes.isEmpty ? nil : trimmedRes
            } else {
                q.resolvedAt = nil
                q.resolution = nil
            }
            appState.updateQuestion(q)
        } else {
            appState.createQuestion(
                text: trimmedText,
                profileIDs: profileIDs,
                priority: priority,
                promotedFrom: .manual
            )
        }
        dismiss()
    }
}
