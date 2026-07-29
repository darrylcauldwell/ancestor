import SwiftUI

/// Resolve disputed fields where sources disagree.
struct ConflictResolutionView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    let dispute: FieldDispute

    @State private var selectedSourceIndex: Int?
    @State private var manualValue = ""
    /// CL UI pass ⟨G8⟩⟨G2⟩ — the store-level row carrying the weighing
    /// inputs (witness_summary) and the rule-by-rule ladder trace.
    @State private var storeRow: DisputeRow?
    /// Per-competing-value citation (repository/collection/page/url), keyed by
    /// "origin|raw" — so two same-source rows (e.g. two FreeBMD records) are
    /// distinguishable by what record each actually is. Loaded on appear from
    /// `field_sources` (competingSources themselves carry no citation).
    @State private var citationByKey: [String: Citation] = [:]

    private func sourceKey(_ source: FieldSource) -> String {
        "\(source.origin.identifier)|\(source.raw)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Text("Resolve Dispute")
                .font(.title2)
                .fontWeight(.bold)
                .onAppear {
                    storeRow = ((try? appState.currentDatabase?.openDisputes(profileID: profile.id)) ?? [])
                        .first { $0.kind == .fieldValue && $0.field == dispute.field.rawValue }
                    // Re-load the field's sources WITH their citations and key by
                    // origin|raw so each competing row can show its record detail.
                    let sourced = (try? appState.currentDatabase?.fieldSources(
                        profileID: profile.id, field: dispute.field)) ?? []
                    citationByKey = Dictionary(
                        sourced.compactMap { src in
                            src.citation.flatMap { $0.isEmpty ? nil : (sourceKey(src), $0) }
                        },
                        uniquingKeysWith: { first, _ in first })
                }

            Text("\(profile.displayName) — \(dispute.field.rawValue)")
                .foregroundStyle(.secondary)

            Text(dispute.reason.description)
                .font(.caption)
                .foregroundStyle(.orange)

            Divider()

            // ⟨G8⟩ the weighing inputs — the user sees the evidence
            // arithmetic, not just the verdict.
            if let summary = storeRow?.witnessSummary, !summary.isEmpty {
                Text("Evidence weighing: \(summary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if let trace = storeRow?.ladderTrace, trace.contains("fired") || trace.contains("not-fired") {
                DisclosureGroup("Resolution ladder trace") {
                    Text(trace)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }

            // Competing sources
            Text("Sources disagree:")
                .font(.headline)

            ForEach(Array(dispute.competingSources.enumerated()), id: \.offset) { index, source in
                HStack {
                    RadioButton(isSelected: selectedSourceIndex == index) {
                        selectedSourceIndex = index
                        manualValue = ""
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.raw)
                            .font(.body)
                        Text(source.origin.identifier.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                        // The record this value actually came from — collection,
                        // district/vol/page, URL — so two same-source rows are
                        // distinguishable. Shown only when a citation was stored.
                        if let citation = citationByKey[sourceKey(source)] {
                            Text(citation.formatted)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text("Added \(source.addedAt.formatted())")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Manual entry option
            HStack {
                RadioButton(isSelected: selectedSourceIndex == nil && !manualValue.isEmpty) {
                    selectedSourceIndex = nil
                }
                TextField("Or enter value manually...", text: $manualValue)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: manualValue) {
                        if !manualValue.isEmpty { selectedSourceIndex = nil }
                    }
            }

            Spacer()

            // Actions — M16.14. Both Defer and Resolve write through to the
            // database via AppState.resolveDispute, which wraps the change
            // in a transaction for undo replay and rebuilds the snapshot.
            HStack(spacing: 16) {
                Button("Defer") {
                    appState.resolveDispute(
                        profileID: profile.id,
                        field: dispute.field,
                        resolution: .deferred
                    )
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Resolve") {
                    let resolution: DisputeResolution
                    if let index = selectedSourceIndex,
                       index >= 0,
                       index < dispute.competingSources.count {
                        resolution = .accepted(dispute.competingSources[index])
                    } else if !manualValue.trimmingCharacters(in: .whitespaces).isEmpty {
                        resolution = .manual(manualValue)
                    } else {
                        // Disabled state should prevent this, but be defensive.
                        return
                    }
                    appState.resolveDispute(
                        profileID: profile.id,
                        field: dispute.field,
                        resolution: resolution
                    )
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSourceIndex == nil && manualValue.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 350)
    }
}

/// Simple radio button view.
private struct RadioButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
    }
}

nonisolated extension DisputeReason {
    var description: String {
        switch self {
        case .noOverlap: "Date ranges do not overlap"
        case .approximateOverlap: "Both dates are approximate with only partial overlap"
        case .valueMismatch: "Values differ between sources"
        }
    }
}
