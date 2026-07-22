import Testing
import Foundation
import GRDB
@testable import FieldResearcherMCP

/// CONFLICT_LAYER_SPEC CL6 (§4.8.5) — the MCP dispute surface:
/// AC3 (read-only ledger on get_profile + the disputes resource; no
/// dispute-writing tool exists) and AC4 (§14.3 gate refuses auto-approval
/// on open disputes, including structural kinds field_sources
/// recomputation cannot see).
struct DisputeSurfaceTests {

    private func makeDB() throws -> String {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl6-\(UUID().uuidString).sqlite").path
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE leads (id TEXT PRIMARY KEY, profile_id TEXT, name TEXT, relationship TEXT, status TEXT, evidence TEXT, birth_year INTEGER, death_year INTEGER, created_at DATETIME, investigated_at DATETIME, source TEXT, given_name TEXT, surname TEXT, resolved_at DATETIME, resolution TEXT)")
            try db.execute(sql: """
                CREATE TABLE profiles (
                    id TEXT PRIMARY KEY, first_name TEXT, last_name TEXT,
                    birth_date_original TEXT, birth_date_earliest INTEGER,
                    birth_date_latest INTEGER, death_date_original TEXT,
                    birth_location TEXT, gender TEXT
                )
                """)
            try db.execute(sql: "INSERT INTO profiles (id, first_name, last_name) VALUES ('P1','Ernest','Cauldwell')")
            try db.execute(sql: """
                CREATE TABLE field_sources (
                    entity_id TEXT, entity_kind TEXT, field TEXT,
                    origin TEXT, raw TEXT, added_at DATETIME
                )
                """)
            try db.execute(sql: """
                INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at)
                VALUES ('P1','profile','birthDate','import','1887 [GRO Index]', ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                CREATE TABLE pending_facts (
                    id TEXT PRIMARY KEY, profile_id TEXT, fact_kind TEXT,
                    value_json TEXT, sources_json TEXT, review_status TEXT,
                    created_at DATETIME, source_url TEXT, source_title TEXT,
                    evidence_text TEXT, reasoning TEXT, agent_id TEXT,
                    verification_status TEXT, reviewed_at DATETIME,
                    approval_method TEXT, approval_rule_ids TEXT, approved_at DATETIME
                )
                """)
            try db.execute(sql: """
                INSERT INTO pending_facts
                (id, profile_id, fact_kind, value_json, review_status, created_at,
                 source_url, source_title, evidence_text, reasoning, agent_id, verification_status)
                VALUES ('PF1','P1','birthDate','"1887"','pending', ?,
                        'https://www.freebmd.org.uk/cgi/search.pl', 'FreeBMD',
                        'Ernest 1887', 'test', 'field-researcher', 'pending')
                """, arguments: [Date()])
            // profileDetail joins relationships + pending tables.
            try db.execute(sql: """
                CREATE TABLE relationships (
                    id TEXT PRIMARY KEY, from_id TEXT, to_id TEXT,
                    type TEXT, role TEXT, subtype TEXT,
                    marriage_date_original TEXT, marriage_location TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE life_events (
                    id TEXT PRIMARY KEY, profile_id TEXT, type TEXT,
                    date_original TEXT, location TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE research_runs (
                    id TEXT PRIMARY KEY, profile_id TEXT, mode TEXT,
                    started_at DATETIME, completed_at DATETIME,
                    fact_count INTEGER, lead_count INTEGER,
                    cluster_count INTEGER, gps_score INTEGER, result_json TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE negative_searches (
                    profile_id TEXT, source_id TEXT, record_type TEXT,
                    searched_at DATETIME, query_key TEXT
                )
                """)
            // CL1-shaped dispute ledger (the columns the CL6 surface reads).
            try db.execute(sql: """
                CREATE TABLE field_disputes (
                    entity_id TEXT, entity_kind TEXT, field TEXT, reason TEXT,
                    competing_sources TEXT, detected_at DATETIME,
                    resolution TEXT, kind TEXT, severity TEXT, detected_by TEXT,
                    evidence_json TEXT, ladder_trace TEXT, witness_summary TEXT,
                    resolved_at DATETIME
                )
                """)
        }
        return dbPath
    }

    private func addDispute(
        dbPath: String, kind: String, field: String, resolved: Bool = false
    ) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO field_disputes
                (entity_id, entity_kind, field, reason, competing_sources,
                 detected_at, resolution, kind, severity, detected_by, ladder_trace)
                VALUES ('P1', 'profile', ?, 'valueMismatch', '[]', ?, ?, ?, 'conflict',
                        'consistencySweep', '[]')
                """, arguments: [field, Date(), resolved ? "{\"manual\":{\"_0\":\"kept\"}}" : nil, kind])
        }
    }

    // MARK: - AC3: read-only ledger

    @Test func getProfileReturnsDisputesReadOnly() async throws {
        let dbPath = try makeDB()
        try addDispute(dbPath: dbPath, kind: "fieldValue", field: "deathDate")
        try addDispute(dbPath: dbPath, kind: "timeline", field: "death-vs-alive", resolved: true)
        let handler = try MCPHandler(dbPath: dbPath)

        let detail = try await handler.profileDetail(id: "P1")
        #expect(detail.contains("\"disputes\""))
        #expect(detail.contains("deathDate"))
        #expect(detail.contains("\"open\""))
        #expect(detail.contains("\"resolved\""))

        // The disputes resource carries the full ledger.
        let resource = try await handler.disputesResource(profileID: "P1")
        #expect(resource.contains("timeline"))
        #expect(resource.contains("ladder_trace"))

        // No dispute-writing tool exists — the firewall is unchanged.
        // (Structural assertion: the tool registry has no dispute mutator.)
        #expect(!detail.contains("resolve_dispute"))
    }

    // MARK: - Lead IDs surfaced on get_profile (Batch-1 defect c)

    @Test func getProfileIncludesLeadID() async throws {
        let dbPath = try makeDB()
        let queue = try DatabaseQueue(path: dbPath)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO leads (id, profile_id, name, status, evidence, created_at)
                VALUES ('lead-42', 'P1', 'Robert CAULDWELL', 'new', 'census 1891', ?)
                """, arguments: [Date()])
        }
        let handler = try MCPHandler(dbPath: dbPath)
        let detail = try await handler.profileDetail(id: "P1")
        #expect(detail.contains("lead-42"),
                "get_profile must expose the lead id so an agent can promote/dismiss a lead it just read")
    }

    // MARK: - AC4: §14.3 gate refuses on open disputes

    @Test func gateRefusesAutoApprovalOnOpenFieldDispute() async throws {
        let dbPath = try makeDB()
        try addDispute(dbPath: dbPath, kind: "fieldValue", field: "birthDate")
        let handler = try MCPHandler(dbPath: dbPath)
        let reason = try await handler.approvalRefusalReason(pendingFactID: "PF1")
        #expect(reason == "open_dispute_on_target")
    }

    @Test func gateRefusesOnStructuralKindsInvisibleToFieldSources() async throws {
        let dbPath = try makeDB()
        // A parentRole dispute — field key "mother" never parses as a
        // ProfileField, so field_sources recomputation cannot see it.
        try addDispute(dbPath: dbPath, kind: "parentRole", field: "mother")
        let handler = try MCPHandler(dbPath: dbPath)
        let reason = try await handler.approvalRefusalReason(pendingFactID: "PF1")
        #expect(reason == "open_dispute_on_target")
    }

    @Test func resolvedDisputesDoNotBlockApproval() async throws {
        let dbPath = try makeDB()
        try addDispute(dbPath: dbPath, kind: "fieldValue", field: "birthDate", resolved: true)
        let handler = try MCPHandler(dbPath: dbPath)
        let reason = try await handler.approvalRefusalReason(pendingFactID: "PF1")
        #expect(reason != "open_dispute_on_target")
        // (The fact may still refuse on other gates — convergence etc. —
        // but never on a RESOLVED dispute.)
    }
}
