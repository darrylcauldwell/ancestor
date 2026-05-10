import SwiftUI

/// Sheet for creating or editing a `ResearchGoal`. Add mode starts blank;
/// edit mode hydrates from the supplied goal and offers a Delete button.
/// Per DESIGN.md §5.16.
struct GoalEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case add
        case edit(ResearchGoal)
    }

    let mode: Mode

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var status: GoalStatus = .active
    @State private var progress: Double = 0
    @State private var focusSetID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit goal" : "New goal")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Title")
                    TextField("e.g. Trace maternal line to the 1700s", text: $title)
                        .textFieldStyle(.roundedBorder)

                    sectionTitle("Description")
                    TextEditor(text: $description)
                        .font(AppTypography.cardBody)
                        .frame(minHeight: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    sectionTitle("Status")
                    Picker("Status", selection: $status) {
                        ForEach(GoalStatus.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    sectionTitle("Progress — \(Int(progress))%")
                    Slider(value: $progress, in: 0...100, step: 1)

                    sectionTitle("Focus set")
                    Picker("Focus set", selection: $focusSetID) {
                        Text("None").tag(UUID?.none)
                        ForEach(appState.focusSets) { set in
                            Text(set.displayTitle).tag(UUID?.some(set.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding()
            }

            Divider()
            HStack {
                if isEditing {
                    Button(role: .destructive) {
                        deleteAndDismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.glass)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 540, minHeight: 540)
        .onAppear(perform: hydrate)
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hydrate() {
        if case .edit(let goal) = mode {
            title = goal.title
            description = goal.description ?? ""
            status = goal.status
            progress = Double(goal.progress)
            focusSetID = goal.focusSetID
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let descValue: String? = trimmedDesc.isEmpty ? nil : trimmedDesc

        switch mode {
        case .add:
            guard let created = appState.createGoal(
                title: trimmedTitle,
                description: descValue,
                focusSetID: focusSetID
            ) else {
                dismiss()
                return
            }
            // If the user changed status/progress in the add sheet, persist them.
            if status != .active || Int(progress) != 0 {
                var updated = created
                updated.status = status
                updated.progress = Int(progress)
                if status == .completed && updated.completedAt == nil {
                    updated.completedAt = Date()
                }
                appState.updateGoal(updated)
            }

        case .edit(let original):
            var updated = original
            updated.title = trimmedTitle
            updated.description = descValue
            updated.status = status
            updated.progress = Int(progress)
            updated.focusSetID = focusSetID
            // Stamp completion when transitioning to .completed.
            if status == .completed && updated.completedAt == nil {
                updated.completedAt = Date()
            } else if status != .completed {
                updated.completedAt = nil
            }
            appState.updateGoal(updated)
        }
        dismiss()
    }

    private func deleteAndDismiss() {
        if case .edit(let goal) = mode {
            appState.deleteGoal(id: goal.id)
        }
        dismiss()
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
