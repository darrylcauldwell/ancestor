import SwiftUI
import AncestorKit

/// Slice E review surface (LOCATION_MODEL_SPEC Part II) — the "un-muddle" as a
/// dry-run the user approves. It scans every profile's freeform, code-less
/// birth/death place, shows what the deterministic resolver can confidently
/// structure, and applies ONLY the proposals the user keeps ticked. Ambiguous /
/// unknown places are listed read-only (left as freeform — the future
/// local-model tier's input), never silently resolved. Display strings are
/// preserved; only the structured code column is filled.
struct LocationNormalizeReviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var report: LocationNormalizer.Report?
    @State private var selected: Set<String> = []
    @State private var appliedCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                if let report {
                    if report.proposals.isEmpty {
                        emptyState
                    } else {
                        content(report)
                    }
                } else {
                    ProgressView("Scanning locations…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 580, minHeight: 500)
        .onAppear(perform: buildReport)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Normalise locations")
                .font(AppTypography.cardTitle)
            Text("Match existing freeform birth and death places to the place gazetteer. Nothing is written until you apply — display text is kept exactly as it is; only the structured code is added.")
                .font(AppTypography.cardMeta)
                .foregroundStyle(.secondary)
            if let report {
                HStack(spacing: 12) {
                    summaryChip("\(report.deterministicCount) can be matched", tint: .green)
                    summaryChip("\(report.leftFreeformCount) need review", tint: .orange)
                    if let appliedCount {
                        summaryChip("\(appliedCount) applied", tint: .blue)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func summaryChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(AppTypography.badge)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: - Content

    private func content(_ report: LocationNormalizer.Report) -> some View {
        List {
            if !report.deterministic.isEmpty {
                Section("Confident matches — tick to apply") {
                    ForEach(report.deterministic) { p in
                        Button {
                            toggle(p.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(p.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selected.contains(p.id) ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.profileName).fontWeight(.medium)
                                    HStack(spacing: 4) {
                                        Text(fieldLabel(p.field)).foregroundStyle(.secondary)
                                        Text("“\(p.currentText)”")
                                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                        Text(p.proposedDisplay ?? "").foregroundStyle(.green)
                                    }
                                    .font(AppTypography.badge)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !report.leftFreeform.isEmpty {
                Section("Need review — kept as freeform text") {
                    ForEach(report.leftFreeform) { p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.profileName).fontWeight(.medium)
                            HStack(spacing: 4) {
                                Text(fieldLabel(p.field)).foregroundStyle(.secondary)
                                Text("“\(p.currentText)”")
                                Text("— no confident gazetteer match").foregroundStyle(.tertiary)
                            }
                            .font(AppTypography.badge)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Every location is already structured or empty.")
                .font(AppTypography.cardBody)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Select all") { selectAllConfident() }
                .buttonStyle(.glass)
                .disabled((report?.deterministicCount ?? 0) == 0)
            Button("Select none") { selected.removeAll() }
                .buttonStyle(.glass)
                .disabled(selected.isEmpty)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button("Apply \(selected.count) match\(selected.count == 1 ? "" : "es")") { applySelected() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
        }
        .padding()
    }

    // MARK: - Actions

    private func buildReport() {
        let profiles = Array(appState.snapshot.profiles.values)
        let r = LocationNormalizer.report(for: profiles)
        report = r
        // Default-tick every confident match (the common "apply them all" path);
        // preserve any prior selection that's still present after a rebuild.
        let confidentIDs = Set(r.deterministic.map(\.id))
        selected = selected.isEmpty ? confidentIDs : selected.intersection(confidentIDs)
        if selected.isEmpty { selected = confidentIDs }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func selectAllConfident() {
        selected = Set(report?.deterministic.map(\.id) ?? [])
    }

    private func applySelected() {
        guard let db = appState.currentDatabase, let report else { return }
        var count = 0
        for p in report.deterministic where selected.contains(p.id) {
            do { try LocationNormalizer.apply(p, in: db); count += 1 } catch { /* skip non-confident */ }
        }
        if count > 0, let snap = try? db.buildSnapshot() {
            appState.snapshot = snap
        }
        appliedCount = (appliedCount ?? 0) + count
        selected.removeAll()
        buildReport()   // applied fields now carry a code and drop off the list
    }

    private func fieldLabel(_ field: ProfileField) -> String {
        field == .birthLocation ? "Birth:" : "Death:"
    }
}
