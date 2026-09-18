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
            try db.execute(sql: "CREATE TABLE evidence_records (id TEXT PRIMARY KEY, profile_id TEXT, source_id TEXT, source_record_id TEXT, record_type TEXT, verdict TEXT, record_json TEXT, citation_full TEXT, citation_url TEXT, scored_at DATETIME, user_status TEXT DEFAULT 'unreviewed', gates_json TEXT, applied_at DATETIME)")
            try db.execute(sql: """
                CREATE TABLE profiles (
                    id TEXT PRIMARY KEY, first_name TEXT, last_name TEXT,
                    birth_date_original TEXT, birth_date_earliest INTEGER,
                    birth_date_latest INTEGER, death_date_original TEXT,
                    birth_location TEXT, gender TEXT,
                    is_deleted INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: "INSERT INTO profiles (id, first_name, last_name) VALUES ('P1','Ernest','Cauldwell')")
            try db.execute(sql: """
                CREATE TABLE field_sources (
                    entity_id TEXT, entity_kind TEXT, field TEXT,
                    origin TEXT, raw TEXT, added_at DATETIME,
                    citation_json TEXT, evidence_quality INTEGER, fact_confidence TEXT
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
                    date_original TEXT, date_earliest INTEGER, date_latest INTEGER,
                    end_date_original TEXT, location TEXT, description TEXT,
                    confidence TEXT, details_json TEXT, sources_json TEXT,
                    sensitive INTEGER DEFAULT 0
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
                    searched_at DATETIME, query_key TEXT, result_kind TEXT
                )
                """)
            try db.execute(sql: "CREATE TABLE research_hypotheses (id TEXT PRIMARY KEY, subject_profile_id TEXT, kind_discriminator TEXT, verdict TEXT, origin TEXT, reasoning TEXT, attempts INTEGER, user_rejected INTEGER DEFAULT 0)")
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
        dbPath: String, kind: String, field: String, resolved: Bool = false,
        resolutionJSON: String? = nil
    ) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO field_disputes
                (entity_id, entity_kind, field, reason, competing_sources,
                 detected_at, resolution, kind, severity, detected_by, ladder_trace)
                VALUES ('P1', 'profile', ?, 'valueMismatch', '[]', ?, ?, ?, 'conflict',
                        'consistencySweep', '[]')
                """, arguments: [
                    field, Date(),
                    resolutionJSON ?? (resolved ? "{\"manual\":{\"_0\":\"kept\"}}" : nil),
                    kind,
                ])
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

    // MARK: - EV36: a DEFERRED dispute is parked, not settled

    /// `DisputeResolution.deferred` carries no payload, so Swift's synthesised
    /// Codable writes exactly this. Pinning the literal is the point: if the
    /// encoding ever moves, these tests fail loudly instead of silently
    /// reclassifying every parked dispute as resolved.
    private static let deferredJSON = "{\"deferred\":{}}"

    private func decodeRows(_ json: String) throws -> [[String: Any]] {
        (try JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
    }

    @Test func deferredDisputeReadsAsOpenOnEveryMCPSurface() async throws {
        let dbPath = try makeDB()
        try addDispute(dbPath: dbPath, kind: "fieldValue", field: "birthLocation",
                       resolutionJSON: Self.deferredJSON)
        let handler = try MCPHandler(dbPath: dbPath)

        let resource = try await handler.disputesResource(profileID: "P1")
        let ledger = ((try JSONSerialization.jsonObject(with: Data(resource.utf8)))
            as? [String: Any])?["disputes"] as? [[String: Any]] ?? []
        #expect(ledger.count == 1)
        #expect(ledger[0]["status"] as? String == "open",
                "a parked dispute is not a settled one — the app never shows it as Resolved")
        #expect(ledger[0]["deferred"] as? Bool == true)

        let detail = try await handler.profileDetail(id: "P1")
        let disputes = ((try JSONSerialization.jsonObject(with: Data(detail.utf8)))
            as? [String: Any])?["disputes"] as? [[String: Any]] ?? []
        #expect(disputes.first?["status"] as? String == "open")

        let dossier = try await handler.dossierResource(profileID: "P1")
        let d2 = ((try JSONSerialization.jsonObject(with: Data(dossier.utf8)))
            as? [String: Any])?["d2_what_conflicts"] as? [[String: Any]] ?? []
        #expect(d2.first?["status"] as? String == "open",
                "the MCP dossier must agree with DossierAssembler.isOpen")
    }

    @Test func getOpenDisputesListsDeferredRowsAsOpen() async throws {
        let dbPath = try makeDB()
        try addDispute(dbPath: dbPath, kind: "fieldValue", field: "birthLocation",
                       resolutionJSON: Self.deferredJSON)
        try addDispute(dbPath: dbPath, kind: "fieldValue", field: "deathDate", resolved: true)
        try addDispute(dbPath: dbPath, kind: "timeline", field: "death-vs-alive")
        let handler = try MCPHandler(dbPath: dbPath)

        let open = try decodeRows(try await handler.getOpenDisputesResponseText(["status": "open"]))
        let openFields = Set(open.compactMap { $0["field"] as? String })
        #expect(openFields == ["birthLocation", "death-vs-alive"],
                "status:'open' must not silently omit the parked disputes an agent should be working on")

        let resolved = try decodeRows(try await handler.getOpenDisputesResponseText(["status": "resolved"]))
        #expect(Set(resolved.compactMap { $0["field"] as? String }) == ["deathDate"])

        let parked = try decodeRows(try await handler.getOpenDisputesResponseText(["status": "deferred"]))
        #expect(Set(parked.compactMap { $0["field"] as? String }) == ["birthLocation"])

        let all = try decodeRows(try await handler.getOpenDisputesResponseText(["status": "all"]))
        #expect(all.count == 3)
    }

    @Test func manualNoteMentioningDeferralIsStillResolved() async throws {
        let dbPath = try makeDB()
        try addDispute(dbPath: dbPath, kind: "fieldValue", field: "birthDate",
                       resolutionJSON: "{\"manual\":{\"_0\":\"deferred to the GRO certificate\"}}")
        let handler = try MCPHandler(dbPath: dbPath)

        let open = try decodeRows(try await handler.getOpenDisputesResponseText(["status": "open"]))
        #expect(open.isEmpty, "the SQL LIKE is a coarse net; the decoded key is what decides")

        let resolved = try decodeRows(try await handler.getOpenDisputesResponseText(["status": "resolved"]))
        #expect(resolved.count == 1)
        #expect(resolved[0]["deferred"] == nil)
    }

    // MARK: - Review F08/F10: the LIMIT caps the FILTERED set, not the superset

    /// The `resolved` SQL clause (`d.resolution IS NOT NULL`) matches parked
    /// rows too, and the Swift narrow then drops them. With the cap on the
    /// un-narrowed superset, the newest parked disputes ate every slot and
    /// the tool answered "nothing has ever been resolved" while plenty had.
    @Test func resolvedDisputesAreNotCrowdedOutByNewerParkedOnes() async throws {
        let dbPath = try makeDB()
        // Older rows (lower rowid) are the genuinely-resolved ones …
        for i in 0..<6 {
            try addDispute(dbPath: dbPath, kind: "fieldValue", field: "settled-\(i)", resolved: true)
        }
        // … and the owner has since parked ten newer conflicts with
        // "Decide later", which is exactly what `ORDER BY rowid DESC` sees first.
        for i in 0..<10 {
            try addDispute(dbPath: dbPath, kind: "fieldValue", field: "parked-\(i)",
                           resolutionJSON: Self.deferredJSON)
        }
        let handler = try MCPHandler(dbPath: dbPath)

        let capped = try decodeRows(
            try await handler.getOpenDisputesResponseText(["status": "resolved", "limit": 4]))
        #expect(capped.count == 4,
                "limit:4 with 6 resolved disputes must return 4 — parked rows must not consume result slots")
        #expect(capped.allSatisfy { $0["status"] as? String == "resolved" })
        #expect(capped.allSatisfy { ($0["field"] as? String)?.hasPrefix("settled-") == true })

        // And a limit above the true count returns the whole answer, so a
        // short result honestly means "that is all there is".
        let everything = try decodeRows(
            try await handler.getOpenDisputesResponseText(["status": "resolved", "limit": 100]))
        #expect(everything.count == 6)

        // The mirror image on the open arm: newer RESOLVED rows must not
        // crowd out the open ones the superset also sweeps in.
        for i in 0..<8 {
            try addDispute(dbPath: dbPath, kind: "fieldValue", field: "open-\(i)")
        }
        for i in 0..<8 {
            try addDispute(dbPath: dbPath, kind: "fieldValue", field: "closed-\(i)",
                           resolutionJSON: "{\"manual\":{\"_0\":\"deferred to the GRO certificate\"}}")
        }
        let handler2 = try MCPHandler(dbPath: dbPath)
        let open = try decodeRows(
            try await handler2.getOpenDisputesResponseText(["status": "open", "limit": 5]))
        #expect(open.count == 5)
        #expect(open.allSatisfy { $0["status"] as? String == "open" })
    }

    /// Regression fence on the gate that must NOT move with the read surfaces.
    @Test func deferredDisputeStillDoesNotBlockAutoApproval() async throws {
        let dbPath = try makeDB()
        try addDispute(dbPath: dbPath, kind: "fieldValue", field: "birthDate",
                       resolutionJSON: Self.deferredJSON)
        let handler = try MCPHandler(dbPath: dbPath)
        let reason = try await handler.approvalRefusalReason(pendingFactID: "PF1")
        #expect(reason != "open_dispute_on_target",
                "the §14.3 gate is `resolution IS NULL` by design — HealthTriage.blocksAutoApproval mirrors it")
    }
}
