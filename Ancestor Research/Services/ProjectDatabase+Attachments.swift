import Foundation
import GRDB

/// Attachment persistence (M13). Per DESIGN.md §5.15. The DB row stores
/// metadata + a relative path; the actual file lives in the project's
/// media directory.
nonisolated extension ProjectDatabase {

    @discardableResult
    func addAttachment(_ attachment: Attachment) throws -> Attachment {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO attachments
                  (id, filename, media_type, caption, date_taken, location_taken,
                   relative_path, target_kind, target_primary_id, target_json, added_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    attachment.id.uuidString, attachment.filename,
                    attachment.mediaType.rawValue, attachment.caption,
                    attachment.dateTaken, attachment.locationTaken,
                    attachment.relativePath,
                    attachment.attachedTo.kind, attachment.attachedTo.primaryID,
                    Self.encodeJSON(attachment.attachedTo),
                    attachment.addedAt,
                ])
        }
        return attachment
    }

    @discardableResult
    func updateAttachment(_ attachment: Attachment) throws -> Attachment {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE attachments
                SET filename = ?, caption = ?, date_taken = ?, location_taken = ?
                WHERE id = ?
                """, arguments: [
                    attachment.filename, attachment.caption,
                    attachment.dateTaken, attachment.locationTaken,
                    attachment.id.uuidString,
                ])
        }
        return attachment
    }

    func deleteAttachment(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM attachments WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    func loadAttachments() throws -> [Attachment] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM attachments ORDER BY added_at DESC")
            return rows.compactMap(Self.attachmentFromRow)
        }
    }

    /// All attachments for a target. Indexed read.
    func loadAttachments(for target: AttachmentTarget) throws -> [Attachment] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM attachments
                WHERE target_kind = ? AND target_primary_id = ?
                ORDER BY added_at DESC
                """, arguments: [target.kind, target.primaryID])
            return rows.compactMap(Self.attachmentFromRow)
        }
    }

    /// All attachments for a profile, INCLUDING those attached to its life
    /// events and field sources. Used by the gallery view.
    func loadAttachmentsForProfile(_ profileID: String) throws -> [Attachment] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM attachments
                WHERE (target_kind = 'profile' AND target_primary_id = ?)
                   OR (target_kind = 'fieldSource' AND target_primary_id LIKE ?)
                ORDER BY added_at DESC
                """, arguments: [profileID, "\(profileID):%"])
            return rows.compactMap(Self.attachmentFromRow)
        }
    }

    static func attachmentFromRow(_ row: Row) -> Attachment? {
        guard
            let idStr: String = row["id"], let id = UUID(uuidString: idStr),
            let filename: String = row["filename"],
            let mediaTypeStr: String = row["media_type"],
            let mediaType = AttachmentType(rawValue: mediaTypeStr),
            let relativePath: String = row["relative_path"],
            let targetJSON: String = row["target_json"],
            let targetData = targetJSON.data(using: .utf8),
            let target = try? JSONDecoder().decode(AttachmentTarget.self, from: targetData),
            let addedAt: Date = row["added_at"]
        else { return nil }
        return Attachment(
            id: id, filename: filename, mediaType: mediaType,
            caption: row["caption"],
            dateTaken: row["date_taken"],
            locationTaken: row["location_taken"],
            relativePath: relativePath,
            attachedTo: target,
            addedAt: addedAt
        )
    }
}
