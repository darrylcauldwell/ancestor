import SwiftUI

/// Sheet for creating a hypothesis. Editing existing hypotheses reuses
/// the detail view, which has confidence + reasoning + evidence editors.
/// The composer's job is the *claim* — picking one of the four shapes
/// and filling its specific fields.
struct HypothesisComposerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Currently only `nil` is meaningful — composer is create-only.
    /// (Edit goes through `HypothesisDetailView`.)
    let initial: Hypothesis?

    @State private var kind: HypothesisClaim.Kind = .relationship
    @State private var confidence: HypothesisConfidence = .speculation
    @State private var reasoning: String = ""

    // Per-claim-type fields. Only the fields for the selected `kind` are read.
    @State private var fromProfileID: String?
    @State private var toProfileID: String?
    @State private var relationshipType: RelationshipType = .parent
    @State private var role: ParentRole = .unspecified

    @State private var fieldProfileID: String?
    @State private var field: ProfileField = .firstName
    @State private var fieldValue: String = ""

    @State private var idA: String?
    @State private var idB: String?

    @State private var existenceDescription: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New hypothesis")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("Claim type")
                    Picker("Kind", selection: $kind) {
                        ForEach(HypothesisClaim.Kind.allCases, id: \.self) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Group {
                        switch kind {
                        case .relationship: relationshipFields
                        case .fieldValue: fieldValueFields
                        case .identityMatch: identityMatchFields
                        case .existence: existenceFields
                        }
                    }

                    Divider()

                    sectionTitle("Confidence")
                    Picker("Confidence", selection: $confidence) {
                        ForEach(HypothesisConfidence.allCases, id: \.self) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    sectionTitle("Reasoning")
                    TextEditor(text: $reasoning)
                        .font(AppTypography.cardBody)
                        .frame(minHeight: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Create") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 580)
    }

    // MARK: - Per-claim sub-forms

    private var relationshipFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Subject (the relative)")
            ProfilePickerField(
                label: "From",
                snapshot: appState.snapshot,
                selectedID: $fromProfileID
            )
            sectionTitle("Of (their parent / spouse)")
            ProfilePickerField(
                label: "To",
                snapshot: appState.snapshot,
                selectedID: $toProfileID
            )
            sectionTitle("Type")
            Picker("Type", selection: $relationshipType) {
                Text("Parent").tag(RelationshipType.parent)
                Text("Spouse").tag(RelationshipType.spouse)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if relationshipType == .parent {
                Picker("Role", selection: $role) {
                    Text("Father").tag(ParentRole.father)
                    Text("Mother").tag(ParentRole.mother)
                    Text("Unspecified").tag(ParentRole.unspecified)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var fieldValueFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Profile")
            ProfilePickerField(
                label: "Subject",
                snapshot: appState.snapshot,
                selectedID: $fieldProfileID
            )
            sectionTitle("Field")
            Picker("Field", selection: $field) {
                ForEach(ProfileField.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.menu)
            sectionTitle("Hypothesised value")
            TextField("Value", text: $fieldValue)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var identityMatchFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identity-match promotion is not yet supported (M9 will introduce the merge flow). You can still record the hypothesis, but promote will route to dismiss-with-reason for now.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            sectionTitle("Profile A")
            ProfilePickerField(
                label: "Profile A",
                snapshot: appState.snapshot,
                selectedID: $idA
            )
            sectionTitle("Profile B")
            ProfilePickerField(
                label: "Profile B",
                snapshot: appState.snapshot,
                selectedID: $idB
            )
        }
    }

    private var existenceFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Description")
            TextField("e.g. James, sibling who died young", text: $existenceDescription)
                .textFieldStyle(.roundedBorder)
            Text("Promoting this hypothesis will create a profile from the description. Wire its relationships afterwards via Add Relationship.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Validation + save

    private var canSave: Bool {
        switch kind {
        case .relationship:
            return fromProfileID != nil && toProfileID != nil && fromProfileID != toProfileID
        case .fieldValue:
            return fieldProfileID != nil && !fieldValue.trimmingCharacters(in: .whitespaces).isEmpty
        case .identityMatch:
            return idA != nil && idB != nil && idA != idB
        case .existence:
            return !existenceDescription.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func save() {
        let claim: HypothesisClaim
        switch kind {
        case .relationship:
            guard let fromID = fromProfileID, let toID = toProfileID else { return }
            claim = .relationship(
                fromID: fromID, toID: toID,
                type: relationshipType,
                role: relationshipType == .parent ? role : nil
            )
        case .fieldValue:
            guard let pid = fieldProfileID else { return }
            claim = .fieldValue(profileID: pid, field: field, value: fieldValue)
        case .identityMatch:
            guard let a = idA, let b = idB else { return }
            claim = .identityMatch(profileID1: a, profileID2: b)
        case .existence:
            claim = .existence(
                description: existenceDescription.trimmingCharacters(in: .whitespaces),
                relatedProfileIDs: []
            )
        }

        appState.createHypothesis(
            claim: claim,
            confidence: confidence,
            reasoning: reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        dismiss()
    }
}
