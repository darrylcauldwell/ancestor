import Foundation
import GRDB

/// Persistence for pipeline-generated `ResearchHypothesis` rows (migration
/// v26). Distinct from the v7 `hypotheses` table which stores user-authored
/// Workbench hypotheses (`ProjectDatabase+Hypotheses.swift`).
///
/// Re-runs of the pipeline call `upsertHypotheses(_:)` — rows matching by
/// `id` are updated in place (verdict, evidence, reasoning, lastTestedAt,
/// attempts, history appended); rows that don't exist are inserted.
/// `created_at` carries forward from the first insertion.
///
/// User-rejection persists via the `user_rejected` flag; rejected rows
/// stay in the table so the UI knows not to re-surface them.
///
/// See `AncestorApp/RESEARCH_PIPELINE_V2_SPEC.md` Part II §4.3 and §5.1.
nonisolated extension ProjectDatabase {

    /// Insert-or-update a batch of hypotheses. `created_at` is preserved
    /// on update; `last_tested_at`, `verdict`, `is_model_assisted`,
    /// `supporting_evidence`, `contradicting_evidence`, `reasoning`,
    /// `attempts`, and `history` are overwritten with the new values.
    func upsertHypotheses(_ hypotheses: [ResearchHypothesis]) throws {
        try dbQueue.write { db in
            for h in hypotheses {
                try Self.upsertOne(h, db: db)
            }
        }
    }

    /// Single-hypothesis convenience.
    func upsertHypothesis(_ hypothesis: ResearchHypothesis) throws {
        try upsertHypotheses([hypothesis])
    }

    /// All hypotheses for a profile (or all tree-wide hypotheses when
    /// `profileID` is nil). Excludes user-rejected rows by default —
    /// pass `includingRejected: true` to see everything.
    func loadHypotheses(
        forProfile profileID: String?,
        includingRejected: Bool = false
    ) throws -> [ResearchHypothesis] {
        try dbQueue.read { db in
            let rejectClause = includingRejected ? "" : " AND user_rejected = 0"
            let rows: [Row]
            if let pid = profileID {
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM research_hypotheses
                    WHERE subject_profile_id = ?\(rejectClause)
                    ORDER BY last_tested_at DESC
                    """, arguments: [pid])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM research_hypotheses
                    WHERE subject_profile_id IS NULL\(rejectClause)
                    ORDER BY last_tested_at DESC
                    """)
            }
            return rows.compactMap(Self.researchHypothesisFromRow)
        }
    }

    /// Single hypothesis by id, including rejected.
    func loadHypothesis(id: String) throws -> ResearchHypothesis? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT * FROM research_hypotheses WHERE id = ?
                """, arguments: [id])
            return row.flatMap(Self.researchHypothesisFromRow)
        }
    }

    /// Flip `user_rejected = 1` for a hypothesis. The row stays in the
    /// table — re-runs won't re-surface it, but the rejection history is
    /// preserved.
    func rejectHypothesis(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE research_hypotheses SET user_rejected = 1 WHERE id = ?
                """, arguments: [id])
        }
    }

    /// Clear `user_rejected` for a hypothesis (unrejected → visible again).
    func unrejectHypothesis(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE research_hypotheses SET user_rejected = 0 WHERE id = ?
                """, arguments: [id])
        }
    }

    // MARK: - Private helpers

    private static func upsertOne(_ h: ResearchHypothesis, db: Database) throws {
        // SQLite UPSERT preserves created_at via the ON CONFLICT clause —
        // only the mutable fields are overwritten. user_rejected is also
        // preserved so user-rejection survives a re-run.
        try db.execute(sql: """
            INSERT INTO research_hypotheses (
                id, subject_profile_id, kind_discriminator, kind_payload,
                verdict, is_model_assisted, supporting_evidence,
                contradicting_evidence, reasoning, created_at,
                last_tested_at, attempts, history, user_rejected
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                verdict = excluded.verdict,
                is_model_assisted = excluded.is_model_assisted,
                supporting_evidence = excluded.supporting_evidence,
                contradicting_evidence = excluded.contradicting_evidence,
                reasoning = excluded.reasoning,
                last_tested_at = excluded.last_tested_at,
                attempts = excluded.attempts,
                history = excluded.history
            """, arguments: [
                h.id,
                h.subjectProfileID,
                h.kind.discriminator,
                ProjectDatabase.encodeJSON(h.kind),
                h.verdict.rawValue,
                h.isModelAssisted ? 1 : 0,
                ProjectDatabase.encodeJSON(h.supportingEvidence),
                ProjectDatabase.encodeJSON(h.contradictingEvidence),
                h.reasoning,
                h.createdAt,
                h.lastTestedAt,
                h.attempts,
                ProjectDatabase.encodeJSON(h.history),
                0,
            ])
    }

    static func researchHypothesisFromRow(_ row: Row) -> ResearchHypothesis? {
        guard
            let id: String = row["id"],
            let kindJSON: String = row["kind_payload"],
            let kindData = kindJSON.data(using: .utf8),
            let kind = try? JSONDecoder().decode(HypothesisKind.self, from: kindData),
            let verdictRaw: String = row["verdict"],
            let verdict = ResearchHypothesis.Verdict(rawValue: verdictRaw),
            let supportingJSON: String = row["supporting_evidence"],
            let supportingData = supportingJSON.data(using: .utf8),
            let supporting = try? JSONDecoder().decode([String].self, from: supportingData),
            let contradictingJSON: String = row["contradicting_evidence"],
            let contradictingData = contradictingJSON.data(using: .utf8),
            let contradicting = try? JSONDecoder().decode([String].self, from: contradictingData),
            let reasoning: String = row["reasoning"],
            let createdAt: Date = row["created_at"],
            let lastTestedAt: Date = row["last_tested_at"],
            let historyJSON: String = row["history"],
            let historyData = historyJSON.data(using: .utf8),
            let history = try? JSONDecoder().decode([ResearchHypothesis.Transition].self, from: historyData)
        else { return nil }

        let isModelAssistedInt: Int = row["is_model_assisted"] ?? 0
        let attempts: Int = row["attempts"] ?? 0

        return ResearchHypothesis(
            id: id,
            subjectProfileID: row["subject_profile_id"],
            kind: kind,
            verdict: verdict,
            isModelAssisted: isModelAssistedInt != 0,
            supportingEvidence: supporting,
            contradictingEvidence: contradicting,
            reasoning: reasoning,
            createdAt: createdAt,
            lastTestedAt: lastTestedAt,
            attempts: attempts,
            history: history
        )
    }
}
