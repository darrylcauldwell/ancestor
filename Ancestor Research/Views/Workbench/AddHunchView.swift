import SwiftUI

/// "Add a hunch" form (RESEARCH_PIPELINE_SPEC §5.15.7 phase b). The user
/// asserts what they *think* the subject's parents were called; the
/// engine turns the hunch into targeted probes through the standard
/// verdict lifecycle. Doctrine: a hunch is a search directive, never data
/// — this form writes only a queued `user_hypothesis_seeds` row via the
/// shared `HypothesisSeedService.submitSeed` seam, nothing on the tree.
///
/// Create-only, presented as a sheet (mirrors `HypothesisComposerView`).
/// Validation is NOT re-implemented here — the service refuses with a
/// structured reason and this view renders it.
struct AddHunchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// The subject whose parents are being hinted (the child). Pre-set
    /// from the Workbench selection when available; the picker lets the
    /// user pick another.
    @State private var subjectID: String?

    @State private var fatherGiven: String = ""
    @State private var fatherSurname: String = ""
    @State private var motherGiven: String = ""
    @State private var motherMaidenSurname: String = ""

    @State private var narrowWindow: Bool = false
    @State private var windowStartText: String = ""
    @State private var windowEndText: String = ""

    @State private var refusalMessage: String?

    /// The VM owning the shared submit seam. Created here and pointed at
    /// the current project database.
    @State private var model = UserHypothesisViewModel()

    init(subjectID: String? = nil) {
        _subjectID = State(initialValue: subjectID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    doctrineNote
                    sectionTitle("Whose parents?")
                    ProfilePickerField(
                        label: "Subject",
                        snapshot: appState.snapshot,
                        selectedID: $subjectID
                    )

                    Divider()
                    sectionTitle("Father (any part you know)")
                    hintField("Given name, e.g. Bob", text: $fatherGiven)
                    hintField("Surname", text: $fatherSurname)

                    sectionTitle("Mother (any part you know)")
                    hintField("Given name, e.g. Sue", text: $motherGiven)
                    hintField("Maiden surname", text: $motherMaidenSurname)

                    Divider()
                    Toggle(isOn: $narrowWindow) {
                        Text("Narrow the marriage-year window")
                            .font(AppTypography.cardBody)
                    }
                    if narrowWindow {
                        HStack(spacing: 8) {
                            yearField("From", text: $windowStartText)
                            yearField("To", text: $windowEndText)
                        }
                        Text("Left blank, the window is derived from the subject's birth year (birth − 30 to birth + 1).")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.tertiary)
                    }

                    if let refusalMessage {
                        Text(refusalMessage)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            model.database = appState.currentDatabase
            model.snapshot = appState.snapshot
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Add a hunch")
                .font(.title3).fontWeight(.semibold)
            Spacer()
        }
        .padding()
    }

    private var doctrineNote: some View {
        Text("A hunch tells the engine where to look — it never adds anyone to your tree. It's tested against real records and can be supported, refuted, or come back inconclusive.")
            .font(AppTypography.cardMeta)
            .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button("Seed hunch") { submit() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
        .padding()
    }

    // MARK: - Field builders

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func hintField(_ prompt: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .font(AppTypography.cardBody)
    }

    private func yearField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text("year"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
        }
    }

    // MARK: - Validation + submit

    /// Local pre-check for the button's enablement only — the authoritative
    /// validation is `HypothesisSeedService.submitSeed` (§5.15.2). At least
    /// one name hint and a chosen subject.
    private var canSubmit: Bool {
        guard subjectID != nil else { return false }
        return [fatherGiven, fatherSurname, motherGiven, motherMaidenSurname]
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func submit() {
        guard let subjectID else { return }
        refusalMessage = nil
        let hints = HypothesisSeedService.SeedHints(
            fatherGiven: emptyToNil(fatherGiven),
            fatherSurname: emptyToNil(fatherSurname),
            motherGiven: emptyToNil(motherGiven),
            motherMaidenSurname: emptyToNil(motherMaidenSurname),
            marriageWindowStart: narrowWindow ? Int(windowStartText.trimmingCharacters(in: .whitespaces)) : nil,
            marriageWindowEnd: narrowWindow ? Int(windowEndText.trimmingCharacters(in: .whitespaces)) : nil
        )
        let result = model.submit(profileID: subjectID, hints: hints)
        switch result {
        case .queued:
            appState.successMessage = "Hunch seeded. It'll be tested on the next research run."
            dismiss()
        case .refused(let reason):
            refusalMessage = Self.refusalCopy(reason)
        case nil:
            refusalMessage = model.errorMessage ?? "Could not save the hunch."
        }
    }

    private func emptyToNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Human copy for each structured refusal reason (§5.15.2).
    static func refusalCopy(_ reason: HypothesisSeedService.RefusalReason) -> String {
        switch reason {
        case .noNameHints:
            return "Give at least one name — a father or mother, given name or surname."
        case .profileNotFound:
            return "That person is no longer in the tree."
        case .noSubjectBirthEstimate:
            return "This person has no birth-year estimate, so the marriage window can't be worked out. Add birth years above, or set the window manually."
        case .previouslyRejected:
            return "You already dismissed this exact hunch. Un-dismiss it from the hunch list instead of re-seeding."
        case .invalidWindow:
            return "The 'from' year must not be after the 'to' year."
        case .unsupportedKind, .invalidPayload:
            return "Something went wrong preparing this hunch. Please try again."
        }
    }
}
