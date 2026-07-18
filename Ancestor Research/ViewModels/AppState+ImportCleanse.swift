import Foundation
import AncestorKit

/// IMPORT_DEDUPE_SPEC — the post-import duplicate review surfaced on AppState.
/// Split from AppState.swift to keep that file under budget. Carries two kinds
/// of candidate: zero-edge orphan stubs (Changes 1–3) and single-spouse-edge
/// phantom spouses (Changes 4–6).
struct ImportCleanseReview: Identifiable, Sendable {
    let id = UUID()
    let candidates: [OrphanStubCandidate]
    let phantomSpouseCandidates: [PhantomSpouseCandidate]

    init(candidates: [OrphanStubCandidate],
         phantomSpouseCandidates: [PhantomSpouseCandidate] = []) {
        self.candidates = candidates
        self.phantomSpouseCandidates = phantomSpouseCandidates
    }

    var emptyStubIDs: [String] {
        var seen = Set<String>()
        return candidates.filter { $0.stubIsEmpty && seen.insert($0.stubID).inserted }
            .map(\.stubID)
    }
    var nonEmptyCandidates: [OrphanStubCandidate] { candidates.filter { !$0.stubIsEmpty } }
    var emptyCount: Int { emptyStubIDs.count }
    /// Nothing left to review — both lists empty.
    var isEmpty: Bool { candidates.isEmpty && phantomSpouseCandidates.isEmpty }
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
    /// flagged in the Audit tab by OrphanStubRule / PhantomSpouseRule).
    func dismissImportCleanse() { importCleanseReview = nil }

    /// On-demand duplicate scan for an ALREADY-imported tree (the import
    /// cleanse only runs at import; this re-runs it against the current
    /// snapshot). Surfaces the same review sheet with BOTH orphan stubs and
    /// phantom spouses. Returns whether anything was found.
    @discardableResult
    func scanForImportDuplicates() -> Bool {
        let orphans = OrphanStubDetector.candidates(in: snapshot)
        let phantoms = phantomSpouseCandidatesToReview()
        guard !orphans.isEmpty || !phantoms.isEmpty else {
            successMessage = "No duplicate records found."
            return false
        }
        importCleanseReview = ImportCleanseReview(
            candidates: orphans, phantomSpouseCandidates: phantoms)
        return true
    }

    // MARK: - Phantom-spouse card actions (Change 5)

    /// "Combine into…" — merge the phantom into the chosen real spouse, then
    /// rebuild the review from the fresh snapshot. The phantom's sole
    /// spouse-edge re-points onto the winner and dedups against the anchor's
    /// existing edge (ProfileMergeEngine); its life events, attachments, and
    /// cited records are preserved on the winner first.
    func combinePhantomSpouse(phantomID: String, winnerID: String) {
        do {
            try performProfileMerge(loserID: phantomID, winnerID: winnerID)
            runPostLoadAudit()
            successMessage = "Combined the duplicate spouse into the correct profile."
            refreshImportCleanseAfterChange()
        } catch {
            errorMessage = "Could not combine: \(error.localizedDescription)"
        }
    }

    /// "These were separate people" — mark the phantom reviewed so it stops
    /// surfacing, WITHOUT deleting it (occasionally a man really did have
    /// several sparsely-documented wives).
    func markPhantomSpouseSeparate(phantomID: String) {
        do {
            try currentDatabase?.markPhantomSpouseReviewed(profileID: phantomID)
            refreshImportCleanseAfterChange()
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Shared profile-merge used by BOTH the phantom card and
    /// `CompareProfilesView`: preserve the loser's life events + attachments,
    /// redirect its edges onto the winner, hard-delete it, refresh the
    /// snapshot. The single choke point where evidence preservation lives.
    func performProfileMerge(loserID: String, winnerID: String) throws {
        guard let db = currentDatabase else { return }
        // Preserve the loser's life events + attachments before the structural
        // merge cascade-deletes them (IMPORT_DEDUPE Change 3 / commit 3a1c2b1).
        try db.reassignLifeEventsAndAttachments(fromProfileID: loserID, toProfileID: winnerID)
        // Option A (2026-07-18): also salvage the loser's cited records so the
        // hard-delete can't destroy real evidence (bare GEDCOM name provenance
        // is left behind — it only describes the loser's unwanted fields).
        try db.salvageCitedFieldSources(fromProfileID: loserID, toProfileID: winnerID)
        try ProfileMergeEngine.merge(
            loserID: loserID, winnerID: winnerID, snapshot: snapshot, db: db)
        snapshot = try db.buildSnapshot()
    }

    /// Phantom-spouse candidates minus any the user has marked "separate
    /// people" (the reviewed marker, Change 5). Shared by the on-demand scan,
    /// the post-import trigger, and the after-action refresh — "one detector,
    /// every trigger" (Change 6 invariant).
    func phantomSpouseCandidatesToReview() -> [PhantomSpouseCandidate] {
        let all = PhantomSpouseDetector.candidates(in: snapshot)
        guard let db = currentDatabase,
              let reviewed = try? db.reviewedPhantomSpouseIDs() else { return all }
        return all.filter { !reviewed.contains($0.phantomID) }
    }

    /// Rebuild the current review from the live snapshot after a card action;
    /// clears it when nothing remains.
    private func refreshImportCleanseAfterChange() {
        let orphans = OrphanStubDetector.candidates(in: snapshot)
        let phantoms = phantomSpouseCandidatesToReview()
        if orphans.isEmpty && phantoms.isEmpty {
            importCleanseReview = nil
        } else {
            importCleanseReview = ImportCleanseReview(
                candidates: orphans, phantomSpouseCandidates: phantoms)
        }
    }
}
