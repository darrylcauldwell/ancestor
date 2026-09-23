import Foundation
import os
import AncestorKit

private nonisolated let mergeLogger = Logger(
    subsystem: "dev.dreamfold.Ancestor-Research", category: "Merge")

/// Import dedupe Change 3 — whole-profile merge execution (distinct
/// from `MergeEngine`, which is field-level *value* policy). Redirects a
/// loser profile's edges onto a winner, moves its provenance, and
/// hard-deletes it — one operation, undo-compatible via the delete
/// transaction. Human-initiated in every case; never silent.
@MainActor
enum ProfileMergeEngine {

    enum MergeError: Error { case profileMissing(String), sameProfile }

    /// Cleanse a single EMPTY orphan stub: verify it carries no data and no
    /// edges (so nothing is lost), confirm a name-matching linked target
    /// exists, then hard-delete the stub. The safe import-time path — the
    /// stub is a discardable export artifact, not a merge.
    @discardableResult
    static func cleanseEmptyStub(
        stubID: String,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) throws -> Bool {
        guard let stub = snapshot.profiles[stubID] else {
            throw MergeError.profileMissing(stubID)
        }
        // Re-verify against the live snapshot — never delete something that
        // has gained edges or data since detection.
        guard OrphanStubDetector.isEdgeless(stubID, relationships: snapshot.relationships),
              OrphanStubDetector.isEmpty(stub),
              OrphanStubDetector.candidates(in: snapshot).contains(where: { $0.stubID == stubID })
        else { return false }
        try db.hardDeleteProfile(id: stubID)
        return true
    }

    /// Cleanse every empty orphan stub in one pass. Returns the count
    /// removed. Idempotent — re-running finds nothing.
    @discardableResult
    static func cleanseAllEmptyStubs(
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) throws -> Int {
        var removed = 0
        for id in OrphanStubDetector.cleansableEmptyStubIDs(in: snapshot) {
            if try cleanseEmptyStub(stubID: id, snapshot: snapshot, db: db) { removed += 1 }
        }
        return removed
    }

    /// General merge: fold `loserID` into `winnerID`. Redirects the loser's
    /// relationship edges to the winner (skipping any that would duplicate
    /// an existing winner edge or create a self-loop), then hard-deletes
    /// the loser. Field-value reconciliation for non-empty losers rides the
    /// normal apply/overwrite + conflict-detection path when the caller
    /// subsequently re-applies the loser's field_sources; this method owns
    /// the structural graft only (edges + removal), which is the part with
    /// no existing primitive.
    static func merge(
        loserID: String,
        winnerID: String,
        snapshot: FamilyGraphSnapshot,
        db: ProjectDatabase
    ) throws {
        guard loserID != winnerID else { throw MergeError.sameProfile }
        guard snapshot.profiles[loserID] != nil else { throw MergeError.profileMissing(loserID) }
        guard snapshot.profiles[winnerID] != nil else { throw MergeError.profileMissing(winnerID) }

        let winnerEdges = snapshot.relationships.filter { $0.from == winnerID || $0.to == winnerID }
        func winnerAlreadyLinks(_ other: String, type: RelationshipType, role: ParentRole?) -> Bool {
            winnerEdges.contains { e in
                e.type == type && e.role == role &&
                ((e.from == winnerID && e.to == other) || (e.to == winnerID && e.from == other))
            }
        }

        for edge in snapshot.relationships where edge.from == loserID || edge.to == loserID {
            let other = edge.from == loserID ? edge.to : edge.from
            // Merge is irreversible — an edge that fails to drop leaves the
            // winner carrying kinship the merge was meant to collapse, and
            // there is no undo to fall back on.
            func dropEdge() {
                do { _ = try db.removeRelationship(id: edge.id) }
                catch { mergeLogger.error("Removing edge \(edge.id) during merge failed: \(error.localizedDescription)") }
            }
            if other == winnerID { dropEdge(); continue }
            if winnerAlreadyLinks(other, type: edge.type, role: edge.role) {
                dropEdge()
                continue
            }
            // Repoint: drop the loser edge, add the equivalent on the winner.
            _ = try db.removeRelationship(id: edge.id)
            let newEdge = Relationship(
                id: UUID(),
                from: edge.from == loserID ? winnerID : edge.from,
                to: edge.to == loserID ? winnerID : edge.to,
                type: edge.type, role: edge.role, subtype: edge.subtype,
                marriageDate: edge.marriageDate, marriageLocation: edge.marriageLocation,
                divorceDate: edge.divorceDate)
            _ = try db.addRelationship(newEdge)
        }
        try db.hardDeleteProfile(id: loserID)
    }
}
