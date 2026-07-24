import SwiftUI
import AncestorKit

/// IMPORT_DEDUPE_SPEC — post-import review of duplicate records left by a
/// GEDCOM export (e.g. Ancestry merges). Two shapes:
/// - Orphan stubs (zero edges): empty ones offer a one-click removal.
/// - Phantom spouses (one spouse-edge, dateless): a plain-language guided
///   card that combines each into the correct real spouse (Change 5).
struct ImportCleanseSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let review: ImportCleanseReview

    private var totalCount: Int {
        review.candidates.count + review.phantomSpouseCandidates.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable content — the phantom-spouse list can run to dozens of
            // cards on a freshly-imported tree, so it must scroll rather than
            // grow the sheet off the bottom of the screen.
            ScrollView {
                content
                    .padding(24)
            }

            Divider()

            // Pinned footer — the dismiss control is always reachable no matter
            // how long the list is. Also bound to Escape via `.cancelAction`.
            HStack {
                Spacer()
                Button("Keep everything") { appState.dismissImportCleanse(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(
            minWidth: 460, idealWidth: 520, maxWidth: 560,
            minHeight: 320, idealHeight: 560, maxHeight: 680
        )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Duplicate records found")
                .font(.title2).fontWeight(.bold)

            Text("Your tree has \(totalCount) record\(totalCount == 1 ? "" : "s") that look like duplicates of people already in it — a common artifact of a tree-merge tool (e.g. Ancestry.com), which strips a duplicate's family links but leaves the record behind.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if review.emptyCount > 0 {
                GroupBox {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(review.emptyCount) empty duplicate\(review.emptyCount == 1 ? "" : "s")")
                                .font(.headline)
                            Text("These carry no dates, places, or family — only a name that matches a linked profile. Removing them loses nothing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Remove \(review.emptyCount)") {
                            appState.cleanseImportEmptyStubs()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            // Change 5 — phantom-spouse guided cards. One per phantom; each
            // resolves to the correct real spouse (or a picker when the anchor
            // has more than one documented wife).
            if !review.phantomSpouseCandidates.isEmpty {
                ForEach(review.phantomSpouseCandidates, id: \.phantomID) { candidate in
                    PhantomSpouseCard(candidate: candidate)
                }
            }

            if !review.nonEmptyCandidates.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(review.nonEmptyCandidates.count) with data to review")
                            .font(.headline)
                        Text("These carry some information, so review each in the tree before merging. They stay flagged under Audit → Orphan Duplicate Records.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(review.nonEmptyCandidates, id: \.stubID) { c in
                            Text("• \(c.matchBasis)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

        }
    }
}

/// A single phantom-spouse decision, framed for a non-expert (no "merge",
/// "loser", "edge", or "stub" jargon — decision Change 5 AC3).
private struct PhantomSpouseCard: View {
    @Environment(AppState.self) private var appState
    let candidate: PhantomSpouseCandidate

    private func name(_ id: String?) -> String {
        guard let id, let p = appState.snapshot.profiles[id] else { return "this person" }
        return p.displayName
    }
    private var phantomName: String { name(candidate.phantomID) }
    private var anchorName: String { name(candidate.anchorID) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(anchorName) has an extra spouse that looks like a duplicate")
                    .font(.headline)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    combineControl
                    Button("These were separate people") {
                        appState.markPhantomSpouseSeparate(phantomID: candidate.phantomID)
                    }
                    Spacer()
                }
            }
        }
    }

    private var explanation: String {
        let lead = "\(phantomName) has no dates and no records, and only exists as a marriage link to \(anchorName)."
        if let target = candidate.suggestedTargetID {
            return "\(lead) They're likely the same person as \(name(target))."
        } else if !candidate.documentedSpouseIDs.isEmpty {
            return "\(lead) Which of \(anchorName)'s known spouses is this?"
        }
        return lead
    }

    @ViewBuilder private var combineControl: some View {
        if let target = candidate.suggestedTargetID {
            Button("Combine into \(name(target))") {
                appState.combinePhantomSpouse(phantomID: candidate.phantomID, winnerID: target)
            }
            .buttonStyle(.borderedProminent)
        } else if !candidate.documentedSpouseIDs.isEmpty {
            Menu("Combine into…") {
                ForEach(candidate.documentedSpouseIDs, id: \.self) { spouseID in
                    Button(name(spouseID)) {
                        appState.combinePhantomSpouse(
                            phantomID: candidate.phantomID, winnerID: spouseID)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        // No documented spouse → only "separate people" applies; the anchor has
        // nothing to combine into, so the card offers just that + the overall
        // "Keep everything" dismiss.
    }
}
