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
/// Identifiable payload for the relationship-unlink confirmation dialog.
private struct RelationshipRemoval: Identifiable {
    let id = UUID()
    let edgeID: UUID
    let relativeName: String
    let roleWord: String
}

/// Editable marriage date + place for one spouse edge. Owns its own local text
/// (initialised from the edge) and commits explicitly via the Save button, so a
/// keystroke never triggers a DB write + audit refresh. Empty fields clear the
/// column.
private struct SpouseMarriageEditRow: View {
    @Environment(AppState.self) private var appState
    let edgeID: UUID
    @State private var date: String
    @State private var location: String

    init(edgeID: UUID, initialDate: String, initialLocation: String) {
        self.edgeID = edgeID
        _date = State(initialValue: initialDate)
        _location = State(initialValue: initialLocation)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("m.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("date", text: $date)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 130)
                .onSubmit(commit)
            TextField("place", text: $location)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            Button(action: commit) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .help("Save marriage date and place")
            .accessibilityLabel("Save marriage")
        }
        .font(.caption2)
    }

    private func commit() {
        let trimmedDate = date.trimmingCharacters(in: .whitespaces)
        let trimmedLoc = location.trimmingCharacters(in: .whitespaces)
        appState.setRelationshipMarriage(
            id: edgeID,
            date: trimmedDate.isEmpty ? nil : GenealogicalDate(parsing: trimmedDate),
            location: trimmedLoc.isEmpty ? nil : trimmedLoc)
    }
}

struct SharedProfileLayout: View {
    let profile: Profile
    let snapshot: FamilyGraphSnapshot
    var editable: Bool = false
    var bindings: ProfileEditBindings? = nil
    /// RETIRE_POPOVER_SPEC Change 2 — when set, relationship rows become
    /// tappable navigation (jump the tree to that relative), replacing the
    /// popover's off-canvas relatives list. Nil (plain-text rows) in
    /// contexts with no tree to navigate (EditPersonView sheets).
    var onNavigateToProfile: ((String) -> Void)? = nil
    /// Advance warning that navigating to this relative will flip the tree's
    /// view mode (pedigree ↔ descendants) — the popover's orange
    /// mode-switch glyph, host-supplied so this layout stays ignorant of
    /// TreeViewMode. Nil → no hint shown.
    var navigateSwitchesMode: ((String) -> Bool)? = nil

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
    @State private var structuralDisputes: [DisputeRow] = []
    /// All evidence records for this profile (applied / researched / rejected),
    /// so a fact, marriage, or census row can expand to its complete evidence
    /// picture in context.
    @State private var factRecords: [ProfileSourcesLedger.RecordDetail] = []
    /// Context keys ("birthDate", "spouse:<edgeID>", "census") whose top-level
    /// evidence expander is open.
    @State private var expandedEvidenceKeys: Set<String> = []
    /// "<contextKey>|<standing>" for each open nested research bucket.
    @State private var expandedEvidenceBuckets: Set<String> = []
    /// An applied record the user is confirming removal of (un-apply inline).
    @State private var recordRemovalCandidate: ProfileSourcesLedger.RecordDetail?
    @State private var candidateGroups: [[ResearchHypothesis]] = []
    @State private var proposals: [ProfileField: ConflictResolutionActions.ProposedResolution] = [:]
    /// Pending relationship unlink (edit-mode remove on parent/child/spouse
    /// rows). Confirmed via a dialog so an edge is never dropped on a mis-click.
    @State private var relationshipRemoval: RelationshipRemoval?

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
                let evidence = evidencedFactCount(potentiallyLiving: comp.potentiallyLiving)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("\(comp.score)/\(comp.maximum)")
                            .font(.caption)
                            .foregroundStyle(comp.score == comp.maximum ? .green : .orange)
                            .help("Completeness — how many core fields are filled in. This says nothing about whether a field is backed by a source; a GEDCOM import alone can read full marks.")
                        if comp.potentiallyLiving {
                            Text("(living)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // Evidence metric — the companion to completeness above.
                    // Counts how many of the FILLED-IN life facts (birth/death
                    // date + place) have an actual research record behind them
                    // (a source of tier `.researchSource`), as opposed to only
                    // a GEDCOM/WikiTree import or a manually typed value. A 7/7
                    // profile can still be 0/4 evidenced when it's all unsourced
                    // import — which is the whole point of showing both.
                    if evidence.present > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: evidence.backed == evidence.present ? "checkmark.seal.fill" : "seal")
                                .font(.caption2)
                            Text("\(evidence.backed)/\(evidence.present) evidenced")
                                .font(.caption)
                        }
                        .foregroundStyle(evidence.backed == evidence.present ? .green : .secondary)
                        .help("Evidenced — how many of the filled-in life facts (birth/death date and place) have an actual research record behind them, as opposed to only a GEDCOM/WikiTree import or a manually typed value.")
                    }
                    // Pending-facts badge — small orange pill linking
                    // to the firewall queue for this profile. Hidden
                    // when zero so it doesn't clutter the common case.
                    pendingFactsBadge
                }
            }

            Divider()

            // FreeREG parish-register lookup — LINK-ONLY by design (2026-07-27):
            // FreeREG's terms forbid programmatic searching, so the app can't
            // search it for you, but its baptisms (which name BOTH parents) are
            // the richest free parentage source — so this opens their search for
            // the permitted human lookup. (The old scraper connector was retired
            // the same day; the per-gap "Missing facts"/"Explore" sections too.)
            searchFreeREGRow

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
            relationshipSection("Parents", profiles: snapshot.parentsOf(profile.id),
                                roleWord: "parent", edgeIDFor: parentEdgeID,
                                roleEditFor: parentRoleEdit)
            // Spouses get their own renderer so marriage date / location
            // surface alongside the spouse name. Without this, the
            // marriage enrichment Apply path writes to the spouse edge
            // but the user has no way to see that it happened — the
            // generic relationshipSection only renders profile fields.
            spousesSection(for: profile, snapshot: snapshot)
            relationshipSection("Children", profiles: snapshot.childrenOf(profile.id),
                                roleWord: "child", edgeIDFor: childEdgeID)
            // Siblings are derived from shared parents — no stored edge to
            // unlink, so no edgeIDFor (removing a parent edge re-derives them).
            relationshipSection("Siblings", profiles: snapshot.siblingsOf(profile.id))

            // Census evidence sits by the family — a census IS the household,
            // and it carries the age that pins a birth year. Applied on top,
            // then researched / rejected candidates nested.
            censusEvidenceRow

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
                        // `.deferred` is "parked", not decided — still open and
                        // actionable, never shown as "Resolved".
                        if dispute.resolution == nil || dispute.resolution == .deferred {
                            // ⟨G12⟩ — a linked candidate hypothesis has
                            // resolved the question: PROPOSE, never apply.
                            if let proposal = proposals[dispute.field] {
                                Button(proposal.label) {
                                    acceptProposal(proposal)
                                }
                                .buttonStyle(.glassProminent)
                                .tint(.green)
                                .controlSize(.small)
                            }
                            if dispute.resolution == .deferred {
                                Text("deferred")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
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

            // Conflicts (CONFLICT_LAYER_SPEC CL2) — structural dispute
            // kinds (timeline / parentRole / spouseIdentity) whose field
            // keys deliberately do not parse as ProfileField, so they
            // never appear in profile.disputes. Loaded live from the
            // dispute store; refreshed whenever the profile changes.
            if !structuralDisputes.isEmpty {
                Divider()
                Text("Conflicts")
                    .font(.headline)
                    .foregroundStyle(.red)
                ForEach(structuralDisputes) { row in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.kind.rawValue) · \(row.field)")
                                .font(.caption)
                                .fontWeight(.semibold)
                            ForEach(row.competingSources, id: \.raw) { source in
                                Text("  \(source.origin.identifier): \(source.raw)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        structuralResolveMenu(for: row)
                    }
                }
            }

            // Investigations (CL5/CL6 ⟨G5⟩) — open candidate groups for
            // this profile, each a single choose-one card.
            if !candidateGroups.isEmpty {
                Divider()
                Text("Investigations")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ForEach(candidateGroups, id: \.first?.id) { group in
                    CandidateGroupCard(group: group, profile: profile) {
                        reloadInvestigations()
                        structuralDisputes = ((try? appState.currentDatabase?.openDisputes(profileID: profile.id)) ?? [])
                            .filter { $0.kind != .fieldValue }
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
        .task(id: profile.id) {
            structuralDisputes = ((try? appState.currentDatabase?.openDisputes(profileID: profile.id)) ?? [])
                .filter { $0.kind != .fieldValue }
            reloadInvestigations()
            reloadFactRecords()
        }
        // Any snapshot mutation (applying a record, adding a verified record)
        // should refresh the per-fact evidence — profile.id is unchanged, so the
        // task above won't re-fire on its own.
        .onChange(of: appState.treeContentRevision) { _, _ in
            reloadFactRecords()
        }
        .confirmationDialog(
            "Remove this record?",
            isPresented: Binding(
                get: { recordRemovalCandidate != nil },
                set: { if !$0 { recordRemovalCandidate = nil } }),
            presenting: recordRemovalCandidate
        ) { rec in
            Button("Remove", role: .destructive) {
                removeAppliedRecord(rec)
                recordRemovalCandidate = nil
            }
            Button("Cancel", role: .cancel) { recordRemovalCandidate = nil }
        } message: { rec in
            Text("Reverts the fields this \(rec.recordType.rawValue) record set (where they still hold its value), removes its life events, and remembers the rejection so research won't re-add it. It stays in history and can be re-applied.")
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
        .confirmationDialog(
            "Unlink \(relationshipRemoval?.relativeName ?? "")?",
            isPresented: Binding(
                get: { relationshipRemoval != nil },
                set: { if !$0 { relationshipRemoval = nil } }
            ),
            presenting: relationshipRemoval
        ) { removal in
            Button("Unlink", role: .destructive) {
                appState.removeRelationship(id: removal.edgeID)
                relationshipRemoval = nil
            }
            Button("Cancel", role: .cancel) { relationshipRemoval = nil }
        } message: { removal in
            Text("Removes the \(removal.roleWord) link between \(profile.displayName) and \(removal.relativeName). Neither profile is deleted.")
        }
    }

    /// FreeREG is link-only (its terms forbid programmatic search): a button that
    /// opens FreeREG's parish-register search so the user runs the permitted human
    /// lookup — the direct route to a baptism naming both parents.
    @ViewBuilder
    private var searchFreeREGRow: some View {
        if let url = URL(string: "https://www.freereg.org.uk/search_queries/new") {
            // What to type into FreeREG's own form. We can't pre-fill it — their
            // terms forbid a front-end "entering search parameters" — so we show
            // the criteria for a read-and-type hand-off instead.
            let surname = (profile.lastName ?? "").trimmingCharacters(in: .whitespaces)
            let county = profile.birthLocation?
                .split(separator: ",").last
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .map { $0.replacingOccurrences(of: #"\s*\([A-Z]{2,3}\)$"#, with: "", options: .regularExpression) }
            let criteria = [surname.isEmpty ? nil : surname, county, "Baptism"]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Parish registers — FreeREG")
                        .font(.callout)
                    if !criteria.isEmpty {
                        Text("enter: \(criteria)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // FamilySearch hints sits beside Search FreeREG so both
                // find-more-evidence actions live on the profile face, matching
                // the tree/■■■ context menu (owner request: both in both places).
                Button {
                    appState.requestFetchFSHints = profile.id
                } label: {
                    Label("FamilySearch hints", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Fetch FamilySearch's record hints for this person (queries FamilySearch in-app). Sign in to FamilySearch in Settings first.")
                Link(destination: url) {
                    Label("Search FreeREG", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Opens FreeREG's parish-register search in your browser. Type in \(criteria.isEmpty ? "the surname, county and Baptism" : criteria) — baptisms name both parents. FreeREG's terms only allow manual searching, so the app can't pre-fill the form or search for you.")
            }
            Divider()
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
                    VStack(alignment: .leading, spacing: 2) {
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
                    // Source link (e.g. a Find a Grave memorial) — outside the
                    // edit Button so it's a reliable, separate tap.
                    if let url = eventSourceURL(event) {
                        Link(destination: url) {
                            Label("View source ↗", systemImage: "arrow.up.right.square")
                                .font(AppTypography.badge)
                                .foregroundStyle(.blue)
                        }
                        .padding(.leading, 26)
                    }
                    }
                }
            }
        }
    }

    /// The first source URL a life event carries, for the "View source" link.
    private func eventSourceURL(_ event: LifeEvent) -> URL? {
        for src in event.sources {
            if let u = src.citation?.url, !u.isEmpty, let url = URL(string: u) { return url }
        }
        return nil
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
                    GuidedDateField(label: "", text: b.birthDateText)
                }
                editableFieldRow("Birth location", field: .birthLocation) {
                    LocationPicker(
                        label: "Birth location",
                        text: b.birthLocation,
                        locationCode: b.birthLocationCode
                    )
                }
                editableFieldRow("Death date", field: .deathDate) {
                    GuidedDateField(label: "", text: b.deathDateText)
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
        let records = evidenceRecords(for: field)
        // Render when there's a value/place OR research surfaced records for it
        // (so a not-yet-applied fact still shows its researched candidates).
        if value != nil || place != nil || !records.isEmpty {
            let sources = profile.sources[field] ?? []
            let confidence = effectiveConfidence(sources)
            let key = field.rawValue
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    sourceBadges(for: field)
                    evidenceTrigger(key: key, records: records)
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
                } else if !records.isEmpty {
                    Text("Not recorded — \(records.count) researched")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
                if let p = place {
                    Text(p)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if expandedEvidenceKeys.contains(key) {
                    evidenceDisclosure(key: key, records: records)
                }
            }
        }
    }

    // MARK: - Per-fact evidence expander (applied on top; researched buckets nested)

    /// Which record types feed a given fact row, so its expander shows the
    /// relevant evidence. Census/baptism corroborate a birth; burial/probate a
    /// death — and both carry the age that discriminates namesakes.
    private func recordTypes(for field: ProfileField) -> Set<RecordType> {
        switch field {
        case .birthDate, .birthLocation: return [.birth, .census, .baptism, .christening]
        case .deathDate, .deathLocation: return [.death, .burial, .probate]
        case .marriedSurname:            return [.marriage]
        default:                          return []
        }
    }

    private func evidenceRecords(for field: ProfileField) -> [ProfileSourcesLedger.RecordDetail] {
        let types = recordTypes(for: field)
        guard !types.isEmpty else { return [] }
        return factRecords.filter { types.contains($0.recordType) }
    }

    private func reloadFactRecords() {
        guard let db = appState.currentDatabase else { factRecords = []; return }
        factRecords = (try? ProfileSourcesLedger.allRecords(for: profile.id, db: db, profile: profile)) ?? []
    }

    private func removeAppliedRecord(_ rec: ProfileSourcesLedger.RecordDetail) {
        guard let db = appState.currentDatabase else { return }
        let ids = Set(rec.duplicateIDs)
        let evidence = (try? db.loadEvidenceForProfile(profile.id)) ?? []
        // Remove every underlying row this card collapsed (duplicate re-scrapes),
        // so a de-duplicated applied record is fully cleared, not left orphaned.
        for ev in evidence where ids.contains(ev.sourceRecordID) && ev.userStatus == .savedAsLead {
            _ = appState.removeAppliedRecord(ev)
        }
        reloadFactRecords()
    }

    private func toggleEvidenceKey(_ key: String) {
        if expandedEvidenceKeys.contains(key) { expandedEvidenceKeys.remove(key) }
        else { expandedEvidenceKeys.insert(key) }
    }

    private func toggleEvidenceBucket(_ key: String) {
        if expandedEvidenceBuckets.contains(key) { expandedEvidenceBuckets.remove(key) }
        else { expandedEvidenceBuckets.insert(key) }
    }

    /// The chevron + count that opens a context's evidence. Shared by the fact
    /// rows, the spouse rows (marriage), and the census row.
    @ViewBuilder
    private func evidenceTrigger(key: String, records: [ProfileSourcesLedger.RecordDetail]) -> some View {
        if !records.isEmpty {
            let open = expandedEvidenceKeys.contains(key)
            Button { toggleEvidenceKey(key) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("\(records.count)")
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                }
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Records behind this — applied on top, then researched / rejected")
        }
    }

    /// Applied record(s) on top, then the three research buckets as nested
    /// disclosures: researched-not-applied, user-rejected, scorer-rejected.
    @ViewBuilder
    private func evidenceDisclosure(key: String, records: [ProfileSourcesLedger.RecordDetail]) -> some View {
        let applied = records.filter { $0.standing == .applied }
        VStack(alignment: .leading, spacing: 6) {
            if applied.isEmpty {
                Text("Nothing applied yet")
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                ForEach(applied) { recordLine($0, showPill: true) }
            }
            evidenceBucket(key: key, label: "Researched — not applied",
                           standing: .researched, tint: .blue,
                           records: records.filter { $0.standing == .researched })
            evidenceBucket(key: key, label: "You rejected",
                           standing: .userRejected, tint: .gray,
                           records: records.filter { $0.standing == .userRejected })
            evidenceBucket(key: key, label: "Scorer rejected (impossible)",
                           standing: .scorerRejected, tint: .orange,
                           records: records.filter { $0.standing == .scorerRejected })
        }
        .padding(.top, 4)
        .padding(.leading, 4)
    }

    /// One nested, collapsible research bucket. Hidden entirely when empty.
    @ViewBuilder
    private func evidenceBucket(key: String, label: String,
                                standing: ProfileSourcesLedger.Standing, tint: Color,
                                records: [ProfileSourcesLedger.RecordDetail]) -> some View {
        if !records.isEmpty {
            let bkey = "\(key)|\(standing.rawValue)"
            let open = expandedEvidenceBuckets.contains(bkey)
            VStack(alignment: .leading, spacing: 4) {
                Button { toggleEvidenceBucket(bkey) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                        Text("\(label) (\(records.count))")
                    }
                    .font(AppTypography.badge)
                    .foregroundStyle(tint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    let cap = 20
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(records.prefix(cap)) { recordLine($0, showPill: false) }
                        // A pending bucket can hold hundreds of namesake leads —
                        // capping keeps the view tree bounded, and bulk-review
                        // belongs in Triage, not this in-context expander.
                        if records.count > cap {
                            Button { appState.requestSidebarTab = .triage } label: {
                                Text("Showing \(cap) of \(records.count) — review all in Triage →")
                                    .font(AppTypography.badge)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                    }
                    .padding(.leading, 12)
                }
            }
        }
    }

    /// One record: type · source · (age→birth year) over its citation.
    @ViewBuilder
    private func recordLine(_ rec: ProfileSourcesLedger.RecordDetail, showPill: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if showPill { standingPill(rec.standing) }
                Text(rec.recordType.rawValue.capitalized)
                    .font(AppTypography.badge)
                    .foregroundStyle(.secondary)
                Text(rec.sourceID.uppercased())
                    .font(AppTypography.sourceBadge)
                    .foregroundStyle(.tertiary)
                if let age = rec.ageDetail {
                    Text(age)
                        .font(AppTypography.badge.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            Text(rec.citation)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let note = rec.reconcileNote {
                Text(note)
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                SourceVerifyLink(sourceID: rec.sourceID, citationURL: rec.citationURL)
                // Apply in context — for records not already on the profile.
                if rec.standing != .applied {
                    Button {
                        appState.applyEvidenceRecord(sourceRecordID: rec.id, profileID: profile.id)
                        reloadFactRecords()
                    } label: {
                        Label("Apply", systemImage: "checkmark.circle")
                            .font(AppTypography.badge)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)
                    .help("Apply this record: fills any blank fields, refines where allowed, and attaches its citation — your existing more-precise values are kept.")
                } else {
                    // Un-apply a record applied in error — reverts the fields it
                    // set, removes its life events, and remembers the rejection.
                    Button { recordRemovalCandidate = rec } label: {
                        Label("Remove", systemImage: "arrow.uturn.backward")
                            .font(AppTypography.badge)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("Remove this applied record — reverts what it wrote (where the value is still its own), removes its life events, and won't be re-added by research. It stays in history and can be re-applied.")
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func standingPill(_ standing: ProfileSourcesLedger.Standing) -> some View {
        let (text, tint): (String, Color) = switch standing {
        case .applied:        ("Applied", .green)
        case .researched:     ("Researched", .blue)
        case .userRejected:   ("You rejected", .gray)
        case .scorerRejected: ("Impossible", .orange)
        }
        Text(text)
            .font(AppTypography.badge)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: .capsule)
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
            Button {
                // Hand the user to THIS profile's review cards on Triage.
                // Both requests are needed: ContentView consumes the tab
                // switch; ResearchView consumes the pending-review target
                // (otherwise the user lands on the profile selector, whose
                // prominent "Research All" button is a hazardous mis-click).
                appState.requestPendingReviewProfileID = profile.id
                appState.requestSidebarTab = .triage
            } label: {
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
            }
            .buttonStyle(.plain)
            .help("Evidence proposals awaiting human review for this profile. Click to review in Triage.")
            .accessibilityLabel("\(count) pending facts")
            .accessibilityHint("Opens Triage to review evidence proposals")
        }
    }

    /// Companion to the completeness score: of the record-backable life facts
    /// that are actually FILLED IN (birth date/place always; death date/place
    /// only for the dead), how many carry a real research source — a
    /// `FieldSource` whose origin tier is `.researchSource` (FreeBMD, CWGC,
    /// FindAGrave, FreeReg, FamilySearch, probate, parish, engine-enrichment).
    /// A bare GEDCOM/WikiTree import (`.initialImport`) or a manual value
    /// (`.userAuthoritative`) does NOT count — those fill the field without
    /// providing an inspectable record. Returns (backed, present) so the header
    /// can render "N/M evidenced".
    private func evidencedFactCount(potentiallyLiving: Bool) -> (backed: Int, present: Int) {
        var fields: [ProfileField] = []
        if profile.birthDate != nil { fields.append(.birthDate) }
        if profile.birthLocation != nil { fields.append(.birthLocation) }
        if !potentiallyLiving {
            if profile.deathDate != nil { fields.append(.deathDate) }
            if profile.deathLocation != nil { fields.append(.deathLocation) }
        }
        let backed = fields.filter { field in
            (profile.sources[field] ?? []).contains { $0.origin.tier == .researchSource }
        }
        return (backed.count, fields.count)
    }

    @ViewBuilder
    private func sourceBadges(for field: ProfileField) -> some View {
        let sources = profile.sources[field] ?? []
        HStack(spacing: 2) {
            ForEach(sources, id: \.raw) { source in
                // Click-through when the source carried a citation URL (e.g. a
                // FindAGrave memorial or CWGC casualty page). Link-only by
                // design — we point at the record, never copy its content.
                // Falls back to a plain, non-clickable badge otherwise.
                let url = source.citation?.url.flatMap { URL(string: $0) }
                if let url {
                    Link(destination: url) {
                        sourceBadgeLabel(source, clickable: true)
                    }
                    .buttonStyle(.plain)
                    .help("Open the \(source.origin.identifier.uppercased()) record")
                    .accessibilityLabel("Source \(source.origin.identifier)")
                    .accessibilityHint("Opens the source record in your browser")
                } else {
                    sourceBadgeLabel(source, clickable: false)
                        .help(sourceConfidenceHelp(source.confidence))
                        .accessibilityLabel("Source \(source.origin.identifier)")
                        .accessibilityHint(sourceConfidenceHelp(source.confidence))
                }
            }
        }
    }

    /// The badge chip itself, factored out so the clickable (Link-wrapped) and
    /// plain variants share one rendering. When `clickable`, a small arrow
    /// glyph signals the badge opens the source record.
    @ViewBuilder
    private func sourceBadgeLabel(_ source: FieldSource, clickable: Bool) -> some View {
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
            if clickable {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: .capsule)
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


    // MARK: - Conflict-layer UI helpers (CL UI pass)

    private func reloadInvestigations() {
        guard let db = appState.currentDatabase else { return }
        let all = (try? db.loadHypotheses(forProfile: profile.id)) ?? []
        var byGroup: [String: [ResearchHypothesis]] = [:]
        for h in all where h.candidateGroupID != nil && h.verdict != .contradicted {
            byGroup[h.candidateGroupID!, default: []].append(h)
        }
        candidateGroups = byGroup.values
            .filter { $0.count >= 2 }
            .sorted { ($0.first?.candidateGroupID ?? "") < ($1.first?.candidateGroupID ?? "") }

        // ⟨G12⟩ proposals for open date disputes.
        proposals = [:]
        for field in [ProfileField.birthDate, .deathDate] {
            if profile.disputes[field]?.resolution == nil,
               profile.disputes[field] != nil,
               let proposal = ConflictResolutionActions.proposedResolution(
                    for: field, profileID: profile.id, db: db) {
                proposals[field] = proposal
            }
        }
    }

    @ViewBuilder
    private func structuralResolveMenu(for row: DisputeRow) -> some View {
        Menu("Resolve") {
            switch row.kind {
            case .parentRole:
                if let role = ParentRole(rawValue: row.field) {
                    let occupants = snapshot.relationships
                        .filter { $0.type == .parent && $0.to == profile.id
                                  && $0.subtype == .biological && $0.role == role }
                        .compactMap { snapshot.profiles[$0.from] }
                    ForEach(occupants, id: \.id) { parent in
                        Button("Keep \(parent.displayName)") {
                            try? ConflictResolutionActions.chooseParent(
                                subjectID: profile.id, role: role,
                                keepParentID: parent.id,
                                snapshot: snapshot,
                                db: appState.currentDatabase!)
                            refreshAfterResolve()
                        }
                    }
                    Button("Keep both (e.g. adoptive)") {
                        try? ConflictResolutionActions.keepBothParents(
                            subjectID: profile.id, role: role,
                            db: appState.currentDatabase!)
                        refreshAfterResolve()
                    }
                }
            case .timeline:
                if row.field == "death-vs-alive" {
                    Button("Death date is wrong — clear it") {
                        try? ConflictResolutionActions.clearDeathDate(
                            profile: profile, db: appState.currentDatabase!)
                        refreshAfterResolve()
                    }
                }
                ForEach(disputedLifeEvents(for: row), id: \.id) { event in
                    Button("Discard \(event.type.rawValue) \(event.date?.original ?? "") — not the same person") {
                        try? ConflictResolutionActions.discardLifeEvent(
                            event, disputeFieldKey: row.field,
                            db: appState.currentDatabase!)
                        refreshAfterResolve()
                    }
                }
            case .spouseIdentity:
                Button("Dismiss — not the same person") {
                    try? ConflictResolutionActions.dismissNotSamePerson(
                        profileID: profile.id, kind: row.kind, fieldKey: row.field,
                        db: appState.currentDatabase!)
                    refreshAfterResolve()
                }
            case .fieldValue:
                EmptyView()
            }
            Divider()
            Button("Defer") {
                try? ConflictResolutionActions.deferDispute(
                    profileID: profile.id, kind: row.kind, fieldKey: row.field,
                    db: appState.currentDatabase!)
                refreshAfterResolve()
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The life events a timeline dispute references (evidence_json
    /// carries lifeEventIDs by reference — §5).
    private func disputedLifeEvents(for row: DisputeRow) -> [LifeEvent] {
        guard let json = row.evidenceJSON,
              let data = json.data(using: .utf8),
              let refs = try? JSONDecoder().decode([String: [String]].self, from: data),
              let ids = refs["lifeEventIDs"] else { return [] }
        let idSet = Set(ids.compactMap(UUID.init))
        let events = (try? appState.currentDatabase?.loadLifeEvents(profileID: profile.id)) ?? []
        return events.filter { idSet.contains($0.id) }
    }

    /// ⟨G12⟩ accept a proposed resolution: routes through the SAME accept
    /// flow as the candidate card (write value, resolve dispute,
    /// contradict rivals) — the proposal itself never wrote anything.
    private func acceptProposal(_ proposal: ConflictResolutionActions.ProposedResolution) {
        guard let db = appState.currentDatabase,
              let hypothesis = try? db.loadHypothesis(id: proposal.hypothesisID) else { return }
        do {
            switch hypothesis.kind {
            case .birthYearCandidate:
                try ApplyEngine.applyBirthYearCandidate(hypothesis, snapshot: appState.snapshot, db: db)
                if let groupID = hypothesis.candidateGroupID {
                    try db.contradictRivals(inCandidateGroup: groupID, acceptedID: hypothesis.id)
                }
            case .deathYearCandidate:
                try ApplyEngine.applyDeathYearCandidate(hypothesis, snapshot: appState.snapshot, db: db)
            default:
                return
            }
            refreshAfterResolve()
        } catch {
            // Surfaced via the card path normally; here we log and leave
            // the dispute open — never a partial state.
        }
    }

    private func refreshAfterResolve() {
        guard let db = appState.currentDatabase else { return }
        appState.snapshot = (try? db.buildSnapshot()) ?? appState.snapshot
        structuralDisputes = ((try? db.openDisputes(profileID: profile.id)) ?? [])
            .filter { $0.kind != .fieldValue }
        reloadInvestigations()
    }

    @ViewBuilder
    private func relationshipSection(
        _ title: String,
        profiles: [Profile],
        roleWord: String? = nil,
        edgeIDFor: ((Profile) -> UUID?)? = nil,
        roleEditFor: ((Profile) -> (edgeID: UUID, current: ParentRole?)?)? = nil
    ) -> some View {
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(profiles) { relative in
                    relativeRow(
                        relative,
                        removeEdgeID: editable ? edgeIDFor?(relative) : nil,
                        roleWord: roleWord ?? "relative",
                        roleEdit: editable ? roleEditFor?(relative) : nil
                    )
                }
            }
        }
    }

    private func roleLabel(_ role: ParentRole?) -> String {
        switch role {
        case .father: "father"
        case .mother: "mother"
        default: "role?"
        }
    }

    /// Stored parent edge where `parent` is a parent of the subject.
    private func parentEdgeID(_ parent: Profile) -> UUID? {
        snapshot.relationships.first {
            $0.type == .parent && $0.from == parent.id && $0.to == profile.id
        }?.id
    }

    /// The parent edge's id + current role, for the in-row re-role menu.
    private func parentRoleEdit(_ parent: Profile) -> (edgeID: UUID, current: ParentRole?)? {
        guard let edge = snapshot.relationships.first(where: {
            $0.type == .parent && $0.from == parent.id && $0.to == profile.id
        }) else { return nil }
        return (edge.id, edge.role)
    }

    /// Stored parent edge where the subject is the parent of `child`.
    private func childEdgeID(_ child: Profile) -> UUID? {
        snapshot.relationships.first {
            $0.type == .parent && $0.from == profile.id && $0.to == child.id
        }?.id
    }

    /// One relative line. With `onNavigateToProfile` set it is a Button that
    /// jumps the tree to the relative (chevron affordance); otherwise plain
    /// text. Button, not `.onTapGesture` — tap gestures inside a ScrollView
    /// are unreliably delivered on macOS.
    @ViewBuilder
    private func relativeRow(
        _ relative: Profile,
        removeEdgeID: UUID? = nil,
        roleWord: String = "relative",
        roleEdit: (edgeID: UUID, current: ParentRole?)? = nil
    ) -> some View {
        let switchesMode = navigateSwitchesMode?(relative.id) ?? false
        let hasTrailing = removeEdgeID != nil || roleEdit != nil
        let label = HStack {
            Text(relative.displayName)
                .font(.callout)
            if let year = relative.birthDate?.bestYear {
                Text("b. \(String(year))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if switchesMode {
                // Navigating flips pedigree ↔ descendants — same advance
                // hint the popover (and TreeSearchField) used.
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Switches view mode")
            }
            if onNavigateToProfile != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        return HStack(spacing: 8) {
            if let navigate = onNavigateToProfile {
                Button { navigate(relative.id) } label: {
                    label.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(relative.displayName) in the tree")
            } else {
                label
            }
            if hasTrailing { Spacer(minLength: 8) }
            // Edit-mode parent re-role — correct a mis-roled edge (father↔mother).
            if editable, let re = roleEdit {
                Menu {
                    Button("Father") { appState.setRelationshipRole(id: re.edgeID, role: .father) }
                    Button("Mother") { appState.setRelationshipRole(id: re.edgeID, role: .mother) }
                    Button("Unspecified") { appState.setRelationshipRole(id: re.edgeID, role: .unspecified) }
                } label: {
                    Text(roleLabel(re.current))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change this parent's role")
            }
            // Edit-mode unlink — remove a mis-linked parent/child/spouse edge.
            // Confirmed before it fires; the relative's own profile is untouched.
            if let edgeID = removeEdgeID {
                Button {
                    relationshipRemoval = RelationshipRemoval(
                        edgeID: edgeID, relativeName: relative.displayName, roleWord: roleWord)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Unlink \(relative.displayName) as a \(roleWord)")
                .accessibilityLabel("Unlink \(relative.displayName)")
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
    /// Census evidence, rendered by the family (a census is the household).
    /// Only appears when census records exist for the profile.
    @ViewBuilder
    private var censusEvidenceRow: some View {
        let census = factRecords.filter { $0.recordType == .census }
        if !census.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Census")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    evidenceTrigger(key: "census", records: census)
                }
                if expandedEvidenceKeys.contains("census") {
                    evidenceDisclosure(key: "census", records: census)
                }
            }
        }
    }

    @ViewBuilder
    private func spousesSection(for subject: Profile, snapshot: FamilyGraphSnapshot) -> some View {
        let spouseEdges = snapshot.relationships.filter { rel in
            rel.type == .spouse && (rel.from == subject.id || rel.to == subject.id)
        }
        let marriageRecords = factRecords.filter { $0.recordType == .marriage }
        if !spouseEdges.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Spouses")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Marriage evidence for the whole section (one person's
                    // marriage records; kept section-level to avoid guessing
                    // which record belongs to which spouse on remarriages).
                    evidenceTrigger(key: "marriage", records: marriageRecords)
                }
                if expandedEvidenceKeys.contains("marriage") {
                    evidenceDisclosure(key: "marriage", records: marriageRecords)
                }
                ForEach(spouseEdges, id: \.id) { edge in
                    let otherID = edge.from == subject.id ? edge.to : edge.from
                    if let spouse = snapshot.profiles[otherID] {
                        VStack(alignment: .leading, spacing: 2) {
                            // Same navigation affordance as relativeRow —
                            // spouses render separately only for the
                            // marriage-metadata lines below.
                            relativeRow(spouse,
                                        removeEdgeID: editable ? edge.id : nil,
                                        roleWord: "spouse")
                            if editable {
                                // Editable marriage date + place (its own commit —
                                // relationship metadata isn't part of the profile
                                // field bindings the parent Save flow writes).
                                SpouseMarriageEditRow(
                                    edgeID: edge.id,
                                    initialDate: edge.marriageDate?.original ?? "",
                                    initialLocation: edge.marriageLocation ?? "")
                            } else {
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
}
