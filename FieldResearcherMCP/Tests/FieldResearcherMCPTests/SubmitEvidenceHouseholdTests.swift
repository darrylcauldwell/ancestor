import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// EV28 — an 1841 census roster (no relationship column, so every member
/// arrives with `relationship: ""`) was silently discarded IN FULL: the
/// members were compactMap'd away, the `household` key was never written to
/// `sources_json`, and the tool still answered "Evidence submitted". Empty is
/// the correct value for 1841.
///
/// EV20 (2026-08-26) then narrowed what "carries no identity" means. This file
/// originally said only a NAMELESS row carried none; that was wrong. An
/// unnamed infant ("female, 0, daughter") is a real schedule row and the
/// strongest missing-child signal a census gives, so it is STORED as evidence
/// and reported. The guard that matters — you cannot create a PROFILE from a
/// nameless row — lives in `CensusFamilyLinker.familyLinks` and in the
/// discovery extractor, not here. Only a row carrying nothing at all is
/// dropped.
/// `submitEvidence` returns a non-Sendable `[String: Any]`; this
/// actor-isolated shim keeps the dictionary on the actor. Named apart from
/// `submitEvidenceText` in SubmitEvidenceURLCorrectionTests — one member per
/// name on `MCPHandler`.
private extension MCPHandler {
    func submitHouseholdEvidenceText(_ args: [String: Any]) throws -> String {
        let result = try submitEvidence(args)
        let content = result["content"] as? [[String: Any]] ?? []
        return content.first?["text"] as? String ?? ""
    }
}

struct SubmitEvidenceHouseholdTests {

    private func makeDB() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("household-\(UUID().uuidString)", isDirectory: true)
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

    private func baseArgs(_ household: Any?) -> [String: Any] {
        var args: [String: Any] = [
            "profile_id": "P1", "field": "census", "value": "1841 census, Turnditch",
            "source_url": "https://example.org/1841", "source_title": "1841 census",
            "evidence_text": "t", "reasoning": "t", "confidence": "high",
            "event_date": "1841",
        ]
        if let household { args["household"] = household }
        return args
    }

    private func storedHousehold(_ path: String) throws -> [[String: Any]] {
        let json = try DatabaseQueue(path: path).read { db in
            try String.fetchOne(db, sql: "SELECT sources_json FROM pending_facts") ?? "{}"
        }
        let payload = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return payload["household"] as? [[String: Any]] ?? []
    }

    @Test func rosterWithEmptyRelationshipIsWritten() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        let text = try await handler.submitHouseholdEvidenceText(baseArgs([
            ["name": "John Cauldwell", "relationship": "", "age": 40],
            ["name": "Ann Cauldwell", "relationship": "", "age": 35],
        ]))
        let household = try storedHousehold(path)
        #expect(household.count == 2, "1841 roster must survive — empty relationship is correct")
        #expect(household.allSatisfy { ($0["relationship"] as? String) == "" })
        #expect(!text.contains("ROSTER WARNING"), "nothing was dropped")
    }

    /// EV20 — the unnamed infant is KEPT. It is evidence that a child existed
    /// in that dwelling at that age, which is precisely the signal a missing
    /// sibling leaves; dropping it threw away the reason to go looking.
    @Test func namelessRowIsKeptAndReported() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        let text = try await handler.submitHouseholdEvidenceText(baseArgs([
            ["name": "John Cauldwell", "relationship": "Head"],
            ["relationship": "Dau"],
        ]))
        #expect(try storedHousehold(path).count == 2, "an unnamed infant is a roster member")
        #expect(text.contains("ROSTER WARNING"), "a stored-but-nameless row is never silent")
        #expect(text.contains("stored with no name"))
        #expect(text.contains("can never become a profile"),
                "the response must say why a nameless row is safe to keep")
    }

    /// A row carrying NOTHING — no name, no role, no age, no place — is the one
    /// shape that is still refused, because there is nothing to be evidence of.
    @Test func rosterThatStoresNothingSaysSo() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        let text = try await handler.submitHouseholdEvidenceText(baseArgs([
            ["name": "", "relationship": ""], ["name": "", "relationship": ""],
        ]))
        #expect(try storedHousehold(path).isEmpty)
        #expect(text.contains("NO roster was stored"))
        #expect(text.contains("carried no information at all"))
    }

    /// The boundary between the two tests above: a bare ROLE is content, so the
    /// row survives even with no name. Pins that EV20's relaxation is scoped to
    /// "says nothing at all", not "says little".
    @Test func aBareRoleIsEnoughToStoreARow() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        _ = try await handler.submitHouseholdEvidenceText(baseArgs([
            ["relationship": "Head"], ["relationship": "Wife"],
        ]))
        #expect(try storedHousehold(path).count == 2)
    }

    @Test func numericStringAgeIsKept() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        _ = try await handler.submitHouseholdEvidenceText(baseArgs([
            ["name": "John Cauldwell", "relationship": "", "age": "40"],
        ]))
        #expect(try storedHousehold(path).first?["age"] as? Int == 40)
    }

    @Test func malformedHouseholdIsRefusedNotIgnored() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        await #expect(throws: MCPError.self) {
            _ = try await handler.submitHouseholdEvidenceText(baseArgs(["John", "Ann"]))
        }
    }

    /// A caller that passes `"household": null` is saying "no roster", not
    /// "here is a broken one" — it must not start being refused.
    @Test func absentHouseholdIsStillFine() async throws {
        let path = try makeDB()
        let handler = try MCPHandler(dbPath: path)
        let text = try await handler.submitHouseholdEvidenceText(baseArgs(NSNull()))
        #expect(try storedHousehold(path).isEmpty)
        #expect(!text.contains("ROSTER WARNING"))
    }
}
