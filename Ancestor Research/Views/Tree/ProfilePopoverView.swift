import SwiftUI

/// Tier 2 popover — expanded profile detail anchored to a canvas node.
/// Shows off-canvas-only relatives, source badges, missing fields, dispute indicator.
struct ProfilePopoverView: View {
    let profile: Profile
    let snapshot: FamilyGraphSnapshot
    let completeness: ProfileCompleteness
    let visibleNodeIDs: Set<String>
    let isRoot: Bool
    let currentViewMode: TreeViewMode

    var onRecenter: (String) -> Void
    var onFocusHere: () -> Void
    var onShowDetail: () -> Void
    var onResearch: (() -> Void)?
    var onEdit: (() -> Void)?
    var onAddRelative: ((AutoSuggestService.RelationContext) -> Void)?
    var onAddRelationship: (() -> Void)?
    var onRemove: (() -> Void)?
    var onRemoveBranch: ((Bool) -> Void)?  // ancestors=true removes ancestors; false removes descendants

    /// W3 Focus actions. `onToggleFocus` toggles whether this profile is in
    /// the active focus set. nil → no active focus set (callback hidden).
    var isInFocus: Bool = false
    var hasActiveFocus: Bool = false
    var onToggleFocus: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                vitalEvents
                offCanvasRelativesSection
                missingFields
                disputeIndicator
                Divider()
                actionButtons
            }
            .padding(16)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.displayName)
                .font(AppTypography.popoverTitle)
            if let wikiTreeID = profile.wikiTreeID {
                Text(wikiTreeID)
                    .font(AppTypography.popoverLabel)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ProgressView(value: Double(completeness.score), total: Double(completeness.maximum))
                    .tint(completeness.score == completeness.maximum ? .green : .orange)
                    .frame(width: 60)
                Text("\(completeness.score)/\(completeness.maximum)")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(completeness.score == completeness.maximum ? .green : .orange)
            }
        }
    }

    // MARK: - Vital Events

    private var vitalEvents: some View {
        VStack(alignment: .leading, spacing: 8) {
            if profile.birthDate != nil || profile.birthLocation != nil {
                fieldRow("Born", date: profile.birthDate?.original, location: profile.birthLocation, field: .birthDate)
            }
            if profile.deathDate != nil || profile.deathLocation != nil {
                fieldRow("Died", date: profile.deathDate?.original, location: profile.deathLocation, field: .deathDate)
            } else if completeness.potentiallyLiving {
                Text("Living")
                    .font(AppTypography.popoverValue)
                    .foregroundStyle(.secondary)
            }
            if let gender = profile.gender {
                HStack {
                    Text("Gender").font(AppTypography.popoverLabel).foregroundStyle(.secondary)
                    Spacer()
                    Text(gender.rawValue.capitalized).font(AppTypography.popoverValue)
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ label: String, date: String?, location: String?, field: ProfileField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(AppTypography.popoverLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                sourceBadges(for: field)
            }
            if let d = date {
                Text(d).font(AppTypography.popoverValue)
            }
            if let l = location {
                Text(l).font(AppTypography.popoverLabel).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func sourceBadges(for field: ProfileField) -> some View {
        let sources = profile.sources[field] ?? []
        HStack(spacing: 2) {
            ForEach(sources, id: \.raw) { source in
                Text(source.origin.identifier.uppercased())
                    .font(AppTypography.sourceBadge)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
            }
        }
    }

    // MARK: - Off-Canvas Relatives

    private var offCanvas: (parents: [Profile], spouses: [Profile],
                            children: [Profile], siblings: [Profile]) {
        (
            snapshot.parentsOf(profile.id).filter { !visibleNodeIDs.contains($0.id) },
            snapshot.spousesOf(profile.id).filter { !visibleNodeIDs.contains($0.id) },
            snapshot.childrenOf(profile.id).filter { !visibleNodeIDs.contains($0.id) },
            snapshot.siblingsOf(profile.id).filter { !visibleNodeIDs.contains($0.id) }
        )
    }

    private var hasOffCanvas: Bool {
        !offCanvas.parents.isEmpty || !offCanvas.spouses.isEmpty ||
        !offCanvas.children.isEmpty || !offCanvas.siblings.isEmpty
    }

    @ViewBuilder
    private var offCanvasRelativesSection: some View {
        if hasOffCanvas {
            VStack(alignment: .leading, spacing: 6) {
                Text("Off-canvas relatives")
                    .font(AppTypography.popoverLabel)
                    .foregroundStyle(.secondary)
                relativeGroup("Parent", relatives: offCanvas.parents, isAncestor: true)
                relativeGroup("Spouse", relatives: offCanvas.spouses, isAncestor: false)
                relativeGroup("Child", relatives: offCanvas.children, isAncestor: false)
                relativeGroup("Sibling", relatives: offCanvas.siblings, isAncestor: false)
            }
        } else {
            Text("All relatives visible on canvas")
                .font(AppTypography.popoverLabel)
                .foregroundStyle(.tertiary)
                .italic()
        }
    }

    @ViewBuilder
    private func relativeGroup(_ label: String, relatives: [Profile], isAncestor: Bool) -> some View {
        if !relatives.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(relatives.count == 1 ? label : "\(label)s")
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)

                ForEach(relatives) { relative in
                    Button {
                        onRecenter(relative.id)
                    } label: {
                        HStack(spacing: 4) {
                            if wouldSwitchMode(isAncestor: isAncestor) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(AppTypography.badge)
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("Switches view mode")
                            }
                            Text(relative.displayName)
                                .font(AppTypography.popoverValue)
                            if let year = relative.birthDate?.bestYear {
                                Text("b. \(year)")
                                    .font(AppTypography.badge)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle")
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                }
            }
        }
    }

    private func wouldSwitchMode(isAncestor: Bool) -> Bool {
        (isAncestor && currentViewMode == .descendants) ||
        (!isAncestor && currentViewMode == .pedigree)
    }

    // MARK: - Missing Fields & Disputes

    @ViewBuilder
    private var missingFields: some View {
        if !completeness.missing.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Missing")
                    .font(AppTypography.popoverLabel)
                    .foregroundStyle(.secondary)
                ForEach(completeness.missing, id: \.self) { check in
                    switch check {
                    case .field(let field):
                        Text("• \(field.rawValue)")
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    case .hasParents:
                        Text("• parents")
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var disputeIndicator: some View {
        if !profile.disputes.isEmpty {
            let count = profile.disputes.count
            Text("⚠ \(count) disputed field\(count == 1 ? "" : "s")")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 6) {
            HStack {
                Button("Focus Here") { onFocusHere() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .disabled(isRoot)
                Spacer()
                if let onResearch {
                    Button("Research") { onResearch() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
                Button("Full Detail") { onShowDetail() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            if onEdit != nil || onAddRelative != nil {
                HStack {
                    if let onEdit {
                        Button("Edit") { onEdit() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                    Spacer()
                    if let onAddRelative {
                        Menu("Add…") {
                            Button("Add Child") { onAddRelative(.child) }
                            Button("Add Spouse") { onAddRelative(.spouse) }
                            Button("Add Parent") { onAddRelative(.parent) }
                            Button("Add Sibling") { onAddRelative(.sibling) }
                            if let onAddRelationship {
                                Divider()
                                Button("Connect to existing person…") { onAddRelationship() }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                    }
                }
            }
            if onRemove != nil || onRemoveBranch != nil || (onToggleFocus != nil && hasActiveFocus) {
                HStack {
                    if let onToggleFocus, hasActiveFocus {
                        Button {
                            onToggleFocus()
                        } label: {
                            Label(
                                isInFocus ? "Remove from focus" : "Add to focus",
                                systemImage: isInFocus ? "scope" : "plus.circle"
                            )
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                    Spacer()
                    if onRemove != nil || onRemoveBranch != nil {
                        Menu("Remove…") {
                            if let onRemove {
                                Button("Remove this person", role: .destructive) { onRemove() }
                            }
                            if let onRemoveBranch {
                                Button("Remove person and ancestors", role: .destructive) { onRemoveBranch(true) }
                                Button("Remove person and descendants", role: .destructive) { onRemoveBranch(false) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
