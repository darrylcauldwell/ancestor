import SwiftUI

/// Bindings the edit consumer hands the shared layout so its editable blocks
/// (names, dates, gender, bio) can render `TextField`/`Picker` content
/// directly. Bundled as a single struct so the read-mode consumer doesn't
/// have to fabricate junk bindings — it just passes `nil`.
///
/// Each `Binding<String>` corresponds 1:1 with a `@State` field in
/// `EditPersonView`; persistence semantics (normalisation, change diffing,
/// save) stay with the edit consumer and the layout merely renders the
/// inputs.
struct ProfileEditBindings {
    var firstName: Binding<String>
    var middleName: Binding<String>
    var lastName: Binding<String>
    var marriedSurname: Binding<String>
    var nickName: Binding<String>
    var mothersMaidenName: Binding<String>
    var gender: Binding<Gender>
    var birthDateText: Binding<String>
    var birthLocation: Binding<String>
    var birthLocationCode: Binding<String?>
    var deathDateText: Binding<String>
    var deathLocation: Binding<String>
    var deathLocationCode: Binding<String?>
    var bio: Binding<String>
}

/// Identifiable wrapper for presenting `ConflictResolutionView` via
/// `.sheet(item:)` — one profile field has at most one displayed dispute
/// (snapshot map invariant), so (profile, field) identifies the sheet.
struct DisputeSheetItem: Identifiable {
    let profile: Profile
    let dispute: FieldDispute
    var id: String { "\(profile.id):\(dispute.field.rawValue)" }
}

/// Shared layout shell for a single profile. Renders the header, fields,
/// relationships, disputes, life events, attachments, and notes blocks. Owns
/// the sheets for adding / editing those subordinate items (life events,
/// notes, attachment importer) since they're part of the layout's internal
/// interactions, not of any particular consumer.
///
/// Steps 1–2 of `AncestorApp/PROFILE_VIEW_UNIFY_SPEC.md`: extracted from
/// `ProfileDetailView`, then taught to render an editable variant of the
/// name / date / gender / bio blocks when the consumer passes `editable: true`
/// + bindings. Persistent leading labels above each input fix the placeholder-
/// only label-visibility bug `EditPersonView` had. Heavy edit machinery
/// (per-field source picker, Correct-vs-Alternative, citation entry) stays
/// out of this view — it belongs above the consumer's `save()` flow.
struct SharedProfileLayout: View {
    let profile: Profile
    let snapshot: FamilyGraphSnapshot
    var editable: Bool = false
    var bindings: ProfileEditBindings? = nil

    @Environment(AppState.self) private var appState
    /// M24 — when true (Settings → Accessibility → "Differentiate without
    /// colour"), state-colour signals are paired with shape/glyph alternatives.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @State private var showingNoteComposer: Bool = false
    @State private var editingNote: WorkbenchNote?
    @State private var showingLifeEventEditor: Bool = false
    @State private var editingLifeEvent: LifeEvent?
    @State private var showingAttachmentImporter: Bool = false
    /// CONFLICT_LAYER_SPEC §4.8.1 — the dispute the user is resolving.
    /// `.sheet(item:)` with an Identifiable wrapper (never
    /// `.sheet(isPresented:) + if let` — the EmptyView-rectangle race).
    @State private var resolvingDispute: DisputeSheetItem?

    /// True when the consumer has opted into editing and supplied bindings.
    /// Treating these together avoids a class of "editable but no bindings"
    /// crashes — every editable branch can `guard let b = editableBindings`.
    private var editableBindings: ProfileEditBindings? {
        editable ? bindings : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(profile.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                    // Name-side source badges. firstName and lastName
                    // each have their own provenance trail in
                    // field_sources; surface both inline next to the
                    // header so the user can see at a glance whether
                    // the name was typed manually, imported from
                    // GEDCOM, or inferred from research.
                    sourceBadges(for: .firstName)
                    sourceBadges(for: .lastName)
                }
                if let wikiTreeID = profile.wikiTreeID {
                    Text(wikiTreeID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let comp = snapshot.completeness(for: profile.id)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("\(comp.score)/\(comp.maximum)")
                            .font(.caption)
                            .foregroundStyle(comp.score == comp.maximum ? .green : .orange)
                        if comp.potentiallyLiving {
                            Text("(living)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // Pending-facts badge — small orange pill linking
                    // to the firewall queue for this profile. Hidden
                    // when zero so it doesn't clutter the common case.
                    pendingFactsBadge
                }
            }

            Divider()

            // Per-gap research entry points (Task #39 +
            // RESEARCH_PIPELINE_SPEC §11.4). The buttons fire focused
            // pipeline runs scoped to the deficit's record types.
            missingFactsSection

            // Discovery-shaped research opportunities — siblings,
            // children, occupation. These aren't gap-driven (the
            // profile may look complete and still have undiscovered
            // siblings or census occupation entries) so they live in
            // their own section.
            exploreSection

            // Editable name fields + gender Picker, only when the consumer
            // opted into edit mode. Inserted above the date rows so users
            // see name/gender first (the most-commonly-edited identity).
            namesBlock

            // Fields with source badges
            datesBlock
            hypotheticalLine(for: .birthDate)
            hypotheticalLine(for: .deathDate)

            // Gender row. Read-mode keeps the existing LabeledContent
            // rendering; edit-mode is suppressed here because `namesBlock`
            // already renders the Picker alongside the name fields.
            if editableBindings == nil, let gender = profile.gender {
                LabeledContent("Gender") {
                    HStack(spacing: 6) {
                        Text(gender.rawValue.capitalized)
                        // Gender is a sourced field — the wizard, GEDCOM
                        // import, and per-field source-recording paths
                        // all write a provenance entry under .gender.
                        // Previously invisible on the profile detail.
                        sourceBadges(for: .gender)
                    }
                }
            }
            hypotheticalLine(for: .gender)

            // Editable biography, edit-mode only. Read mode renders nothing
            // here — the detail view has never surfaced bio inline.
            bioBlock

            Divider()

            // Relationships
            relationshipSection("Parents", profiles: snapshot.parentsOf(profile.id))
            // Spouses get their own renderer so marriage date / location
            // surface alongside the spouse name. Without this, the
            // marriage enrichment Apply path writes to the spouse edge
            // but the user has no way to see that it happened — the
            // generic relationshipSection only renders profile fields.
            spousesSection(for: profile, snapshot: snapshot)
            relationshipSection("Children", profiles: snapshot.childrenOf(profile.id))
            relationshipSection("Siblings", profiles: snapshot.siblingsOf(profile.id))

            // Disputes — live from CONFLICT_LAYER_SPEC Change 1: the apply
            // path now produces rows, and each open dispute offers the
            // resolution flow (ConflictResolutionView → AppState.resolveDispute).
            if !profile.disputes.isEmpty {
                Divider()
                Text("Disputes")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ForEach(Array(profile.disputes.values), id: \.field) { dispute in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dispute.field.rawValue)
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text(dispute.reason.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(dispute.competingSources, id: \.raw) { source in
                                Text("  \(source.origin.identifier): \(source.raw)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if dispute.resolution == nil {
                            Button("Resolve…") {
                                resolvingDispute = DisputeSheetItem(
                                    profile: profile, dispute: dispute
                                )
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        } else {
                            Label("Resolved", systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }

            // Life Events (M12) — censuses, occupations, residences, baptisms, etc.
            Divider()
            lifeEventsSection

            // Attachments (M13) — photos, scans, transcriptions
            Divider()
            attachmentsSection

            // Notes (M8 W1) — surfaces workbench thinking in context
            Divider()
            notesSection
        }
        .sheet(isPresented: $showingNoteComposer) {
            NoteComposerView(initial: nil, attachedTo: .profile(id: profile.id))
        }
        .sheet(item: $editingNote) { note in
            NoteComposerView(initial: note, attachedTo: note.attachedTo)
        }
        .sheet(isPresented: $showingLifeEventEditor) {
            LifeEventEditorView(mode: .add(profileID: profile.id))
        }
        .sheet(item: $editingLifeEvent) { event in
            LifeEventEditorView(mode: .edit(event))
        }
        .sheet(isPresented: $showingAttachmentImporter) {
            AttachmentImportSheet(target: .profile(id: profile.id))
        }
        .sheet(item: $resolvingDispute) { item in
            ConflictResolutionView(profile: item.profile, dispute: item.dispute)
        }
    }

    /// Per-gap research entry points (Task #39 + RESEARCH_PIPELINE_SPEC
    /// §11.4). Each missing fact maps to a `ResearchFocus` via
    /// `CompletenessCheck.researchFocus`; gaps with a focus get a
    /// scoped action label ("Research parents", "Research death") and
    /// fire a focus-narrowed pipeline run via the standard config sheet.
    /// Gaps with no engine-researchable answer (firstName, gender,
    /// bio) get a disabled placeholder so the row still appears in the
    /// list but the user isn't promised an action that wouldn't help.
    @ViewBuilder
    private var missingFactsSection: some View {
        let comp = snapshot.completeness(for: profile.id)
        if !comp.missing.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Missing facts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(comp.missing, id: \.self) { gap in
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.tertiary)
                            .font(.callout)
                        Text(gap.label)
                            .font(.callout)
                        Spacer()
                        if let focus = gap.researchFocus {
                            let recordTypeList = focus.recordTypes
                                .map(\.rawValue).sorted()
                                .joined(separator: ", ")
                            Button(focus.actionLabel) {
                                appState.researchConfigFocus = focus
                                appState.researchConfigProfile = profile
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .help("Narrows the dispatch to \(recordTypeList)")
                        } else {
                            Text("Manual")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Divider()
        }
    }

    /// Discovery-shaped focus buttons (RESEARCH_PIPELINE_SPEC §11.4).
    /// These three focuses don't correspond to a missing-fact deficit
    /// — even a fully-populated profile may have siblings the engine
    /// hasn't surfaced yet, children not yet linked, or census-derived
    /// occupations that aren't in the tree. The section appears once
    /// the profile has enough basic data for any focus to plausibly
    /// return results (given name + birth year); without those the
    /// engine has nothing to gate searches on.
    @ViewBuilder
    private var exploreSection: some View {
        let hasGivenName = (profile.firstName ?? "").isEmpty == false
        let hasBirthYear = profile.birthDate?.earliest != nil
        let hasSpouse = snapshot.spousesOf(profile.id).isEmpty == false
        // Sibling discovery (RESEARCH_PIPELINE_SPEC §11.6) gates on
        // "both parents linked + identity resolved", but the engine's
        // MMN derivation in ResearchSubject.fromProfile falls back to
        // `profile.mothersMaidenName` when a mother isn't linked. So
        // the surface gate is: a linked parent OR a populated MMN.
        // Without either, the FreeBMD MMN match has nothing to key on
        // and the search would return empty.
        let hasParent = snapshot.parentsOf(profile.id).isEmpty == false
        let hasMMN = (profile.mothersMaidenName ?? "").isEmpty == false
        let siblingsActionable = hasParent || hasMMN

        if hasGivenName && hasBirthYear {
            VStack(alignment: .leading, spacing: 6) {
                Text("Explore")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if siblingsActionable {
                    exploreRow(label: "Siblings", focus: .siblings,
                               hint: "MMN-based discovery of brothers and sisters via FreeBMD birth index.")
                }
                // Children gated on a known spouse — without a marriage
                // anchor the dispatcher has nothing useful to chase. An
                // adult-but-unmarried profile would just return empty.
                if hasSpouse {
                    exploreRow(label: "Children", focus: .children,
                               hint: "Marriage records + census household to find unlinked children.")
                }
                exploreRow(label: "Occupation history", focus: .occupation,
                           hint: "Census and probate records across the subject's lifetime.")
            }
            Divider()
        }
    }

    @ViewBuilder
    private func exploreRow(label: String, focus: ResearchFocus, hint: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .foregroundStyle(.tertiary)
                .font(.callout)
            Text(label)
                .font(.callout)
            Spacer()
            Button(focus.actionLabel) {
                appState.researchConfigFocus = focus
                appState.researchConfigProfile = profile
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help(hint)
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        let attachedNotes = appState.notesForProfile(profile.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notes")
                    .font(.headline)
                Spacer()
                Button {
                    showingNoteComposer = true
                } label: {
                    Label("New", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            if attachedNotes.isEmpty {
                Text("No notes for this person yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(attachedNotes) { note in
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
                            LinkAwareNoteText(content: note.content, snapshot: snapshot) { other in
                                appState.researchProfileID = other.id
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
    }

    /// Interactive list of life events for this profile (M12). Tap a row to
    /// edit; tap "+ New" in the header to add. The editor sheet handles both.
    @ViewBuilder
    private var lifeEventsSection: some View {
        let events = appState.lifeEventsForProfile(profile.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Life Events")
                    .font(.headline)
                Spacer()
                Text("\(events.count)")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
                Button {
                    showingLifeEventEditor = true
                } label: {
                    Label("New", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            if events.isEmpty {
                Text("No life events yet.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(events) { event in
                    Button {
                        editingLifeEvent = event
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: event.type.systemImage)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(event.type.displayName)
                                        .font(AppTypography.cardBody.weight(.semibold))
                                    if let year = event.sortYear {
                                        Text(String(year))
                                            .font(AppTypography.cardMeta)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let description = event.description, !description.isEmpty {
                                    Text(description)
                                        .font(AppTypography.cardBody)
                                }
                                if let location = event.location, !location.isEmpty {
                                    Text(location)
                                        .font(AppTypography.cardMeta)
                                        .foregroundStyle(.secondary)
                                }
                                // Task #52 — surface the typed details
                                // payload below the freeform description so
                                // structured fields the source emitted
                                // (rank, cemetery, household, etc.) are
                                // actually visible to the user. Falls
                                // through silently when `details` is nil.
                                if let details = event.details {
                                    LifeEventDetailsView(details: details)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Photos / PDFs / typed transcriptions attached to this profile (M13).
    /// Tile grid lives in AttachmentGalleryView; the header opens the importer.
    @ViewBuilder
    private var attachmentsSection: some View {
        let attachments = appState.attachmentsForProfile(profile.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Attachments")
                    .font(.headline)
                Spacer()
                Text("\(attachments.count)")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
                Button {
                    showingAttachmentImporter = true
                } label: {
                    Label("New", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            AttachmentGalleryView(profileID: profile.id)
        }
    }

    // MARK: - Editable blocks (step 2 of PROFILE_VIEW_UNIFY_SPEC)

    /// Editable name + gender block. Renders only when the consumer is in
    /// edit mode. Each `TextField` sits below a persistent caption label so
    /// the field's purpose stays visible after the user types — the bug
    /// `EditPersonView`'s placeholder-only labels had.
    ///
    /// `marriedSurname` is shown only for female profiles, matching the
    /// genealogy convention (and `EditPersonView`'s previous behaviour) —
    /// UK Probate / post-marriage census records file deceased married
    /// women under the married surname, so capturing it unlocks those
    /// research paths without cluttering male profiles.
    @ViewBuilder
    private var namesBlock: some View {
        if let b = editableBindings {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    labeledField("First name", field: .firstName) {
                        TextField("", text: b.firstName)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("Middle name", field: .middleName) {
                        TextField("", text: b.middleName)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("Last name", field: .lastName) {
                        TextField("", text: b.lastName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                // Name-length warning — shown when any name part exceeds
                // the soft limit. Lives inside `namesBlock` so the warning
                // sits visually next to the fields it concerns; the same
                // service backs `AddPersonView`.
                if let warning = NameLengthWarning.warningText(forName: b.firstName.wrappedValue)
                    ?? NameLengthWarning.warningText(forName: b.middleName.wrappedValue)
                    ?? NameLengthWarning.warningText(forName: b.lastName.wrappedValue) {
                    Text(warning)
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(AnyShapeStyle(Color.orange))
                }
                if b.gender.wrappedValue == .female {
                    labeledField("Married surname (optional)", field: .marriedSurname) {
                        TextField("", text: b.marriedSurname)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    labeledField("Known as (optional)", field: .nickName) {
                        TextField("", text: b.nickName)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("Mother's maiden name (optional)", field: .mothersMaidenName) {
                        TextField("", text: b.mothersMaidenName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gender")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        sourceBadges(for: .gender)
                    }
                    Picker("Gender", selection: b.gender) {
                        Text("Unknown").tag(Gender.unknown)
                        Text("Female").tag(Gender.female)
                        Text("Male").tag(Gender.male)
                        Text("Other").tag(Gender.other)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }

    /// Birth + death rows. Read-mode keeps the existing two-line `fieldRow`
    /// (label/source-badges row, then value + place underneath). Edit-mode
    /// swaps in `DateParsePreviewField` + `LocationPicker`, each with the
    /// same persistent caption label so the field type stays visible.
    @ViewBuilder
    private var datesBlock: some View {
        if let b = editableBindings {
            VStack(alignment: .leading, spacing: 8) {
                editableFieldRow("Birth date", field: .birthDate) {
                    DateParsePreviewField(label: "Birth date", text: b.birthDateText)
                }
                editableFieldRow("Birth location", field: .birthLocation) {
                    LocationPicker(
                        label: "Birth location",
                        text: b.birthLocation,
                        locationCode: b.birthLocationCode
                    )
                }
                editableFieldRow("Death date", field: .deathDate) {
                    DateParsePreviewField(label: "Death date", text: b.deathDateText)
                }
                editableFieldRow("Death location", field: .deathLocation) {
                    LocationPicker(
                        label: "Death location",
                        text: b.deathLocation,
                        locationCode: b.deathLocationCode
                    )
                }
            }
        } else {
            fieldRow("Birth", value: profile.birthDate?.original, place: profile.birthLocation, field: .birthDate)
            fieldRow("Death", value: profile.deathDate?.original, place: profile.deathLocation, field: .deathDate)
        }
    }

    /// Editable bio. Read mode renders nothing — the detail view has never
    /// surfaced bio inline — so this block is purely a step-2 addition the
    /// edit consumer benefits from.
    @ViewBuilder
    private var bioBlock: some View {
        if let b = editableBindings {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Biography")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    sourceBadges(for: .bio)
                }
                TextEditor(text: b.bio)
                    .font(AppTypography.cardBody)
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
        }
    }

    /// Persistent leading-label wrapper for an editable input. The label
    /// sits above the input (caption-styled, muted) and stays visible after
    /// the user has typed — that's the headline fix of step 2. When `field`
    /// is supplied, existing source badges render on the right of the label
    /// row so the user can see provenance before overwriting.
    @ViewBuilder
    private func labeledField<Content: View>(
        _ label: String,
        field: ProfileField? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let field = field {
                    sourceBadges(for: field)
                }
            }
            content()
        }
    }

    /// Edit-mode equivalent of `fieldRow` for the dates block — same
    /// "label + source badges over the value" two-line shape, but the
    /// content slot accepts an input view (`DateParsePreviewField`,
    /// `LocationPicker`) instead of a `Text`. Pulled out so the four
    /// date/location rows stay structurally identical.
    @ViewBuilder
    private func editableFieldRow<Content: View>(
        _ label: String,
        field: ProfileField,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                sourceBadges(for: field)
            }
            content()
        }
    }

    /// Render any active `.fieldValue` hypotheses targeting this profile for
    /// the given field as italic + muted text. Per DESIGN.md §7.7.7 line
    /// "Hypothetical field value → italic, muted text in inspector."
    @ViewBuilder
    private func hypotheticalLine(for field: ProfileField) -> some View {
        let alternatives = appState.hypotheses.filter { h in
            guard h.status == .active else { return false }
            if case .fieldValue(let pid, let f, _) = h.claim {
                return pid == profile.id && f == field
            }
            return false
        }
        if !alternatives.isEmpty {
            ForEach(alternatives, id: \.id) { h in
                if case .fieldValue(_, _, let value) = h.claim {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text("Hypothesised: ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .italic()
                        Text(value)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ label: String, value: String?, place: String?, field: ProfileField) -> some View {
        if value != nil || place != nil {
            let sources = profile.sources[field] ?? []
            let confidence = effectiveConfidence(sources)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    sourceBadges(for: field)
                }
                if let v = value {
                    HStack(spacing: 4) {
                        valueText(v, confidence: confidence)
                        if confidence == .wellEvidenced {
                            Image(systemName: "checkmark.seal.fill")
                                .font(AppTypography.badge)
                                .foregroundStyle(.green)
                                .help("Well evidenced — multiple independent sources agree.")
                                .accessibilityLabel("Well evidenced")
                                .accessibilityHint("Multiple independent sources agree.")
                        }
                    }
                }
                if let p = place {
                    Text(p)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Render the field value with confidence styling. Tentative fields get a
    /// dashed orange underline and a tooltip; standard/wellEvidenced render
    /// without altering the text colour (the wellEvidenced checkmark is added
    /// separately by the caller).
    @ViewBuilder
    private func valueText(_ value: String, confidence: FactConfidence?) -> some View {
        if confidence == .tentative {
            Text(value)
                .font(.body)
                .underline(true, pattern: .dash, color: .orange)
                .help("Tentative — committed but watching for more evidence.")
                .accessibilityHint("Tentative — committed but watching for more evidence.")
        } else {
            Text(value)
                .font(.body)
        }
    }

    /// Count of pending facts awaiting human review for this profile.
    /// Cheap COUNT(*) query, recomputed each view render so it tracks
    /// inserts from MCP `submit_evidence` and from the in-app pipeline.
    private var pendingFactCount: Int {
        appState.currentDatabase?.pendingFactCount(profileID: profile.id) ?? 0
    }

    /// Pill that surfaces firewall-queued evidence on the profile detail
    /// header. Tapping switches to the Triage tab where the user can
    /// review + accept / discard each entry. Hidden when nothing is
    /// pending so the badge doesn't accrue visual noise on most profiles.
    @ViewBuilder
    private var pendingFactsBadge: some View {
        let count = pendingFactCount
        if count > 0 {
            HStack(spacing: 4) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("\(count) pending")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.18))
            .foregroundStyle(.orange)
            .clipShape(.capsule)
            .help("Evidence proposals awaiting human review for this profile. Open Triage to accept or discard them.")
            .accessibilityLabel("\(count) pending facts")
            .accessibilityHint("Evidence proposals awaiting human review")
        }
    }

    @ViewBuilder
    private func sourceBadges(for field: ProfileField) -> some View {
        let sources = profile.sources[field] ?? []
        HStack(spacing: 2) {
            ForEach(sources, id: \.raw) { source in
                HStack(spacing: 3) {
                    // M24 — colourblind / high-contrast users see a glyph
                    // (`?` for tentative, `✓` for well evidenced) in place
                    // of the colour-only dot. Default-contrast users keep
                    // the existing dot rendering unchanged.
                    if let dot = sourceConfidenceDotColor(source.confidence) {
                        if let glyph = sourceConfidenceGlyph(source.confidence),
                           differentiateWithoutColor {
                            Image(systemName: glyph)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(dot)
                        } else {
                            Circle()
                                .fill(dot)
                                .frame(width: 5, height: 5)
                        }
                    }
                    Text(source.origin.identifier.uppercased())
                        .font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .glassEffect(.regular, in: .capsule)
                .help(sourceConfidenceHelp(source.confidence))
                .accessibilityLabel("Source \(source.origin.identifier)")
                .accessibilityHint(sourceConfidenceHelp(source.confidence))
            }
        }
    }

    /// SF Symbol glyph paired with the per-source confidence dot when the
    /// user has Differentiate Without Colour enabled. Routed through
    /// `HighContrastShape` so the mapping lives in one place.
    private func sourceConfidenceGlyph(_ confidence: FactConfidence?) -> String? {
        switch confidence {
        case .tentative:
            return HighContrastShape.differentiator(
                for: .sourceConfidenceTentative,
                differentiateWithoutColor: true
            )
        case .wellEvidenced:
            return HighContrastShape.differentiator(
                for: .sourceConfidenceWellEvidenced,
                differentiateWithoutColor: true
            )
        case .standard, .none:
            return nil
        }
    }

    /// Map a per-source confidence to a tinted dot. Standard / nil renders
    /// nothing — only the two non-default cases earn a visual.
    private func sourceConfidenceDotColor(_ confidence: FactConfidence?) -> Color? {
        switch confidence {
        case .tentative: return .orange
        case .wellEvidenced: return .green
        case .standard, .none: return nil
        }
    }

    /// Tooltip for source pills. Empty when there's nothing to say so the
    /// pill itself stays uninterrupted on hover.
    private func sourceConfidenceHelp(_ confidence: FactConfidence?) -> String {
        switch confidence {
        case .tentative: return "Source marked tentative — watching for more evidence."
        case .wellEvidenced: return "Source marked well evidenced."
        case .standard, .none: return ""
        }
    }

    @ViewBuilder
    private func relationshipSection(_ title: String, profiles: [Profile]) -> some View {
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(profiles) { relative in
                    HStack {
                        Text(relative.displayName)
                            .font(.callout)
                        if let year = relative.birthDate?.bestYear {
                            Text("b. \(year)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    /// Spouses rendered with their marriage edge metadata inlined. Iterates
    /// the spouse `Relationship` rows directly (rather than going via
    /// `snapshot.spousesOf`, which returns only profiles) so marriage date
    /// and location — written by `applyProposedRelative` and
    /// `applyMarriageToSubjectSpouseEdge` — show up on each spouse line.
    /// Without this, the enrichment Apply path silently writes to the edge
    /// but the user has no visible confirmation it happened.
    @ViewBuilder
    private func spousesSection(for subject: Profile, snapshot: FamilyGraphSnapshot) -> some View {
        let spouseEdges = snapshot.relationships.filter { rel in
            rel.type == .spouse && (rel.from == subject.id || rel.to == subject.id)
        }
        if !spouseEdges.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Spouses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(spouseEdges, id: \.id) { edge in
                    let otherID = edge.from == subject.id ? edge.to : edge.from
                    if let spouse = snapshot.profiles[otherID] {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(spouse.displayName)
                                    .font(.callout)
                                if let year = spouse.birthDate?.bestYear {
                                    Text("b. \(year)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            // Marriage metadata, when present. "m." prefix
                            // mirrors common genealogy abbreviation. Location
                            // sits on its own line so a long district name
                            // doesn't crowd the date.
                            if let date = edge.marriageDate?.original, !date.isEmpty {
                                Text("m. \(date)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let location = edge.marriageLocation, !location.isEmpty {
                                Text(location)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }
}
