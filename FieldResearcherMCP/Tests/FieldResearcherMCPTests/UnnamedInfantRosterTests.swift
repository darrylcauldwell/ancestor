import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// EV20 (2026-08-26) — the firewall's `name` guard, the sibling of EV28's
/// `relationship` guard on the adjacent line. A hand-searched census row for an
/// unnamed infant ("female, 0, daughter, no forename") was dropped on submit:
/// legitimate evidence, and the strongest missing-child signal a schedule
/// gives, deleted for lacking a field the schedule itself never carried.
///
/// A roster is EVIDENCE, so the row is stored. The guard that matters — you
/// cannot create a PROFILE from a nameless row — lives in
/// `CensusFamilyLinker.familyLinks` on the app side and is untouched.
///
/// `submitEvidence` returns a non-Sendable `[String: Any]`; this
/// actor-isolated shim keeps the dictionary on the actor. Named apart from the
/// shims in the other submit_evidence suites — one member per name on
/// `MCPHandler`.
private extension MCPHandler {
    func submitUnnamedInfantEvidenceText(_ args: [String: Any]) throws -> String {
        let result = try submitEvidence(args)
        let content = result["content"] as? [[String: Any]] ?? []
        return content.first?["text"] as? String ?? ""
    }
}

struct UnnamedInfantRosterTests {

    private func makeDB() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unnamed-infant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE leads (id TEXT PRIMARY KEY, status TEXT, resolved_at DATETIME, resolution TEXT)")
            try db.execute(sql: "CREATE TABLE profiles (id TEXT PRIMARY KEY, first_name TEXT, last_name TEXT)")
            try db.execute(sql: "INSERT INTO profiles (id, first_name, last_name) VALUES ('P1','William','Gladwin')")
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

    private func baseArgs(_ household: [[String: Any]]) -> [String: Any] {
        [
            "profile_id": "P1", "field": "census", "value": "1891 census, Chesterfield",
            "source_url": "https://example.org/1891", "source_title": "1891 census",
            "evidence_text": "t", "reasoning": "t", "confidence": "high",
            "event_date": "1891",
            "household": household,
        ]
    }

    private func storedHousehold(_ path: String) throws -> [[String: Any]] {
        let json = try DatabaseQueue(path: path).read { db in
            try String.fetchOne(db, sql: "SELECT sources_json FROM pending_facts") ?? "{}"
        }
        let payload = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return payload["household"] as? [[String: Any]] ?? []
    }

    @Test func submitEvidenceKeepsAnUnnamedInfantRow() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        let household: [[String: Any]] = [
            ["name": "William Gladwin", "relationship": "Head", "age": 34],
            ["name": "", "relationship": "Dau", "age": 0, "sex": "F"],
        ]
        let text = try await handler.submitUnnamedInfantEvidenceText(baseArgs(household))
        let stored = try storedHousehold(path)
        #expect(stored.count == 2, "an unnamed infant is a census row, not a malformed one")
        #expect(stored.last?["name"] as? String == "")
        #expect(stored.last?["relationship"] as? String == "Dau")
        #expect(stored.last?["age"] as? Int == 0)
        // Kept, but never silently: the submitter is told what the row can and
        // cannot become.
        #expect(text.contains("stored with no name"))
    }

    @Test func submitEvidenceStillRefusesARowThatSaysNothing() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        let household: [[String: Any]] = [
            ["name": "William Gladwin", "relationship": "Head", "age": 34],
            [String: Any](),
        ]
        let text = try await handler.submitUnnamedInfantEvidenceText(baseArgs(household))
        #expect(try storedHousehold(path).count == 1)
        #expect(text.contains("carried no information at all"))
    }

    /// A row with no name and no role but a real AGE still says something —
    /// "someone aged 0 was enumerated here" — so it is kept.
    @Test func aRowCarryingOnlyAnAgeIsStillEvidence() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        let household: [[String: Any]] = [
            ["name": "William Gladwin", "relationship": "Head", "age": 34],
            ["age": 0, "sex": "F"],
        ]
        _ = try await handler.submitUnnamedInfantEvidenceText(baseArgs(household))
        let stored = try storedHousehold(path)
        #expect(stored.count == 2)
        #expect(stored.last?["sex"] as? String == "F")
    }
}
