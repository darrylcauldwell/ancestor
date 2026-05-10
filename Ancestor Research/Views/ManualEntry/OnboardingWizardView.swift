import SwiftUI

/// Guided multi-step flow for the very first session of a manual project.
/// Walks the user through home person → parents → grandparents → spouse/children,
/// then commits everything as a single addFamily transaction and sets homePersonID.
struct OnboardingWizardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .structure
    @State private var input: OnboardingWizardBuilder.Input = .blank

    private enum Step: Int, CaseIterable {
        case structure         // Step 0
        case you               // Step 1
        case parents           // Step 2
        case paternalGrand     // Step 3a
        case maternalGrand     // Step 3b
        case family            // Step 4 (optional spouse + children)
        case review            // Final summary

        var title: String {
            switch self {
            case .structure: return "Before we start"
            case .you: return "Let's start with you"
            case .parents: return "Now your parents"
            case .paternalGrand: return "Your father's parents"
            case .maternalGrand: return "Your mother's parents"
            case .family: return "Your family"
            case .review: return "Ready to build"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .structure: structureStep
                    case .you: youStep
                    case .parents: parentsStep
                    case .paternalGrand: paternalGrandparentsStep
                    case .maternalGrand: maternalGrandparentsStep
                    case .family: familyStep
                    case .review: reviewStep
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 580, minHeight: 600)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Build Your Tree")
                .font(.title3).fontWeight(.semibold)
            Text(step.title)
                .font(.title2).fontWeight(.semibold)
            ProgressView(value: progress)
                .tint(.accentColor)
        }
        .padding(20)
    }

    private var progress: Double {
        let total = Double(Step.allCases.count - 1)
        return Double(step.rawValue) / total
    }

    // MARK: - Steps

    private var structureStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Is there anything unusual about your immediate family?")
                .font(AppTypography.cardBody)
            structureChoice(.standard, title: "No, straightforward",
                             subtitle: "Biological parents")
            structureChoice(.adopted, title: "I was adopted",
                             subtitle: "Adoptive parents (you can add biological parents later)")
            structureChoice(.divorced, title: "My parents divorced or remarried",
                             subtitle: "We'll record one couple now; add the other later")
            // Fourth option: skip the wizard entirely. Phrased as a peer choice
            // (per spec §7.5.1) so users with non-standard structures don't feel
            // shoehorned. The flexible Add Family flow handles arbitrary shapes.
            complicatedChoice
        }
    }

    private var complicatedChoice: some View {
        Button {
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("It's complicated").font(AppTypography.cardBody.weight(.medium))
                    Text("Skip the wizard — you'll add people one family at a time.")
                        .font(AppTypography.cardMeta).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func structureChoice(_ value: OnboardingWizardBuilder.Structure,
                                  title: String, subtitle: String) -> some View {
        Button {
            input.structure = value
            advance()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AppTypography.cardBody.weight(.medium))
                    Text(subtitle).font(AppTypography.cardMeta).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var youStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This will be the person your tree is centred on.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            personFields(input: $input.you, defaultGender: nil, includeLocation: true)
        }
    }

    private var parentsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    columnTitle(parentLabel(role: .father))
                    personFields(input: $input.father, defaultGender: .male, includeLocation: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    columnTitle(parentLabel(role: .mother))
                    personFields(input: $input.mother, defaultGender: .female, includeLocation: true)
                }
            }
            // DESIGN.md §7.5.1 — divorced/remarried families need a third
            // parent slot. Surfaced as a button so the row is opt-in; when
            // tapped the third row appears and routes through the builder
            // with RelationshipSubtype.step pre-set.
            stepparentRow
            VStack(alignment: .leading, spacing: 6) {
                columnTitle("Marriage (optional)")
                DateParsePreviewField(label: "Marriage date", text: $input.marriageDateText)
                TextField("Marriage location", text: $input.marriageLocation)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private var stepparentRow: some View {
        if let _ = input.stepparent {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    columnTitle("Stepparent")
                    Spacer()
                    Button {
                        input.stepparent = nil
                    } label: {
                        Image(systemName: "minus.circle")
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove stepparent")
                    .accessibilityLabel("Remove stepparent")
                    .accessibilityHint("Remove stepparent")
                }
                personFields(
                    input: stepparentBinding,
                    defaultGender: nil,
                    includeLocation: true
                )
            }
        } else {
            Button {
                input.stepparent = blankPerson()
            } label: {
                Label("Add stepparent", systemImage: "person.badge.plus")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    /// Force-unwrap binding for the stepparent slot — only constructed when
    /// `input.stepparent != nil` (the `if let` branch above gates this).
    private var stepparentBinding: Binding<OnboardingWizardBuilder.PersonInput> {
        Binding(
            get: { input.stepparent ?? blankPerson() },
            set: { input.stepparent = $0 }
        )
    }

    private var paternalGrandparentsStep: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                columnTitle("Paternal grandfather")
                personFields(input: $input.paternalGrandfather, defaultGender: .male, includeLocation: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                columnTitle("Paternal grandmother")
                personFields(input: $input.paternalGrandmother, defaultGender: .female, includeLocation: false)
            }
        }
    }

    private var maternalGrandparentsStep: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                columnTitle("Maternal grandfather")
                personFields(input: $input.maternalGrandfather, defaultGender: .male, includeLocation: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                columnTitle("Maternal grandmother")
                personFields(input: $input.maternalGrandmother, defaultGender: .female, includeLocation: false)
                // Maternal grandmother surname is her maiden name — suggest from
                // existing female profiles' surnames (per DESIGN.md §7.5.8).
                maidenSurnameSuggestions(target: $input.maternalGrandmother.lastName)
            }
        }
    }

    private var familyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("I'd like to add my spouse and/or children", isOn: $input.includeSpouseAndChildren)
            if input.includeSpouseAndChildren {
                columnTitle("Spouse")
                personFields(input: $input.spouse, defaultGender: nil, includeLocation: false)
                DateParsePreviewField(label: "Marriage date", text: $input.spouseMarriageDateText)
                Divider()
                columnTitle("Children")
                ForEach($input.children) { $child in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                TextField("First name", text: $child.firstName)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Last name", text: $child.lastName)
                                    .textFieldStyle(.roundedBorder)
                            }
                            DateParsePreviewField(label: "Birth date", text: $child.birthDateText)
                        }
                        Button {
                            input.children.removeAll { $0.id == child.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove child")
                    }
                }
                Button {
                    input.children.append(blankPerson())
                } label: {
                    Label("Add child", systemImage: "plus.circle")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }

    private var reviewStep: some View {
        let preview = OnboardingWizardBuilder.build(input)
        return VStack(alignment: .leading, spacing: 12) {
            if let preview {
                Text("Ready to create \(preview.profiles.count) people and \(preview.relationships.count) relationships.")
                    .font(AppTypography.cardBody)
                Text("This will all happen in one step — undo will reverse the whole wizard.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
            } else {
                Text("Add at least your own name to continue.")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .structure {
                Button("Back") { back() }
                    .buttonStyle(.glass)
            }
            Spacer()
            if step != .structure && step != .review {
                Button("Skip") { advance() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            if step == .review {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                Button("Build my tree") { commit() }
                    .buttonStyle(.glassProminent)
                    .disabled(OnboardingWizardBuilder.build(input) == nil)
            } else if step != .structure {
                // Step 0 advances on choice tap; other steps need an explicit Next.
                Button("Next") { advance() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Step navigation

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        }
    }

    private func back() {
        if let prev = Step(rawValue: step.rawValue - 1) {
            step = prev
        }
    }

    // MARK: - Commit

    private func commit() {
        guard let result = OnboardingWizardBuilder.build(input) else { return }
        appState.completeOnboarding(
            profiles: result.profiles,
            relationships: result.relationships,
            homePersonID: result.homePersonID,
            source: result.defaultSource
        )
        dismiss()
    }

    // MARK: - Reusable controls

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func parentLabel(role: ParentRole) -> String {
        let isAdopted = input.structure == .adopted
        switch role {
        case .father: return isAdopted ? "Adoptive father" : "Father"
        case .mother: return isAdopted ? "Adoptive mother" : "Mother"
        case .unspecified: return "Parent"
        }
    }

    @ViewBuilder
    private func personFields(
        input: Binding<OnboardingWizardBuilder.PersonInput>,
        defaultGender: Gender?,
        includeLocation: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("First name", text: input.firstName)
                    .textFieldStyle(.roundedBorder)
                TextField("Last name", text: input.lastName)
                    .textFieldStyle(.roundedBorder)
            }
            DateParsePreviewField(label: "Birth date", text: input.birthDateText)
            if includeLocation {
                TextField("Birth location", text: input.birthLocation)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private func maidenSurnameSuggestions(target: Binding<String>) -> some View {
        let suggestions = AutoSuggestService.maidenSurnames(snapshot: appState.snapshot)
        if !suggestions.isEmpty && target.wrappedValue.isEmpty {
            HStack(spacing: 6) {
                Text("Maiden name?")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.tertiary)
                ForEach(suggestions, id: \.self) { name in
                    Button(name) { target.wrappedValue = name }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                }
            }
        }
    }

    private func blankPerson() -> OnboardingWizardBuilder.PersonInput {
        OnboardingWizardBuilder.PersonInput(
            firstName: "", lastName: "", gender: nil,
            birthDateText: "", birthLocation: ""
        )
    }
}
