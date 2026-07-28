import Foundation
import GRDB
import AncestorKit

/// Persistence for "Not a duplicate" dismissals (v51).
///
/// `DuplicateDetectionRule` re-scores name/birth-year similarity on every
/// audit and has no memory of its own, so without this table a pair the user
/// has already judged "two different people" reappears on every re-audit. Each
/// row is one reviewed pair, stored canonically (a < b) so the composite
/// primary key collapses the two orderings and re-dismissing is idempotent.
nonisolated extension ProjectDatabase {

    /// Record that `idX` and `idY` are NOT the same person. Order-insensitive
    /// and idempotent — a repeat dismissal just refreshes `dismissed_at`.
    func dismissDuplicatePair(_ idX: String, _ idY: String, at date: Date = Date()) throws {
        let key = DuplicatePairKey(idX, idY)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO dismissed_duplicates (profile_id_a, profile_id_b, dismissed_at)
                VALUES (?, ?, ?)
                ON CONFLICT(profile_id_a, profile_id_b) DO UPDATE SET
                  dismissed_at = excluded.dismissed_at
                """, arguments: [key.a, key.b, date])
        }
    }

    /// Undo a dismissal — the pair becomes eligible for flagging again. Kept
    /// for symmetry / a future "restore" affordance; not yet surfaced in the UI.
    func undismissDuplicatePair(_ idX: String, _ idY: String) throws {
        let key = DuplicatePairKey(idX, idY)
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM dismissed_duplicates
                WHERE profile_id_a = ? AND profile_id_b = ?
                """, arguments: [key.a, key.b])
        }
    }

    /// All dismissed pairs, as canonical keys — fed to `FamilyGraphSnapshot`
    /// so `DuplicateDetectionRule` can skip them.
    func loadDismissedDuplicatePairs() throws -> Set<DuplicatePairKey> {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT profile_id_a, profile_id_b FROM dismissed_duplicates")
            return Set(rows.compactMap { row -> DuplicatePairKey? in
                guard let a: String = row["profile_id_a"],
                      let b: String = row["profile_id_b"] else { return nil }
                return DuplicatePairKey(a, b)
            })
        }
    }
}
