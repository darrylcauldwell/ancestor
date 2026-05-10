import Foundation
import GRDB

/// Audit rule override persistence (M18, DESIGN.md §13).
///
/// The override surface is small: insert/upsert one row per (ruleID, scope)
/// pair, load all, delete. Loading is O(N) where N = override count; in
/// practice users override <20 rules per project so we don't index more
/// aggressively than the lookup index in the migration.
nonisolated extension ProjectDatabase {

    /// Persist a new or updated override. The override's `id` field is used
    /// as the primary key — callers should reuse the same id when updating
    /// an existing override (the lookup helpers below resolve this).
    @discardableResult
    func upsertAuditRuleOverride(_ override: AuditRuleOverride) throws -> AuditRuleOverride {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO audit_rule_overrides
                  (id, rule_id, scope_kind, scope_profile_id, enabled, snoozed_until, thresholds_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  rule_id = excluded.rule_id,
                  scope_kind = excluded.scope_kind,
                  scope_profile_id = excluded.scope_profile_id,
                  enabled = excluded.enabled,
                  snoozed_until = excluded.snoozed_until,
                  thresholds_json = excluded.thresholds_json
                """, arguments: [
                    override.id.uuidString,
                    override.ruleID,
                    override.scope.kind,
                    override.scope.profileID,
                    override.enabled ? 1 : 0,
                    override.snoozedUntil,
                    Self.encodeJSON(override.thresholds),
                ])
        }
        return override
    }

    func deleteAuditRuleOverride(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM audit_rule_overrides WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    /// All overrides, in no particular order. Caller filters by scope.
    func loadAuditRuleOverrides() throws -> [AuditRuleOverride] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM audit_rule_overrides")
            return rows.compactMap(Self.auditRuleOverrideFromRow)
        }
    }

    /// The currently-active override for a (ruleID, scope) pair, or nil.
    /// Used by the Settings UI to avoid creating duplicate rows on edit.
    func loadAuditRuleOverride(ruleID: String, scope: AuditOverrideScope) throws -> AuditRuleOverride? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT * FROM audit_rule_overrides
                WHERE rule_id = ? AND scope_kind = ? AND scope_profile_id IS ?
                LIMIT 1
                """, arguments: [ruleID, scope.kind, scope.profileID])
            return row.flatMap(Self.auditRuleOverrideFromRow)
        }
    }

    static func auditRuleOverrideFromRow(_ row: Row) -> AuditRuleOverride? {
        guard
            let idStr: String = row["id"], let id = UUID(uuidString: idStr),
            let ruleID: String = row["rule_id"],
            let scopeKind: String = row["scope_kind"]
        else { return nil }

        let scope: AuditOverrideScope = {
            switch scopeKind {
            case "profile":
                if let profileID: String = row["scope_profile_id"] {
                    return .profile(id: profileID)
                }
                return .global
            default: return .global
            }
        }()

        let enabledRaw: Int = row["enabled"] ?? 1
        let thresholdsJSON: String = row["thresholds_json"] ?? "{}"
        let thresholds = (try? JSONDecoder().decode([String: Double].self, from: Data(thresholdsJSON.utf8))) ?? [:]

        return AuditRuleOverride(
            id: id,
            ruleID: ruleID,
            scope: scope,
            enabled: enabledRaw == 1,
            snoozedUntil: row["snoozed_until"],
            thresholds: thresholds
        )
    }
}
