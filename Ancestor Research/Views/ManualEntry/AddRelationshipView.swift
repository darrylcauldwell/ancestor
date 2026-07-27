import SwiftUI

/// Sheet for adding a relationship between two existing profiles.
/// Replaces the placeholder behaviour from Phase 3 where "Add Parent"/"Add Sibling"
/// could only create a profile but not always wire up the edge.
///
/// Two flows are supported:
///  - **Connect to anchor**: pick a target profile that the anchor already
///    knows nothing about, choose the kind of edge.
///  - **Sibling shortcut**: when the anchor has no parents yet, picking
///    "Sibling" creates a `NameStatus.placeholder` parent so both anchor
///    and target end up sharing parents. Phase 5b will prompt to replace
///    the placeholder when real parents are added.
struct AddRelationshipView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// The profile we're adding a relationship from. Pre-filled from the
    /// caller (tree selection / connect-banner orphan) but ALWAYS visible
    /// and changeable in the sheet — an invisible selection-derived anchor
    /// nearly welded two unrelated families (owner report 2026-07-15).
    @State private var anchorID: String
    /// Optional mirror of `anchorID` bound to the picker. `ProfilePickerField`
    /// reveals its search field only when the selection is `nil`, so the anchor
    /// needs an optional to be re-selectable. `anchorID` stays the non-optional
    /// source of truth used everywhere below; a real pick syncs back into it.
    /// (Previously the anchor bound a hand-rolled `Binding<String?>` whose setter
    /// dropped `nil`, so "Change" could never open the search field.)
    @State private var anchorSelection: String?

    init(anchorID: String, initialKind: Kind = .parent, newPerson: NewPerson? = nil) {
        self._anchorID = State(initialValue: anchorID)
        self._anchorSelection = State(initialValue: anchorID)
        self._kind = State(initialValue: initialKind)
        self._newPerson = State(initialValue: newPerson)
    }

    /// A person NOT yet in the tree (e.g. a census household member) to be
    /// created and linked on save, instead of picking an existing profile.
    struct NewPerson: Equatable {
        var name: String
        var birthYear: Int?
        var birthPlace: String?
        var sex: String?
        var sourceID: String?
    }

    @State private var kind: Kind
    @State private var newPerson: NewPerson?
    @State private var targetID: String?
    @State private var subtype: RelationshipSubtype = .biological
    @State private var marriageDateText: String = ""
    @State private var marriageLocation: String = ""
    @State private var marriageLocationCode: String? = nil
    /// DESIGN.md §7.5.7 — when the saved edge would be the third (or later)
    /// parent on the receiving profile, the user must explicitly confirm
    /// the subtype. Set to true once they pick a value in the prompt.
    @State private var thirdParentSubtypeConfirmed: Bool = false

    enum Kind: String, CaseIterable, Identifiable {
        case parent          // target IS A PARENT OF anchor
        case child           // target IS A CHILD OF anchor
        case spouse          // target is anchor's spouse
        case sibling         // target shares parents with anchor — uses placeholder if no parents

        var id: String { rawValue }
        var label: String {
            switch self {
            case .parent: return "Parent"
            case .child: return "Child"
            case .spouse: return "Spouse"
            case .sibling: return "Sibling"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Relationship")
                    .font(.title2).fontWeight(.semibold)
                Spacer()
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    anchorSummary
                    kindSection
                    targetSection
                    if kind == .parent || kind == .child {
                        subtypeSection
                    }
                    if kind == .spouse {
                        marriageSection
                    }
                    edgeDescription
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 480)
    }

    // MARK: - Sections

    private var anchorSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("This person")
            ProfilePickerField(
                label: "Anchor",
                snapshot: appState.snapshot,
                selectedID: $anchorSelection
            )
            .onChange(of: anchorSelection) { _, newValue in
                // Only a real pick updates the anchor. Clearing (Change → nil)
                // leaves `anchorID` intact and flips the field to its search
                // box; Add stays disabled until a person is chosen (see footer).
                if let id = newValue { anchorID = id }
            }
        }
    }

    /// Plain-English statement of the edge Add will create — the reader's
    /// last defence against an anchor they didn't intend.
    /// One-line context for the to-be-created person: birth year + place.
    private func newPersonDetail(_ np: NewPerson) -> String {
        var parts = ["New person"]
        if let y = np.birthYear { parts.append("b. ~\(y)") }
        if let p = np.birthPlace, !p.isEmpty { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var edgeDescription: some View {
        if let anchor = appState.snapshot.profiles[anchorID], let np = newPerson, targetID == nil {
            let noun: String = switch kind {
            case .parent: "a parent of"
            case .child: "a child of"
            case .spouse: "the spouse of"
            case .sibling: "a sibling of"
            }
            Text("\(np.name) will be added to the tree and recorded as \(noun) \(anchor.displayName).")
                .font(AppTypography.cardMeta.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let anchor = appState.snapshot.profiles[anchorID],
           let targetID, let target = appState.snapshot.profiles[targetID] {
            let sentence: String = {
                switch kind {
                case .parent:
                    return "\(target.displayName) will be recorded as a parent of \(anchor.displayName)."
                case .child:
                    return "\(target.displayName) will be recorded as a child of \(anchor.displayName)."
                case .spouse:
                    return "\(anchor.displayName) and \(target.displayName) will be recorded as spouses."
                case .sibling:
                    switch siblingWiring(targetID: targetID) {
                    case .inherit(let childID, let sourceID):
                        let child = appState.snapshot.profiles[childID]?.displayName ?? childID
                        let source = appState.snapshot.profiles[sourceID]?.displayName ?? sourceID
                        return "\(child) will be attached to \(source)'s parents, as their sibling."
                    case .placeholder:
                        return "\(anchor.displayName) and \(target.displayName) will share a new placeholder parent (neither has parents yet). You can replace it with a real person later."
                    case .bothHaveParents:
                        return "\(anchor.displayName) and \(target.displayName) each already have parents recorded — they can't be linked as siblings automatically. Reconcile their parents first."
                    }
                }
            }()
            Text(sentence)
                .font(AppTypography.cardMeta.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var kindSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Relationship type")
            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases) { k in
                    Text(k.label).tag(k)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Other person")
            if let np = newPerson {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(np.name)
                            .font(AppTypography.cardBody.weight(.medium))
                        Text(newPersonDetail(np))
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
            } else {
                ProfilePickerField(
                    label: "Target",
                    snapshot: appState.snapshot,
                    selectedID: $targetID
                )
            }
            if kind == .sibling, siblingIsPlaceholderCase {
                Text("Neither person has parents yet — a placeholder parent will be created so they share it. You can replace the placeholder with a real person later.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtypeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Subtype")
            Picker("Subtype", selection: $subtype) {
                Text("Biological").tag(RelationshipSubtype.biological)
                Text("Adoptive").tag(RelationshipSubtype.adoptive)
                Text("Step").tag(RelationshipSubtype.step)
                Text("Unknown").tag(RelationshipSubtype.unknown)
            }
            .pickerStyle(.segmented)
            .onChange(of: subtype) { _, _ in
                // Picking any value — biological included — counts as
                // explicit confirmation. The third-parent prompt below
                // only fires while the user has not yet touched the picker.
                if requiresThirdParentConfirmation {
                    thirdParentSubtypeConfirmed = true
                }
            }
            if requiresThirdParentConfirmation && !thirdParentSubtypeConfirmed {
                thirdParentPrompt
            }
        }
    }

    /// True when saving would push the receiving profile past two parents.
    /// `kind == .parent` → target is the new parent; child receives the edge.
    /// `kind == .child` → anchor is the new parent; target receives the edge.
    private var requiresThirdParentConfirmation: Bool {
        switch kind {
        case .parent:
            return appState.snapshot.parentCount(for: anchorID) >= 2
        case .child:
            guard let targetID else { return false }
            return appState.snapshot.parentCount(for: targetID) >= 2
        case .spouse, .sibling:
            return false
        }
    }

    private var thirdParentPrompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This would be a third parent — what's the relationship?")
                .font(AppTypography.cardMeta.weight(.medium))
                .foregroundStyle(.orange)
            Text("Pick a subtype above. Biological means a previously unrecorded biological parent; step or adoptive describe the more common reasons for a third parent.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 6))
    }

    private var marriageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Marriage (optional)")
            DateParsePreviewField(label: "Marriage date", text: $marriageDateText)
            LocationPicker(
                label: "Marriage location",
                text: $marriageLocation,
                locationCode: $marriageLocationCode
            )
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button("Add") { save() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(anchorSelection == nil || (targetID == nil && newPerson == nil) || (requiresThirdParentConfirmation && !thirdParentSubtypeConfirmed) || siblingBlockedBothHaveParents)
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

    private var anchorHasParents: Bool {
        !appState.snapshot.parentsOf(anchorID).isEmpty
    }

    /// True when a sibling link would create a shared placeholder (neither side
    /// has parents yet).
    private var siblingIsPlaceholderCase: Bool {
        guard kind == .sibling, let targetID else { return false }
        if case .placeholder = siblingWiring(targetID: targetID) { return true }
        return false
    }

    /// True when a sibling link is refused because both sides already have
    /// parents — Add is disabled so we never stack a second parent set.
    private var siblingBlockedBothHaveParents: Bool {
        guard kind == .sibling, let targetID else { return false }
        if case .bothHaveParents = siblingWiring(targetID: targetID) { return true }
        return false
    }

    /// Build a Profile from a census household member — split the name into
    /// given/surname, title-case a shouty census surname, derive gender from
    /// the sex column, and record a calculated (±1) birth year.
    static func buildProfile(from np: NewPerson) -> Profile {
        let tokens = np.name.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let last = tokens.count > 1 ? tokens.last?.capitalized : nil
        let first = (tokens.count > 1 ? tokens.dropLast().joined(separator: " ") : tokens.first)?.capitalized
        let gender: Gender? = switch (np.sex ?? "").uppercased().first {
        case "M": .male
        case "F": .female
        default: nil
        }
        let birth = np.birthYear.map { GenealogicalDate(parsing: "CAL \($0)") }
        return Profile(
            id: UUID().uuidString, externalIDs: [:],
            firstName: first, middleName: nil, lastName: last,
            gender: gender, attributes: nil,
            birthDate: birth, birthLocation: np.birthPlace,
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func save() {
        // Resolve the target: an existing pick, or a freshly-created person.
        let resolvedTargetID: String?
        if let existing = targetID {
            resolvedTargetID = existing
        } else if let np = newPerson {
            let profile = Self.buildProfile(from: np)
            appState.addProfile(
                profile,
                source: SourceOrigin(identifier: np.sourceID ?? "census.household"),
                relatedTo: nil)
            resolvedTargetID = profile.id
        } else {
            resolvedTargetID = nil
        }
        guard let targetID = resolvedTargetID else { return }

        switch kind {
        case .parent:
            // target IS A PARENT OF anchor
            appState.addRelationship(parentEdge(parent: targetID, child: anchorID, subtype: subtype))
            // Establishing a real parent retires the blank placeholder the
            // sibling shortcut left behind (and carries the siblings onto
            // this parent) rather than stacking a 3rd/4th parent.
            appState.reconcilePlaceholderParent(
                childID: anchorID, realParentID: targetID,
                role: parentRole(forParentID: targetID))
        case .child:
            // anchor IS A PARENT OF target
            let role = roleOfAnchorAsParent
            appState.addRelationship(Relationship(
                id: UUID(), from: anchorID, to: targetID,
                type: .parent, role: role, subtype: subtype,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil
            ))
        case .spouse:
            appState.addRelationship(Relationship(
                id: UUID(), from: anchorID, to: targetID,
                type: .spouse, role: nil, subtype: .unknown,
                marriageDate: GenealogicalDate.parsePreview(marriageDateText).parsed,
                marriageLocation: AutoSuggestService.normaliseName(marriageLocation),
                marriageLocationCode: marriageLocationCode,
                divorceDate: nil
            ))
        case .sibling:
            siblingShortcut(targetID: targetID)
        }

        dismiss()
    }

    /// How a sibling link will be wired. Direction follows **parent-presence**,
    /// not the anchor/target slot: the orphan-connect banner anchors on the
    /// parent-less person, so keying off the anchor sent the link backwards and
    /// stacked placeholder parents onto the established profile (owner report
    /// 2026-07-16 — Elsie picked up four blank placeholder parents).
    private enum SiblingWiring {
        /// `childID` inherits the parents of `sourceID`.
        case inherit(childID: String, sourceID: String)
        /// Neither side has parents — create a placeholder shared by both.
        case placeholder
        /// Both already have parents — stacking one set onto the other is the
        /// exact pollution this shortcut must avoid; refuse and make the user
        /// reconcile parents explicitly.
        case bothHaveParents
    }

    private func siblingWiring(targetID: String) -> SiblingWiring {
        let anchorHas = !appState.snapshot.parentsOf(anchorID).isEmpty
        let targetHas = !appState.snapshot.parentsOf(targetID).isEmpty
        switch (anchorHas, targetHas) {
        case (true, false):  return .inherit(childID: targetID, sourceID: anchorID)
        case (false, true):  return .inherit(childID: anchorID, sourceID: targetID)
        case (false, false): return .placeholder
        case (true, true):   return .bothHaveParents
        }
    }

    /// Sibling shortcut. Whichever side lacks parents inherits the other's; if
    /// neither has parents, a placeholder parent is created and shared by both.
    /// Refuses when both already have parents (see `SiblingWiring`).
    private func siblingShortcut(targetID: String) {
        switch siblingWiring(targetID: targetID) {
        case .inherit(let childID, let sourceID):
            for parent in appState.snapshot.parentsOf(sourceID) {
                appState.addRelationship(parentEdge(parent: parent.id, child: childID, subtype: .biological))
            }
        case .placeholder:
            let placeholder = Profile(
                id: UUID().uuidString,
                externalIDs: [:],
                firstName: nil, lastName: nil, gender: nil,
                attributes: PersonAttributes(
                    nameStatus: .placeholder,
                    lifeStatus: .normal,
                    privacy: .normal
                ),
                birthDate: nil, birthLocation: nil,
                deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false,
                sources: [:], disputes: [:]
            )
            appState.addProfile(placeholder, source: .manualMemory, relatedTo: nil)
            appState.addRelationship(parentEdge(parent: placeholder.id, child: anchorID, subtype: .biological))
            appState.addRelationship(parentEdge(parent: placeholder.id, child: targetID, subtype: .biological))
        case .bothHaveParents:
            // No-op: the Add button is disabled for this case, so save() is not
            // reachable here in practice. Guarded anyway to never stack parents.
            break
        }
    }

    private func parentEdge(parent: String, child: String, subtype: RelationshipSubtype) -> Relationship {
        let role = parentRole(forParentID: parent)
        return Relationship(
            id: UUID(), from: parent, to: child,
            type: .parent, role: role, subtype: subtype,
            marriageDate: nil, marriageLocation: nil, divorceDate: nil
        )
    }

    private func parentRole(forParentID id: String) -> ParentRole {
        switch appState.snapshot.profiles[id]?.gender {
        case .female: return .mother
        case .male: return .father
        default: return .unspecified
        }
    }

    private var roleOfAnchorAsParent: ParentRole {
        parentRole(forParentID: anchorID)
    }
}
