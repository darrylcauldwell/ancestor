import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// EV33 (2026-08-26) — a research finding lives as TWO rows (a `leads`
/// suggestion and a scored `evidence_records` row) and nothing kept them in
/// step. Proven live 2026-08-25: 99 leads dismissed over MCP, every matching
/// evidence record still `user_status = 'unreviewed'`, so not one profile card
/// moved. These tests pin both directions of the repair:
///
///   * `discard_scored_record` (new) — refuse a scored record, cascade to the
///     lead;
///   * `dismiss_lead` — dismiss a lead, cascade to the scored record.
///
/// The load-bearing invariant throughout: `user_status` ONLY. `verdict` is
/// scorer-owned — re-stomped on every run, with only `user_status`
/// surviving one — and must never move.
struct EvidenceLeadSyncTests {

    /// The tables the handler's schema-age check needs, plus the three this
    /// pair of tools touches, in their real column shapes.
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
            // Mirrors the real DDL (ProjectDatabase.swift v-init + the v11
            // `sensitive` migration). `sensitive` matters: it is NOT NULL and
            // the refusal-note INSERT does not name it, so only a fixture
            // carrying the column proves the INSERT relies on a real DEFAULT
            // rather than on the column being absent (EV33, 2026-08-26).
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

    /// The real pair from the 2026-08-25 session: Sarah A Gladwin's FreeBMD
    /// death index row and the lead that mirrors it.
    private let profileID = "2AD1811B-DB1C-4677-A2DC-083601B3941E"
    private let sourceRecordID = "freebmd_death_7b_1527_179857986"
    private var evidenceID: String { "\(profileID)|\(sourceRecordID)" }
    private var leadID: String { "lead_\(sourceRecordID)" }

    private func insertEvidence(
        _ dbPath: String, sourceRecordID: String, verdict: String = "lead",
        userStatus: String = "unreviewed", appliedAt: Date? = nil
    ) throws {
        let q = try DatabaseQueue(path: dbPath)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO evidence_records
                  (id, profile_id, source_id, source_record_id, record_type, verdict,
                   record_json, citation_full, citation_url, scored_at, user_status, applied_at)
                VALUES (?, ?, 'freebmd', ?, 'death', ?, '{"death":{"common":{"surname":"Gladwin"}}}',
                        'FreeBMD Death Index', 'https://www.freebmd.org.uk/x', ?, ?, ?)
                """, arguments: [
                    "\(profileID)|\(sourceRecordID)", profileID, sourceRecordID, verdict,
                    Date(timeIntervalSince1970: 1_000), userStatus, appliedAt,
                ])
        }
    }

    private func insertLead(_ dbPath: String, id: String, status: String = "new") throws {
        let q = try DatabaseQueue(path: dbPath)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO leads (id, profile_id, name, source, status, evidence, created_at)
                VALUES (?, ?, 'Sarah A Gladwin', 'scoredLead', ?, 'FreeBMD death index row', ?)
                """, arguments: [id, profileID, status, Date()])
        }
    }

    // MARK: - discard_scored_record

    @Test func discardSetsUserStatusAndLeavesVerdictUntouched() async throws {
        let dbPath = try makeDB()
        // verdict 'fact' on purpose: the scorer over-accepting a namesake is
        // precisely the case a human discard exists for.
        try insertEvidence(dbPath, sourceRecordID: sourceRecordID, verdict: "fact")
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": sourceRecordID,
            "reason": "Namesake — this is the Belper Sarah; ours is alive in the 1891 census.",
        ])
        #expect(json.contains("\"status\""))
        #expect(json.contains("discarded"))
        #expect(!json.contains("refused"))

        let state = try await handler.evidenceRowState(evidenceRecordID: evidenceID)
        #expect(state["user_status"] == "discarded")
        // The deterministic sandwich still owns the verdict.
        #expect(state["verdict"] == "fact")
    }

    @Test func discardAcceptsCompositeEvidenceRecordIDHandle() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, sourceRecordID: sourceRecordID)
        let handler = try MCPHandler(dbPath: dbPath)

        _ = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": evidenceID,   // the composite handle
            "reason": "Wrong district.",
        ])
        let state = try await handler.evidenceRowState(evidenceRecordID: evidenceID)
        #expect(state["user_status"] == "discarded")
    }

    @Test func discardCascadesToMatchingLead() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, sourceRecordID: sourceRecordID)
        try insertLead(dbPath, id: leadID)
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": sourceRecordID,
            "reason": "Namesake.",
        ])
        #expect(json.contains(leadID))
        #expect(try await handler.leadStatus(leadID: leadID) == "dismissed")
    }

    @Test func discardLeavesAnAlreadySettledLeadAlone() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, sourceRecordID: sourceRecordID)
        try insertLead(dbPath, id: leadID, status: "promoted")
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": sourceRecordID,
            "reason": "Namesake.",
        ])
        #expect(json.contains("already_resolved"))
        // A promoted lead must not be reopened or restamped by a later
        // discard on the evidence side.
        #expect(try await handler.leadStatus(leadID: leadID) == "promoted")
    }

    @Test func discardRefusesEmptyReason() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, sourceRecordID: sourceRecordID)
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": sourceRecordID,
            "reason": "",
        ])
        #expect(json.contains("refused"))
        #expect(json.contains("missing_reason"))
        let state = try await handler.evidenceRowState(evidenceRecordID: evidenceID)
        #expect(state["user_status"] == "unreviewed")
    }

    @Test func discardRefusesWhitespaceOnlyReason() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, sourceRecordID: sourceRecordID)
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": sourceRecordID,
            "reason": "   \n\t  ",
        ])
        #expect(json.contains("refused"))
        #expect(json.contains("missing_reason"))
        let state = try await handler.evidenceRowState(evidenceRecordID: evidenceID)
        #expect(state["user_status"] == "unreviewed")
    }

    @Test func discardRefusesUnknownRecordWithAClearMessage() async throws {
        let dbPath = try makeDB()
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": "freebmd_death_never_scored",
            "reason": "Namesake.",
        ])
        #expect(json.contains("refused"))
        #expect(json.contains("record_not_found"))
        #expect(json.contains("get_scored_records"))
    }

    @Test func discardRefusesARecordBelongingToAnotherProfile() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, sourceRecordID: sourceRecordID)
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": "SOME-OTHER-PROFILE",
            "source_record_id": sourceRecordID,
            "reason": "Namesake.",
        ])
        #expect(json.contains("record_not_found"))
        let state = try await handler.evidenceRowState(evidenceRecordID: evidenceID)
        #expect(state["user_status"] == "unreviewed")
    }

    @Test func discardIsIdempotentAndSaysSoWhenAlreadyDiscarded() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, sourceRecordID: sourceRecordID, userStatus: "discarded")
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": sourceRecordID,
            "reason": "Namesake.",
        ])
        #expect(json.contains("already_discarded"))
        #expect(!json.contains("refused"))
        let state = try await handler.evidenceRowState(evidenceRecordID: evidenceID)
        #expect(state["user_status"] == "discarded")
    }

    @Test func discardOfAnAppliedRecordWarnsThatTheFactIsStillOnTheProfile() async throws {
        let dbPath = try makeDB()
        try insertEvidence(
            dbPath, sourceRecordID: sourceRecordID, verdict: "fact",
            appliedAt: Date(timeIntervalSince1970: 5_000))
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": sourceRecordID,
            "reason": "Namesake — applied in error.",
        ])
        #expect(json.contains("applied_at"))
        #expect(json.contains("warning"))
        // applied_at is the app's to clear, never this tool's.
        let q = try DatabaseQueue(path: dbPath)
        let stamp = try await q.read { db in
            try Date.fetchOne(
                db, sql: "SELECT applied_at FROM evidence_records WHERE id = ?",
                arguments: [evidenceID])
        }
        #expect(stamp != nil)
    }

    @Test func discardFilesTheReasonAsAWorkbenchNote() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, sourceRecordID: sourceRecordID)
        let handler = try MCPHandler(dbPath: dbPath)

        let reason = "Namesake — this is the Belper Sarah."
        let json = try await handler.discardScoredRecordResponseText([
            "profile_id": profileID,
            "source_record_id": sourceRecordID,
            "reason": reason,
        ])
        #expect(json.contains("reason_note_id"))

        let q = try DatabaseQueue(path: dbPath)
        let notes = try await q.read { db in
            try Row.fetchAll(db, sql: "SELECT content, tag, attachment_id FROM workbench_notes")
                .map { row -> [String: String] in
                    [
                        "content": row["content"] as String? ?? "",
                        "tag": row["tag"] as String? ?? "",
                        "attachment_id": row["attachment_id"] as String? ?? "",
                    ]
                }
        }
        #expect(notes.count == 1)
        let note = notes.first ?? [:]
        #expect(note["content", default: ""].contains(reason))
        // Was `discard` — not a NoteTag case, so the app dropped the note on
        // read. See `refusalNoteTagIsDecodableByTheApp` (EV33, 2026-08-26).
        #expect(note["tag"] == "meta")
        #expect(note["attachment_id"] == profileID)
    }

    // MARK: - dismiss_lead cascade

    @Test func dismissLeadCascadesToItsScoredRecord() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, sourceRecordID: sourceRecordID)
        try insertLead(dbPath, id: leadID)
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.dismissLeadResponseText(["lead_id": leadID])
        #expect(json.contains("dismissed"))
        #expect(json.contains(evidenceID))

        #expect(try await handler.leadStatus(leadID: leadID) == "dismissed")
        // The half the user can actually see on the profile card.
        let state = try await handler.evidenceRowState(evidenceRecordID: evidenceID)
        #expect(state["user_status"] == "discarded")
        #expect(state["verdict"] == "lead")
    }

    @Test func dismissHouseholdLeadTouchesNoEvidence() async throws {
        let dbPath = try makeDB()
        let hhLead = "lead_hh_wirksworth_1891"
        try insertLead(dbPath, id: hhLead)
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.dismissLeadResponseText(["lead_id": hhLead])
        #expect(json.contains("not_applicable"))
        #expect(!json.contains("refused"))
        #expect(try await handler.leadStatus(leadID: hhLead) == "dismissed")
    }

    @Test func dismissParentInferredLeadTouchesNoEvidence() async throws {
        let dbPath = try makeDB()
        let inferredLead = "lead_parentInferred_hyp-42"
        try insertLead(dbPath, id: inferredLead)
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.dismissLeadResponseText(["lead_id": inferredLead])
        #expect(json.contains("not_applicable"))
        #expect(!json.contains("refused"))
        #expect(try await handler.leadStatus(leadID: inferredLead) == "dismissed")
    }

    @Test func dismissFieldResearcherLeadTouchesNoEvidence() async throws {
        let dbPath = try makeDB()
        let frLead = "lead_fr_123456_1700000000.0"
        try insertLead(dbPath, id: frLead)
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.dismissLeadResponseText(["lead_id": frLead])
        #expect(json.contains("not_applicable"))
        #expect(!json.contains("refused"))
        #expect(try await handler.leadStatus(leadID: frLead) == "dismissed")
    }

    @Test func dismissLeadWithNoScoredRecordStillDismisses() async throws {
        let dbPath = try makeDB()
        // Follows the 'lead_' + source_record_id convention but the evidence
        // row was pruned — dismiss, report the miss, do not error.
        try insertLead(dbPath, id: leadID)
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.dismissLeadResponseText(["lead_id": leadID])
        #expect(json.contains("no_matching_record"))
        #expect(try await handler.leadStatus(leadID: leadID) == "dismissed")
    }

    @Test func dismissUnknownLeadReportsItRatherThanErroring() async throws {
        let dbPath = try makeDB()
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.dismissLeadResponseText(["lead_id": "lead_never_existed"])
        #expect(json.contains("lead_found"))
        #expect(json.contains("false"))
    }

    @Test func dismissLeadRecordsAnOptionalReason() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, sourceRecordID: sourceRecordID)
        try insertLead(dbPath, id: leadID)
        let handler = try MCPHandler(dbPath: dbPath)

        _ = try await handler.dismissLeadResponseText([
            "lead_id": leadID, "reason": "Wrong registration district.",
        ])
        let q = try DatabaseQueue(path: dbPath)
        let count = try await q.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workbench_notes") ?? 0
        }
        #expect(count == 1)
    }

    // MARK: - Lead-id convention

    @Test func sourceRecordIDDerivationFollowsTheLeadPrefixConvention() {
        #expect(MCPHandler.sourceRecordID(forLeadID: "lead_freebmd_death_7b_1527_179857986")
                == "freebmd_death_7b_1527_179857986")
        #expect(MCPHandler.sourceRecordID(forLeadID: "lead_hh_x_1891") == nil)
        #expect(MCPHandler.sourceRecordID(forLeadID: "lead_parentInferred_h1") == nil)
        #expect(MCPHandler.sourceRecordID(forLeadID: "lead_fr_1_2") == nil)
        #expect(MCPHandler.sourceRecordID(forLeadID: "lead_") == nil)
        #expect(MCPHandler.sourceRecordID(forLeadID: "not-a-lead-id") == nil)
    }

    // MARK: - Cross-package coupling

    /// EV33 verification (2026-08-26). This package depends on GRDB only, so
    /// nothing makes the compiler check that the refusal note's tag is a real
    /// `NoteTag`. It shipped as `'discard'`, which is not a case — and the
    /// app's `noteFromRow` guards `NoteTag(rawValue:)` and returns nil on a
    /// miss, so it silently dropped every refusal reason from the Workbench
    /// while MCP's own raw-SQL reader still showed it. The reason was
    /// invisible to the only person it is written for.
    ///
    /// The literal below is copied from
    /// `AncestorKit/Sources/AncestorKit/Workbench/WorkbenchNote.swift`. If a
    /// case is ever renamed there, this fails and points at the coupling
    /// instead of letting notes go quietly missing again.
    @Test func refusalNoteTagIsDecodableByTheApp() {
        let noteTagCases = ["observation", "todo", "insight", "sourceLog", "meta"]
        #expect(noteTagCases.contains(MCPHandler.refusalNoteTag))
        #expect(MCPHandler.validNoteTags == Set(noteTagCases))
    }

    /// EV33 verification (2026-08-26). `NoteAttachment` is an enum with
    /// associated values and synthesised `Codable`, so Swift keys the JSON
    /// object by CASE NAME: `{"profile":{"id":"…"}}`. This shipped emitting
    /// `{"kind":"profile","id":"…"}`, which `JSONDecoder` cannot turn back
    /// into a `NoteAttachment` — and `noteFromRow` swallows that with `try?`,
    /// so the note simply disappeared from the app.
    ///
    /// The expected strings below were produced by encoding the real enum
    /// with `JSONEncoder`, not read off the declaration. The app-side
    /// counterpart (`anMCPRefusalReasonNoteIsReadableInTheApp`) proves the
    /// round trip against a real migrated database.
    @Test func noteAttachmentJSONMatchesTheAppsEnumEncoding() {
        #expect(MCPHandler.noteAttachmentJSON(id: "ABC-123")
                == #"{"profile":{"id":"ABC-123"}}"#)
        #expect(MCPHandler.noteAttachmentJSON(kind: "relationship", id: "R-9")
                == #"{"relationship":{"id":"R-9"}}"#)
        // The old shape, pinned as WRONG so it cannot quietly return.
        #expect(!MCPHandler.noteAttachmentJSON(id: "ABC-123").contains(#""kind""#))
    }
}
