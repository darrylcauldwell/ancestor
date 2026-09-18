import Foundation
import GRDB

/// Workbench persistence: notes and questions. Hypotheses, focus sets,
/// sessions and goals live in `ProjectDatabase+Focus.swift`; their tables were
/// created together in migration v7.
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
                WHERE id IN (?, ?)
                """, arguments: [
                    updated.content, updated.tag.rawValue,
                    Self.encodeJSON(updated.attachedTo),
                    updated.attachedTo.kind, updated.attachedTo.attachmentID,
                    updated.updatedAt, updated.sensitive ? 1 : 0,
                    // EV33 follow-up (review C2): a legacy MCP note surfaces
                    // under its mapped UUID but sits on disk under `fr_…` —
                    // the write must reach either form of the id.
                    updated.id.uuidString,
                    Self.legacyFieldResearcherNoteID(from: updated.id) ?? updated.id.uuidString,
                ])
        }
        return updated
    }

    func deleteNote(id: UUID) throws {
        try dbQueue.write { db in
            // EV33 follow-up (review C2): a legacy MCP note surfaces under its
            // mapped UUID; deleting it must reach the on-disk `fr_…` row too.
            try db.execute(
                sql: "DELETE FROM workbench_notes WHERE id IN (?, ?)",
                arguments: [id.uuidString, Self.legacyFieldResearcherNoteID(from: id) ?? id.uuidString])
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
            let idStr: String = row["id"],
            // EV33 follow-up (review C2): MCP notes were keyed by the raw
            // `fr_<16hex>` idempotency id, which this UUID guard silently
            // dropped — every refusal reason and add_workbench_note row was
            // invisible in the Workbench. The fallback maps those legacy rows
            // to the same deterministic UUID new MCP writes use.
            let id = UUID(uuidString: idStr) ?? noteUUID(fromLegacyFieldResearcherID: idStr),
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

    // MARK: - Legacy field-researcher note ids (EV33 follow-up, review C2)

    /// The MCP server (`FieldResearcherMCP`) filed `workbench_notes` rows
    /// under its raw idempotency id — `"fr_" + 16 lowercase hex digits` —
    /// which `UUID(uuidString:)` rejects, so `noteFromRow` silently dropped
    /// every note it ever wrote (refusal reasons and `add_workbench_note`
    /// alike). New MCP writes use a UUID derived from the same hash; this
    /// fallback maps the legacy rows already on disk to the SAME UUID so they
    /// render without a migration.
    ///
    /// Derivation — byte-for-byte identical to the MCP side
    /// (`MCPHandler.noteUUIDString(fromLegacyID:)` in
    /// `FieldResearcherMCP/Sources/MCPServer.swift`):
    ///   1. take the 16 lowercase hex digits after "fr_",
    ///   2. concatenate the run with itself to make 32 hex digits,
    ///   3. uppercase and hyphenate 8-4-4-4-12.
    /// Same hash → same UUID on both ends, so a replayed MCP write dedups
    /// against the row this fallback surfaces instead of duplicating it. The
    /// doubled pattern (first 16 nibbles == last 16) makes the mapping
    /// invertible below; a genuine random UUID matches it with probability
    /// 2⁻⁶⁴.
    static func noteUUID(fromLegacyFieldResearcherID idStr: String) -> UUID? {
        guard idStr.hasPrefix("fr_") else { return nil }
        let hex = String(idStr.dropFirst("fr_".count)).lowercased()
        guard hex.count == 16, hex.allSatisfy(\.isHexDigit) else { return nil }
        let digits = Array((hex + hex).uppercased())
        let dashed = [digits[0..<8], digits[8..<12], digits[12..<16], digits[16..<20], digits[20..<32]]
            .map { String($0) }
            .joined(separator: "-")
        return UUID(uuidString: dashed)
    }

    /// The inverse of `noteUUID(fromLegacyFieldResearcherID:)`: recover the
    /// on-disk `fr_…` id from a mapped UUID, or nil when the UUID does not
    /// carry the doubled-digits signature. Lets `updateNote` / `deleteNote`
    /// reach a legacy row through the UUID the read fallback handed out.
    static func legacyFieldResearcherNoteID(from id: UUID) -> String? {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let first = hex.prefix(16)
        guard first == hex.suffix(16) else { return nil }
        return "fr_" + first
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
