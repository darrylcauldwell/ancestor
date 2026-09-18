import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// EV33 follow-up (review C1) — `dismiss_lead` had no status guard: it
/// demoted a PROMOTED lead to `dismissed`, overwrote the
/// `promoted_to_<id>` resolution pointer with `'dismissed'`, and the EV33
/// cascade then buried the (possibly applied) evidence row as `discarded` —
/// dropping its Sources-ledger entry and putting the record into the
/// pipeline's permanent suppression set. All of it silent, all of it from a
/// replayed triage list. The opposite direction was already guarded
/// (`cascadeDismissLead` skips promoted/dismissed/resolved, pinned by
/// `discardLeavesAnAlreadySettledLeadAlone`); these tests pin the mirror
/// guard, the clean already-dismissed no-op, and applied_at warning parity
/// with `discard_scored_record`.
struct DismissLeadSettledGuardTests {

    /// Same fixture shape as `EvidenceLeadSyncTests` (they are file-private
    /// there): the tables the handler's schema-age check needs plus the three
    /// this tool touches, in their real column shapes.
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
    private var evidenceID: String { "\(profileID)|\(sourceRecordID)" }
    private var leadID: String { "lead_\(sourceRecordID)" }

    private func insertEvidence(
        _ dbPath: String, userStatus: String = "unreviewed", appliedAt: Date? = nil
    ) throws {
        let q = try DatabaseQueue(path: dbPath)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO evidence_records
                  (id, profile_id, source_id, source_record_id, record_type, verdict,
                   record_json, citation_full, citation_url, scored_at, user_status, applied_at)
                VALUES (?, ?, 'freebmd', ?, 'death', 'lead', '{"death":{"common":{"surname":"Gladwin"}}}',
                        'FreeBMD Death Index', 'https://www.freebmd.org.uk/x', ?, ?, ?)
                """, arguments: [
                    evidenceID, profileID, sourceRecordID,
                    Date(timeIntervalSince1970: 1_000), userStatus, appliedAt,
                ])
        }
    }

    private func insertLead(
        _ dbPath: String, status: String,
        resolution: String? = nil, resolvedAt: Date? = nil
    ) throws {
        let q = try DatabaseQueue(path: dbPath)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO leads
                  (id, profile_id, name, source, status, evidence, created_at,
                   resolved_at, resolution)
                VALUES (?, ?, 'Sarah A Gladwin', 'scoredLead', ?, 'FreeBMD death index row', ?, ?, ?)
                """, arguments: [leadID, profileID, status, Date(), resolvedAt, resolution])
        }
    }

    private func leadRow(_ dbPath: String) async throws -> (status: String?, resolution: String?, resolvedAt: Date?) {
        let q = try DatabaseQueue(path: dbPath)
        return try await q.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT status, resolution, resolved_at FROM leads WHERE id = ?",
                arguments: [self.leadID])
            return (row?["status"], row?["resolution"], row?["resolved_at"])
        }
    }

    // MARK: - The settled guard

    /// THE regression: a replayed triage list hits a lead the user has since
    /// promoted. The dismissal must not stomp the stronger, later decision —
    /// on either half.
    @Test func dismissingAPromotedLeadIsSkippedAndNamesItsStatus() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, userStatus: "saved_as_lead")
        try insertLead(dbPath, status: "promoted",
                       resolution: "promoted_to_NEW-PROFILE-ID",
                       resolvedAt: Date(timeIntervalSince1970: 2_000))
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.dismissLeadResponseText(["lead_id": leadID])

        #expect(json.contains("skipped"))
        #expect(json.contains("promoted"), "the response must name the lead's actual status")
        let lead = try await leadRow(dbPath)
        #expect(lead.status == "promoted", "a promoted lead must not be demoted")
        #expect(lead.resolution == "promoted_to_NEW-PROFILE-ID",
                "the pointer to the profile the promotion created must survive")
        // The cascade must NOT have run: the user's saved_as_lead verdict
        // stands, and the record must not enter the permanent suppression set.
        let state = try await handler.evidenceRowState(evidenceRecordID: evidenceID)
        #expect(state["user_status"] == "saved_as_lead")
    }

    @Test func dismissingAResolvedLeadIsSkipped() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath)
        try insertLead(dbPath, status: "resolved", resolution: "resolved")
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.dismissLeadResponseText(["lead_id": leadID])

        #expect(json.contains("skipped"))
        #expect(json.contains("resolved"))
        let lead = try await leadRow(dbPath)
        #expect(lead.status == "resolved")
        let state = try await handler.evidenceRowState(evidenceRecordID: evidenceID)
        #expect(state["user_status"] == "unreviewed", "the cascade must not run on a skip")
    }

    /// A skip writes nothing at all — including the optional reason note.
    @Test func aSkippedDismissalFilesNoReasonNote() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath)
        try insertLead(dbPath, status: "promoted", resolution: "promoted_to_X")
        let handler = try MCPHandler(dbPath: dbPath)

        _ = try await handler.dismissLeadResponseText([
            "lead_id": leadID, "reason": "Wrong registration district.",
        ])

        let count = try await DatabaseQueue(path: dbPath).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workbench_notes") ?? -1
        }
        #expect(count == 0, "a refusal that did nothing must not file a refusal reason")
    }

    // MARK: - Already-dismissed: clean no-op on the lead, cascade still repairs

    @Test func redismissingADismissedLeadDoesNotRestampItButStillRepairsTheEvidenceHalf() async throws {
        let dbPath = try makeDB()
        // The EV33 drift, inverted in time: the lead was dismissed long ago,
        // the evidence row never followed.
        let originalStamp = Date(timeIntervalSince1970: 2_000)
        try insertEvidence(dbPath, userStatus: "unreviewed")
        try insertLead(dbPath, status: "dismissed",
                       resolution: "dismissed", resolvedAt: originalStamp)
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.dismissLeadResponseText(["lead_id": leadID])

        #expect(json.contains("already_dismissed"))
        let lead = try await leadRow(dbPath)
        #expect(lead.status == "dismissed")
        // The original stamp records WHEN the human decided — not re-stamped.
        let stamp = try #require(lead.resolvedAt)
        #expect(abs(stamp.timeIntervalSince1970 - originalStamp.timeIntervalSince1970) < 1,
                "a replay must not overwrite the original dismissal time")
        // The cascade still runs: repairing the divergence is what EV33 is for.
        let state = try await handler.evidenceRowState(evidenceRecordID: evidenceID)
        #expect(state["user_status"] == "discarded")
    }

    // MARK: - applied_at parity with discard_scored_record

    @Test func dismissingALeadWhoseRecordWasAppliedWarnsLoudly() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath, appliedAt: Date(timeIntervalSince1970: 5_000))
        try insertLead(dbPath, status: "new")
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.dismissLeadResponseText(["lead_id": leadID])

        #expect(json.contains("applied_at"))
        #expect(json.contains("warning"),
                "burying an applied record must never be silent — parity with discard_scored_record")
        // applied_at is the app's to clear, never this tool's.
        let stamp = try await DatabaseQueue(path: dbPath).read { db in
            try Date.fetchOne(
                db, sql: "SELECT applied_at FROM evidence_records WHERE id = ?",
                arguments: [self.evidenceID])
        }
        #expect(stamp != nil)
    }

    @Test func dismissingAnUnappliedLeadCarriesNoWarning() async throws {
        let dbPath = try makeDB()
        try insertEvidence(dbPath)
        try insertLead(dbPath, status: "new")
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.dismissLeadResponseText(["lead_id": leadID])

        #expect(!json.contains("warning"), "the warning must fire only when applied_at is set")
        let state = try await handler.evidenceRowState(evidenceRecordID: evidenceID)
        #expect(state["user_status"] == "discarded")
    }
}
