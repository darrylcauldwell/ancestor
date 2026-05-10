import SwiftUI

/// Sheet to create or edit a focus set. Title is optional; profile picker
/// uses the existing `ProfilePickerField` (single-select) and adds picks
/// to a chip strip. Removing a chip clears that profile from the set.
struct FocusComposerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// nil → creating. Non-nil → editing.
    let initial: FocusSet?

    @State private var title: String = ""
    @State private var profileIDs: [String] = []
    @State private var pickerSelection: String?

    /// M17.4 — IDs of profiles touched by transactions in the last 30 minutes,
    /// surfaced as a Quick-add row. Loaded once on appear; not auto-added.
    @State private var recentSuggestions: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(initial == nil ? "New focus set" : "Edit focus set")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Title (optional)")
                    TextField("e.g. Maternal grandmother's siblings", text: $title)
                        .textFieldStyle(.roundedBorder)

                    sectionTitle("Profiles in this focus")
                    if profileIDs.isEmpty {
                        Text("Add profiles below — typically 3 to 10.")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.tertiary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(profileIDs, id: \.self) { id in
                                chip(for: id)
                            }
                        }
                    }

                    quickAddSection

                    sectionTitle("Add a profile")
                    ProfilePickerField(
                        label: "Search profiles",
                        snapshot: appState.snapshot,
                        selectedID: $pickerSelection
                    )
                    .onChange(of: pickerSelection) { _, newID in
                        if let id = newID, !profileIDs.contains(id) {
                            profileIDs.append(id)
                        }
                        pickerSelection = nil
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(initial == nil ? "Create" : "Save") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 540, minHeight: 540)
        .onAppear {
            if let existing = initial {
                title = existing.title ?? ""
                profileIDs = existing.profileIDs
            }
            loadRecentSuggestions()
        }
    }

    /// Quick-add row: profiles touched in the last 30 minutes that aren't
    /// already in the working set. Hidden when there are no candidates.
    @ViewBuilder
    private var quickAddSection: some View {
        let candidates = recentSuggestions.filter { !profileIDs.contains($0) }
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Quick add — recent activity")
                FlowLayout(spacing: 6) {
                    ForEach(candidates, id: \.self) { id in
                        recentChip(for: id)
                    }
                }
            }
        }
    }

    private func recentChip(for id: String) -> some View {
        Button {
            if !profileIDs.contains(id) {
                profileIDs.append(id)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle")
                    .accessibilityHidden(true)
                Text(appState.snapshot.profiles[id]?.displayName ?? id)
                    .font(AppTypography.cardMeta)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .accessibilityLabel("Add \(appState.snapshot.profiles[id]?.displayName ?? id) to focus set")
    }

    private func loadRecentSuggestions() {
        guard let db = appState.currentDatabase else { return }
        // Pull a generous slice — the engine windows by completion time so
        // anything older than 30 minutes is filtered out anyway.
        guard let transactions = try? db.loadTransactions(limit: 200) else { return }
        let suggestions = FocusSuggestionEngine.suggestRecentlyActive(transactions: transactions)
        // Restrict to profiles that exist (and aren't soft-deleted) in the
        // current snapshot. The snapshot already excludes soft-deleted ones.
        recentSuggestions = suggestions.filter { appState.snapshot.profiles[$0] != nil }
    }

    private func chip(for id: String) -> some View {
        HStack(spacing: 4) {
            Text(appState.snapshot.profiles[id]?.displayName ?? id)
                .font(AppTypography.cardMeta)
            Button {
                profileIDs.removeAll { $0 == id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(appState.snapshot.profiles[id]?.displayName ?? id) from focus set")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(AppTypography.cardMeta.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        if let existing = initial {
            var updated = existing
            updated.title = trimmedTitle.isEmpty ? nil : trimmedTitle
            updated.profileIDs = profileIDs
            updated.lastActiveAt = Date()
            appState.updateFocusSet(updated)
        } else {
            appState.createFocusSet(
                title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                profileIDs: profileIDs
            )
        }
        dismiss()
    }
}

/// Minimal flow layout — wraps chips onto multiple lines without overflowing.
/// SwiftUI doesn't ship one, so a tiny custom Layout fills the gap.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
