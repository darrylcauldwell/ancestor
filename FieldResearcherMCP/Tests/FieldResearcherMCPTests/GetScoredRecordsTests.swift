import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// get_scored_records reads from `evidence_records` (the live per-profile
/// archive), NOT the vestigial `scored_records ⋈ research_records` tables the
/// app abandoned at the v13 cutover — which returned 0 rows for every
/// profile. Pins the repointed read path + filters.
struct GetScoredRecordsTests {

    /// Minimal DB with the tables MCPHandler.init's schema-age check needs,
    /// plus evidence_records for this tool.
    private func makeDB() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite").path
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: "CREATE TABLE leads (id TEXT PRIMARY KEY, status TEXT, resolved_at DATETIME, resolution TEXT)")
            try db.execute(sql: "CREATE TABLE project_meta (id TEXT PRIMARY KEY, name TEXT, source_kind TEXT, source_value TEXT, created_at DATETIME)")
            try db.execute(sql: "CREATE TABLE profiles (id TEXT PRIMARY KEY, is_deleted INTEGER DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE relationships (id TEXT PRIMARY KEY)")
            try db.execute(sql: """
                CREATE TABLE evidence_records (
                    id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, source_id TEXT NOT NULL,
                    source_record_id TEXT NOT NULL, record_type TEXT NOT NULL, verdict TEXT NOT NULL,
                    record_json TEXT NOT NULL, citation_full TEXT, citation_url TEXT, scored_at DATETIME NOT NULL, user_status TEXT NOT NULL DEFAULT 'unreviewed', gates_json TEXT)
                """)
            try db.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES (?,'T','manual','',?)", arguments: [UUID().uuidString, Date()])
        }
        return path
    }

    private func insert(dbPath: String, id: String, sourceID: String, sourceRecordID: String,
                        recordType: String, verdict: String, recordJSON: String,
                        citationFull: String? = nil, citationURL: String? = nil,
                        scoredAt: Date) throws {
        let q = try DatabaseQueue(path: dbPath)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO evidence_records
                  (id, profile_id, source_id, source_record_id, record_type, verdict, record_json, citation_full, citation_url, scored_at)
                VALUES (?, 'P1', ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, sourceID, sourceRecordID, recordType, verdict, recordJSON, citationFull, citationURL, scoredAt])
        }
    }

    @Test func returnsRowsFromEvidenceRecords() async throws {
        let dbPath = try makeDB()
        try insert(
            dbPath: dbPath, id: "P1|ev-birth", sourceID: "freebmd",
            sourceRecordID: "rec-birth", recordType: "birth", verdict: "fact",
            recordJSON: "{\"birth\":{\"common\":{\"surname\":\"Cauldwell\",\"givenName\":\"Ernest\"}}}",
            citationFull: "FreeBMD Birth Index", citationURL: "https://www.freebmd.org.uk/x",
            scoredAt: Date(timeIntervalSince1970: 1_000)
        )
        let handler = try MCPHandler(dbPath: dbPath)

        let json = try await handler.getScoredRecordsResponseText(["profile_id": "P1"])
        #expect(json.contains("\"verdict\""))
        #expect(json.contains("\"fact\""))
        #expect(json.contains("ev-birth"))
        #expect(json.contains("freebmd"))
        #expect(json.contains("Cauldwell"))
        #expect(json.contains("Ernest"))
        #expect(json.contains("citation_full"))
        #expect(json.contains("citation_url"))
        // The 4-gate breakdown lived only on the never-written scored_records
        // table — the payload must no longer claim one.
        #expect(!json.contains("\"gates\""))
        #expect(!json.contains("gate_name"))
    }

    @Test func returnsEmptyArrayForUnknownProfile() async throws {
        let dbPath = try makeDB()
        let handler = try MCPHandler(dbPath: dbPath)
        let json = try await handler.getScoredRecordsResponseText(["profile_id": "no-such"])
        let compact = json.filter { !$0.isWhitespace }
        #expect(compact == "[]")
        #expect(!json.contains("\"verdict\""))
    }

    @Test func filtersByRecordTypeAndVerdict() async throws {
        let dbPath = try makeDB()
        try insert(
            dbPath: dbPath, id: "P1|ev-m1", sourceID: "freebmd",
            sourceRecordID: "rec-m1", recordType: "marriage", verdict: "fact",
            recordJSON: "{\"marriage\":{\"common\":{\"surname\":\"Brooks\"},\"marriageYear\":1911,\"district\":\"Belper\",\"volume\":\"7b\",\"page\":\"1397\",\"partnerSurnameFromSamePage\":\"Land\"}}",
            scoredAt: Date(timeIntervalSince1970: 2_000)
        )
        try insert(
            dbPath: dbPath, id: "P1|ev-b1", sourceID: "freebmd",
            sourceRecordID: "rec-b1", recordType: "birth", verdict: "lead",
            recordJSON: "{\"birth\":{\"common\":{\"surname\":\"Brooks\"}}}",
            scoredAt: Date(timeIntervalSince1970: 3_000)
        )
        let handler = try MCPHandler(dbPath: dbPath)

        let marriageOnly = try await handler.getScoredRecordsResponseText([
            "profile_id": "P1", "record_type": "marriage",
        ])
        #expect(marriageOnly.contains("ev-m1"))
        #expect(!marriageOnly.contains("ev-b1"))
        #expect(marriageOnly.contains("partnerSurnameFromSamePage"))
        #expect(marriageOnly.contains("Land"))

        let leadsOnly = try await handler.getScoredRecordsResponseText([
            "profile_id": "P1", "verdict": "lead",
        ])
        #expect(leadsOnly.contains("ev-b1"))
        #expect(!leadsOnly.contains("ev-m1"))
    }

    @Test func ordersNewestFirstAndClampsLimit() async throws {
        let dbPath = try makeDB()
        try insert(
            dbPath: dbPath, id: "P1|ev-old", sourceID: "freebmd",
            sourceRecordID: "rec-old", recordType: "birth", verdict: "fact",
            recordJSON: "{\"birth\":{\"common\":{}}}",
            scoredAt: Date(timeIntervalSince1970: 1_000)
        )
        try insert(
            dbPath: dbPath, id: "P1|ev-new", sourceID: "freebmd",
            sourceRecordID: "rec-new", recordType: "birth", verdict: "fact",
            recordJSON: "{\"birth\":{\"common\":{}}}",
            scoredAt: Date(timeIntervalSince1970: 9_000)
        )
        let handler = try MCPHandler(dbPath: dbPath)

        let one = try await handler.getScoredRecordsResponseText([
            "profile_id": "P1", "limit": 0,
        ])
        #expect(one.contains("ev-new"))
        #expect(!one.contains("ev-old"))
    }
}
