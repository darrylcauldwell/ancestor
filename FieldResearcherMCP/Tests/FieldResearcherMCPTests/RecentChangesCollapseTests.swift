import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// Same-second collapse in get_recent_changes (owner dogfood 2026-07-30): one
/// research run re-scores hundreds of evidence rows with a single timestamp —
/// surfaced raw, the change feed was unreadable spam. Rows written by one
/// operation (same profile, same second) must aggregate to ONE event with a
/// count; single-row groups keep their per-row detail.
struct RecentChangesCollapseTests {

    private func makeDB() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite").path
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: "CREATE TABLE project_meta (id TEXT PRIMARY KEY, name TEXT, source_kind TEXT, source_value TEXT, created_at DATETIME)")
            try db.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
            try db.execute(sql: """
                CREATE TABLE evidence_records (id TEXT PRIMARY KEY, profile_id TEXT, source_id TEXT,
                    source_record_id TEXT, record_type TEXT, verdict TEXT, record_json TEXT,
                    scored_at DATETIME)
                """)
            try db.execute(sql: """
                CREATE TABLE leads (id TEXT PRIMARY KEY, profile_id TEXT, name TEXT, status TEXT,
                    created_at DATETIME)
                """)
            try db.execute(sql: """
                CREATE TABLE field_sources (id TEXT PRIMARY KEY, entity_kind TEXT, entity_id TEXT,
                    field TEXT, origin TEXT, added_at DATETIME)
                """)
            try db.execute(sql: "CREATE TABLE research_runs (id TEXT PRIMARY KEY, profile_id TEXT, mode TEXT, completed_at DATETIME, fact_count INTEGER, lead_count INTEGER)")
            try db.execute(sql: "CREATE TABLE pending_facts (id TEXT PRIMARY KEY, profile_id TEXT, fact_kind TEXT, review_status TEXT, created_at DATETIME)")
        }
        return path
    }

    private func decode(_ json: String) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    @Test func sameSecondEvidenceRowsCollapseToOneEvent() async throws {
        let dbPath = try makeDB()
        let runStamp = Date(timeIntervalSince1970: 1_800_000_000)
        let q = try DatabaseQueue(path: dbPath)
        try await q.write { db in
            for i in 0..<40 {
                try db.execute(sql: """
                    INSERT INTO evidence_records (id, profile_id, source_id, source_record_id, record_type, verdict, record_json, scored_at)
                    VALUES (?, '@P1@', 'freebmd', ?, 'birth', ?, '{}', ?)
                    """, arguments: ["e\(i)", "rec\(i)", i < 3 ? "fact" : "lead", runStamp])
            }
        }
        let handler = try MCPHandler(dbPath: dbPath)
        let events = try decode(try await handler.getRecentChangesResponseText(
            ["since": "2026-01-01T00:00:00Z"]))
        let evidence = events.filter { ($0["kind"] as? String) == "evidence_scored" }
        #expect(evidence.count == 1, "40 same-second rows must read as ONE event, got \(evidence.count)")
        #expect(evidence.first?["records"] as? Int == 40)
        #expect(evidence.first?["facts"] as? Int == 3)
        #expect(evidence.first?["leads"] as? Int == 37)
    }

    @Test func singleEvidenceRowKeepsPerRowDetail() async throws {
        let dbPath = try makeDB()
        let q = try DatabaseQueue(path: dbPath)
        try await q.write { db in
            try db.execute(sql: """
                INSERT INTO evidence_records (id, profile_id, source_id, source_record_id, record_type, verdict, record_json, scored_at)
                VALUES ('e1', '@P1@', 'freecen', 'rec1', 'census', 'fact', '{}', ?)
                """, arguments: [Date(timeIntervalSince1970: 1_800_000_100)])
        }
        let handler = try MCPHandler(dbPath: dbPath)
        let events = try decode(try await handler.getRecentChangesResponseText(
            ["since": "2026-01-01T00:00:00Z"]))
        let evidence = events.filter { ($0["kind"] as? String) == "evidence_scored" }
        #expect(evidence.count == 1)
        #expect(evidence.first?["source"] as? String == "freecen")
        #expect(evidence.first?["verdict"] as? String == "fact")
        #expect(evidence.first?["records"] == nil, "no count field on a lone row")
    }

    @Test func distinctSecondsAndProfilesStaySeparate() async throws {
        let dbPath = try makeDB()
        let q = try DatabaseQueue(path: dbPath)
        try await q.write { db in
            try db.execute(sql: """
                INSERT INTO leads (id, profile_id, name, status, created_at) VALUES
                ('l1', '@P1@', 'Lead A', 'new', ?),
                ('l2', '@P1@', 'Lead B', 'new', ?),
                ('l3', '@P2@', 'Lead C', 'new', ?)
                """, arguments: [Date(timeIntervalSince1970: 1_800_000_000),
                                 Date(timeIntervalSince1970: 1_800_000_060),
                                 Date(timeIntervalSince1970: 1_800_000_000)])
        }
        let handler = try MCPHandler(dbPath: dbPath)
        let events = try decode(try await handler.getRecentChangesResponseText(
            ["since": "2026-01-01T00:00:00Z"]))
        let leads = events.filter { ($0["kind"] as? String) == "lead_created" }
        #expect(leads.count == 3, "different seconds / different profiles never merge")
    }

    @Test func sameSecondAppliedFieldsCollapseWithFieldList() async throws {
        let dbPath = try makeDB()
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let q = try DatabaseQueue(path: dbPath)
        try await q.write { db in
            try db.execute(sql: """
                INSERT INTO field_sources (id, entity_kind, entity_id, field, origin, added_at) VALUES
                ('f1', 'profile', '@P1@', 'deathDate', 'freebmd', ?),
                ('f2', 'profile', '@P1@', 'deathLocation', 'freebmd', ?)
                """, arguments: [stamp, stamp])
        }
        let handler = try MCPHandler(dbPath: dbPath)
        let events = try decode(try await handler.getRecentChangesResponseText(
            ["since": "2026-01-01T00:00:00Z"]))
        let applied = events.filter { ($0["kind"] as? String) == "fact_applied" }
        #expect(applied.count == 1)
        #expect(applied.first?["count"] as? Int == 2)
        let fields = applied.first?["field"] as? String ?? ""
        #expect(fields.contains("deathDate") && fields.contains("deathLocation"))
    }
}
