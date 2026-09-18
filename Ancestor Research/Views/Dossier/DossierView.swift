import SwiftUI

/// Dossier #T9-Change1 — the investigation dossier, rendered.
///
/// Pure display of `DossierAssembler`'s deterministic skeleton: what we
/// know, what conflicts, what's honestly missing, what's being
/// investigated. Every sentence carries its provenance refs (shown as
/// small keys); the D7 footer narrates the process honestly. Challenges
/// (D6) and steering arrive with #T9-Change2/3; smoothing with Change 5.
/// One-line profile-page door to the dossier (spec surface (a)) —
/// self-contained so `SharedProfileLayout` gains a single embed. Uses
/// `.sheet(item:)` with an Identifiable wrapper (the `.sheet(isPresented:)`
/// + `if let` EmptyView-rectangle pitfall is documented in memory).
struct DossierEntryRow: View {
    let profileID: String

    private struct SheetTarget: Identifiable {
        let id: String
    }
    @State private var target: SheetTarget?

    var body: some View {
        Button {
            target = SheetTarget(id: profileID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                Text("Investigation Dossier")
                    .font(AppTypography.cardBody)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(AppTypography.badge)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The pre-commit decision dossier: what we know, what conflicts, what's honestly missing, what's being investigated — every line grounded in a stored row.")
        .sheet(item: $target) { target in
            DossierView(profileID: target.id)
        }
    }
}

struct DossierView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let profileID: String

    @State private var dossier: Dossier?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Investigation Dossier")
                        .font(AppTypography.cardTitle)
                    if let dossier {
                        Text(dossier.subjectName)
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if let dossier {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(dossier.sections, id: \.id) { section in
                            sectionView(section)
                        }
                        footerView(dossier.footer)
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView {
                    Label("No dossier", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Open a project and select a profile to assemble its dossier.")
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { dossier = appState.assembleDossier(for: profileID) }
    }

    @ViewBuilder
    private func sectionView(_ section: DossierSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(AppTypography.cardTitle)
            if section.sentences.isEmpty {
                Text(section.emptyState ?? "Nothing recorded.")
                    .font(AppTypography.cardBody)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                ForEach(Array(section.sentences.enumerated()), id: \.offset) { _, sentence in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sentence.text)
                            .font(AppTypography.cardBody)
                            .textSelection(.enabled)
                        // Provenance refs as small keys — the grounding is
                        // visible, not implied (tappable anchors arrive with
                        // the steering surface, #T9-Change3).
                        Text(sentence.refs.map(\.key).joined(separator: " · "))
                            .font(AppTypography.badge)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func footerView(_ footer: DossierFooter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Provenance")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            Text("Narration: \(footer.narrationMode) · \(footer.termination)")
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
            let counts = footer.rowCounts.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }.joined(separator: "  ")
            Text("Source rows — \(counts)")
                .font(AppTypography.badge)
                .foregroundStyle(.tertiary)
            Text("Skeleton \(footer.skeletonHash)")
                .font(AppTypography.badge)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 4)
    }
}
