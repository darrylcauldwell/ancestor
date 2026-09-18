import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

private extension MCPHandler {
    func workbenchNoteText(_ args: [String: Any]) throws -> String {
        Self.toolResponseText(try addWorkbenchNote(args))
    }
}

/// EV33 follow-up (review C2) — `workbench_notes` ids must be UUID strings.
/// The app's only note decoder (`ProjectDatabase.noteFromRow`) guards
/// `UUID(uuidString:)` and returns nil on a miss, so the raw `fr_<16hex>`
/// idempotency ids this server wrote made every MCP note — refusal reasons
/// and `add_workbench_note` alike — silently invisible in the Workbench,
/// while raw-SQL `get_workbench_notes` still showed them. The very defect
/// class EV33 fixed for `tag` and `attached_to`, with the id column missed.
///
/// The repair keeps the idempotency hash and maps it to a deterministic UUID
/// (16 hex digits doubled to 32, uppercased, hyphenated 8-4-4-4-12). The app
/// mirrors the mapping in `ProjectDatabase.noteUUID(fromLegacyFieldResearcherID:)`
/// so pre-fix rows render — same hash, same UUID, both ends.
struct NoteIDDerivationTests {

    private func makeDB() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite").path
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: """
                CREATE TABLE leads (
                    id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, name TEXT NOT NULL,
                    surname TEXT, given_name TEXT, birth_year INTEGER, death_year INTEGER,
                    relationship TEXT, source TEXT NOT NULL, status TEXT NOT NULL,
                    evidence TEXT NOT NULL, created_at DATETIME NOT NULL,
                    investigated_at DATETIME, resolved_at DATETIME, resolution TEXT)
                """)
            try db.execute(sql: """
                CREATE TABLE evidence_records (
                    id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, source_id TEXT NOT NULL,
                    source_record_id TEXT NOT NULL, record_type TEXT NOT NULL,
                    verdict TEXT NOT NULL, record_json TEXT NOT NULL, citation_full TEXT,
                    citation_url TEXT, scored_at DATETIME NOT NULL,
                    user_status TEXT NOT NULL DEFAULT 'unreviewed', gates_json TEXT,
                    applied_at DATETIME)
                """)
            try db.execute(sql: """
                CREATE TABLE workbench_notes (
                    id TEXT PRIMARY KEY, content TEXT NOT NULL, tag TEXT NOT NULL,
                    attached_to TEXT NOT NULL, attachment_kind TEXT NOT NULL,
                    attachment_id TEXT, created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    sensitive INTEGER NOT NULL DEFAULT 0)
                """)
            try db.execute(sql: "CREATE TABLE project_meta (id TEXT PRIMARY KEY, name TEXT, source_kind TEXT, source_value TEXT, created_at DATETIME)")
            try db.execute(sql: "CREATE TABLE profiles (id TEXT PRIMARY KEY, is_deleted INTEGER DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE relationships (id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES (?,'T','manual','',?)", arguments: [UUID().uuidString, Date()])
        }
        return path
    }

    private let profileID = "2AD1811B-DB1C-4677-A2DC-083601B3941E"
    private let sourceRecordID = "freebmd_death_7b_1527_179857986"

    private func insertEvidence(_ dbPath: String) throws {
        let q = try DatabaseQueue(path: dbPath)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO evidence_records
                  (id, profile_id, source_id, source_record_id, record_type, verdict,
                   record_json, citation_full, citation_url, scored_at, user_status)
                VALUES (?, ?, 'freebmd', ?, 'death', 'lead', '{}',
                        'FreeBMD Death Index', 'https://www.freebmd.org.uk/x', ?, 'unreviewed')
                """, arguments: [
                    "\(profileID)|\(sourceRecordID)", profileID, sourceRecordID,
                    Date(timeIntervalSince1970: 1_000),
                ])
        }
    }

    private func noteRows(_ dbPath: String) async throws -> [String] {
        try await DatabaseQueue(path: dbPath).read { db in
            try String.fetchAll(db, sql: "SELECT id FROM workbench_notes ORDER BY id")
        }
    }

    // MARK: - The mapping

    @Test func theLegacyMappingIsDeterministicAndDocumented() {
        // 16 hex digits doubled to 32, uppercased, hyphenated 8-4-4-4-12 —
        // exactly what the app-side fallback derives from the same input.
        #expect(MCPHandler.noteUUIDString(fromLegacyID: "fr_00a1b2c3d4e5f607")
                == "00A1B2C3-D4E5-F607-00A1-B2C3D4E5F607")
        // Only the real legacy shape maps.
        #expect(MCPHandler.noteUUIDString(fromLegacyID: "lead_fr_1_2") == nil)
        #expect(MCPHandler.noteUUIDString(fromLegacyID: "fr_abc") == nil)
        #expect(MCPHandler.noteUUIDString(fromLegacyID: "fr_00a1b2c3d4e5g607") == nil)
    }

    // MARK: - The writer files app-readable ids

    /// THE regression: pre-fix, this id was `fr_<16hex>`, which
    /// `UUID(uuidString:)` rejects — so the mandatory discard reason was
    /// invisible to the one person it exists for.
    @Test func aRefusalReasonNoteIsFiledUnderAUUIDStringID() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath)
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": sourceRecordID,
            "reason": "Namesake — this is the Belper Sarah.",
        ])
        #expect(json.contains("reason_note_id"))

        let ids = try await noteRows(dbPath)
        #expect(ids.count == 1)
        #expect(UUID(uuidString: ids[0]) != nil,
                "the app's noteFromRow guards UUID(uuidString:) — a non-UUID id is silently dropped")
    }

    @Test func aDismissReasonNoteIsFiledUnderAUUIDStringID() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath)
        try await DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
                INSERT INTO leads (id, profile_id, name, source, status, evidence, created_at)
                VALUES (?, ?, 'Sarah A Gladwin', 'scoredLead', 'new', 'row', ?)
                """, arguments: ["lead_\(sourceRecordID)", profileID, Date()])
        }
        let handler = try MCPHandler(dbPath: dbPath)

        _ = try await handler.dismissLeadResponseText([
            "lead_id": "lead_\(sourceRecordID)", "reason": "Wrong district.",
        ])

        let ids = try await noteRows(dbPath)
        #expect(ids.count == 1)
        #expect(UUID(uuidString: ids[0]) != nil)
    }

    @Test func addWorkbenchNoteFilesAUUIDStringID() async throws {
        let dbPath = try makeDB()
        let handler = try MCPHandler(dbPath: dbPath)

        _ = try await handler.workbenchNoteText([
            "attachment_kind": "profile", "attachment_id": profileID,
            "content": "Check the 1891 Wirksworth household.", "tag": "todo",
        ])

        let ids = try await noteRows(dbPath)
        #expect(ids.count == 1)
        #expect(UUID(uuidString: ids[0]) != nil)
    }

    // MARK: - Replay dedup survives the id change

    @Test func replayingADiscardDoesNotStackASecondNote() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath)
        let handler = try MCPHandler(dbPath: dbPath)
        // Fresh dictionaries per call: a non-Sendable value cannot be sent
        // into the actor twice.
        func args() -> [String: Any] {
            [
                "profile_id": profileID,
                "source_record_id": sourceRecordID,
                "reason": "Namesake.",
            ]
        }

        _ = try await handler.discardScoredRecordResponseText(args())
        _ = try await handler.discardScoredRecordResponseText(args())

        let ids = try await noteRows(dbPath)
        #expect(ids.count == 1, "same content hash, same UUID — the replay must dedup")
    }

    /// A reason already on disk under the PRE-FIX `fr_…` id: the replay must
    /// recognise it and not stack a second, UUID-keyed copy.
    @Test func aReasonFiledUnderTheLegacyIDIsNotDuplicatedOnReplay() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath)
        let handler = try MCPHandler(dbPath: dbPath)
        let reason = "Namesake — this is the Belper Sarah."
        // The exact id the pre-fix writer used for this discard.
        let legacyID = await handler.idempotencyKey(
            profileID: profileID, field: "discard_reason",
            value: reason, sourceURL: sourceRecordID)
        #expect(legacyID.hasPrefix("fr_"))
        try await DatabaseQueue(path: dbPath).write { db in
            try db.execute(sql: """
                INSERT INTO workbench_notes
                (id, content, tag, attached_to, attachment_kind, attachment_id,
                 created_at, updated_at)
                VALUES (?, 'Discarded scored record x: old copy', 'meta',
                        ?, 'profile', ?, ?, ?)
                """, arguments: [
                    legacyID, #"{"profile":{"id":"\#(self.profileID)"}}"#,
                    profileID, Date(), Date(),
                ])
        }

        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": sourceRecordID,
            "reason": reason,
        ])
        #expect(json.contains("reason_recorded"))

        let ids = try await noteRows(dbPath)
        #expect(ids == [legacyID],
                "the legacy row already carries this reason — no second UUID-keyed row")
    }

    @Test func replayingAnAddWorkbenchNoteDoesNotDuplicate() async throws {
        let dbPath = try makeDB()
        let handler = try MCPHandler(dbPath: dbPath)
        func args() -> [String: Any] {
            [
                "attachment_kind": "profile", "attachment_id": profileID,
                "content": "Check the 1891 Wirksworth household.", "tag": "todo",
            ]
        }

        _ = try await handler.workbenchNoteText(args())
        _ = try await handler.workbenchNoteText(args())

        let ids = try await noteRows(dbPath)
        #expect(ids.count == 1)
    }
}
