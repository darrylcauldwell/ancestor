import SwiftUI
import AncestorKit

/// IMPORT_DEDUPE_SPEC — post-import review of orphan-stub duplicates left
/// by the GEDCOM export (e.g. Ancestry merges). Empty stubs offer a
/// one-click removal (they carry no data); non-empty ones are listed for
/// manual review via the tree's Compare flow.
struct ImportCleanseSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let review: ImportCleanseReview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Duplicate records found")
                .font(.title2).fontWeight(.bold)

            Text("This GEDCOM export left \(review.candidates.count) record\(review.candidates.count == 1 ? "" : "s") that look like duplicates of people already in your tree — a common artifact of Ancestry.com's tree-merge tool, which strips a duplicate's family links but leaves the record behind.")
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

            HStack {
                Spacer()
                Button("Keep everything") { appState.dismissImportCleanse(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460, maxWidth: 560)
    }
}
