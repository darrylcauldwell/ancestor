import Foundation
import GRDB
import AncestorKit

/// Persistence for the Places tab's decisions (v60).
///
/// Supersede-then-insert, never UPDATE and never DELETE: a changed mind is a
/// fact worth keeping, and the history is what makes "why is this recorded as
/// Ashbourne?" answerable in six months.
nonisolated extension ProjectDatabase {

    /// Record a decision, retiring whatever previously governed the same
    /// (text, scope). One write transaction so a crash cannot leave a string
    /// with two live decisions or none.
    func recordPlaceDecision(_ decision: PlaceDecision) throws {
        // The migration's NOT NULL is the only other constraint, and no foreign
        // key is possible — PlaceAuthority is bundled JSON, not a table.
        try ProjectDatabase.validatePlaceCode(decision.placeAuthorityID)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE place_decisions SET superseded_at = ?
                WHERE place_text = ? AND scope_field = ? AND superseded_at IS NULL
                """, arguments: [decision.decidedAt, decision.placeText, decision.scopeField ?? ""])
            try db.execute(sql: """
                INSERT INTO place_decisions
                  (id, place_text, display_text, scope_field, place_authority_id,
                   year_from, year_to, reason, decided_at, superseded_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """, arguments: [
                    decision.id, decision.placeText, decision.displayText,
                    decision.scopeField ?? "", decision.placeAuthorityID,
                    decision.yearFrom, decision.yearTo, decision.reason, decision.decidedAt,
                ])
        }
    }

    /// Retire a decision without replacing it — the undo. The row stays.
    func supersedePlaceDecision(id: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE place_decisions SET superseded_at = ? WHERE id = ? AND superseded_at IS NULL",
                arguments: [date, id])
        }
    }

    func loadPlaceDecisions(includingSuperseded: Bool = false) throws -> [PlaceDecision] {
        try dbQueue.read { db in
            let sql = includingSuperseded
                ? "SELECT * FROM place_decisions ORDER BY decided_at DESC"
                : "SELECT * FROM place_decisions WHERE superseded_at IS NULL ORDER BY decided_at DESC"
            return try Row.fetchAll(db, sql: sql).compactMap(Self.placeDecision(from:))
        }
    }

    /// Every decision ever made about one string, newest first — the audit trail.
    func placeDecisionHistory(forText text: String) throws -> [PlaceDecision] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM place_decisions WHERE place_text = ? ORDER BY decided_at DESC",
                arguments: [PlaceDecision.canonicalKey(text)]
            ).compactMap(Self.placeDecision(from:))
        }
    }

    /// Settings-level reset, beside the existing unresolvable-flags reset.
    func clearAllPlaceDecisions() throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM place_decisions") }
    }

    private static func placeDecision(from row: Row) -> PlaceDecision? {
        guard let id: String = row["id"],
              let placeText: String = row["place_text"],
              let authorityID: String = row["place_authority_id"],
              let decidedAt: Date = row["decided_at"] else { return nil }
        let scope: String = row["scope_field"] ?? ""
        return PlaceDecision(
            id: id,
            placeText: placeText,
            displayText: row["display_text"] ?? placeText,
            scopeField: scope.isEmpty ? nil : scope,
            placeAuthorityID: authorityID,
            yearFrom: row["year_from"],
            yearTo: row["year_to"],
            reason: row["reason"] ?? "",
            decidedAt: decidedAt,
            supersededAt: row["superseded_at"]
        )
    }
}
