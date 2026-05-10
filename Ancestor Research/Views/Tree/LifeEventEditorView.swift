import SwiftUI

/// Sheet for adding or editing a `LifeEvent` on a profile (M12). Mirrors
/// `NoteComposerView`'s pattern — same view drives both add and edit.
///
/// Init in one of two modes:
/// - `.add(profileID:)` — creates a new event for the given profile.
/// - `.edit(_:)` — edits an existing event in place; surfaces a Delete button.
struct LifeEventEditorView: View {
    enum Mode {
        case add(profileID: String)
        case edit(LifeEvent)
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var selectedType: LifeEventType = .occupation
    @State private var dateText: String = ""
    @State private var endDateText: String = ""
    @State private var location: String = ""
    @State private var eventDescription: String = ""
    @State private var confidence: FactConfidence = .standard
    @State private var sensitive: Bool = false

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var profileID: String {
        switch mode {
        case .add(let id): return id
        case .edit(let event): return event.profileID
        }
    }

    /// At least one of date/location/description must carry signal.
    private var hasSignal: Bool {
        !dateText.trimmingCharacters(in: .whitespaces).isEmpty
            || !location.trimmingCharacters(in: .whitespaces).isEmpty
            || !eventDescription.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditMode ? "Edit Life Event" : "Add Life Event")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Type", selection: $selectedType) {
                        ForEach(LifeEventType.allCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.systemImage)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.menu)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Date")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        TextField("e.g. 1887, ABT 1880, BEF 1890", text: $dateText)
                            .textFieldStyle(.roundedBorder)
                    }

                    if selectedType.hasDuration {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("End Date")
                                .font(AppTypography.badge)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            TextField("e.g. 1895, ABT 1900", text: $endDateText)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Location")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        TextField("Town, county, country", text: $location)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        TextField(descriptionPlaceholder(for: selectedType), text: $eventDescription, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...5)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Confidence")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Picker("Confidence", selection: $confidence) {
                            ForEach(FactConfidence.allCases, id: \.self) { c in
                                Text(c.displayName).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(confidence.explanation)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Sensitive — exclude from shared exports", isOn: $sensitive)
                        Text("Excluded from shared exports when the global filter is on.")
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                if isEditMode {
                    Button(role: .destructive) {
                        deleteEvent()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .tint(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button(isEditMode ? "Save" : "Add") { save() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasSignal)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 460)
        .onAppear(perform: hydrate)
    }

    private func hydrate() {
        if case .edit(let event) = mode {
            selectedType = event.type
            dateText = event.date?.original ?? ""
            endDateText = event.endDate?.original ?? ""
            location = event.location ?? ""
            eventDescription = event.description ?? ""
            confidence = event.confidence
            sensitive = event.sensitive
        }
    }

    private func descriptionPlaceholder(for type: LifeEventType) -> String {
        switch type {
        case .occupation: return "e.g. Framework knitter"
        case .residence: return "e.g. 42 King Street"
        case .militaryService: return "e.g. Royal Navy"
        case .education: return "e.g. Belper Grammar School"
        case .religion: return "e.g. Wesleyan Methodist"
        case .census: return "Household notes, head of household, etc."
        case .baptism, .burial: return "Officiant, parish, witnesses"
        case .probate: return "Executor, beneficiaries"
        case .immigration, .emigration: return "Origin/destination, vessel"
        case .other: return "Describe the event"
        }
    }

    private func parsedDate(_ raw: String) -> GenealogicalDate? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return GenealogicalDate(parsing: trimmed)
    }

    private func nilIfEmpty(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func save() {
        guard hasSignal else { return }
        let date = parsedDate(dateText)
        let endDate = selectedType.hasDuration ? parsedDate(endDateText) : nil
        let loc = nilIfEmpty(location)
        let desc = nilIfEmpty(eventDescription)

        switch mode {
        case .add(let profileID):
            _ = appState.createLifeEvent(
                profileID: profileID,
                type: selectedType,
                date: date,
                endDate: endDate,
                location: loc,
                description: desc,
                confidence: confidence,
                sensitive: sensitive
            )
        case .edit(let existing):
            var updated = existing
            updated.type = selectedType
            updated.date = date
            updated.endDate = endDate
            updated.location = loc
            updated.description = desc
            updated.confidence = confidence
            updated.sensitive = sensitive
            appState.updateLifeEvent(updated)
        }
        dismiss()
    }

    private func deleteEvent() {
        if case .edit(let event) = mode {
            appState.deleteLifeEvent(id: event.id)
            dismiss()
        }
    }
}
