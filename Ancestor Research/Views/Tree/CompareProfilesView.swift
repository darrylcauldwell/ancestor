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
    /// True when opened from a `duplicateDetection` audit row. Adds the
    /// "Not a duplicate" action so the user can dismiss a false-positive pair
    /// permanently. False for the tree's "Compare with…" flow, where the pair
    /// was never flagged as a duplicate in the first place.
    var fromDuplicateReview: Bool = false

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    /// M24 — Drop the toast fade-in for users who prefer reduced motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Merge state. `keepLeft` — which profile survives (the other folds in and
    /// is removed). Defaults to the more-complete one; user can flip.
    @State private var keepLeft: Bool = true
    @State private var mergeDefaulted = false
    @State private var showMergeConfirm = false
    @State private var mergeError: String?

    private var mergeAssessment: MergeSafety.Assessment {
        guard let l = leftProfile, let r = rightProfile else { return .ok }
        return MergeSafety.assess(left: l, right: r, relationships: appState.snapshot.relationships)
    }

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
        // The vertical Divider between the columns is greedy on the vertical
        // axis; without this it competes with the scrolling field grid for
        // leftover height and inflates the header into a tall empty band.
        // Pin the header to its content so all spare space goes to the grid.
        .fixedSize(horizontal: false, vertical: true)
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
                // `.nameForms` is a repeatable non-scalar field with no
                // single-value cell — exclude it from the scalar compare grid.
                ForEach(ProfileField.allCases.filter { $0 != .nameForms }, id: \.self) { field in
                    fieldRow(field: field, left: left, right: right, differs: diffs.contains(field))
                    Divider()
                }
                // Relationships — parents/spouse/children are the decisive
                // signal for "same person vs coincidental namesake": two
                // same-named people with different families are NOT duplicates.
                HStack {
                    Text("Relationships")
                        .font(AppTypography.cardMeta)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 8)
                relationshipRow(label: "Parents", left: parentNames(left), right: parentNames(right))
                Divider()
                relationshipRow(label: "Spouse", left: spouseNames(left), right: spouseNames(right))
                Divider()
                relationshipRow(label: "Children", left: childNames(left), right: childNames(right))
                Divider()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func parentNames(_ p: Profile) -> [String] {
        appState.snapshot.parentsOf(p.id).map(\.displayName).filter { !$0.isEmpty }.sorted()
    }
    private func spouseNames(_ p: Profile) -> [String] {
        appState.snapshot.spousesOf(p.id).map(\.displayName).filter { !$0.isEmpty }.sorted()
    }
    private func childNames(_ p: Profile) -> [String] {
        appState.snapshot.childrenOf(p.id).map(\.displayName).filter { !$0.isEmpty }.sorted()
    }

    /// A relationship row (parents / spouse / children) — differing families
    /// tint orange, the same "look here" cue the scalar diff rows use.
    @ViewBuilder
    private func relationshipRow(label: String, left: [String], right: [String]) -> some View {
        let differs = Set(left.map { $0.lowercased() }) != Set(right.map { $0.lowercased() })
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(AppTypography.popoverLabel)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            valueCell(value: left.isEmpty ? nil : left.joined(separator: ", "), differs: differs)
            Divider()
            valueCell(value: right.isEmpty ? nil : right.joined(separator: ", "), differs: differs)
        }
        .padding(.vertical, 8)
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
        case .middleName: return "Middle name"
        case .lastName: return "Last name"
        case .marriedSurname: return "Married surname"
        case .nickName: return "Nickname"
        case .mothersMaidenName: return "Mother's maiden name"
        case .gender: return "Gender"
        case .birthDate: return "Birth date"
        case .birthLocation: return "Birth location"
        case .deathDate: return "Death date"
        case .deathLocation: return "Death location"
        case .bio: return "Bio"
        case .nameForms: return "Name variants"
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

    @ViewBuilder
    private var actionsRow: some View {
        let assessment = mergeAssessment
        VStack(alignment: .leading, spacing: 8) {
            // Safety banner — the father/son guard. Blocked = no merge at all.
            switch assessment {
            case .blocked(let reason):
                Label(reason, systemImage: "hand.raised.fill")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.red)
            case .warn(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(AppTypography.cardMeta)
                    .foregroundStyle(.orange)
            case .ok:
                EmptyView()
            }
            if let mergeError {
                Text(mergeError).font(AppTypography.cardMeta).foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                if canMerge {
                    // Which profile survives — the other folds into it and is
                    // removed (undoable). Default is the more-complete one.
                    // The caption is essential: the segmented control alone gives
                    // no cue that the highlighted one is the record that's KEPT.
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Keep this one — the other merges into it", systemImage: "checkmark.circle")
                            .font(AppTypography.badge)
                            .foregroundStyle(.secondary)
                        Picker("Keep", selection: $keepLeft) {
                            Text(shortName(leftProfile, leftProfileID)).tag(true)
                            Text(shortName(rightProfile, rightProfileID)).tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                    }
                }
                Spacer()
                if fromDuplicateReview {
                    // The honest counterpart to Merge: record that these two are
                    // different people so the pair is never re-flagged. Persists
                    // per-pair (v51), unlike snoozing the whole rule.
                    Button {
                        appState.dismissDuplicatePair(leftProfileID, rightProfileID)
                        dismiss()
                    } label: {
                        Label("Not a duplicate", systemImage: "person.2.slash")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Mark these two as different people — they won't be flagged as a possible duplicate again")
                }
                if canMerge {
                    Button("Merge…") { showMergeConfirm = true }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { defaultWinnerToMoreComplete() }
        .confirmationDialog(
            "Merge \(shortName(loserProfile, "")) into \(shortName(winnerProfile, ""))?",
            isPresented: $showMergeConfirm, titleVisibility: .visible
        ) {
            Button("Merge", role: .destructive) { performMerge() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    /// Merge is offered unless the pair is structurally impossible (blocked).
    private var canMerge: Bool {
        guard leftProfile != nil, rightProfile != nil else { return false }
        if case .blocked = mergeAssessment { return false }
        return true
    }

    private var winnerProfile: Profile? { keepLeft ? leftProfile : rightProfile }
    private var loserProfile: Profile? { keepLeft ? rightProfile : leftProfile }

    private var confirmMessage: String {
        var msg = "\(shortName(loserProfile, "the other profile"))'s records and relationships move onto \(shortName(winnerProfile, "the kept profile")), and it is removed. This can be undone."
        if case .warn(let reason) = mergeAssessment {
            msg = "⚠︎ \(reason)\n\n" + msg
        }
        return msg
    }

    private func shortName(_ p: Profile?, _ fallback: String) -> String {
        guard let p, !p.displayName.isEmpty else { return fallback }
        let name = p.displayName
        // When both sides share a display name (a duplicate merge), the Keep
        // picker and the merge dialog would otherwise read "X → X" with no way
        // to tell them apart. Append the first attribute that differs so the
        // user knows which profile survives and which is removed.
        guard let l = leftProfile, let r = rightProfile, l.id != r.id,
              l.displayName.caseInsensitiveCompare(r.displayName) == .orderedSame,
              let extra = distinguisher(p, vs: p.id == l.id ? r : l)
        else { return name }
        return "\(name) · \(extra)"
    }

    /// The first attribute that distinguishes `p` from `other`, for labelling
    /// two same-named profiles in the merge UI.
    private func distinguisher(_ p: Profile, vs other: Profile) -> String? {
        if let y = p.birthDate?.bestYear, y != other.birthDate?.bestYear { return "b. \(y)" }
        if let y = p.deathDate?.bestYear, y != other.deathDate?.bestYear { return "d. \(y)" }
        let pc = childNames(p).count, oc = childNames(other).count
        if pc != oc { return pc == 0 ? "no children" : "\(pc) child\(pc == 1 ? "" : "ren")" }
        if Set(spouseNames(p)) != Set(spouseNames(other)) {
            return spouseNames(p).first.map { "m. \($0)" } ?? "no spouse"
        }
        let psrc = p.sources.values.reduce(0) { $0 + $1.count }
        let osrc = other.sources.values.reduce(0) { $0 + $1.count }
        if psrc != osrc { return "\(psrc) source\(psrc == 1 ? "" : "s")" }
        return "id …\(p.id.suffix(4))"
    }

    /// Default the survivor to whichever profile is more complete (a stub
    /// should fold into the rich original, not the reverse).
    private func defaultWinnerToMoreComplete() {
        guard !mergeDefaulted, let l = leftProfile, let r = rightProfile else { return }
        mergeDefaulted = true
        let lc = appState.snapshot.completeness(for: l.id).score
        let rc = appState.snapshot.completeness(for: r.id).score
        keepLeft = lc >= rc
    }

    private func performMerge() {
        guard let db = appState.currentDatabase,
              let winner = winnerProfile, let loser = loserProfile else { return }
        do {
            // Preserve the loser's life events + attachments (hardDeleteProfile
            // would otherwise cascade-destroy them) BEFORE the structural merge.
            try db.reassignLifeEventsAndAttachments(fromProfileID: loser.id, toProfileID: winner.id)
            try ProfileMergeEngine.merge(
                loserID: loser.id, winnerID: winner.id,
                snapshot: appState.snapshot, db: db
            )
            appState.snapshot = try db.buildSnapshot()
            // Re-audit + re-sweep on the post-merge tree: the removed profile is
            // gone, so its stale duplicate/conflict findings must clear (else
            // Health shows a "duplicate" with nothing left to compare).
            appState.runConflictSweep(force: true)
            appState.runPostLoadAudit()
            dismiss()
        } catch {
            mergeError = "Merge failed: \(error.localizedDescription)"
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
                                    Text("b. \(String(year))")
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
