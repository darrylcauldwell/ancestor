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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                    if let wikiTreeID = profile.wikiTreeID {
                        Text(wikiTreeID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let comp = snapshot.completeness(for: profile.id)
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
                }

                Divider()

                // Fields with source badges
                fieldRow("Birth", value: profile.birthDate?.original, place: profile.birthLocation, field: .birthDate)
                hypotheticalLine(for: .birthDate)
                fieldRow("Death", value: profile.deathDate?.original, place: profile.deathLocation, field: .deathDate)
                hypotheticalLine(for: .deathDate)

                if let gender = profile.gender {
                    LabeledContent("Gender") {
                        Text(gender.rawValue.capitalized)
                    }
                }
                hypotheticalLine(for: .gender)

                Divider()

                // Relationships
                relationshipSection("Parents", profiles: snapshot.parentsOf(profile.id))
                relationshipSection("Spouses", profiles: snapshot.spousesOf(profile.id))
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
}
