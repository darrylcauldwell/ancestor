import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// #27 — `replaces_source_url` on submit_evidence. The idempotency key
/// includes source_url, so a resubmission that only repairs a wrong URL
/// (owner dogfood 2026-08-24: FamilySearch search-persona ark URLs 404 in a
/// browser) would mint a SECOND review card while the stale one sat in
/// Triage. Naming the wrong URL migrates the still-pending row in place;
/// rows the human already reviewed are never touched.
/// `submitEvidence` returns a non-Sendable `[String: Any]`; this
/// actor-isolated shim keeps the dictionary on the actor and hands the test
/// a Sendable summary.
private extension MCPHandler {
    func submitEvidenceText(_ args: [String: Any]) throws -> String {
        let result = try submitEvidence(args)
        let content = result["content"] as? [[String: Any]] ?? []
        return content.first?["text"] as? String ?? ""
    }
}

struct SubmitEvidenceURLCorrectionTests {

    private func makeDB() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("url-correct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE leads (id TEXT PRIMARY KEY, status TEXT, resolved_at DATETIME, resolution TEXT)")
            try db.execute(sql: "CREATE TABLE profiles (id TEXT PRIMARY KEY, first_name TEXT, last_name TEXT)")
            try db.execute(sql: "INSERT INTO profiles (id, first_name, last_name) VALUES ('P1','Ernest','Cauldwell')")
            try db.execute(sql: """
                CREATE TABLE pending_facts (
                    id TEXT PRIMARY KEY,
                    profile_id TEXT,
                    fact_kind TEXT,
                    value_json TEXT,
                    sources_json TEXT,
                    review_status TEXT,
                    created_at DATETIME,
                    source_url TEXT,
                    source_title TEXT,
                    evidence_text TEXT,
                    reasoning TEXT,
                    agent_id TEXT,
                    verification_status TEXT,
                    reviewed_at DATETIME
                )
                """)
        }
        return path
    }

    private func submit(_ handler: MCPHandler, url: String, replaces: String? = nil) async throws {
        var args: [String: Any] = [
            "profile_id": "P1", "field": "census",
            "value": "1901 census, Turnditch",
            "source_url": url, "source_title": "1901 census: John Cauldwell household",
            "evidence_text": "t", "reasoning": "t", "confidence": "high",
            "event_date": "1901",
        ]
        if let replaces { args["replaces_source_url"] = replaces }
        _ = try await handler.submitEvidenceText(args)
    }

    private func rows(_ path: String) throws -> [(url: String, status: String)] {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in
            try Row.fetchAll(
                db, sql: "SELECT source_url, review_status FROM pending_facts ORDER BY source_url")
                .map { ($0["source_url"] as String? ?? "", $0["review_status"] as String? ?? "") }
        }
    }

    private let dead = "https://www.familysearch.org/ark:/61903/1:1:p_10268848273"
    private let real = "https://www.familysearch.org/ark:/61903/1:1:XSJJ-LD6"

    @Test func correctedURLMigratesThePendingRowInPlace() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        try await submit(handler, url: dead)
        try await submit(handler, url: real, replaces: dead)
        let all = try rows(path)
        #expect(all.count == 1, "no duplicate review card")
        #expect(all.first?.url == real)
        #expect(all.first?.status == "pending")
    }

    @Test func reviewedRowsAreNeverTouched() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        try await submit(handler, url: dead)
        let queue = try DatabaseQueue(path: path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE pending_facts SET review_status = 'accepted'")
        }
        try await submit(handler, url: real, replaces: dead)
        let all = try rows(path)
        #expect(all.count == 2, "accepted row untouched; corrected card queued alongside")
        #expect(all.contains { $0.url == dead && $0.status == "accepted" })
        #expect(all.contains { $0.url == real && $0.status == "pending" })
    }

    @Test func correctionWhenFixedRowAlreadyExistsDropsTheStaleOne() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        try await submit(handler, url: dead)
        try await submit(handler, url: real)                 // corrected row exists already
        try await submit(handler, url: real, replaces: dead) // migration would collide → stale dropped
        let all = try rows(path)
        #expect(all.count == 1)
        #expect(all.first?.url == real)
    }

    @Test func replacesIsInertWhenNothingMatches() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        try await submit(handler, url: real, replaces: dead)
        let all = try rows(path)
        #expect(all.count == 1)
        #expect(all.first?.url == real)
    }
}
