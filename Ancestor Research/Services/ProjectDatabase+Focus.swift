import Foundation
import GRDB

/// Workbench (M8 W3) focus-set persistence. The `focus_sets` table is
/// already created by migration v7; this extension just surfaces CRUD.
nonisolated extension ProjectDatabase {

    @discardableResult
    func addFocusSet(_ set: FocusSet) throws -> FocusSet {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO focus_sets (id, title, profile_ids, created_at, last_active_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    set.id.uuidString, set.title,
                    Self.encodeJSON(set.profileIDs),
                    set.createdAt, set.lastActiveAt,
                ])
        }
        return set
    }

    @discardableResult
    func updateFocusSet(_ set: FocusSet) throws -> FocusSet {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE focus_sets
                SET title = ?, profile_ids = ?, last_active_at = ?
                WHERE id = ?
                """, arguments: [
                    set.title, Self.encodeJSON(set.profileIDs),
                    set.lastActiveAt, set.id.uuidString,
                ])
        }
        return set
    }

    func deleteFocusSet(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM focus_sets WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    /// Bump `last_active_at` to now — used when the user switches focus sets.
    /// Returns the updated record.
    @discardableResult
    func touchFocusSet(id: UUID) throws -> FocusSet? {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE focus_sets SET last_active_at = ? WHERE id = ?",
                           arguments: [Date(), id.uuidString])
        }
        return try loadFocusSet(id: id)
    }

    func loadFocusSet(id: UUID) throws -> FocusSet? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM focus_sets WHERE id = ?",
                                       arguments: [id.uuidString])
            return row.flatMap(Self.focusSetFromRow)
        }
    }

    /// All focus sets, most-recently-active first.
    func loadFocusSets() throws -> [FocusSet] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM focus_sets ORDER BY last_active_at DESC
                """)
            return rows.compactMap(Self.focusSetFromRow)
        }
    }

    static func focusSetFromRow(_ row: Row) -> FocusSet? {
        guard
            let idStr: String = row["id"], let id = UUID(uuidString: idStr),
            let profileIDsJSON: String = row["profile_ids"],
            let profileIDsData = profileIDsJSON.data(using: .utf8),
            let profileIDs = try? JSONDecoder().decode([String].self, from: profileIDsData),
            let createdAt: Date = row["created_at"],
            let lastActiveAt: Date = row["last_active_at"]
        else { return nil }
        return FocusSet(
            id: id,
            title: row["title"],
            profileIDs: profileIDs,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt
        )
    }
}
