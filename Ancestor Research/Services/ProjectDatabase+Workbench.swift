import Foundation
import GRDB

/// Workbench (M8) persistence: notes and questions. Hypotheses, focus sets,
/// sessions, and goals get added in W3+ but their tables already exist
/// from migration v7.
nonisolated extension ProjectDatabase {

    // MARK: - Notes (W1)

    @discardableResult
    func addNote(_ note: WorkbenchNote) throws -> WorkbenchNote {
        try dbQueue.write { db in
            try Self.insertNote(note, db: db)
        }
        return note
    }

    /// Update an existing note's content/tag/attachment. Bumps `updatedAt`.
    /// Returns the updated note for caller convenience.
    @discardableResult
    func updateNote(_ note: WorkbenchNote) throws -> WorkbenchNote {
        var updated = note
        updated.updatedAt = Date()
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE workbench_notes
                SET content = ?, tag = ?, attached_to = ?, attachment_kind = ?, attachment_id = ?, updated_at = ?, sensitive = ?
                WHERE id = ?
                """, arguments: [
                    updated.content, updated.tag.rawValue,
                    Self.encodeJSON(updated.attachedTo),
                    updated.attachedTo.kind, updated.attachedTo.attachmentID,
                    updated.updatedAt, updated.sensitive ? 1 : 0,
                    updated.id.uuidString,
                ])
        }
        return updated
    }

    func deleteNote(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM workbench_notes WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// All notes, newest first.
    func loadNotes() throws -> [WorkbenchNote] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM workbench_notes ORDER BY updated_at DESC
                """)
            return rows.compactMap(Self.noteFromRow)
        }
    }

    /// Notes attached to a specific entity. Used by ProfileDetailView's notes
    /// section and (later) hypothesis/question detail screens.
    func loadNotes(attachedToKind kind: String, id: String?) throws -> [WorkbenchNote] {
        try dbQueue.read { db in
            let sql: String
            let arguments: StatementArguments
            if let id {
                sql = """
                    SELECT * FROM workbench_notes
                    WHERE attachment_kind = ? AND attachment_id = ?
                    ORDER BY updated_at DESC
                    """
                arguments = [kind, id]
            } else {
                sql = """
                    SELECT * FROM workbench_notes
                    WHERE attachment_kind = ? AND attachment_id IS NULL
                    ORDER BY updated_at DESC
                    """
                arguments = [kind]
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.compactMap(Self.noteFromRow)
        }
    }

    /// Full-text search of note content. Empty query returns []. Caller
    /// should sanitise user input — FTS5 MATCH expressions are sensitive.
    func searchNotes(query: String) throws -> [WorkbenchNote] {
        let sanitised = query.trimmingCharacters(in: .whitespaces)
        guard !sanitised.isEmpty else { return [] }
        // Wrap in quotes so users can paste arbitrary text without breaking
        // the MATCH grammar. They lose advanced operators; we get safety.
        let phrase = "\"\(sanitised.replacingOccurrences(of: "\"", with: ""))\""
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.* FROM workbench_notes n
                JOIN workbench_notes_fts fts ON fts.rowid = n.rowid
                WHERE workbench_notes_fts MATCH ?
                ORDER BY rank
                """, arguments: [phrase])
            return rows.compactMap(Self.noteFromRow)
        }
    }

    // MARK: - Questions (W2)

    @discardableResult
    func addQuestion(_ question: OpenQuestion) throws -> OpenQuestion {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO open_questions
                  (id, text, profile_ids, priority, status, tried_sources, promoted_from,
                   created_at, resolved_at, resolution)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    question.id.uuidString, question.text,
                    Self.encodeJSON(question.profileIDs),
                    question.priority.rawValue, question.status.rawValue,
                    question.triedSources,
                    question.promotedFrom.map(Self.encodeJSON),
                    question.createdAt, question.resolvedAt, question.resolution,
                ])
        }
        return question
    }

    @discardableResult
    func updateQuestion(_ question: OpenQuestion) throws -> OpenQuestion {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE open_questions
                SET text = ?, profile_ids = ?, priority = ?, status = ?,
                    tried_sources = ?, promoted_from = ?,
                    resolved_at = ?, resolution = ?
                WHERE id = ?
                """, arguments: [
                    question.text, Self.encodeJSON(question.profileIDs),
                    question.priority.rawValue, question.status.rawValue,
                    question.triedSources,
                    question.promotedFrom.map(Self.encodeJSON),
                    question.resolvedAt, question.resolution,
                    question.id.uuidString,
                ])
        }
        return question
    }

    /// Convenience: mark a question resolved with timestamp + resolution text.
    @discardableResult
    func resolveQuestion(id: UUID, resolution: String?) throws -> OpenQuestion? {
        var question = try loadQuestion(id: id)
        guard question != nil else { return nil }
        question?.status = .resolved
        question?.resolvedAt = Date()
        question?.resolution = resolution
        if let q = question {
            return try updateQuestion(q)
        }
        return nil
    }

    func deleteQuestion(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM open_questions WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func loadQuestion(id: UUID) throws -> OpenQuestion? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM open_questions WHERE id = ?",
                                       arguments: [id.uuidString])
            return row.flatMap(Self.questionFromRow)
        }
    }

    /// All questions. Sort key: status (open first) then priority then created_at.
    func loadQuestions() throws -> [OpenQuestion] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM open_questions ORDER BY created_at DESC
                """)
            return rows.compactMap(Self.questionFromRow)
        }
    }

    /// Questions referencing a specific profile (via profile_ids JSON).
    /// Loads then filters in Swift — simpler than JSON-querying SQLite, and
    /// the volume is small (typically &lt;100 questions per project).
    func loadQuestions(forProfile profileID: String) throws -> [OpenQuestion] {
        try loadQuestions().filter { $0.profileIDs.contains(profileID) }
    }

    // MARK: - Row decoders

    static func noteFromRow(_ row: Row) -> WorkbenchNote? {
        guard
            let idStr: String = row["id"], let id = UUID(uuidString: idStr),
            let content: String = row["content"],
            let tagRaw: String = row["tag"], let tag = NoteTag(rawValue: tagRaw),
            let attachedJSON: String = row["attached_to"],
            let attachedData = attachedJSON.data(using: .utf8),
            let attached = try? JSONDecoder().decode(NoteAttachment.self, from: attachedData),
            let createdAt: Date = row["created_at"],
            let updatedAt: Date = row["updated_at"]
        else { return nil }
        let sensitiveRaw: Int? = row["sensitive"]
        let sensitive = (sensitiveRaw ?? 0) == 1
        return WorkbenchNote(
            id: id, content: content, tag: tag, attachedTo: attached,
            createdAt: createdAt, updatedAt: updatedAt, sensitive: sensitive
        )
    }

    static func questionFromRow(_ row: Row) -> OpenQuestion? {
        guard
            let idStr: String = row["id"], let id = UUID(uuidString: idStr),
            let text: String = row["text"],
            let profileIDsJSON: String = row["profile_ids"],
            let profileIDsData = profileIDsJSON.data(using: .utf8),
            let profileIDs = try? JSONDecoder().decode([String].self, from: profileIDsData),
            let priorityRaw: String = row["priority"],
            let priority = QuestionPriority(rawValue: priorityRaw),
            let statusRaw: String = row["status"],
            let status = QuestionStatus(rawValue: statusRaw),
            let createdAt: Date = row["created_at"]
        else { return nil }

        var origin: QuestionOrigin?
        if let originJSON: String = row["promoted_from"],
           let originData = originJSON.data(using: .utf8) {
            origin = try? JSONDecoder().decode(QuestionOrigin.self, from: originData)
        }

        return OpenQuestion(
            id: id, text: text, profileIDs: profileIDs,
            priority: priority, status: status,
            triedSources: row["tried_sources"],
            promotedFrom: origin,
            createdAt: createdAt,
            resolvedAt: row["resolved_at"],
            resolution: row["resolution"]
        )
    }

    static func insertNote(_ note: WorkbenchNote, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO workbench_notes
              (id, content, tag, attached_to, attachment_kind, attachment_id, created_at, updated_at, sensitive)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                note.id.uuidString, note.content, note.tag.rawValue,
                encodeJSON(note.attachedTo),
                note.attachedTo.kind, note.attachedTo.attachmentID,
                note.createdAt, note.updatedAt, note.sensitive ? 1 : 0,
            ])
    }
}
