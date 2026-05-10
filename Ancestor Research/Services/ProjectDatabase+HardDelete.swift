import Foundation
import GRDB

/// Hard-delete a profile and ALL its associated data (M14, DESIGN.md §7.15.2).
/// Irreversible. Used by Settings → Deleted People → "Permanently remove".
///
/// Removes from these tables:
/// - profiles
/// - field_sources, field_changes, field_disputes for the profile
/// - life_events with this profileID
/// - attachments targeting the profile or any of its field sources
/// - relationships where this profile is the from or to side
/// - workbench_notes attached to the profile
///
/// Open questions and hypotheses that reference the profile are left intact —
/// they may carry research context the user wants to retain. The profile_ids
/// array on questions / claim profileIDs on hypotheses become dangling
/// references; UI should handle missing IDs gracefully.
nonisolated extension ProjectDatabase {

    func hardDeleteProfile(id: String) throws {
        try dbQueue.write { db in
            // Profile row
            try db.execute(sql: "DELETE FROM profiles WHERE id = ?", arguments: [id])

            // Field-related tables
            try db.execute(sql: "DELETE FROM field_sources WHERE entity_id = ? AND entity_kind = 'profile'",
                           arguments: [id])
            try db.execute(sql: "DELETE FROM field_changes WHERE entity_id = ? AND entity_kind = 'profile'",
                           arguments: [id])
            try db.execute(sql: "DELETE FROM field_disputes WHERE entity_id = ?", arguments: [id])

            // Life events
            try db.execute(sql: "DELETE FROM life_events WHERE profile_id = ?", arguments: [id])

            // Attachments — both .profile and .fieldSource targets keyed off this id
            try db.execute(sql: """
                DELETE FROM attachments
                WHERE (target_kind = 'profile' AND target_primary_id = ?)
                   OR (target_kind = 'fieldSource' AND target_primary_id LIKE ?)
                """, arguments: [id, "\(id):%"])

            // Relationships
            try db.execute(sql: "DELETE FROM relationships WHERE from_id = ? OR to_id = ?",
                           arguments: [id, id])

            // Workbench notes attached to the profile
            try db.execute(sql: """
                DELETE FROM workbench_notes
                WHERE attachment_kind = 'profile' AND attachment_id = ?
                """, arguments: [id])
        }
    }
}
