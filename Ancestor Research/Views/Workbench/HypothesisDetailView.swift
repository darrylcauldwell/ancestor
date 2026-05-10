import SwiftUI

/// Full hypothesis detail with editable confidence and reasoning, an
/// add/remove evidence list, and the action footer (promote, dismiss,
/// supersede, delete). Promote routes to AppState.promoteHypothesis;
/// dismiss prompts for a reason then writes it to the record.
struct HypothesisDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let hypothesis: Hypothesis

    @State private var confidence: HypothesisConfidence = .speculation
    @State private var reasoning: String = ""
    @State private var supporting: [String] = []
    @State private var contradicting: [String] = []
    @State private var newSupporting: String = ""
    @State private var newContradicting: String = ""
    @State private var showingDismiss: Bool = false
    @State private var dismissReason: String = ""
    @State private var actionMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    claimBlock
                    Divider()
                    sectionTitle("Confidence")
                    Picker("Confidence", selection: $confidence) {
                        ForEach(HypothesisConfidence.allCases, id: \.self) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(hypothesis.status != .active)

                    sectionTitle("Reasoning")
                    TextEditor(text: $reasoning)
                        .font(AppTypography.cardBody)
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                        .disabled(hypothesis.status != .active)

                    evidenceList(title: "Supporting", items: $supporting, draft: $newSupporting)
                    evidenceList(title: "Contradicting", items: $contradicting, draft: $newContradicting)

                    Divider()
                    AttachedNotesSection(
                        attachedTo: .hypothesis(id: hypothesis.id),
                        load: { appState.notesForHypothesis(hypothesis.id) }
                    )

                    if let reason = hypothesis.dismissalReason, hypothesis.status == .dismissed {
                        Divider()
                        sectionTitle("Dismissed because")
                        Text(reason)
                            .font(AppTypography.cardBody)
                            .foregroundStyle(.secondary)
                    }
                    if let msg = actionMessage {
                        Divider()
                        Text(msg)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 600)
        .onAppear {
            confidence = hypothesis.confidence
            reasoning = hypothesis.reasoning
            supporting = hypothesis.supportingEvidence
            contradicting = hypothesis.contradictingEvidence
        }
        .alert("Dismiss hypothesis", isPresented: $showingDismiss) {
            TextField("Reason", text: $dismissReason)
            Button("Dismiss", role: .destructive) {
                appState.dismissHypothesis(id: hypothesis.id, reason: dismissReason)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Recording why you ruled this out prevents the same idea from re-surfacing later.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                Text("Hypothesis")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                Text(hypothesis.claimSummary)
                    .font(.title3).fontWeight(.semibold)
            }
            Spacer()
            Text(hypothesis.status.displayName)
                .font(AppTypography.badge)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
        }
        .padding()
    }

    private var claimBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Claim")
            Group {
                switch hypothesis.claim {
                case .relationship(let fromID, let toID, let type, let role):
                    let from = appState.snapshot.profiles[fromID]?.displayName ?? fromID
                    let to = appState.snapshot.profiles[toID]?.displayName ?? toID
                    let roleText = role.map { " (\($0.rawValue))" } ?? ""
                    Text("\(from) — \(type.rawValue)\(roleText) → \(to)")
                case .fieldValue(let pid, let field, let value):
                    let name = appState.snapshot.profiles[pid]?.displayName ?? pid
                    Text("\(name) — \(field.rawValue) = \"\(value)\"")
                case .identityMatch(let a, let b):
                    let nameA = appState.snapshot.profiles[a]?.displayName ?? a
                    let nameB = appState.snapshot.profiles[b]?.displayName ?? b
                    Text("\(nameA) ≡ \(nameB)")
                case .existence(let description, _):
                    Text(description)
                }
            }
            .font(AppTypography.cardBody)
        }
    }

    @ViewBuilder
    private func evidenceList(title: String, items: Binding<[String]>, draft: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(title)
            ForEach(items.wrappedValue, id: \.self) { item in
                HStack(alignment: .top) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(item).font(AppTypography.cardBody)
                    Spacer()
                    if hypothesis.status == .active {
                        Button {
                            items.wrappedValue.removeAll { $0 == item }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove evidence item")
                    }
                }
            }
            if hypothesis.status == .active {
                HStack {
                    TextField("Add \(title.lowercased())", text: draft)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        items.wrappedValue.append(trimmed)
                        draft.wrappedValue = ""
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                appState.deleteHypothesis(id: hypothesis.id)
                dismiss()
            } label: {
                Image(systemName: "trash")
                    .accessibilityHidden(true)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .accessibilityLabel("Delete hypothesis")
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            if hypothesis.status == .active {
                Button("Save") { saveEdits() }
                    .buttonStyle(.glass)
                Button("Dismiss…") {
                    showingDismiss = true
                    dismissReason = ""
                }
                .buttonStyle(.glass)
                Button("Promote to fact") { promote() }
                    .buttonStyle(.glassProminent)
                    .disabled(promoteBlockedReason != nil)
            }
        }
        .padding()
    }

    private var promoteBlockedReason: String? {
        if case .identityMatch = hypothesis.claim {
            return "Identity-match promotion needs the merge flow."
        }
        return nil
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func saveEdits() {
        var updated = hypothesis
        updated.confidence = confidence
        updated.reasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.supportingEvidence = supporting
        updated.contradictingEvidence = contradicting
        appState.updateHypothesis(updated)
        dismiss()
    }

    private func promote() {
        // Persist any pending edits before promoting so the recorded reasoning
        // matches what the user just confirmed.
        saveEditsInPlace()
        let result = appState.promoteHypothesis(id: hypothesis.id)
        switch result {
        case .success: dismiss()
        case .unsupported(let reason): actionMessage = reason
        case .failed(let reason): actionMessage = reason
        }
    }

    /// Like `saveEdits` but doesn't dismiss — used by promote().
    private func saveEditsInPlace() {
        var updated = hypothesis
        updated.confidence = confidence
        updated.reasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.supportingEvidence = supporting
        updated.contradictingEvidence = contradicting
        appState.updateHypothesis(updated)
    }
}
