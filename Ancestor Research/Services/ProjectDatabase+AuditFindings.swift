import Foundation
import GRDB
import AncestorKit

/// One persisted audit finding row (v55) — the durable projection of an
/// `AuditResult` that external MCP readers consume. `profileID` is nil for
/// tree-level findings; `computedAt` is the timestamp of the audit pass that
/// produced the snapshot, so staleness is honest.
nonisolated struct PersistedAuditFinding: Sendable, Equatable {
    let id: String
    let ruleID: String
    let profileID: String?
    let severity: Severity
    let message: String
    let computedAt: Date
}

/// Persistence for Health audit findings (v55, MCP_CONSUMER_SURFACE_SPEC MC4).
///
/// `AuditEngine.audit(snapshot:)` recomputes everything from scratch on every
/// pass, so the table holds exactly one snapshot: replace semantics, never
/// append. The MCP server reads this table (`ancestor://audit_findings`);
/// the app itself keeps using the in-memory `AuditSummary`.
nonisolated extension ProjectDatabase {

    /// Replace the persisted audit snapshot with `results`, all stamped with
    /// the same `computedAt`. One write transaction: DELETE all prior rows,
    /// INSERT the new snapshot (the results array is always complete — an
    /// empty array legitimately clears the table).
    func replaceAuditFindings(_ results: [AuditResult], computedAt: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM audit_findings")
            for result in results {
                // Empty profileID = tree-level finding → stored as NULL.
                let profileID = result.profileID.isEmpty ? nil : result.profileID
                try db.execute(sql: """
                    INSERT INTO audit_findings
                        (id, rule_id, profile_id, severity, message, computed_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        result.id.uuidString, result.ruleID, profileID,
                        result.severity.rawValue, result.message, computedAt
                    ])
            }
        }
    }

    /// The persisted snapshot — all findings, or just those for `profileID`
    /// when given. Ordered by severity (errors first) then rule for a stable,
    /// meaningful read.
    func latestAuditFindings(profileID: String? = nil) throws -> [PersistedAuditFinding] {
        try dbQueue.read { db in
            let rows: [Row]
            if let profileID {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, rule_id, profile_id, severity, message, computed_at
                    FROM audit_findings WHERE profile_id = ?
                    ORDER BY CASE severity WHEN 'error' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, rule_id
                    """, arguments: [profileID])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, rule_id, profile_id, severity, message, computed_at
                    FROM audit_findings
                    ORDER BY CASE severity WHEN 'error' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, rule_id
                    """)
            }
            return rows.compactMap { row -> PersistedAuditFinding? in
                guard let id: String = row["id"],
                      let ruleID: String = row["rule_id"],
                      let severityRaw: String = row["severity"],
                      let severity = Severity(rawValue: severityRaw),
                      let message: String = row["message"],
                      let computedAt: Date = row["computed_at"] else { return nil }
                return PersistedAuditFinding(
                    id: id, ruleID: ruleID, profileID: row["profile_id"],
                    severity: severity, message: message, computedAt: computedAt)
            }
        }
    }
}
