import Foundation
import GRDB

/// Workbench (M8 W5) hypothesis persistence. The `hypotheses` table is
/// created by migration v7; this extension surfaces CRUD plus a small
/// helper to fetch only active hypotheses (the common UI query).
nonisolated extension ProjectDatabase {

    @discardableResult
    func addHypothesis(_ hypothesis: Hypothesis) throws -> Hypothesis {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO hypotheses
                  (id, claim, confidence, reasoning,
                   supporting_evidence, contradicting_evidence,
                   status, created_at, resolved_at, dismissal_reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    hypothesis.id.uuidString,
                    Self.encodeJSON(hypothesis.claim),
                    hypothesis.confidence.rawValue,
                    hypothesis.reasoning,
                    Self.encodeJSON(hypothesis.supportingEvidence),
                    Self.encodeJSON(hypothesis.contradictingEvidence),
                    hypothesis.status.rawValue,
                    hypothesis.createdAt,
                    hypothesis.resolvedAt,
                    hypothesis.dismissalReason,
                ])
        }
        return hypothesis
    }

    @discardableResult
    func updateHypothesis(_ hypothesis: Hypothesis) throws -> Hypothesis {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE hypotheses
                SET claim = ?, confidence = ?, reasoning = ?,
                    supporting_evidence = ?, contradicting_evidence = ?,
                    status = ?, resolved_at = ?, dismissal_reason = ?
                WHERE id = ?
                """, arguments: [
                    Self.encodeJSON(hypothesis.claim),
                    hypothesis.confidence.rawValue,
                    hypothesis.reasoning,
                    Self.encodeJSON(hypothesis.supportingEvidence),
                    Self.encodeJSON(hypothesis.contradictingEvidence),
                    hypothesis.status.rawValue,
                    hypothesis.resolvedAt,
                    hypothesis.dismissalReason,
                    hypothesis.id.uuidString,
                ])
        }
        return hypothesis
    }

    func deleteHypothesis(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM hypotheses WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    func loadHypothesis(id: UUID) throws -> Hypothesis? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM hypotheses WHERE id = ?",
                                       arguments: [id.uuidString])
            return row.flatMap(Self.hypothesisFromRow)
        }
    }

    /// All hypotheses, newest first. UI groups by confidence at display time.
    func loadHypotheses() throws -> [Hypothesis] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM hypotheses ORDER BY created_at DESC
                """)
            return rows.compactMap(Self.hypothesisFromRow)
        }
    }

    /// Active-only — used by the tree uncertainty layer (dashed edges) so
    /// we don't render dismissed/promoted hypotheses as still-uncertain.
    func loadActiveHypotheses() throws -> [Hypothesis] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM hypotheses WHERE status = ? ORDER BY created_at DESC
                """, arguments: [HypothesisStatus.active.rawValue])
            return rows.compactMap(Self.hypothesisFromRow)
        }
    }

    static func hypothesisFromRow(_ row: Row) -> Hypothesis? {
        guard
            let idStr: String = row["id"], let id = UUID(uuidString: idStr),
            let claimJSON: String = row["claim"],
            let claimData = claimJSON.data(using: .utf8),
            let claim = try? JSONDecoder().decode(HypothesisClaim.self, from: claimData),
            let confidenceRaw: String = row["confidence"],
            let confidence = HypothesisConfidence(rawValue: confidenceRaw),
            let reasoning: String = row["reasoning"],
            let supportingJSON: String = row["supporting_evidence"],
            let supportingData = supportingJSON.data(using: .utf8),
            let supporting = try? JSONDecoder().decode([String].self, from: supportingData),
            let contradictingJSON: String = row["contradicting_evidence"],
            let contradictingData = contradictingJSON.data(using: .utf8),
            let contradicting = try? JSONDecoder().decode([String].self, from: contradictingData),
            let statusRaw: String = row["status"],
            let status = HypothesisStatus(rawValue: statusRaw),
            let createdAt: Date = row["created_at"]
        else { return nil }
        return Hypothesis(
            id: id, claim: claim, confidence: confidence, reasoning: reasoning,
            supportingEvidence: supporting,
            contradictingEvidence: contradicting,
            status: status, createdAt: createdAt,
            resolvedAt: row["resolved_at"],
            dismissalReason: row["dismissal_reason"]
        )
    }
}
