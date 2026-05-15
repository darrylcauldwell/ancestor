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

    /// The profile we're adding a relationship from.
    let anchorID: String

    @State private var kind: Kind = .parent
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
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 480)
    }

    // MARK: - Sections

    @ViewBuilder
    private var anchorSummary: some View {
        if let anchor = appState.snapshot.profiles[anchorID] {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Anchor:")
                    .font(AppTypography.cardMeta).foregroundStyle(.secondary)
                Text(anchor.displayName)
                    .font(AppTypography.cardBody.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
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
            ProfilePickerField(
                label: "Target",
                snapshot: appState.snapshot,
                selectedID: $targetID
            )
            if kind == .sibling, !anchorHasParents {
                Text("Anchor has no parents yet — a placeholder parent will be created so anchor and target share it. You can replace the placeholder with a real person later.")
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
                .disabled(targetID == nil || (requiresThirdParentConfirmation && !thirdParentSubtypeConfirmed))
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

    private func save() {
        guard let targetID else { return }

        switch kind {
        case .parent:
            // target IS A PARENT OF anchor
            appState.addRelationship(parentEdge(parent: targetID, child: anchorID, subtype: subtype))
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

    /// Sibling shortcut. If the anchor already has parents, attach the target
    /// to those same parents. Otherwise, create a placeholder parent and attach
    /// both anchor and target to it as biological children.
    private func siblingShortcut(targetID: String) {
        let parents = appState.snapshot.parentsOf(anchorID)
        if !parents.isEmpty {
            for parent in parents {
                appState.addRelationship(parentEdge(parent: parent.id, child: targetID, subtype: .biological))
            }
            return
        }

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
