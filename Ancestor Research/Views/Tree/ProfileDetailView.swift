import SwiftUI

/// Unified profile card — read inspector and edit form on the same surface,
/// rendered as a floating Liquid Glass card. The Edit button flips
/// `isEditing` in place: the shared layout switches `Text` → `TextField`,
/// the action row swaps to Cancel + Save Changes, and the heavy edit
/// machinery (per-field source picker, Correct/Alternative, citation)
/// slides in below.
///
/// Step 4 of `AncestorApp/PROFILE_VIEW_UNIFY_SPEC.md`: removes the modal
/// `EditPersonView` sheet from the inspector flow. External callsites
/// (audit / tree-graph context menu) still open `EditPersonView`, which is
/// now a thin sheet wrapper that hosts this view with
/// `startInEditMode: true`.
struct ProfileDetailView: View {
    let profile: Profile
    let snapshot: FamilyGraphSnapshot
    var onSetRoot: (() -> Void)?
    /// Caller-provided dismissal. When non-nil, an X button renders in the
    /// card's top-right corner. The tree-graph host wires this up to
    /// `treeVM.showInspector = false`; the modal wrapper leaves it nil and
    /// relies on the sheet's own close affordance.
    var onClose: (() -> Void)?
    /// Skip the read inspector and open straight into edit mode. Used by
    /// `EditPersonView` (the sheet wrapper) so the audit / context-menu
    /// edit flows still land directly on the form.
    var startInEditMode: Bool = false

    @Environment(AppState.self) private var appState

    // MARK: - Edit-mode form state (moved from `EditPersonView`)

    @State private var isEditing: Bool = false
    @State private var firstName: String = ""
    @State private var middleName: String = ""
    @State private var lastName: String = ""
    @State private var marriedSurname: String = ""
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

    @State private var defaultSource: SourceOrigin = .manualMemory
    @State private var sourcePerField: [ProfileField: SourceOrigin] = [:]
    @State private var fieldChoice: [ProfileField: ChangeMode] = [:]
    @State private var citation: Citation?
    @State private var quality: EvidenceQuality?
    @State private var original: OriginalSnapshot = .empty

    enum ChangeMode: String, Hashable {
        case correct
        case alternative
    }

    // MARK: - Read-mode sheets

    @State private var showingTimeline: Bool = false
    @State private var showingRelationshipCalculator: Bool = false
    @State private var cleansePresentation: CleansePresentation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if onClose != nil {
                    closeButtonRow
                }

                SharedProfileLayout(
                    profile: profile,
                    snapshot: snapshot,
                    editable: isEditing,
                    bindings: isEditing ? makeBindings() : nil
                )

                if isEditing {
                    sourceDetailsSection(profile: profile)
                    Divider()
                    sourceSection
                }

                Divider()
                actionRow
            }
            .padding(20)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 8)
        .onAppear {
            if startInEditMode {
                populate()
                isEditing = true
            }
        }
        .onChange(of: profile.id) { _, _ in
            // Selection changed — exit edit without saving and let the
            // next Edit click repopulate from the new profile. Preserves
            // the in-progress edit accidentally would invite a save against
            // the wrong subject.
            isEditing = false
        }
        .onChange(of: isEditing) { _, nowEditing in
            // Repopulate on every entry to edit mode so the form always
            // reflects the persisted profile, not a stale buffer from a
            // previous cancelled session.
            if nowEditing { populate() }
        }
        .sheet(isPresented: $showingTimeline) {
            ProfileTimelineView(profileID: profile.id)
                .frame(minWidth: 540, minHeight: 600)
        }
        .sheet(isPresented: $showingRelationshipCalculator) {
            RelationshipCalculatorView(
                initialFromID: appState.currentProject?.homePersonID,
                initialTargetID: profile.id
            )
        }
        .sheet(item: $cleansePresentation) { presentation in
            ProfileCleanseWizard(mode: presentation.mode)
        }
    }

    // MARK: - Layout pieces

    private var closeButtonRow: some View {
        HStack {
            Spacer()
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .help("Close")
            .accessibilityLabel("Close profile")
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if isEditing {
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    isEditing = false
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)

                Button("Save Changes") {
                    save()
                    isEditing = false
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(!hasChanges || !namesWithinLimit)
                .keyboardShortcut(.defaultAction)
            }
        } else {
            HStack(spacing: 8) {
                Button("Edit") {
                    isEditing = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    showingTimeline = true
                } label: {
                    Label("Timeline", systemImage: "calendar")
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    showingRelationshipCalculator = true
                } label: {
                    Label("Relationship to…", systemImage: "person.2")
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    appState.researchConfigProfile = profile
                } label: {
                    Label("Research", systemImage: "magnifyingglass")
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    cleansePresentation = .singleProfile(profile.id)
                } label: {
                    Label("Cleanse", systemImage: "sparkles")
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                if let setRoot = onSetRoot {
                    // Same action as the popover's Focus Here and the
                    // canvas right-click → Focus Here. Vocabulary
                    // harmonised so the user finds it in any surface
                    // they reach for.
                    Button("Focus Here") {
                        setRoot()
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Edit machinery

    private func makeBindings() -> ProfileEditBindings {
        ProfileEditBindings(
            firstName: $firstName,
            middleName: $middleName,
            lastName: $lastName,
            marriedSurname: $marriedSurname,
            nickName: $nickName,
            mothersMaidenName: $mothersMaidenName,
            gender: $gender,
            birthDateText: $birthDateText,
            birthLocation: $birthLocation,
            birthLocationCode: $birthLocationCode,
            deathDateText: $deathDateText,
            deathLocation: $deathLocation,
            deathLocationCode: $deathLocationCode,
            bio: $bio
        )
    }

    /// Per-changed-field source picker + Correct/Alternative toggle. Mirrors
    /// the prior `EditPersonView` implementation — empty when nothing has
    /// changed, so the card stays quiet until the user touches a field.
    @ViewBuilder
    private func sourceDetailsSection(profile: Profile) -> some View {
        let changedFields = ProfileField.allCases.filter { fieldChanged($0, profile: profile) }
        if !changedFields.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Source details for changed fields")
                ForEach(changedFields, id: \.self) { field in
                    changedFieldRow(field: field, profile: profile)
                }
            }
        }
    }

    @ViewBuilder
    private func changedFieldRow(field: ProfileField, profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayLabel(for: field))
                .font(AppTypography.cardMeta.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SourcePicker(
                    selection: Binding(
                        get: { sourcePerField[field] ?? defaultSource },
                        set: { sourcePerField[field] = $0 }
                    ),
                    label: "Source"
                )
                .pickerStyle(.menu)
                .controlSize(.small)

                if hasImportedSource(field, profile: profile) {
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
        }
    }

    private func displayLabel(for field: ProfileField) -> String {
        switch field {
        case .firstName: return "First name"
        case .middleName: return "Middle name"
        case .lastName: return "Last name"
        case .marriedSurname: return "Married surname"
        case .nickName: return "Known as"
        case .mothersMaidenName: return "Mother's maiden name"
        case .gender: return "Gender"
        case .birthDate: return "Birth date"
        case .birthLocation: return "Birth location"
        case .deathDate: return "Death date"
        case .deathLocation: return "Death location"
        case .bio: return "Biography"
        case .nameForms: return "Name variants"
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Default source for this edit")
            SourcePicker(selection: $defaultSource)
                .pickerStyle(.menu)
                .onChange(of: defaultSource) { _, newValue in
                    for field in ProfileField.allCases where sourcePerField[field] == nil {
                        sourcePerField[field] = newValue
                    }
                }
            Text("Set per field above — this default applies to fields you don't override.")
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

    private func hasImportedSource(_ field: ProfileField, profile: Profile) -> Bool {
        (profile.sources[field] ?? []).contains { !$0.origin.isManual }
    }

    private func fieldChanged(_ field: ProfileField, profile: Profile) -> Bool {
        switch field {
        case .firstName: return AutoSuggestService.normaliseName(firstName) != original.firstName
        case .middleName: return AutoSuggestService.normaliseName(middleName) != original.middleName
        case .lastName: return AutoSuggestService.normaliseName(lastName) != original.lastName
        case .marriedSurname: return AutoSuggestService.normaliseName(marriedSurname) != original.marriedSurname
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
        // This flat-field editor never edits name forms, so it never reports a
        // change for them; name-form edits will land through their own section.
        case .nameForms:
            return false
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    /// Populate the form state from the current profile. Called on entry
    /// to edit mode (and on initial appearance when `startInEditMode` is
    /// true). Idempotent — safe to call repeatedly.
    private func populate() {
        firstName = profile.firstName ?? ""
        middleName = profile.middleName ?? ""
        lastName = profile.lastName ?? ""
        marriedSurname = profile.marriedSurname ?? ""
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
            marriedSurname: profile.marriedSurname,
            nickName: profile.nickName,
            mothersMaidenName: profile.mothersMaidenName,
            gender: profile.gender,
            birthDate: profile.birthDate,
            birthLocation: profile.birthLocation,
            deathDate: profile.deathDate,
            deathLocation: profile.deathLocation,
            bio: profile.bio
        )
        // Reset per-field overrides and choice buffers for this edit session.
        citation = nil
        quality = nil
        fieldChoice = [:]
        defaultSource = SourceDefaults.defaultSource(
            context: .relativeOf(
                profileID: profile.id,
                primarySource: profile.primarySource
            )
        )
        sourcePerField = [:]
        for field in ProfileField.allCases {
            sourcePerField[field] = defaultSource
        }
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
        let newMarried = AutoSuggestService.normaliseName(marriedSurname)
        if newMarried != original.marriedSurname {
            changes.append((.marriedSurname, original.marriedSurname, newMarried))
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
        let allChanges = buildChanges()
        let allDateChanges = buildDateChanges()

        let correctChanges = allChanges.filter { (fieldChoice[$0.field] ?? .correct) == .correct }
        let correctDateChanges = allDateChanges.filter { (fieldChoice[$0.field] ?? .correct) == .correct }

        if !correctChanges.isEmpty || !correctDateChanges.isEmpty {
            appState.editProfile(
                id: profile.id,
                changes: correctChanges,
                dateChanges: correctDateChanges,
                source: defaultSource,
                sourceByField: sourcePerField
            )
        }

        if let db = appState.currentDatabase {
            try? db.updateProfileLocationCodes(
                profileID: profile.id,
                birthCode: birthLocationCode,
                deathCode: deathLocationCode
            )
        }

        for change in allChanges where (fieldChoice[change.field] ?? .correct) == .alternative {
            if let raw = change.newValue, !raw.isEmpty {
                appState.recordAlternativeFact(
                    profileID: profile.id, field: change.field,
                    rawValue: raw, source: sourcePerField[change.field] ?? defaultSource
                )
            }
        }
        for change in allDateChanges where (fieldChoice[change.field] ?? .correct) == .alternative {
            if let raw = change.newDate?.original, !raw.isEmpty {
                appState.recordAlternativeFact(
                    profileID: profile.id, field: change.field,
                    rawValue: raw, source: sourcePerField[change.field] ?? defaultSource
                )
            }
        }

        let hasCitation = (citation != nil && !(citation?.isEmpty ?? true)) || quality != nil
        if hasCitation {
            let changedFields: [ProfileField] = allChanges.map(\.field) + allDateChanges.map(\.field)
            for field in changedFields {
                appState.attachCitation(
                    profileID: profile.id, field: field,
                    origin: sourcePerField[field] ?? defaultSource,
                    citation: citation, quality: quality
                )
            }
        }
    }

    private struct OriginalSnapshot {
        var firstName: String?
        var middleName: String?
        var lastName: String?
        var marriedSurname: String?
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
