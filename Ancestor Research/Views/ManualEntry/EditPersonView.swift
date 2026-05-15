import SwiftUI

/// Sheet for editing an existing profile. Pre-populates from the current
/// profile and writes only the fields that actually changed when the user saves.
/// Existing source badges are shown above each field so the user knows the
/// provenance of the value they're about to overwrite.
struct EditPersonView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let profileID: String

    // MARK: Form state
    @State private var firstName: String = ""
    @State private var middleName: String = ""
    @State private var lastName: String = ""
    @State private var nickName: String = ""
    @State private var mothersMaidenName: String = ""
    @State private var gender: Gender = .unknown
    @State private var birthDateText: String = ""
    @State private var birthLocation: String = ""
    @State private var birthLocationCode: String? = nil
    @State private var deathDateText: String = ""
    @State private var deathLocation: String = ""
    @State private var deathLocationCode: String? = nil
    @State private var bio: String = ""

    /// Default source for any field whose per-field picker hasn't been
    /// touched. Acts as the seed when populating `sourcePerField` on load.
    @State private var defaultSource: SourceOrigin = .manualMemory

    /// M17.2 — per-field source picker. Each editable field gets its own
    /// `SourceOrigin`. Populated once on load with the default source, then
    /// the user can override individually via the inline picker shown below
    /// each field. On save, AppState groups changes by source so each field
    /// lands in `field_sources` with the correct origin.
    @State private var sourcePerField: [ProfileField: SourceOrigin] = [:]

    @State private var didLoad: Bool = false

    // Optional structured citation + evidence-quality rating. Scoped to the
    // chosen default source (one citation per save), applied to every changed
    // field whose per-field source matches the default. Per-field citation
    // entry can be revisited if a real user workflow demands distinct
    // citations on distinct fields in one edit; for now a single shared
    // citation matches the most common case.
    @State private var citation: Citation?
    @State private var quality: EvidenceQuality?

    /// Per-field choice for changes to fields with non-manual existing sources.
    /// `.correct` (default) overwrites the column value; `.alternative` keeps
    /// the imported value and appends the user's value as a competing source.
    @State private var fieldChoice: [ProfileField: ChangeMode] = [:]

    enum ChangeMode: String, Hashable {
        case correct
        case alternative
    }

    // Original values captured on load — used to compute the diff at save.
    @State private var original: OriginalSnapshot = .empty

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if let profile = appState.snapshot.profiles[profileID] {
                    VStack(alignment: .leading, spacing: 16) {
                        nameSection(profile: profile)
                        datesSection(profile: profile)
                        bioSection(profile: profile)
                        sourceSection
                    }
                    .padding(20)
                } else {
                    Text("Profile not found.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear { loadIfNeeded() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Edit Person")
                .font(.title2).fontWeight(.semibold)
            Spacer()
        }
        .padding(20)
    }

    private func nameSection(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Name")
            HStack(spacing: 8) {
                fieldWithBadges(field: .firstName, profile: profile) {
                    TextField("First name", text: $firstName)
                        .textFieldStyle(.roundedBorder)
                }
                fieldWithBadges(field: .middleName, profile: profile) {
                    TextField("Middle name", text: $middleName)
                        .textFieldStyle(.roundedBorder)
                }
                fieldWithBadges(field: .lastName, profile: profile) {
                    TextField("Last name", text: $lastName)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if let warning = NameLengthWarning.warningText(forName: firstName)
                ?? NameLengthWarning.warningText(forName: middleName)
                ?? NameLengthWarning.warningText(forName: lastName) {
                Text(warning)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(AnyShapeStyle(Color.orange))
            }
            // Known-as / nickname — common in historical records (Bill for
            // William, Maggie for Margaret). Kept off `displayName` so the
            // tree doesn't get noisy.
            HStack(spacing: 8) {
                fieldWithBadges(field: .nickName, profile: profile) {
                    TextField("Known as (optional)", text: $nickName)
                        .textFieldStyle(.roundedBorder)
                }
                fieldWithBadges(field: .mothersMaidenName, profile: profile) {
                    TextField("Mother's maiden name (optional)", text: $mothersMaidenName)
                        .textFieldStyle(.roundedBorder)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                sourceBadgeRow(for: .gender, profile: profile)
                Picker("Gender", selection: $gender) {
                    Text("Unknown").tag(Gender.unknown)
                    Text("Female").tag(Gender.female)
                    Text("Male").tag(Gender.male)
                    Text("Other").tag(Gender.other)
                }
                .pickerStyle(.segmented)
                perFieldSourcePicker(for: .gender, profile: profile)
                correctOrAlternativePicker(for: .gender, profile: profile)
            }
        }
    }

    private func datesSection(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Dates & Places")

            VStack(alignment: .leading, spacing: 4) {
                sourceBadgeRow(for: .birthDate, profile: profile)
                DateParsePreviewField(label: "Birth date", text: $birthDateText)
                perFieldSourcePicker(for: .birthDate, profile: profile)
                correctOrAlternativePicker(for: .birthDate, profile: profile)
            }
            VStack(alignment: .leading, spacing: 4) {
                sourceBadgeRow(for: .birthLocation, profile: profile)
                LocationPicker(
                    label: "Birth location",
                    text: $birthLocation,
                    locationCode: $birthLocationCode
                )
                perFieldSourcePicker(for: .birthLocation, profile: profile)
                correctOrAlternativePicker(for: .birthLocation, profile: profile)
            }
            VStack(alignment: .leading, spacing: 4) {
                sourceBadgeRow(for: .deathDate, profile: profile)
                DateParsePreviewField(label: "Death date", text: $deathDateText)
                perFieldSourcePicker(for: .deathDate, profile: profile)
                correctOrAlternativePicker(for: .deathDate, profile: profile)
            }
            VStack(alignment: .leading, spacing: 4) {
                sourceBadgeRow(for: .deathLocation, profile: profile)
                LocationPicker(
                    label: "Death location",
                    text: $deathLocation,
                    locationCode: $deathLocationCode
                )
                perFieldSourcePicker(for: .deathLocation, profile: profile)
                correctOrAlternativePicker(for: .deathLocation, profile: profile)
            }
        }
    }

    private func bioSection(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Bio")
            sourceBadgeRow(for: .bio, profile: profile)
            TextEditor(text: $bio)
                .font(AppTypography.cardBody)
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            perFieldSourcePicker(for: .bio, profile: profile)
            correctOrAlternativePicker(for: .bio, profile: profile)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Default source for this edit")
            SourcePicker(selection: $defaultSource)
                .pickerStyle(.menu)
                .onChange(of: defaultSource) { _, newValue in
                    // Re-seed any field whose per-field source still matches
                    // the previous default. Fields the user has explicitly
                    // overridden keep their override.
                    for field in ProfileField.allCases where sourcePerField[field] == nil {
                        sourcePerField[field] = newValue
                    }
                }
            Text("Set per field below — this default applies to fields you don't override.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.tertiary)
            CitationEntryView(
                citation: $citation,
                quality: $quality,
                repositorySuggestions: CitationSuggestService.repositories(snapshot: appState.snapshot),
                collectionSuggestions: CitationSuggestService.collections(snapshot: appState.snapshot)
            )
        }
    }

    @ViewBuilder
    private func fieldWithBadges<Content: View>(
        field: ProfileField,
        profile: Profile,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sourceBadgeRow(for: field, profile: profile)
            content()
            perFieldSourcePicker(for: field, profile: profile)
            correctOrAlternativePicker(for: field, profile: profile)
        }
    }

    /// Inline `Source` picker for a single field. Visible only while the
    /// field is being edited (i.e. the user has changed its value), to keep
    /// the form quiet when nothing has changed. Defaults to the value seeded
    /// at load time from `SourceDefaults`.
    @ViewBuilder
    private func perFieldSourcePicker(for field: ProfileField, profile: Profile) -> some View {
        if fieldChanged(field, profile: profile) {
            HStack(spacing: 6) {
                Text("Source")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                SourcePicker(
                    selection: Binding(
                        get: { sourcePerField[field] ?? defaultSource },
                        set: { sourcePerField[field] = $0 }
                    ),
                    label: ""
                )
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
            }
        }
    }

    /// Whether this field has at least one imported (non-manual) source.
    /// Drives whether the user gets the "Correct vs alternative" choice.
    private func hasImportedSource(_ field: ProfileField, profile: Profile) -> Bool {
        (profile.sources[field] ?? []).contains { !$0.origin.isManual }
    }

    /// Inline segmented picker shown only when the user has changed an imported
    /// field. Default `.correct` matches existing behaviour.
    @ViewBuilder
    private func correctOrAlternativePicker(for field: ProfileField, profile: Profile) -> some View {
        let changed = fieldChanged(field, profile: profile)
        if changed && hasImportedSource(field, profile: profile) {
            Picker("", selection: Binding(
                get: { fieldChoice[field] ?? .correct },
                set: { fieldChoice[field] = $0 }
            )) {
                Text("Correct").tag(ChangeMode.correct)
                Text("Alternative").tag(ChangeMode.alternative)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
        }
    }

    private func fieldChanged(_ field: ProfileField, profile: Profile) -> Bool {
        switch field {
        case .firstName: return AutoSuggestService.normaliseName(firstName) != original.firstName
        case .middleName: return AutoSuggestService.normaliseName(middleName) != original.middleName
        case .lastName: return AutoSuggestService.normaliseName(lastName) != original.lastName
        case .nickName: return AutoSuggestService.normaliseName(nickName) != original.nickName
        case .mothersMaidenName: return AutoSuggestService.normaliseName(mothersMaidenName) != original.mothersMaidenName
        case .gender:
            let g: Gender? = gender == .unknown ? nil : gender
            return g != original.gender
        case .birthDate:
            return GenealogicalDate.parsePreview(birthDateText).parsed != original.birthDate
        case .birthLocation:
            return AutoSuggestService.normaliseName(birthLocation) != original.birthLocation
        case .deathDate:
            return GenealogicalDate.parsePreview(deathDateText).parsed != original.deathDate
        case .deathLocation:
            return AutoSuggestService.normaliseName(deathLocation) != original.deathLocation
        case .bio:
            let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            let new: String? = trimmed.isEmpty ? nil : trimmed
            return new != original.bio
        }
    }

    @ViewBuilder
    private func sourceBadgeRow(for field: ProfileField, profile: Profile) -> some View {
        let sources = profile.sources[field] ?? []
        if !sources.isEmpty {
            HStack(spacing: 4) {
                ForEach(sources, id: \.raw) { src in
                    Text(SourcePicker.displayName(for: src.origin))
                        .font(AppTypography.badge)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button("Save Changes") { save() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges || !namesWithinLimit)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func loadIfNeeded() {
        guard !didLoad, let profile = appState.snapshot.profiles[profileID] else { return }
        firstName = profile.firstName ?? ""
        middleName = profile.middleName ?? ""
        lastName = profile.lastName ?? ""
        nickName = profile.nickName ?? ""
        mothersMaidenName = profile.mothersMaidenName ?? ""
        gender = profile.gender ?? .unknown
        birthDateText = profile.birthDate?.original ?? ""
        birthLocation = profile.birthLocation ?? ""
        birthLocationCode = profile.birthLocationCode
        deathDateText = profile.deathDate?.original ?? ""
        deathLocation = profile.deathLocation ?? ""
        deathLocationCode = profile.deathLocationCode
        bio = profile.bio ?? ""
        original = OriginalSnapshot(
            firstName: profile.firstName,
            middleName: profile.middleName,
            lastName: profile.lastName,
            nickName: profile.nickName,
            mothersMaidenName: profile.mothersMaidenName,
            gender: profile.gender,
            birthDate: profile.birthDate,
            birthLocation: profile.birthLocation,
            deathDate: profile.deathDate,
            deathLocation: profile.deathLocation,
            bio: profile.bio
        )
        // M17.2 — pick a contextual default source. For an existing person
        // we treat the edit as "relativeOf" the same person so an existing
        // manual primary source is inherited (the user's already declared
        // they're working from a Document/Record/etc.); GEDCOM/WikiTree
        // primary sources fall back to .manualMemory because the new edit
        // isn't from the original import.
        defaultSource = SourceDefaults.defaultSource(
            context: .relativeOf(
                profileID: profileID,
                primarySource: profile.primarySource
            )
        )
        // Seed per-field source dict so each entry starts at the default.
        // The user can then override individual fields via the inline picker.
        for field in ProfileField.allCases {
            sourcePerField[field] = defaultSource
        }
        didLoad = true
    }

    private var hasChanges: Bool {
        !buildChanges().isEmpty || !buildDateChanges().isEmpty
    }

    private var namesWithinLimit: Bool {
        firstName.count <= AutoSuggestService.nameHardLimitLength
            && lastName.count <= AutoSuggestService.nameHardLimitLength
    }

    private func buildChanges() -> [(field: ProfileField, oldValue: String?, newValue: String?)] {
        var changes: [(ProfileField, String?, String?)] = []
        let newFirst = AutoSuggestService.normaliseName(firstName)
        if newFirst != original.firstName {
            changes.append((.firstName, original.firstName, newFirst))
        }
        let newMiddle = AutoSuggestService.normaliseName(middleName)
        if newMiddle != original.middleName {
            changes.append((.middleName, original.middleName, newMiddle))
        }
        let newLast = AutoSuggestService.normaliseName(lastName)
        if newLast != original.lastName {
            changes.append((.lastName, original.lastName, newLast))
        }
        let newNick = AutoSuggestService.normaliseName(nickName)
        if newNick != original.nickName {
            changes.append((.nickName, original.nickName, newNick))
        }
        let newMMN = AutoSuggestService.normaliseName(mothersMaidenName)
        if newMMN != original.mothersMaidenName {
            changes.append((.mothersMaidenName, original.mothersMaidenName, newMMN))
        }
        let newGender: Gender? = gender == .unknown ? nil : gender
        if newGender != original.gender {
            changes.append((.gender, original.gender?.rawValue, newGender?.rawValue))
        }
        let newBirthLoc = AutoSuggestService.normaliseName(birthLocation)
        if newBirthLoc != original.birthLocation {
            changes.append((.birthLocation, original.birthLocation, newBirthLoc))
        }
        let newDeathLoc = AutoSuggestService.normaliseName(deathLocation)
        if newDeathLoc != original.deathLocation {
            changes.append((.deathLocation, original.deathLocation, newDeathLoc))
        }
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let newBio: String? = trimmedBio.isEmpty ? nil : trimmedBio
        if newBio != original.bio {
            changes.append((.bio, original.bio, newBio))
        }
        return changes.map { ($0.0, $0.1, $0.2) }
    }

    private func buildDateChanges() -> [(field: ProfileField, oldDate: GenealogicalDate?, newDate: GenealogicalDate?)] {
        var dateChanges: [(ProfileField, GenealogicalDate?, GenealogicalDate?)] = []
        let newBirth = GenealogicalDate.parsePreview(birthDateText).parsed
        if newBirth != original.birthDate {
            dateChanges.append((.birthDate, original.birthDate, newBirth))
        }
        let newDeath = GenealogicalDate.parsePreview(deathDateText).parsed
        if newDeath != original.deathDate {
            dateChanges.append((.deathDate, original.deathDate, newDeath))
        }
        return dateChanges.map { ($0.0, $0.1, $0.2) }
    }

    private func save() {
        // Split changes into "corrections" (overwrite the column value) and
        // "alternatives" (append a competing field source). Per-field choice
        // defaults to .correct; only fields with imported sources can be
        // marked .alternative via the inline picker.
        let allChanges = buildChanges()
        let allDateChanges = buildDateChanges()

        let correctChanges = allChanges.filter { (fieldChoice[$0.field] ?? .correct) == .correct }
        let correctDateChanges = allDateChanges.filter { (fieldChoice[$0.field] ?? .correct) == .correct }

        if !correctChanges.isEmpty || !correctDateChanges.isEmpty {
            // M17.2 — pass the per-field source map so each field's source
            // lands distinct in `field_sources`. Fields without an explicit
            // override fall back to `defaultSource`.
            appState.editProfile(
                id: profileID,
                changes: correctChanges,
                dateChanges: correctDateChanges,
                source: defaultSource,
                sourceByField: sourcePerField
            )
        }

        // Persist the gazetteer-picker's structured codes alongside the freeform
        // location strings. Bypasses the field-source machinery — codes are
        // derived metadata, not attributable facts. Always written so that
        // clearing a match (X-out badge) actually clears the stored code.
        if let db = appState.currentDatabase {
            try? db.updateProfileLocationCodes(
                profileID: profileID,
                birthCode: birthLocationCode,
                deathCode: deathLocationCode
            )
        }

        for change in allChanges where (fieldChoice[change.field] ?? .correct) == .alternative {
            // String fields: record the new typed value as a competing source.
            if let raw = change.newValue, !raw.isEmpty {
                appState.recordAlternativeFact(
                    profileID: profileID, field: change.field,
                    rawValue: raw, source: sourcePerField[change.field] ?? defaultSource
                )
            }
        }
        for change in allDateChanges where (fieldChoice[change.field] ?? .correct) == .alternative {
            if let raw = change.newDate?.original, !raw.isEmpty {
                appState.recordAlternativeFact(
                    profileID: profileID, field: change.field,
                    rawValue: raw, source: sourcePerField[change.field] ?? defaultSource
                )
            }
        }

        // Layer the citation onto every changed field's just-written source row.
        // Skipped when the user left the citation form empty. Each field's
        // citation lands on the row carrying that field's per-field origin.
        let hasCitation = (citation != nil && !(citation?.isEmpty ?? true)) || quality != nil
        if hasCitation {
            let changedFields: [ProfileField] = allChanges.map(\.field) + allDateChanges.map(\.field)
            for field in changedFields {
                appState.attachCitation(
                    profileID: profileID, field: field,
                    origin: sourcePerField[field] ?? defaultSource,
                    citation: citation, quality: quality
                )
            }
        }

        dismiss()
    }

    private struct OriginalSnapshot {
        var firstName: String?
        var middleName: String?
        var lastName: String?
        var nickName: String?
        var mothersMaidenName: String?
        var gender: Gender?
        var birthDate: GenealogicalDate?
        var birthLocation: String?
        var deathDate: GenealogicalDate?
        var deathLocation: String?
        var bio: String?

        static let empty = OriginalSnapshot()
    }
}
