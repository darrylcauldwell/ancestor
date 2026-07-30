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

/// DOSSIER_SPEC #T9-Change1 acceptance criterion 6 — the MCP dossier
/// resource renders the deterministic skeleton from the same rows, with the
/// honesty envelope intact (a truncated search is never an absence claim).
struct DossierResourceTests {

    private func makeDB() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite").path
        let q = try DatabaseQueue(path: path)
        try q.write { db in
            try db.execute(sql: "CREATE TABLE project_meta (id TEXT PRIMARY KEY, name TEXT, source_kind TEXT, source_value TEXT, created_at DATETIME)")
            try db.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
            try db.execute(sql: """
                CREATE TABLE profiles (id TEXT PRIMARY KEY, first_name TEXT, last_name TEXT,
                    is_deleted INTEGER DEFAULT 0)
                """)
            try db.execute(sql: "CREATE TABLE leads (id TEXT PRIMARY KEY, profile_id TEXT, name TEXT, status TEXT, created_at DATETIME)")
            try db.execute(sql: """
                CREATE TABLE evidence_records (id TEXT PRIMARY KEY, profile_id TEXT, source_id TEXT,
                    source_record_id TEXT, record_type TEXT, verdict TEXT, record_json TEXT,
                    citation_full TEXT, user_status TEXT, scored_at DATETIME)
                """)
            try db.execute(sql: "CREATE TABLE field_disputes (rowid INTEGER PRIMARY KEY, entity_id TEXT, field TEXT, severity TEXT, resolution TEXT, ladder_trace TEXT, witness_summary TEXT)")
            try db.execute(sql: "CREATE TABLE negative_searches (rowid INTEGER PRIMARY KEY, profile_id TEXT, source_id TEXT, record_type TEXT, searched_at DATETIME, search_params TEXT, result_kind TEXT, hit_count INTEGER)")
            try db.execute(sql: "CREATE TABLE research_hypotheses (id TEXT PRIMARY KEY, subject_profile_id TEXT, kind_discriminator TEXT, verdict TEXT, origin TEXT, reasoning TEXT, attempts INTEGER, user_rejected INTEGER DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE research_runs (id TEXT PRIMARY KEY, profile_id TEXT, mode TEXT, completed_at DATETIME, gps_score INTEGER, fact_count INTEGER, lead_count INTEGER)")

            try db.execute(sql: "INSERT INTO profiles (id, first_name, last_name) VALUES ('@P1@', 'Elizabeth', 'Shaw')")
            try db.execute(sql: """
                INSERT INTO evidence_records (id, profile_id, source_id, source_record_id, record_type, verdict, record_json, citation_full, user_status, scored_at)
                VALUES ('@P1@|d1', '@P1@', 'freebmd', 'd1', 'death', 'fact', '{}', 'FreeBMD death 7b/920', 'unreviewed', ?),
                       ('@P1@|c1', '@P1@', 'freecen', 'c1', 'census', 'lead', '{}', NULL, 'unreviewed', ?)
                """, arguments: [Date(), Date()])
            try db.execute(sql: "INSERT INTO field_disputes (entity_id, field, severity, witness_summary) VALUES ('@P1@', 'deathDate', 'conflict', '2 witnesses say 1916; 1 says 1914')")
            try db.execute(sql: """
                INSERT INTO negative_searches (profile_id, source_id, record_type, searched_at, result_kind) VALUES
                ('@P1@', 'freebmd', 'birth', ?, 'zero'),
                ('@P1@', 'freecen', 'census', ?, 'truncated')
                """, arguments: [Date(), Date()])
        }
        return path
    }

    @Test func dossierSkeletonRendersFromRowsWithHonestyEnvelope() async throws {
        let handler = try MCPHandler(dbPath: try makeDB())
        let contents = try await handler.dossierResource(profileID: "@P1@")
        let dossier = try #require(JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [String: Any])

        #expect(dossier["subject"] as? String == "Elizabeth Shaw")
        // D1: only the FACT row; the lead is not "what we know".
        let d1 = try #require(dossier["d1_what_we_know"] as? [[String: Any]])
        #expect(d1.count == 1)
        #expect(d1.first?["citation"] as? String == "FreeBMD death 7b/920")
        // D2: verbatim stored strings.
        let d2 = try #require(dossier["d2_what_conflicts"] as? [[String: Any]])
        #expect(d2.first?["witness_summary"] as? String == "2 witnesses say 1916; 1 says 1914")
        #expect(d2.first?["status"] as? String == "open")
        // D3: the truncated row is labelled, never an absence claim.
        let d3 = try #require(dossier["d3_whats_missing"] as? [[String: Any]])
        let conclusions = d3.compactMap { $0["conclusion"] as? String }
        #expect(conclusions.contains("searched and absent"))
        #expect(conclusions.contains { $0.contains("not evidence of absence") })
        // D7: honest narration.
        let d7 = try #require(dossier["d7_footer"] as? [String: Any])
        #expect(d7["narration_mode"] as? String == "deterministic")
    }

    @Test func missingProfileReturnsSharedNotFoundBody() async throws {
        let handler = try MCPHandler(dbPath: try makeDB())
        let contents = try await handler.dossierResource(profileID: "@NOPE@")
        #expect(contents.contains("profile_not_found"))
    }
}
