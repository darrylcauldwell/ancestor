import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// EV24 — filed as "the firewall cannot carry a marriage fact", REFUTED: it
/// carries one on `submit_relationship_proposal`, which has structured
/// `marriage_date`/`marriage_location` columns and an approve path that fills
/// them onto the spouse edge. `submit_evidence` excludes marriage
/// deliberately — `pending_facts` has nowhere to land it, and it was accepted
/// there for months while doing nothing on accept.
///
/// The real residual was the refusal MESSAGE: it named
/// `submit_narrative_finding` / `submit_lead`, and both DROP the date and the
/// place. These tests pin the routing and the refutation.
private extension MCPHandler {
    func refusalText(_ args: [String: Any]) throws -> String {
        let content = try submitEvidence(args)["content"] as? [[String: Any]] ?? []
        return content.first?["text"] as? String ?? ""
    }

    func proposalText(_ args: [String: Any]) throws -> String {
        let content = try submitRelationshipProposal(args)["content"] as? [[String: Any]] ?? []
        return content.first?["text"] as? String ?? ""
    }
}

struct SubmitEvidenceMarriageRoutingTests {

    private func makeDB() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marriage-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE leads (id TEXT PRIMARY KEY, status TEXT, resolved_at DATETIME, resolution TEXT)")
            try db.execute(sql: "CREATE TABLE profiles (id TEXT PRIMARY KEY, first_name TEXT, last_name TEXT)")
            try db.execute(sql: "INSERT INTO profiles (id, first_name, last_name) VALUES ('P1','James','Beresford')")
            try db.execute(sql: "INSERT INTO profiles (id, first_name, last_name) VALUES ('P2','Elizabeth Ann','Crawshaw')")
            try db.execute(sql: """
                CREATE TABLE pending_facts (
                    id TEXT PRIMARY KEY, profile_id TEXT, fact_kind TEXT,
                    value_json TEXT, sources_json TEXT, review_status TEXT,
                    created_at DATETIME, source_url TEXT, source_title TEXT,
                    evidence_text TEXT, reasoning TEXT, agent_id TEXT,
                    verification_status TEXT, reviewed_at DATETIME)
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

    private func evidenceArgs(field: String) -> [String: Any] {
        [
            "profile_id": "P1", "field": field, "value": "Jun 1880",
            "source_url": "https://www.freebmd.org.uk/x", "source_title": "t",
            "evidence_text": "t", "reasoning": "t", "confidence": "high",
        ]
    }

    private func pendingFactCount(_ path: String) throws -> Int {
        try DatabaseQueue(path: path).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_facts") ?? -1
        }
    }

    @Test func aMarriageSubmissionIsRoutedToTheRelationshipProposal() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        for field in ["marriage", "marriageDate", "marriageLocation"] {
            let text = try await handler.refusalText(evidenceArgs(field: field))
            #expect(text.contains("submit_relationship_proposal"))
            #expect(text.contains("marriage_date"))
            #expect(!text.contains("submit_narrative_finding"),
                    "prose loses the date and the place — that is how a marriage becomes unusable")
        }
        #expect(try pendingFactCount(path) == 0, "a refusal writes nothing")
    }

    @Test func anUnrelatedUnsupportedFieldKeepsItsOriginalRouting() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        let text = try await handler.refusalText(evidenceArgs(field: "favouriteColour"))
        #expect(text.contains("submit_narrative_finding"))
        #expect(!text.contains("submit_relationship_proposal"),
                "the marriage branch must not swallow every refusal")
    }

    /// The regression pin for the refutation itself: the tool the message
    /// names really does carry the date and the place, structurally.
    @Test func theRoutedMarriageActuallyLandsInPendingRelationships() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        _ = try await handler.proposalText([
            "from_profile_id": "P1", "to_profile_id": "P2", "rel_type": "spouse",
            "marriage_date": "Jun 1880",
            "marriage_location": "Ecclesall Bierlow, Sheffield",
            "source_url": "https://www.freebmd.org.uk/x",
            "source_title": "GRO marriage index 9c/313",
            "evidence_text": "t", "reasoning": "t",
        ])
        let row = try DatabaseQueue(path: path).read { db in
            try Row.fetchOne(db, sql: """
                SELECT rel_type, review_status, marriage_date, marriage_location
                FROM pending_relationships
                """)
        }
        let found = try #require(row)
        #expect(found["marriage_date"] as String? == "Jun 1880")
        #expect(found["marriage_location"] as String? == "Ecclesall Bierlow, Sheffield")
        #expect(found["rel_type"] as String? == "spouse")
        #expect(found["review_status"] as String? == "pending")
    }
}
