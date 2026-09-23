import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

private extension MCPHandler {
    func resubmitText(_ args: [String: Any]) throws -> String {
        let content = try submitRelationshipProposal(args)["content"] as? [[String: Any]] ?? []
        return content.first?["text"] as? String ?? ""
    }
}

/// M10 (pre-SC-34-40 review) — the #36 marriage columns are not part of the
/// proposal's idempotency key (from|to + rel_type + role + source_url), and
/// the write was `INSERT OR IGNORE`: a resubmission carrying corrected
/// marriage details silently no-opped while the response interpolated the NEW
/// details and claimed "Status: pending human review". Approve would then
/// fill the stale values onto the edge. Worse with reject: the row survives
/// under the same id, so a rejected proposal could never be resubmitted at
/// all — yet the response still reported it as submitted.
///
/// The fix mirrors the 2026-08-14 pending_facts upsert: a still-pending row
/// is refreshed from the resubmission; a reviewed row is never overturned —
/// and the response says which happened. Never claim success for a write that
/// did not run.
struct SubmitRelationshipProposalResubmitTests {

    private func makeDB() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proposal-resubmit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE leads (id TEXT PRIMARY KEY, status TEXT, resolved_at DATETIME, resolution TEXT)")
            try db.execute(sql: "CREATE TABLE profiles (id TEXT PRIMARY KEY, first_name TEXT, last_name TEXT)")
            try db.execute(sql: "INSERT INTO profiles (id, first_name, last_name) VALUES ('P1','James','Beresford')")
            try db.execute(sql: "INSERT INTO profiles (id, first_name, last_name) VALUES ('P2','Elizabeth Ann','Crawshaw')")
            try db.execute(sql: """
                CREATE TABLE relationships (
                    id TEXT PRIMARY KEY, from_id TEXT, to_id TEXT, type TEXT, role TEXT)
                """)
            try db.execute(sql: """
                CREATE TABLE pending_relationships (
                    id TEXT PRIMARY KEY, from_profile_id TEXT, to_profile_id TEXT,
                    rel_type TEXT, role TEXT, subtype TEXT, review_status TEXT,
                    created_at DATETIME, source_url TEXT, source_title TEXT,
                    evidence_text TEXT, reasoning TEXT, agent_id TEXT,
                    marriage_date TEXT, marriage_location TEXT)
                """)
        }
        return path
    }

    private func spouseArgs(
        marriageDate: String? = nil, marriageLocation: String? = nil,
        evidence: String = "GRO index row", reasoning: String = "match on both names"
    ) -> [String: Any] {
        var args: [String: Any] = [
            "from_profile_id": "P1", "to_profile_id": "P2", "rel_type": "spouse",
            "source_url": "https://www.freebmd.org.uk/x",
            "source_title": "GRO marriage index 9c/313",
            "evidence_text": evidence, "reasoning": reasoning,
        ]
        if let marriageDate { args["marriage_date"] = marriageDate }
        if let marriageLocation { args["marriage_location"] = marriageLocation }
        return args
    }

    /// Columns are read out INSIDE the read: GRDB's `Row` is not Sendable, so
    /// returning one from the closure is a concurrency error.
    private func pendingRow(_ path: String) async throws -> [String: String]? {
        try await DatabaseQueue(path: path).read { db -> [String: String]? in
            try Row.fetchOne(db, sql: "SELECT * FROM pending_relationships").map { r in
                ["review_status": r["review_status"] as String? ?? "",
                 "evidence_text": r["evidence_text"] as String? ?? "",
                 "marriage_date": r["marriage_date"] as String? ?? "",
                 "marriage_location": r["marriage_location"] as String? ?? ""]
            }
        }
    }

    private func rowCount(_ path: String) async throws -> Int {
        try await DatabaseQueue(path: path).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_relationships") ?? -1
        }
    }

    private func setReviewStatus(_ path: String, to status: String) async throws {
        try await DatabaseQueue(path: path).write { db in
            try db.execute(
                sql: "UPDATE pending_relationships SET review_status = ?", arguments: [status])
        }
    }

    @Test func aFirstSubmissionStillReportsSubmitted() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)

        let text = try await handler.resubmitText(spouseArgs(marriageDate: "Jun 1880"))

        #expect(text.contains("Relationship proposal submitted"))
        #expect(text.contains("pending human review"))
        #expect(try await rowCount(path) == 1)
    }

    /// THE regression: resubmit with a corrected marriage date — the stored
    /// row must carry the correction, not the stale original.
    @Test func resubmittingWithCorrectedMarriageDetailsUpdatesThePendingRow() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        _ = try await handler.resubmitText(spouseArgs(marriageDate: "Jun 1880"))

        let text = try await handler.resubmitText(spouseArgs(
            marriageDate: "Jun 1881",
            marriageLocation: "Ecclesall Bierlow, Sheffield",
            evidence: "GRO index row, corrected quarter"))

        let row = try #require(try await pendingRow(path))
        #expect(row["marriage_date"] == "Jun 1881",
                "the corrected date must land — Approve fills whatever is stored onto the edge")
        #expect(row["marriage_location"] == "Ecclesall Bierlow, Sheffield")
        #expect(row["evidence_text"] == "GRO index row, corrected quarter")
        #expect(row["review_status"] == "pending")
        #expect(try await rowCount(path) == 1, "refreshed in place, never duplicated")
        // And the response says an UPDATE happened, not a fresh submission.
        #expect(text.contains("already pending"))
        #expect(text.contains("UPDATED"))
    }

    /// Check before overwrite: a resubmission that omits the marriage fields
    /// must not erase previously supplied ones.
    @Test func aResubmissionOmittingMarriageFieldsKeepsTheStoredOnes() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        _ = try await handler.resubmitText(spouseArgs(
            marriageDate: "Jun 1880", marriageLocation: "Sheffield"))

        _ = try await handler.resubmitText(spouseArgs(evidence: "wording tweak only"))

        let row = try #require(try await pendingRow(path))
        #expect(row["marriage_date"] == "Jun 1880")
        #expect(row["marriage_location"] == "Sheffield")
        #expect(row["evidence_text"] == "wording tweak only")
    }

    @Test func resubmittingARejectedProposalSaysSoAndChangesNothing() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        _ = try await handler.resubmitText(spouseArgs(marriageDate: "Jun 1880"))
        try await setReviewStatus(path, to: "rejected")

        let text = try await handler.resubmitText(spouseArgs(marriageDate: "Jun 1881"))

        #expect(text.contains("NOT SUBMITTED"))
        #expect(text.contains("rejected"))
        #expect(!text.contains("Status: pending human review"),
                "never claim a rejected proposal is pending again")
        let row = try #require(try await pendingRow(path))
        #expect(row["review_status"] == "rejected", "the human ruling stands")
        #expect(row["marriage_date"] == "Jun 1880", "nothing was changed")
    }

    @Test func resubmittingAnApprovedProposalSaysSoAndChangesNothing() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        _ = try await handler.resubmitText(spouseArgs(marriageDate: "Jun 1880"))
        try await setReviewStatus(path, to: "approved")

        let text = try await handler.resubmitText(spouseArgs(marriageDate: "Jun 1881"))

        #expect(text.contains("NOT SUBMITTED"))
        #expect(text.contains("approved"))
        let row = try #require(try await pendingRow(path))
        #expect(row["review_status"] == "approved")
        #expect(row["marriage_date"] == "Jun 1880")
    }

    /// A DIFFERENT source URL is genuinely new evidence — it keys a separate
    /// proposal, exactly as before.
    @Test func aDifferentSourceURLStillCreatesASecondProposal() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        _ = try await handler.resubmitText(spouseArgs(marriageDate: "Jun 1880"))

        var other = spouseArgs(marriageDate: "Jun 1880")
        other["source_url"] = "https://www.freebmd.org.uk/other-page"
        let text = try await handler.resubmitText(other)

        #expect(text.contains("Relationship proposal submitted"))
        #expect(try await rowCount(path) == 2)
    }
}
