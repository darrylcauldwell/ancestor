import SwiftUI

/// CLEANSE_WIZARD_SPEC §3 — renders one finding inside the wizard. Stateless
/// view: all transient state (freeform text, selected quarter, selected
/// proposals) is passed in as Bindings from `ProfileCleanseWizard`, which
/// resets them each time the cursor advances.
struct CleanseFindingStep: View {

    let profile: Profile
    let finding: CleanseFinding

    @Binding var freeformText: String
    @Binding var selectedQuarter: String
    @Binding var selectedProposalIDs: Set<String>

    /// External callback for ambiguous-location "apply this candidate" rows.
    /// The wizard wires this; here we just trigger the parent\u{2019}s logic.
    var onApplyMatch: ((GazetteerEntry) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                bodyForFinding
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconForFinding)
                    .foregroundStyle(.orange)
                Text(profile.displayName)
                    .font(.headline)
            }
            Text(finding.title)
                .font(AppTypography.cardTitle)
                .fontWeight(.semibold)
            Text(finding.summary)
                .font(AppTypography.cardBody)
                .foregroundStyle(.secondary)
        }
    }

    private var iconForFinding: String {
        switch finding {
        case .ambiguousLocation:            return "questionmark.diamond"
        case .unmatchedLocation:            return "magnifyingglass.circle"
        case .unconfirmedLocation:          return "mappin.and.ellipse"
        case .missingParentFromBirthRecord: return "person.2.badge.plus"
        case .bareYearDate:                 return "calendar.badge.exclamationmark"
        case .givenNameContainsMiddle:      return "textformat.abc"
        case .junkInName:                   return "exclamationmark.bubble"
        case .incompleteName:               return "person.text.rectangle"
        }
    }

    // MARK: - Body per case

    @ViewBuilder
    private var bodyForFinding: some View {
        switch finding {
        case .ambiguousLocation(_, _, let candidates):
            ambiguousLocationBody(candidates: candidates)
        case .unmatchedLocation(_, _, let fuzzy):
            unmatchedLocationBody(fuzzyMatches: fuzzy)
        case .unconfirmedLocation(_, _, let match):
            unconfirmedLocationBody(match: match)
        case .missingParentFromBirthRecord(_, let proposals):
            missingParentBody(proposals: proposals)
        case .bareYearDate(_, _, let year, let available):
            bareYearBody(year: year, availableQuarter: available)
        case .givenNameContainsMiddle(_, let current, let first, let middle):
            givenNameSplitBody(current: current, first: first, middle: middle)
        case .junkInName(_, let field, let current, let proposed, let nickname):
            junkInNameBody(field: field, current: current, proposed: proposed, nickname: nickname)
        case .incompleteName(_, let reason, let fillField):
            incompleteNameBody(reason: reason, fillField: fillField)
        }
    }

    // MARK: Ambiguous location

    @ViewBuilder
    private func ambiguousLocationBody(candidates: [GazetteerEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick the right place")
                .font(AppTypography.cardTitle)
            ForEach(candidates) { entry in
                Button {
                    onApplyMatch?(entry)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                                .font(AppTypography.cardBody)
                            Text(entry.id)
                                .font(AppTypography.cardMeta)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Image(systemName: "arrow.forward.circle")
                            .foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    // MARK: Unmatched location

    @ViewBuilder
    private func unmatchedLocationBody(fuzzyMatches: [GazetteerEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit the freeform text")
                    .font(AppTypography.cardTitle)
                TextField("Birth location", text: $freeformText)
                    .textFieldStyle(.roundedBorder)
                Text("If the new text matches a single gazetteer entry it will attach a structured code automatically; otherwise it stays freeform.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            }

            if !fuzzyMatches.isEmpty {
                Divider()
                Text("Near misses")
                    .font(AppTypography.cardTitle)
                ForEach(fuzzyMatches) { entry in
                    Button {
                        freeformText = entry.displayName
                    } label: {
                        HStack {
                            Image(systemName: "sparkle.magnifyingglass")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                    .font(AppTypography.cardBody)
                                Text(entry.id)
                                    .font(AppTypography.cardMeta)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Unconfirmed location

    @ViewBuilder
    private func unconfirmedLocationBody(match: GazetteerEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Single gazetteer match")
                .font(AppTypography.cardTitle)
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.displayName)
                        .font(AppTypography.cardBody)
                        .fontWeight(.semibold)
                    Text(match.id)
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.tertiary)
                }
            }
            Text("Confirming attaches the structured code without changing the display text.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Missing parent

    @ViewBuilder
    private func missingParentBody(proposals: [ProposedRelative]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proposed parents")
                .font(AppTypography.cardTitle)
            ForEach(proposals, id: \.id) { proposal in
                Toggle(isOn: Binding(
                    get: { selectedProposalIDs.contains(proposal.id) },
                    set: { isOn in
                        if isOn { selectedProposalIDs.insert(proposal.id) }
                        else { selectedProposalIDs.remove(proposal.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proposalHeadline(proposal))
                            .font(AppTypography.cardBody)
                        Text(proposalSubtitle(proposal))
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            Text("Each accepted proposal creates a ghost profile and a parent-of relationship.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
        }
    }

    private func proposalHeadline(_ p: ProposedRelative) -> String {
        let role: String
        switch p.gender {
        case .female: role = "Mother"
        case .male:   role = "Father"
        default:      role = "Parent"
        }
        return "\(role): \(p.proposedGivenName ?? "?") \(p.proposedSurname ?? "?")"
    }

    private func proposalSubtitle(_ p: ProposedRelative) -> String {
        let yearText: String
        switch (p.birthYearLow, p.birthYearHigh) {
        case let (lo?, hi?): yearText = "born \(lo)\u{2013}\(hi)"
        case let (lo?, nil): yearText = "born after \(lo)"
        case let (nil, hi?): yearText = "born before \(hi)"
        default:             yearText = "birth year unknown"
        }
        return "Inferred from \(p.evidence.count) record\(p.evidence.count == 1 ? "" : "s") \u{2022} \(yearText)"
    }

    // MARK: Bare-year date

    @ViewBuilder
    private func bareYearBody(year: Int, availableQuarter: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let available = availableQuarter {
                HStack {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.tint)
                    Text("Confirmed BMD record carries \(available). Apply to set \(available) \(year).")
                        .font(AppTypography.cardBody)
                }
            }

            Picker("Quarter", selection: $selectedQuarter) {
                Text("Q1 (Jan\u{2013}Mar)").tag("Q1")
                Text("Q2 (Apr\u{2013}Jun)").tag("Q2")
                Text("Q3 (Jul\u{2013}Sep)").tag("Q3")
                Text("Q4 (Oct\u{2013}Dec)").tag("Q4")
            }
            .pickerStyle(.segmented)

            Text("Applied as \"\(selectedQuarter) \(year)\".")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Given / middle split

    @ViewBuilder
    private func givenNameSplitBody(current: String, first: String, middle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proposed split")
                .font(AppTypography.cardTitle)

            HStack(spacing: 10) {
                nameChip(label: "Current given", value: current, tint: .orange)
                Image(systemName: "arrow.forward")
                    .foregroundStyle(.secondary)
                nameChip(label: "Given", value: first, tint: .green)
                nameChip(label: "Middle", value: middle, tint: .green)
            }

            Text("The first word becomes the given name; the rest becomes the middle name. If \u{201C}\(current)\u{201D} is really a single (compound) given name, decline with Skip or Mark unresolvable instead.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Junk in name

    @ViewBuilder
    private func junkInNameBody(field: ProfileField, current: String, proposed: String, nickname: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proposed cleanup")
                .font(AppTypography.cardTitle)
            HStack(spacing: 10) {
                nameChip(label: field == .lastName ? "Current surname" : "Current given",
                         value: current, tint: .orange)
                Image(systemName: "arrow.forward").foregroundStyle(.secondary)
                nameChip(label: "Cleaned", value: proposed.isEmpty ? "(cleared)" : proposed, tint: .green)
                if let nickname, !nickname.isEmpty {
                    nameChip(label: "Nickname", value: nickname, tint: .blue)
                }
            }
            Text("Junk — a \u{201C}?\u{201D}, a parenthetical aside, or a placeholder word — is removed. If this looks wrong, decline with Skip or Mark unresolvable.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Incomplete name

    @ViewBuilder
    private func incompleteNameBody(reason: String, fillField: ProfileField) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reason.prefix(1).uppercased() + reason.dropFirst())
                .font(AppTypography.cardTitle)
            VStack(alignment: .leading, spacing: 4) {
                Text(fillField == .lastName ? "Enter the surname" : "Enter the given name")
                    .font(AppTypography.cardBody)
                TextField(fillField == .lastName ? "Surname" : "Given name", text: $freeformText)
                    .textFieldStyle(.roundedBorder)
            }
            Text("If you don't know it, decline — a surname-only spouse usually needs researching (find the maiden name from a marriage or the children's records) rather than typing.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func nameChip(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(AppTypography.cardMeta)
                .foregroundStyle(.tertiary)
            Text(value.isEmpty ? "—" : value)
                .font(AppTypography.cardBody)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
