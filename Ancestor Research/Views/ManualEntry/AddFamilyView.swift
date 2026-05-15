import SwiftUI

/// Sheet for adding a parent couple plus their children together.
/// Each parent and child can be either an existing profile (picked) or a new
/// profile (filled in inline). Produces a single `addFamily` transaction.
struct AddFamilyView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Drives the source default so census transcription, sibling shortcuts,
    /// etc. land on the right `SourceOrigin` rather than always `.manualMemory`.
    var context: EntryContext = .unknown

    // MARK: Form state — parents
    @State private var fatherSlot: PersonSlot = PersonSlot(role: .father)
    @State private var motherSlot: PersonSlot = PersonSlot(role: .mother)

    // MARK: Marriage
    @State private var marriageDateText: String = ""
    @State private var marriageLocation: String = ""
    @State private var marriageLocationCode: String? = nil

    // MARK: Children
    @State private var childSlots: [PersonSlot] = [PersonSlot(role: .child)]

    // MARK: Source
    @State private var source: SourceOrigin = .manualMemory

    // MARK: Census mode (M16.4)
    @State private var transcribingCensus: Bool = false
    @State private var censusType: CensusType = .census1881
    @State private var censusYearText: String = "1881"
    @State private var censusAddress: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add a Family")
                    .font(.title2).fontWeight(.semibold)
                Spacer()
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    censusToggleSection
                    if transcribingCensus {
                        CensusFieldsSection(
                            censusType: $censusType,
                            yearText: $censusYearText,
                            address: $censusAddress
                        )
                    }
                    parentSection(label: "Father", slot: $fatherSlot, defaultGender: .male)
                    parentSection(label: "Mother", slot: $motherSlot, defaultGender: .female)
                    marriageSection
                    childrenSection
                    sourceSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 640)
        .onAppear {
            // Pull the source default from context (M16.5). Census mode
            // takes precedence — toggling it later flips the source via
            // the toggle's onChange.
            source = SourceDefaults.defaultSource(
                context: context, censusMode: transcribingCensus
            )
        }
    }

    // MARK: - Sections

    private var censusToggleSection: some View {
        Toggle("Transcribing a census record?", isOn: $transcribingCensus)
            .onChange(of: transcribingCensus) { _, newValue in
                source = SourceDefaults.defaultSource(
                    context: context, censusMode: newValue
                )
            }
    }

    @ViewBuilder
    private func parentSection(label: String, slot: Binding<PersonSlot>, defaultGender: Gender) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(label)
            modePicker(for: slot)
            switch slot.wrappedValue.mode {
            case .new:
                newPersonFields(slot: slot, defaultGender: defaultGender)
            case .existing:
                ProfilePickerField(
                    label: label,
                    snapshot: appState.snapshot,
                    selectedID: slot.existingID
                )
            }
            if transcribingCensus {
                CensusPersonRow(
                    ageText: slot.censusAgeText,
                    occupation: slot.censusOccupation,
                    censusYear: parsedCensusYear
                )
            }
        }
    }

    private var marriageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Marriage (optional)")
            DateParsePreviewField(label: "Marriage date", text: $marriageDateText)
            LocationPicker(
                label: "Marriage location",
                text: $marriageLocation,
                locationCode: $marriageLocationCode
            )
        }
    }

    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Children")
            ForEach($childSlots) { $slot in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(slot.mode == .existing ? "Existing person" : "New person")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            childSlots.removeAll { $0.id == slot.id }
                            if childSlots.isEmpty {
                                childSlots = [PersonSlot(role: .child)]
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove child")
                    }
                    modePicker(for: $slot)
                    switch slot.mode {
                    case .new:
                        newPersonFields(slot: $slot, defaultGender: nil)
                    case .existing:
                        ProfilePickerField(
                            label: "Child",
                            snapshot: appState.snapshot,
                            selectedID: $slot.existingID
                        )
                    }
                    if transcribingCensus {
                        CensusPersonRow(
                            ageText: $slot.censusAgeText,
                            occupation: $slot.censusOccupation,
                            censusYear: parsedCensusYear
                        )
                    }
                }
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 6))
            }
            Button {
                childSlots.append(PersonSlot(role: .child))
            } label: {
                Label("Add child", systemImage: "plus.circle")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Source")
            SourcePicker(selection: $source)
                .pickerStyle(.menu)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button("Add Family") { save() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(16)
    }

    // MARK: - Per-slot helpers

    @ViewBuilder
    private func modePicker(for slot: Binding<PersonSlot>) -> some View {
        Picker("", selection: slot.mode) {
            Text("New").tag(PersonSlot.Mode.new)
            Text("Existing").tag(PersonSlot.Mode.existing)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(appState.snapshot.profiles.isEmpty)
    }

    @ViewBuilder
    private func newPersonFields(slot: Binding<PersonSlot>, defaultGender: Gender?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("First name", text: slot.firstName)
                    .textFieldStyle(.roundedBorder)
                TextField("Last name", text: slot.lastName)
                    .textFieldStyle(.roundedBorder)
            }
            if defaultGender == nil {
                Picker("Gender", selection: slot.gender) {
                    Text("Unknown").tag(Gender.unknown)
                    Text("Female").tag(Gender.female)
                    Text("Male").tag(Gender.male)
                    Text("Other").tag(Gender.other)
                }
                .pickerStyle(.segmented)
            }
            DateParsePreviewField(label: "Birth date", text: slot.birthDateText)
            LocationPicker(
                label: "Birth location",
                text: slot.birthLocation,
                locationCode: slot.birthLocationCode
            )
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: - Save

    /// Parsed year from the census-mode year text. Falls back to the
    /// picker's known year when the user hasn't typed anything yet.
    private var parsedCensusYear: Int? {
        let trimmed = censusYearText.trimmingCharacters(in: .whitespaces)
        if let year = Int(trimmed) { return year }
        return censusType.year
    }

    private var canSave: Bool {
        // Need at least one populated parent and one populated child.
        let parentReady = fatherSlot.isReady(snapshot: appState.snapshot)
            || motherSlot.isReady(snapshot: appState.snapshot)
        let childReady = childSlots.contains { $0.isReady(snapshot: appState.snapshot) }
        return parentReady && childReady
    }

    private func save() {
        var profiles: [Profile] = []
        var relationships: [Relationship] = []
        // Slot.id → resolved profileID, so we can attach census life events
        // after the family is committed.
        var slotProfileIDs: [UUID: String] = [:]

        let fatherID = resolveOrCreate(slot: fatherSlot, defaultGender: .male, into: &profiles)
        if let fatherID { slotProfileIDs[fatherSlot.id] = fatherID }
        let motherID = resolveOrCreate(slot: motherSlot, defaultGender: .female, into: &profiles)
        if let motherID { slotProfileIDs[motherSlot.id] = motherID }

        if let fatherID, let motherID {
            relationships.append(Relationship(
                id: UUID(), from: fatherID, to: motherID,
                type: .spouse, role: nil, subtype: .unknown,
                marriageDate: GenealogicalDate.parsePreview(marriageDateText).parsed,
                marriageLocation: AutoSuggestService.normaliseName(marriageLocation),
                marriageLocationCode: marriageLocationCode,
                divorceDate: nil
            ))
        }

        for slot in childSlots where slot.isReady(snapshot: appState.snapshot) {
            guard let childID = resolveOrCreate(slot: slot, defaultGender: nil, into: &profiles) else { continue }
            slotProfileIDs[slot.id] = childID
            if let fatherID {
                relationships.append(Relationship(
                    id: UUID(), from: fatherID, to: childID,
                    type: .parent, role: .father, subtype: .biological,
                    marriageDate: nil, marriageLocation: nil, divorceDate: nil
                ))
            }
            if let motherID {
                relationships.append(Relationship(
                    id: UUID(), from: motherID, to: childID,
                    type: .parent, role: .mother, subtype: .biological,
                    marriageDate: nil, marriageLocation: nil, divorceDate: nil
                ))
            }
        }

        guard !profiles.isEmpty || !relationships.isEmpty else {
            dismiss()
            return
        }

        // Census mode forces source to .manualRecord; otherwise honour
        // whatever the user picked (which itself was seeded from
        // SourceDefaults at appear time).
        let effectiveSource = transcribingCensus
            ? SourceDefaults.defaultSource(context: context, censusMode: true)
            : source

        appState.addFamily(profiles: profiles, relationships: relationships, source: effectiveSource)

        // Attach a `.census` LifeEvent for each profile that the user
        // populated with a year + address. Age and occupation are
        // optional; we still create the event without them so the
        // appearance-on-the-record fact is captured.
        if transcribingCensus {
            attachCensusLifeEvents(slotProfileIDs: slotProfileIDs)
        }

        dismiss()
    }

    /// Walk every populated slot and create a `.census` life event for
    /// the resolved profile. Skipped when census-mode is off — see save().
    private func attachCensusLifeEvents(slotProfileIDs: [UUID: String]) {
        let address = censusAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let yearText = parsedCensusYear.map({ String($0) }),
              !address.isEmpty
        else { return }

        let allSlots = [fatherSlot, motherSlot] + childSlots
        for slot in allSlots {
            guard let profileID = slotProfileIDs[slot.id] else { continue }
            let occupation = slot.censusOccupation.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = appState.createLifeEvent(
                profileID: profileID,
                type: .census,
                date: GenealogicalDate(parsing: yearText),
                location: address,
                description: occupation.isEmpty ? nil : occupation,
                sources: [],
                confidence: .standard
            )
        }
    }

    private func resolveOrCreate(
        slot: PersonSlot,
        defaultGender: Gender?,
        into profiles: inout [Profile]
    ) -> String? {
        switch slot.mode {
        case .existing:
            return slot.existingID
        case .new:
            guard slot.isPopulated else { return nil }
            let id = UUID().uuidString
            profiles.append(Profile(
                id: id,
                externalIDs: [:],
                firstName: AutoSuggestService.normaliseName(slot.firstName),
                lastName: AutoSuggestService.normaliseName(slot.lastName),
                gender: (slot.gender == .unknown ? nil : slot.gender) ?? defaultGender,
                attributes: nil,
                birthDate: GenealogicalDate.parsePreview(slot.birthDateText).parsed,
                birthLocation: AutoSuggestService.normaliseName(slot.birthLocation),
                birthLocationCode: slot.birthLocationCode,
                deathDate: nil,
                deathLocation: nil,
                deathLocationCode: nil,
                bio: nil,
                isDeleted: false,
                sources: [:],
                disputes: [:]
            ))
            return id
        }
    }

    // MARK: - PersonSlot

    /// Per-slot form state: holds either a picked existing-profile ID or new-person fields.
    /// `censusAge`/`censusOccupation` are populated only when the parent
    /// AddFamilyView is in census-transcription mode.
    private struct PersonSlot: Identifiable {
        enum Mode: Hashable { case new, existing }
        enum Role { case father, mother, child }

        let id = UUID()
        let role: Role
        var mode: Mode = .new
        var existingID: String?
        var firstName: String = ""
        var lastName: String = ""
        var gender: Gender = .unknown
        var birthDateText: String = ""
        var birthLocation: String = ""
        var birthLocationCode: String? = nil

        // Census-mode per-person fields (M16.4)
        var censusAgeText: String = ""
        var censusOccupation: String = ""

        var isPopulated: Bool {
            AutoSuggestService.normaliseName(firstName) != nil ||
                AutoSuggestService.normaliseName(lastName) != nil ||
                !birthDateText.trimmingCharacters(in: .whitespaces).isEmpty
        }

        func isReady(snapshot: FamilyGraphSnapshot) -> Bool {
            switch mode {
            case .new: return isPopulated
            case .existing:
                guard let id = existingID else { return false }
                return snapshot.profiles[id] != nil
            }
        }
    }
}
