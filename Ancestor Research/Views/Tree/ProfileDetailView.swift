import SwiftUI

/// Inspector panel showing full profile details with source badges.
struct ProfileDetailView: View {
    let profile: Profile
    let snapshot: FamilyGraphSnapshot
    var onSetRoot: (() -> Void)?

    @Environment(AppState.self) private var appState
    /// M24 — when true (Settings → Accessibility → "Differentiate without
    /// colour"), state-colour signals are paired with shape/glyph alternatives.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var showingEdit: Bool = false
    @State private var showingTimeline: Bool = false
    @State private var showingNoteComposer: Bool = false
    @State private var editingNote: WorkbenchNote?
    @State private var showingRelationshipCalculator: Bool = false
    @State private var showingLifeEventEditor: Bool = false
    @State private var editingLifeEvent: LifeEvent?
    @State private var showingAttachmentImporter: Bool = false
    @State private var cleansePresentation: CleansePresentation?

    var body: some View {
        ScrollView {
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

                // Per-gap research entry points (Task #39). When a profile is
                // missing facts the user can act on each one in-place rather
                // than running a whole-profile sweep. Each row sets the same
                // researchConfigProfile that the whole-profile Research button
                // does — `ResearchConfigSheet` then picks an appropriate
                // default mode for the subject. We don't yet pass a focus
                // hint through to the sheet; that's a future refinement.
                missingFactsSection

                // Fields with source badges
                fieldRow("Birth", value: profile.birthDate?.original, place: profile.birthLocation, field: .birthDate)
                hypotheticalLine(for: .birthDate)
                fieldRow("Death", value: profile.deathDate?.original, place: profile.deathLocation, field: .deathDate)
                hypotheticalLine(for: .deathDate)

                if let gender = profile.gender {
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

                // Disputes
                if !profile.disputes.isEmpty {
                    Divider()
                    Text("Disputes")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    ForEach(Array(profile.disputes.values), id: \.field) { dispute in
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

                // Actions
                Divider()
                HStack(spacing: 8) {
                    Button("Edit") {
                        showingEdit = true
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
                        Button("Show as Root") {
                            setRoot()
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    }
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingEdit) {
            EditPersonView(profileID: profile.id)
        }
        .sheet(isPresented: $showingTimeline) {
            ProfileTimelineView(profileID: profile.id)
                .frame(minWidth: 540, minHeight: 600)
        }
        .sheet(isPresented: $showingNoteComposer) {
            NoteComposerView(initial: nil, attachedTo: .profile(id: profile.id))
        }
        .sheet(item: $editingNote) { note in
            NoteComposerView(initial: note, attachedTo: note.attachedTo)
        }
        .sheet(isPresented: $showingRelationshipCalculator) {
            RelationshipCalculatorView(
                initialFromID: appState.currentProject?.homePersonID,
                initialTargetID: profile.id
            )
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
        .sheet(item: $cleansePresentation) { presentation in
            ProfileCleanseWizard(mode: presentation.mode)
        }
    }

    /// Per-gap research entry points (Task #39). Lists each missing fact /
    /// relationship from the completeness check and offers a Research button
    /// per item. Each button opens the standard `ResearchConfigSheet` for the
    /// profile — the sheet's smart-default mode picker already adapts to the
    /// subject's shape, so a per-gap button on a ghost profile lands on
    /// Discover and on a near-complete profile lands on Verify. Targeted-focus
    /// hinting (e.g. "fill death record specifically") is deliberately not
    /// passed through yet; the pipeline doesn't act on it and the current
    /// signposting value comes from the entry point, not the dispatch.
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
                        Button("Research") {
                            appState.researchConfigProfile = profile
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
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
