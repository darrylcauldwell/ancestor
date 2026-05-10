import SwiftUI

/// M19 — Side-by-side profile comparison sheet (DESIGN.md §13).
///
/// Used for two distinct flows:
///   1. Identity matching during duplicate review — opened from a
///      `duplicateDetection` audit row.
///   2. Sibling / candidate comparison — opened from the tree's
///      "Compare with…" context menu.
///
/// Renders a row per `ProfileField` plus footer rows for source counts
/// and life-event counts. Differing field rows tint orange so the eye
/// catches the contrast immediately.
struct CompareProfilesView: View {
    let leftProfileID: String
    let rightProfileID: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    /// M24 — Drop the toast fade-in for users who prefer reduced motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showMergeNotice: Bool = false

    private var leftProfile: Profile? {
        appState.snapshot.profiles[leftProfileID]
    }

    private var rightProfile: Profile? {
        appState.snapshot.profiles[rightProfileID]
    }

    private var differingFields: Set<ProfileField> {
        guard let l = leftProfile, let r = rightProfile else { return [] }
        return ProfileDiff.differingFields(left: l, right: r)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let left = leftProfile, let right = rightProfile {
                content(left: left, right: right)
            } else {
                ContentUnavailableView(
                    "Profile not found",
                    systemImage: "person.slash",
                    description: Text("One of the profiles is no longer in the tree.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .overlay(alignment: .top) {
            if showMergeNotice {
                Text("Merging is not yet implemented (deferred to a later milestone).")
                    .font(AppTypography.toast)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            columnHeader(profile: leftProfile, fallback: leftProfileID)
            Divider()
            columnHeader(profile: rightProfile, fallback: rightProfileID)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func columnHeader(profile: Profile?, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile?.displayName.isEmpty == false ? profile!.displayName : fallback)
                .font(AppTypography.popoverTitle)
            if let profile {
                let comp = appState.snapshot.completeness(for: profile.id)
                HStack(spacing: 6) {
                    ProgressView(value: Double(comp.score), total: Double(max(comp.maximum, 1)))
                        .tint(comp.score == comp.maximum ? .green : .orange)
                        .frame(width: 80)
                    Text("\(comp.score)/\(comp.maximum)")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(comp.score == comp.maximum ? .green : .orange)
                }
                if let wikiTreeID = profile.wikiTreeID {
                    Text(wikiTreeID)
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Field grid

    @ViewBuilder
    private func content(left: Profile, right: Profile) -> some View {
        let diffs = differingFields
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(ProfileField.allCases, id: \.self) { field in
                    fieldRow(field: field, left: left, right: right, differs: diffs.contains(field))
                    Divider()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func fieldRow(field: ProfileField, left: Profile, right: Profile, differs: Bool) -> some View {
        let leftValue = ProfileDiff.value(of: field, in: left)
        let rightValue = ProfileDiff.value(of: field, in: right)

        HStack(alignment: .top, spacing: 16) {
            Text(label(for: field))
                .font(AppTypography.popoverLabel)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            valueCell(value: leftValue, differs: differs)
            Divider()
            valueCell(value: rightValue, differs: differs)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func valueCell(value: String?, differs: Bool) -> some View {
        let displayed = (value?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        Group {
            if let displayed {
                if differs {
                    Text(displayed)
                        .font(AppTypography.cardBody)
                        .foregroundStyle(Color.orange)
                } else {
                    Text(displayed)
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.primary)
                }
            } else {
                if differs {
                    Text("—")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(Color.orange)
                        .italic()
                } else {
                    Text("—")
                        .font(AppTypography.cardBody)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if differs {
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 3)
                    .padding(.vertical, -4)
            }
        }
        .padding(.leading, differs ? 8 : 0)
    }

    private func label(for field: ProfileField) -> String {
        switch field {
        case .firstName: return "First name"
        case .lastName: return "Last name"
        case .gender: return "Gender"
        case .birthDate: return "Birth date"
        case .birthLocation: return "Birth location"
        case .deathDate: return "Death date"
        case .deathLocation: return "Death location"
        case .bio: return "Bio"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            countsRow
            actionsRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var countsRow: some View {
        let leftSourceCount = leftProfile?.sources.values.reduce(0) { $0 + $1.count } ?? 0
        let rightSourceCount = rightProfile?.sources.values.reduce(0) { $0 + $1.count } ?? 0
        let leftEventCount = leftProfile.map { appState.lifeEventsForProfile($0.id).count } ?? 0
        let rightEventCount = rightProfile.map { appState.lifeEventsForProfile($0.id).count } ?? 0
        return HStack(spacing: 24) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Sources count: \(leftSourceCount) vs \(rightSourceCount)")
                    .font(AppTypography.cardMeta)
            }
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Life events: \(leftEventCount) vs \(rightEventCount)")
                    .font(AppTypography.cardMeta)
            }
            Spacer()
        }
    }

    private var actionsRow: some View {
        HStack {
            Spacer()
            Button("Mark as duplicate") {
                showMergeNotice = true
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    showMergeNotice = false
                    dismiss()
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .disabled(leftProfile == nil || rightProfile == nil)

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: - Target picker

/// Tiny picker sheet — feeds `CompareProfilesView` with its second profile.
/// Excludes the source profile (no point comparing a person with themselves)
/// and soft-deleted entries.
struct CompareTargetPicker: View {
    let sourceProfile: Profile
    let snapshot: FamilyGraphSnapshot
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""

    private var matches: [Profile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = snapshot.profiles.values
            .filter { $0.id != sourceProfile.id && !$0.isDeleted }
            .sorted { $0.displayName < $1.displayName }
        guard !trimmed.isEmpty else { return Array(candidates.prefix(50)) }
        return candidates
            .filter { $0.displayName.lowercased().contains(trimmed) }
            .prefix(50)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Compare \(sourceProfile.displayName) with…")
                    .font(AppTypography.popoverTitle)
                Text("Pick another profile to view side by side.")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query, prompt: Text("Search by name…"))
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { profile in
                        Button {
                            onSelect(profile.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(profile.displayName)
                                    .font(AppTypography.cardBody)
                                if let year = profile.birthDate?.bestYear {
                                    Text("b. \(year)")
                                        .font(AppTypography.cardMeta)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                    if matches.isEmpty {
                        Text("No matches.")
                            .font(AppTypography.cardMeta)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}
