import Foundation
import AncestorKit

/// IMPORT_DEDUPE_SPEC — the post-import orphan-stub review surfaced on
/// AppState. Split from AppState.swift to keep that file under budget.
struct ImportCleanseReview: Identifiable, Sendable {
    let id = UUID()
    let candidates: [OrphanStubCandidate]

    var emptyStubIDs: [String] {
        var seen = Set<String>()
        return candidates.filter { $0.stubIsEmpty && seen.insert($0.stubID).inserted }
            .map(\.stubID)
    }
    var nonEmptyCandidates: [OrphanStubCandidate] { candidates.filter { !$0.stubIsEmpty } }
    var emptyCount: Int { emptyStubIDs.count }
}

@MainActor
extension AppState {

    /// Remove every empty orphan stub the last import surfaced (one
    /// transaction each; nothing lost — the stubs carry no data), refresh
    /// the tree, and clear the review.
    func cleanseImportEmptyStubs() {
        guard let db = currentDatabase else { return }
        do {
            let removed = try ProfileMergeEngine.cleanseAllEmptyStubs(snapshot: snapshot, db: db)
            if removed > 0 {
                snapshot = try db.buildSnapshot()
                runPostLoadAudit()
                successMessage = "Removed \(removed) empty duplicate record\(removed == 1 ? "" : "s") left by the import."
            }
        } catch {
            errorMessage = "Could not remove duplicates: \(error.localizedDescription)"
        }
        importCleanseReview = nil
    }

    /// Dismiss the review without changes (the stubs stay; they remain
    /// flagged in the Audit tab by OrphanStubRule).
    func dismissImportCleanse() { importCleanseReview = nil }

    /// On-demand orphan-stub scan for an ALREADY-imported tree (the import
    /// cleanse only runs at import; this re-runs it against the current
    /// snapshot). Surfaces the same review sheet. Returns whether anything
    /// was found, so a caller can toast "nothing to clean up".
    @discardableResult
    func scanForImportDuplicates() -> Bool {
        let candidates = OrphanStubDetector.candidates(in: snapshot)
        guard !candidates.isEmpty else {
            successMessage = "No orphan duplicate records found."
            return false
        }
        importCleanseReview = ImportCleanseReview(candidates: candidates)
        return true
    }
}
