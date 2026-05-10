import Foundation
import GRDB

/// Workbench (M8 W4) session persistence. The `sessions` table is created
/// by migration v7; this extension surfaces start/touch/load operations.
nonisolated extension ProjectDatabase {

    /// Idle interval after which a session is considered ended.
    /// 30 minutes per DESIGN.md §7.7.6.
    static let sessionIdleThreshold: TimeInterval = 30 * 60

    /// 7 days — beyond this, the session resume screen does not surface
    /// a previous session (per §7.7.6).
    static let sessionResumeWindow: TimeInterval = 7 * 24 * 60 * 60

    @discardableResult
    func startSession(focusSetID: UUID? = nil) throws -> ResearchSession {
        let now = Date()
        let session = ResearchSession(
            id: UUID(),
            startedAt: now, endedAt: now,
            focusSetID: focusSetID,
            profilesAdded: 0, profilesEdited: 0, disputesResolved: 0,
            hypothesesCreated: 0, hypothesesPromoted: 0,
            questionsCreated: 0, questionsResolved: 0,
            notesCreated: 0,
            transactionIDs: []
        )
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions
                  (id, started_at, ended_at, focus_set_id,
                   profiles_added, profiles_edited, disputes_resolved,
                   hypotheses_created, hypotheses_promoted,
                   questions_created, questions_resolved, notes_created,
                   transaction_ids)
                VALUES (?, ?, ?, ?, 0, 0, 0, 0, 0, 0, 0, 0, ?)
                """, arguments: [
                    session.id.uuidString,
                    session.startedAt, session.endedAt,
                    session.focusSetID?.uuidString,
                    Self.encodeJSON([] as [UUID]),
                ])
        }
        return session
    }

    /// Apply an event to a session — bumps endedAt and the relevant counter.
    /// Multiple events from a single user action should each be recorded.
    func recordSessionEvent(_ event: SessionEvent, sessionID: UUID) throws {
        let now = Date()
        try dbQueue.write { db in
            switch event {
            case .profileAdded:
                try db.execute(sql: "UPDATE sessions SET ended_at = ?, profiles_added = profiles_added + 1 WHERE id = ?",
                               arguments: [now, sessionID.uuidString])
            case .profileEdited:
                try db.execute(sql: "UPDATE sessions SET ended_at = ?, profiles_edited = profiles_edited + 1 WHERE id = ?",
                               arguments: [now, sessionID.uuidString])
            case .disputeResolved:
                try db.execute(sql: "UPDATE sessions SET ended_at = ?, disputes_resolved = disputes_resolved + 1 WHERE id = ?",
                               arguments: [now, sessionID.uuidString])
            case .hypothesisCreated:
                try db.execute(sql: "UPDATE sessions SET ended_at = ?, hypotheses_created = hypotheses_created + 1 WHERE id = ?",
                               arguments: [now, sessionID.uuidString])
            case .hypothesisPromoted:
                try db.execute(sql: "UPDATE sessions SET ended_at = ?, hypotheses_promoted = hypotheses_promoted + 1 WHERE id = ?",
                               arguments: [now, sessionID.uuidString])
            case .questionCreated:
                try db.execute(sql: "UPDATE sessions SET ended_at = ?, questions_created = questions_created + 1 WHERE id = ?",
                               arguments: [now, sessionID.uuidString])
            case .questionResolved:
                try db.execute(sql: "UPDATE sessions SET ended_at = ?, questions_resolved = questions_resolved + 1 WHERE id = ?",
                               arguments: [now, sessionID.uuidString])
            case .noteCreated:
                try db.execute(sql: "UPDATE sessions SET ended_at = ?, notes_created = notes_created + 1 WHERE id = ?",
                               arguments: [now, sessionID.uuidString])
            case .transactionRecorded(let txID):
                // Append to transaction_ids JSON. Cheap given session size.
                let existing = try Self.loadTransactionIDs(sessionID: sessionID, db: db)
                let updated = existing + [txID]
                try db.execute(sql: """
                    UPDATE sessions SET ended_at = ?, transaction_ids = ? WHERE id = ?
                    """, arguments: [now, Self.encodeJSON(updated), sessionID.uuidString])
            }
        }
    }

    /// Touch the session's `ended_at` to "now" without bumping any counter.
    /// Used when the user merely opens the app or focuses a profile.
    func touchSession(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET ended_at = ? WHERE id = ?",
                           arguments: [Date(), id.uuidString])
        }
    }

    /// Update which focus set is active in the session. Used so resume can
    /// restore "what the user was looking at."
    func updateSessionFocus(sessionID: UUID, focusSetID: UUID?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET focus_set_id = ? WHERE id = ?",
                           arguments: [focusSetID?.uuidString, sessionID.uuidString])
        }
    }

    /// Most recent session whose `ended_at` is within the idle threshold —
    /// i.e. it's still "live" and the caller should append to it instead of
    /// starting a fresh one.
    func loadActiveSession() throws -> ResearchSession? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT * FROM sessions ORDER BY ended_at DESC LIMIT 1
                """)
            guard let row, let session = Self.sessionFromRow(row) else { return nil }
            let last = session.endedAt ?? session.startedAt
            return Date().timeIntervalSince(last) <= ProjectDatabase.sessionIdleThreshold
                ? session : nil
        }
    }

    /// Most-recent session whose ended_at falls in the resume window
    /// (more than `sessionIdleThreshold` ago, less than `sessionResumeWindow`).
    /// Returns nil otherwise. Drives the launch resume screen.
    func loadResumableSession() throws -> ResearchSession? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT * FROM sessions ORDER BY ended_at DESC LIMIT 1
                """)
            guard let row, let session = Self.sessionFromRow(row) else { return nil }
            let last = session.endedAt ?? session.startedAt
            let elapsed = Date().timeIntervalSince(last)
            guard elapsed > ProjectDatabase.sessionIdleThreshold else { return nil }
            guard elapsed < ProjectDatabase.sessionResumeWindow else { return nil }
            // Don't show resume for a no-activity session — useless content.
            return session.hasActivity ? session : nil
        }
    }

    /// Most-recent first.
    func loadSessions(limit: Int = 50) throws -> [ResearchSession] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM sessions ORDER BY started_at DESC LIMIT ?
                """, arguments: [limit])
            return rows.compactMap(Self.sessionFromRow)
        }
    }

    func loadSession(id: UUID) throws -> ResearchSession? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?",
                                       arguments: [id.uuidString])
            return row.flatMap(Self.sessionFromRow)
        }
    }

    // MARK: - Decoding

    static func sessionFromRow(_ row: Row) -> ResearchSession? {
        guard
            let idStr: String = row["id"], let id = UUID(uuidString: idStr),
            let startedAt: Date = row["started_at"]
        else { return nil }

        let focusSetID: UUID? = (row["focus_set_id"] as String?).flatMap(UUID.init(uuidString:))

        var transactionIDs: [UUID] = []
        if let json: String = row["transaction_ids"],
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([UUID].self, from: data) {
            transactionIDs = decoded
        }

        return ResearchSession(
            id: id,
            startedAt: startedAt,
            endedAt: row["ended_at"],
            focusSetID: focusSetID,
            profilesAdded: row["profiles_added"] ?? 0,
            profilesEdited: row["profiles_edited"] ?? 0,
            disputesResolved: row["disputes_resolved"] ?? 0,
            hypothesesCreated: row["hypotheses_created"] ?? 0,
            hypothesesPromoted: row["hypotheses_promoted"] ?? 0,
            questionsCreated: row["questions_created"] ?? 0,
            questionsResolved: row["questions_resolved"] ?? 0,
            notesCreated: row["notes_created"] ?? 0,
            transactionIDs: transactionIDs
        )
    }

    /// Test-only: backdate `ended_at` so resume-window detection logic can
    /// be exercised without sleeping for 30 minutes. Underscore prefix marks
    /// the contract as not for production callers.
    func _unsafeSetSessionEndedAt(_ date: Date, sessionID: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET ended_at = ? WHERE id = ?",
                           arguments: [date, sessionID.uuidString])
        }
    }

    private static func loadTransactionIDs(sessionID: UUID, db: Database) throws -> [UUID] {
        let row = try Row.fetchOne(db, sql: "SELECT transaction_ids FROM sessions WHERE id = ?",
                                   arguments: [sessionID.uuidString])
        guard let json: String = row?["transaction_ids"],
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
    }
}
