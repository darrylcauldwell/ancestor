import SwiftUI

/// Sheet for adding a single person manually. Optionally relates the new
/// profile to an existing one (parent/child/sibling/spouse). Validation:
/// at least one identifying field (any name OR a birth year) is required.
struct AddPersonView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Optional context: relate the new person to this existing profile.
    var relatedToID: String?
    var relation: AutoSuggestService.RelationContext = .none

    /// Drives the source-default seed (M16.5). Falls back to `.unknown`
    /// for back-compat with any call site that hasn't been updated.
    var context: EntryContext = .unknown

    // MARK: Form state
    @State private var firstName: String = ""
    @State private var middleName: String = ""
    @State private var lastName: String = ""
    @State private var gender: Gender = .unknown
    @State private var birthDateText: String = ""
    @State private var birthLocation: String = ""
    @State private var deathDateText: String = ""
    @State private var deathLocation: String = ""
    @State private var bio: String = ""
    @State private var source: SourceOrigin = .manualMemory

    // Optional structured citation + evidence-quality rating, applied to every
    // field carrying the chosen source after the profile is created. nil when
    // the user leaves the citation section collapsed/empty (the common case).
    @State private var citation: Citation?
    @State private var quality: EvidenceQuality?

    // Advanced (collapsed by default)
    @State private var showAdvanced: Bool = false
    @State private var nameStatus: NameStatus = .known
    @State private var lifeStatus: LifeStatus = .normal
    @State private var privacy: Privacy = .normal

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    contextBanner
                    nameSection
                    datesSection
                    bioSection
                    sourceSection
                    advancedSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            applySurnameSuggestion()
            // M16.5 — pick a contextual default source rather than always
            // .manualMemory. Adding a sibling of someone with a Document
            // source inherits Document; adding a relative of a GEDCOM
            // import falls back to .manualMemory (we don't claim the new
            // person is in the original GEDCOM file).
            source = SourceDefaults.defaultSource(context: context)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Add Person")
                .font(.title2).fontWeight(.semibold)
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private var contextBanner: some View {
        if let relatedToID, let related = appState.snapshot.profiles[relatedToID] {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(relationLabel)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Text(related.displayName)
                    .font(AppTypography.cardBody.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Name")
            HStack(spacing: 8) {
                TextField("First name", text: $firstName)
                    .textFieldStyle(.roundedBorder)
                TextField("Middle name (optional)", text: $middleName)
                    .textFieldStyle(.roundedBorder)
                TextField("Last name", text: $lastName)
                    .textFieldStyle(.roundedBorder)
            }
            if let warning = NameLengthWarning.warningText(forName: firstName)
                ?? NameLengthWarning.warningText(forName: middleName)
                ?? NameLengthWarning.warningText(forName: lastName) {
                Text(warning)
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(AnyShapeStyle(Color.orange))
            }
            Picker("Gender", selection: $gender) {
                Text("Unknown").tag(Gender.unknown)
                Text("Female").tag(Gender.female)
                Text("Male").tag(Gender.male)
                Text("Other").tag(Gender.other)
            }
            .pickerStyle(.segmented)
        }
    }

    private var datesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Dates & Places")
            DateParsePreviewField(label: "Birth date", text: $birthDateText)
            TextField("Birth location", text: $birthLocation)
                .textFieldStyle(.roundedBorder)
            locationSuggestions(target: $birthLocation)
            DateParsePreviewField(label: "Death date", text: $deathDateText)
            TextField("Death location", text: $deathLocation)
                .textFieldStyle(.roundedBorder)
            locationSuggestions(target: $deathLocation)
        }
    }

    private var bioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Bio")
            TextEditor(text: $bio)
                .font(AppTypography.cardBody)
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Source")
            SourcePicker(selection: $source)
                .pickerStyle(.menu)
            CitationEntryView(
                citation: $citation,
                quality: $quality,
                repositorySuggestions: CitationSuggestService.repositories(snapshot: appState.snapshot),
                collectionSuggestions: CitationSuggestService.collections(snapshot: appState.snapshot)
            )
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Name status", selection: $nameStatus) {
                        Text("Known").tag(NameStatus.known)
                        Text("Unknown").tag(NameStatus.unknown)
                        Text("Placeholder").tag(NameStatus.placeholder)
                    }
                    Picker("Life status", selection: $lifeStatus) {
                        Text("Normal").tag(LifeStatus.normal)
                        Text("Infant death").tag(LifeStatus.infantDeath)
                        Text("Stillborn").tag(LifeStatus.stillborn)
                    }
                    Picker("Privacy", selection: $privacy) {
                        Text("Normal").tag(Privacy.normal)
                        Text("Living (private in exports)").tag(Privacy.livingPrivate)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Advanced").font(AppTypography.cardBody.weight(.medium))
            }
        }
    }

    @ViewBuilder
    private func locationSuggestions(target: Binding<String>) -> some View {
        let suggestions = AutoSuggestService.locations(snapshot: appState.snapshot)
            .filter { !$0.isEmpty }
            .prefix(5)
        if !suggestions.isEmpty && target.wrappedValue.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(suggestions), id: \.self) { loc in
                    Button(loc) { target.wrappedValue = loc }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
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
            Button("Add Person") { save() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private var canSave: Bool {
        // Reject when either name field exceeds the hard limit, regardless of
        // whether other identifying data is present.
        if firstName.count > AutoSuggestService.nameHardLimitLength { return false }
        if lastName.count > AutoSuggestService.nameHardLimitLength { return false }
        let birthYear = GenealogicalDate.parsePreview(birthDateText).parsed?.bestYear
        return AutoSuggestService.hasMinimumData(
            firstName: AutoSuggestService.normaliseName(firstName),
            lastName: AutoSuggestService.normaliseName(lastName),
            birthYear: birthYear
        )
    }

    private var relationLabel: String {
        switch relation {
        case .child: return "Adding child of"
        case .sibling: return "Adding sibling of"
        case .parent: return "Adding parent of"
        case .spouse: return "Adding spouse of"
        case .none: return "Related to"
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func applySurnameSuggestion() {
        // Only suggest if the user hasn't typed anything yet.
        guard lastName.isEmpty else { return }
        let suggestions = AutoSuggestService.surnames(
            contextID: relatedToID,
            relation: relation,
            snapshot: appState.snapshot
        )
        if let first = suggestions.first {
            lastName = first
        }
    }

    private func save() {
        let normalisedFirst = AutoSuggestService.normaliseName(firstName)
        let normalisedMiddle = AutoSuggestService.normaliseName(middleName)
        let normalisedLast = AutoSuggestService.normaliseName(lastName)
        let birth = GenealogicalDate.parsePreview(birthDateText).parsed
        let death = GenealogicalDate.parsePreview(deathDateText).parsed

        let attributes = PersonAttributes(
            nameStatus: nameStatus,
            lifeStatus: lifeStatus,
            privacy: privacy
        )

        let profile = Profile(
            id: UUID().uuidString,
            externalIDs: [:],
            firstName: normalisedFirst,
            middleName: normalisedMiddle,
            lastName: normalisedLast,
            gender: gender == .unknown ? nil : gender,
            attributes: attributes == .default ? nil : attributes,
            birthDate: birth,
            birthLocation: AutoSuggestService.normaliseName(birthLocation),
            deathDate: death,
            deathLocation: AutoSuggestService.normaliseName(deathLocation),
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bio,
            isDeleted: false,
            sources: [:],
            disputes: [:]
        )

        let relationships = buildRelationships(forNewID: profile.id)
        if relationships.isEmpty {
            appState.addProfile(profile, source: source, relatedTo: nil)
        } else {
            // addFamily commits profile + every edge in one structural transaction
            // so a single undo reverses the whole "Add Parent of Alice" action.
            appState.addFamily(
                profiles: [profile],
                relationships: relationships,
                source: source
            )
        }

        // Attach the structured citation + quality rating to every field that
        // got the chosen source. Skipped when the user left the citation form
        // empty (no DB rows touched, no churn).
        if (citation != nil && !(citation?.isEmpty ?? true)) || quality != nil {
            for field in fieldsWithSource(profile: profile) {
                appState.attachCitation(
                    profileID: profile.id, field: field,
                    origin: source, citation: citation, quality: quality
                )
            }
        }

        dismiss()
    }

    /// Profile fields that received a `field_sources` row during addProfile —
    /// mirrors `ProjectDatabase.insertFieldSources` (any non-nil value, including
    /// empty strings, gets a row). Drives which rows we layer the citation onto.
    private func fieldsWithSource(profile: Profile) -> [ProfileField] {
        var fields: [ProfileField] = []
        if profile.firstName != nil { fields.append(.firstName) }
        if profile.lastName != nil { fields.append(.lastName) }
        if profile.gender != nil { fields.append(.gender) }
        if profile.birthDate != nil { fields.append(.birthDate) }
        if profile.birthLocation != nil { fields.append(.birthLocation) }
        if profile.deathDate != nil { fields.append(.deathDate) }
        if profile.deathLocation != nil { fields.append(.deathLocation) }
        if profile.bio != nil { fields.append(.bio) }
        return fields
    }

    /// Build the relationship edges to create alongside the new profile.
    /// Atomic via AppState.addFamily — the new profile and every edge land
    /// in one transaction so undo behaves predictably.
    private func buildRelationships(forNewID newID: String) -> [Relationship] {
        guard let relatedToID else { return [] }
        switch relation {
        case .child:
            // Context is the parent of the new profile.
            return [parentEdge(parent: relatedToID, child: newID, role: parentRole(forContext: relatedToID))]
        case .parent:
            // The new profile is the parent of the context — inverse direction.
            return [parentEdge(parent: newID, child: relatedToID, role: parentRoleFromGender(gender))]
        case .spouse:
            return [Relationship(
                id: UUID(), from: relatedToID, to: newID,
                type: .spouse, role: nil, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil
            )]
        case .sibling:
            // Sibling means "shares parents". If the anchor already has parents
            // recorded, attach the new profile as a child of each. If not,
            // there's no shared parent yet — fall back to creating an unlinked
            // profile and let the user wire up parents later via Add Relationship.
            let parents = appState.snapshot.parentsOf(relatedToID)
            return parents.map { parent in
                parentEdge(parent: parent.id, child: newID, role: parentRoleFromGender(parent.gender))
            }
        case .none:
            return []
        }
    }

    private func parentEdge(parent: String, child: String, role: ParentRole?) -> Relationship {
        Relationship(
            id: UUID(), from: parent, to: child,
            type: .parent, role: role, subtype: .biological,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private func parentRoleFromGender(_ gender: Gender?) -> ParentRole? {
        switch gender {
        case .female: return .mother
        case .male: return .father
        default: return .unspecified
        }
    }

    private func parentRole(forContext contextID: String) -> ParentRole? {
        guard let parent = appState.snapshot.profiles[contextID] else { return nil }
        switch parent.gender {
        case .female: return .mother
        case .male: return .father
        default: return .unspecified
        }
    }
}
