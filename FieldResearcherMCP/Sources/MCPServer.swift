import Foundation
import GRDB

/// Minimal MCP server for the Ancestor Research Field Researcher.
/// Communicates via JSON-RPC over stdio. Reads tree context from the
/// project SQLite database and accepts evidence submissions.
///
/// This is the "bolt-on API" — external, at arm's length.
/// Evidence goes to pending_facts; the app scores when it processes.
@main
struct MCPServer {
    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            FileHandle.standardError.write(Data("Usage: FieldResearcherMCP <project.db path>\n".utf8))
            exit(1)
        }

        let dbPath = CommandLine.arguments[1]

        guard FileManager.default.fileExists(atPath: dbPath) else {
            FileHandle.standardError.write(Data("Database not found: \(dbPath)\n".utf8))
            exit(1)
        }

        do {
            let server = try MCPHandler(dbPath: dbPath)
            await server.run()
        } catch {
            FileHandle.standardError.write(Data("Failed to open database: \(error)\n".utf8))
            exit(1)
        }
    }
}

/// Handles MCP JSON-RPC messages over stdio.
actor MCPHandler {
    let db: DatabaseQueue

    /// Supported schema version range (§12).
    static let supportedSchemaVersions = 3...5

    init(dbPath: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.readonly = false
        self.db = try DatabaseQueue(path: dbPath, configuration: config)

        // Schema version check
        try db.read { db in
            // Check for v3 (leads) and v5 (field_researcher) tables
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            if !tables.contains("leads") {
                throw MCPError.invalidParams("Database schema too old (no leads table). Update the app first.")
            }
        }
    }

    func run() async {
        // Read JSON-RPC messages from stdin, line by line
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let id = request["id"]
            let isNotification = (id == nil)
            let method = request["method"] as? String ?? ""
            let params = request["params"] as? [String: Any] ?? [:]

            let envelope: [String: Any]
            do {
                let result = try await handle(method: method, params: params)
                if isNotification { continue }
                envelope = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": result,
                ]
            } catch {
                if isNotification { continue }
                let code: Int
                if case MCPError.methodNotFound = error { code = -32601 } else { code = -32603 }
                envelope = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "error": ["code": code, "message": error.localizedDescription],
                ]
            }

            if let resultData = try? JSONSerialization.data(withJSONObject: envelope),
               let resultString = String(data: resultData, encoding: .utf8) {
                print(resultString)
                fflush(stdout)
            }
        }
    }

    // MARK: - Method Dispatch

    func handle(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        // MCP lifecycle
        case "initialize":
            return initializeResponse()
        case "initialized", "notifications/initialized", "notifications/cancelled":
            return [String: Any]()

        // Resources
        case "resources/list":
            return resourcesList()
        case "resources/read":
            return try readResource(params: params)

        // Tools
        case "tools/list":
            return toolsList()
        case "tools/call":
            return try callTool(params: params)

        // Prompts
        case "prompts/list":
            return promptsList()
        case "prompts/get":
            return getPrompt(params: params)

        default:
            throw MCPError.methodNotFound(method)
        }
    }

    // MARK: - Initialize

    func initializeResponse() -> [String: Any] {
        [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "resources": ["listChanged": false],
                "tools": [String: Any](),
                "prompts": [String: Any](),
            ],
            "serverInfo": [
                "name": "ancestor-research",
                "version": "1.0.0",
            ],
        ]
    }

    // MARK: - Resources

    func resourcesList() -> [String: Any] {
        [
            "resources": [
                resource("ancestor://tree/summary", "Tree Summary", "Overview of the family tree with statistics"),
                resource("ancestor://tree/gaps", "Research Gaps", "Profiles with missing data, sorted by incompleteness"),
                resource("ancestor://profiles", "All Profiles", "Every profile with completeness and GPS scores"),
                // Tier 1 — programmatic read coverage of the per-profile
                // surfaces the UI already shows. Each is a thin SQL query
                // against an existing table; all read-only.
                resource("ancestor://relationships/{id}", "Profile Relationships", "Every spouse / parent edge attached to a profile, including the other party's name + dates"),
                resource("ancestor://research_runs/{id}", "Research History", "Pipeline runs for a profile — mode, counts, GPS score, timing"),
                resource("ancestor://leads", "Leads Queue", "All leads. Append ?status=new|investigating|investigated|promoted|dismissed to filter."),
                resource("ancestor://pending_facts/{id}", "Pending Facts", "Submitted-but-not-yet-applied facts for a profile, with their review status"),
                resource("ancestor://evidence/{id}", "Evidence Records", "Persisted scored records for a profile (the full SourceRecord JSON, verdict, citation)"),
                resource("ancestor://life_events/{id}", "Life Events", "Census / burial / probate / military / parish events attached to a profile"),
                resource("ancestor://lineage/{id}", "Lineage Walk", "Direct ancestors and descendants of a profile. Append ?depth=N (default 4) to bound."),
                resource("ancestor://audit_overrides", "Audit Overrides", "Persisted rule mutes / snoozes / threshold overrides (live audit findings need the app)"),
                resource("ancestor://research_hypotheses/{id}", "Research Hypotheses", "Pipeline-generated research hypotheses for a profile (V2 spec §4.1). Each row carries kind, verdict, isModelAssisted flag, evidence ids, reasoning, attempts counter (expansiveness-ladder progress), and verdict history. Excludes user-rejected by default."),
            ]
        ]
    }

    /// Pulls `id` from a resource URI like `ancestor://relationships/abc-123`
    /// or `ancestor://lineage/abc-123?depth=6`. Returns nil if the URI
    /// doesn't follow the expected `prefix/<id>` shape.
    private func extractIDAndQuery(_ uri: String, prefix: String) -> (id: String, query: [String: String])? {
        guard uri.hasPrefix(prefix) else { return nil }
        let rest = String(uri.dropFirst(prefix.count))
        let parts = rest.split(separator: "?", maxSplits: 1).map(String.init)
        let id = parts.first ?? ""
        guard !id.isEmpty else { return nil }
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        return (id, query)
    }

    /// Pulls only the query string from a resource URI like
    /// `ancestor://leads?status=new`. Returns empty dict when there's none.
    private func extractQuery(_ uri: String) -> [String: String] {
        guard let qmark = uri.firstIndex(of: "?") else { return [:] }
        let rest = uri[uri.index(after: qmark)...]
        var query: [String: String] = [:]
        for pair in rest.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
        }
        return query
    }

    func readResource(params: [String: Any]) throws -> [String: Any] {
        guard let uri = params["uri"] as? String else {
            throw MCPError.invalidParams("missing uri")
        }

        let content: String
        switch uri {
        case "ancestor://tree/summary":
            content = try treeSummary()
        case "ancestor://tree/gaps":
            content = try treeGaps()
        case "ancestor://profiles":
            content = try allProfiles()
        case "ancestor://audit_overrides":
            content = try auditOverrides()
        case _ where uri.hasPrefix("ancestor://leads"):
            content = try leadsList(status: extractQuery(uri)["status"])
        case _ where uri.hasPrefix("ancestor://profile/"):
            let id = String(uri.dropFirst("ancestor://profile/".count))
            content = try profileDetail(id: id)
        case _ where uri.hasPrefix("ancestor://relationships/"):
            guard let parsed = extractIDAndQuery(uri, prefix: "ancestor://relationships/")
            else { throw MCPError.invalidParams("missing profile id") }
            content = try relationshipsForProfile(id: parsed.id)
        case _ where uri.hasPrefix("ancestor://research_runs/"):
            guard let parsed = extractIDAndQuery(uri, prefix: "ancestor://research_runs/")
            else { throw MCPError.invalidParams("missing profile id") }
            content = try researchRunsForProfile(id: parsed.id)
        case _ where uri.hasPrefix("ancestor://pending_facts/"):
            guard let parsed = extractIDAndQuery(uri, prefix: "ancestor://pending_facts/")
            else { throw MCPError.invalidParams("missing profile id") }
            content = try pendingFactsForProfile(id: parsed.id)
        case _ where uri.hasPrefix("ancestor://evidence/"):
            guard let parsed = extractIDAndQuery(uri, prefix: "ancestor://evidence/")
            else { throw MCPError.invalidParams("missing profile id") }
            content = try evidenceForProfile(id: parsed.id)
        case _ where uri.hasPrefix("ancestor://research_hypotheses/"):
            guard let parsed = extractIDAndQuery(uri, prefix: "ancestor://research_hypotheses/")
            else { throw MCPError.invalidParams("missing profile id") }
            content = try researchHypothesesForProfile(id: parsed.id)
        case _ where uri.hasPrefix("ancestor://life_events/"):
            guard let parsed = extractIDAndQuery(uri, prefix: "ancestor://life_events/")
            else { throw MCPError.invalidParams("missing profile id") }
            content = try lifeEventsForProfile(id: parsed.id)
        case _ where uri.hasPrefix("ancestor://lineage/"):
            guard let parsed = extractIDAndQuery(uri, prefix: "ancestor://lineage/")
            else { throw MCPError.invalidParams("missing profile id") }
            let depth = Int(parsed.query["depth"] ?? "") ?? 4
            content = try lineage(id: parsed.id, depth: max(1, min(depth, 10)))
        default:
            throw MCPError.resourceNotFound(uri)
        }

        return [
            "contents": [
                ["uri": uri, "mimeType": "application/json", "text": content]
            ]
        ]
    }

    // MARK: - Tools

    func toolsList() -> [String: Any] {
        [
            "tools": [
                tool(
                    name: "submit_evidence",
                    description: "Submit a research finding as evidence for a profile. The finding will be scored by the app's deterministic pipeline before human review.",
                    properties: [
                        "profile_id": ["type": "string", "description": "Profile ID this evidence is about"],
                        "field": ["type": "string", "description": "Field: birthDate, deathDate, birthLocation, deathLocation, occupation, etc."],
                        "value": ["type": "string", "description": "The proposed value"],
                        "source_url": ["type": "string", "description": "URL where the evidence was found"],
                        "source_title": ["type": "string", "description": "Human-readable source description"],
                        "evidence_text": ["type": "string", "description": "The exact relevant text from the source"],
                        "reasoning": ["type": "string", "description": "How you connected this source to this profile"],
                        "confidence": ["type": "string", "description": "Your confidence: high, medium, or low"],
                    ],
                    required: ["profile_id", "field", "value", "source_url", "source_title", "evidence_text", "reasoning", "confidence"]
                ),
                tool(
                    name: "submit_lead",
                    description: "Submit a lead — a person discovered during research who may be related to someone in the tree.",
                    properties: [
                        "source_profile_id": ["type": "string", "description": "Profile ID this lead relates to"],
                        "name": ["type": "string", "description": "The lead person's name"],
                        "relationship": ["type": "string", "description": "Suspected relationship: father, mother, spouse, child, sibling"],
                        "birth_year": ["type": "integer", "description": "Approximate birth year"],
                        "death_year": ["type": "integer", "description": "Approximate death year"],
                        "evidence": ["type": "string", "description": "Evidence supporting this lead"],
                        "source_url": ["type": "string", "description": "URL where found"],
                    ],
                    required: ["source_profile_id", "name", "evidence", "source_url"]
                ),
                tool(
                    name: "submit_narrative_finding",
                    description: "Submit unstructured biographical evidence that doesn't map to a single field (apprenticeships, wills, newspaper mentions, emigration, etc.).",
                    properties: [
                        "profile_id": ["type": "string", "description": "Profile ID this is about"],
                        "category": ["type": "string", "description": "Category: apprenticeship, will_probate, newspaper, emigration, military_service, education, land_property, poor_law, trade_directory, inscription, other"],
                        "description": ["type": "string", "description": "What was found (max 500 chars)"],
                        "date_or_period": ["type": "string", "description": "When this applied (e.g. 1845, 1841-1851)"],
                        "source_url": ["type": "string", "description": "URL where found"],
                        "source_title": ["type": "string", "description": "Source name"],
                        "evidence_text": ["type": "string", "description": "Exact text from source (max 200 chars)"],
                        "reasoning": ["type": "string", "description": "How connected to this profile"],
                    ],
                    required: ["profile_id", "category", "description", "source_url", "source_title", "evidence_text", "reasoning"]
                ),
                tool(
                    name: "get_profile",
                    description: "Get full detail for a specific profile including all known facts, sources, relationships, and research history.",
                    properties: [
                        "profile_id": ["type": "string", "description": "The profile ID to look up"],
                    ],
                    required: ["profile_id"]
                ),
                tool(
                    name: "search_profiles",
                    description: "Search profiles by name.",
                    properties: [
                        "query": ["type": "string", "description": "Name to search for"],
                    ],
                    required: ["query"]
                ),
                tool(
                    name: "find_path",
                    description: "Find the shortest relationship path between two profiles via parent/spouse edges. Returns the chain of intermediate people or null if no path exists.",
                    properties: [
                        "from_id": ["type": "string", "description": "Starting profile ID"],
                        "to_id": ["type": "string", "description": "Target profile ID"],
                        "max_hops": ["type": "integer", "description": "Search depth cap (default 10, max 25)"],
                    ],
                    required: ["from_id", "to_id"]
                ),
                // Tier 2 — firewall-safe writes. Each proposes into a
                // review queue or performs a pure state transition; none
                // mutate profile / relationship rows directly.
                tool(
                    name: "submit_relationship_proposal",
                    description: "Propose a parent or spouse relationship between two existing profiles. Goes to `pending_relationships` for human review — does not modify the tree directly.",
                    properties: [
                        "from_profile_id": ["type": "string", "description": "Source profile ID (parent for parent edges; either party for spouse edges)"],
                        "to_profile_id": ["type": "string", "description": "Target profile ID (child for parent edges; the other party for spouse edges)"],
                        "rel_type": ["type": "string", "description": "'parent' or 'spouse'"],
                        "role": ["type": "string", "description": "For parent: 'father' / 'mother' / 'unspecified'. Omitted for spouse."],
                        "subtype": ["type": "string", "description": "biological | adoptive | step | unknown (default biological)"],
                        "source_url": ["type": "string", "description": "Where the evidence was found"],
                        "source_title": ["type": "string", "description": "Human-readable source description"],
                        "evidence_text": ["type": "string", "description": "Exact relevant text from the source"],
                        "reasoning": ["type": "string", "description": "How you connected this source to these profiles"],
                    ],
                    required: ["from_profile_id", "to_profile_id", "rel_type", "source_url", "evidence_text", "reasoning"]
                ),
                tool(
                    name: "dismiss_lead",
                    description: "Mark a lead as dismissed — the user has decided it's not relevant. Pure state transition, no fact data written.",
                    properties: [
                        "lead_id": ["type": "string", "description": "Lead ID to dismiss"],
                    ],
                    required: ["lead_id"]
                ),
                tool(
                    name: "flag_audit_override",
                    description: "Propose muting or snoozing an audit rule. Inserts a row into audit_rule_overrides; the app reviews before the mute takes effect.",
                    properties: [
                        "rule_id": ["type": "string", "description": "Audit rule identifier (e.g. parentAgeGap, lifespanTooLong)"],
                        "scope_kind": ["type": "string", "description": "'global' or 'profile'"],
                        "scope_profile_id": ["type": "string", "description": "Profile ID when scope_kind = 'profile'"],
                        "snoozed_until": ["type": "string", "description": "ISO-8601 date to snooze until (omit for permanent mute)"],
                        "reason": ["type": "string", "description": "Why this rule should be muted/snoozed for this scope"],
                    ],
                    required: ["rule_id", "scope_kind", "reason"]
                ),
                tool(
                    name: "add_workbench_note",
                    description: "Attach a free-text research note to a profile or relationship. Notes are user-scoped commentary, not fact data — they bypass the firewall safely.",
                    properties: [
                        "attachment_kind": ["type": "string", "description": "'profile' or 'relationship'"],
                        "attachment_id": ["type": "string", "description": "The profile or relationship ID this note attaches to"],
                        "tag": ["type": "string", "description": "Short tag (e.g. 'todo', 'hypothesis', 'observation')"],
                        "content": ["type": "string", "description": "Note body"],
                    ],
                    required: ["attachment_kind", "attachment_id", "content"]
                ),
                // Tier 3 — pipeline orchestration via request queue.
                tool(
                    name: "kick_off_research",
                    description: "Queue a research run for a profile or lead. The app's request watcher picks up queued rows and fires the pipeline. Returns a request_id; poll get_run_status for completion. Optional auto_accept (Debug-build-only) lets recursive expansion scripts skip the per-proposal human-click bottleneck.",
                    properties: [
                        "profile_id": ["type": "string", "description": "Profile ID to research (mutually exclusive with lead_id)"],
                        "lead_id": ["type": "string", "description": "Lead ID to investigate (mutually exclusive with profile_id)"],
                        "mode": ["type": "string", "description": "verify | extend | discover | all (default extend)"],
                        "scope": ["type": "string", "description": "parish | district | county | adjacent | national (default county)"],
                        "auto_accept": ["type": "string", "description": "'none' (default) keeps manual review. 'confirmed' auto-promotes .confirmed proposed relatives during the run — testing / automation only, honoured only when the app was built with AUTOMATION_AUTO_ACCEPT (Debug). Ignored in release builds."],
                    ],
                    required: []
                ),
                tool(
                    name: "get_run_status",
                    description: "Poll the status of a queued research run. Returns status (queued | running | completed | failed), run_id when completed, and error when failed.",
                    properties: [
                        "request_id": ["type": "string", "description": "The id returned by kick_off_research"],
                    ],
                    required: ["request_id"]
                ),
                // Auto-approval — see AncestorApp/AUTO_APPROVAL_VIA_MCP_SPEC.md.
                // Rules' authority extends to commit when the gate evaluator
                // says unambiguous; ambiguous facts still go to human review.
                tool(
                    name: "approve_pending_fact",
                    description: "Approve a pending fact via the deterministic gate. Commits to the profile + field_sources only if the fact passes every criterion (trust tier, convergence with existing sources, no would-be dispute, field is in the auto-approvable set). Refuses with a reason code otherwise; the fact stays pending for human review. NOTE: disabled by default pending §14.B.1 defensive hallucination re-check — set ANCESTOR_MCP_AUTO_APPROVE=1 in the server's environment to enable. Use inspect_approval_decision to test gate logic without the env override.",
                    properties: [
                        "pending_fact_id": ["type": "string", "description": "The pending_facts row ID to evaluate and commit."],
                    ],
                    required: ["pending_fact_id"]
                ),
                tool(
                    name: "inspect_approval_decision",
                    description: "Dry-run of approve_pending_fact. Runs the same gate evaluator but commits nothing. Returns 'would_approve' with the satisfied criteria or 'would_refuse' with the failing reason.",
                    properties: [
                        "pending_fact_id": ["type": "string", "description": "The pending_facts row ID to evaluate."],
                    ],
                    required: ["pending_fact_id"]
                ),
            ]
        ]
    }

    func callTool(params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String,
              let arguments = params["arguments"] as? [String: Any] else {
            throw MCPError.invalidParams("missing name or arguments")
        }

        switch name {
        case "submit_evidence":
            return try submitEvidence(arguments)
        case "submit_narrative_finding":
            return try submitNarrativeFinding(arguments)
        case "submit_lead":
            return try submitLead(arguments)
        case "get_profile":
            let id = arguments["profile_id"] as? String ?? ""
            let detail = try profileDetail(id: id)
            return ["content": [["type": "text", "text": detail]]]
        case "search_profiles":
            let query = arguments["query"] as? String ?? ""
            let results = try searchProfiles(query: query)
            return ["content": [["type": "text", "text": results]]]
        case "find_path":
            guard let from = arguments["from_id"] as? String,
                  let to = arguments["to_id"] as? String else {
                throw MCPError.invalidParams("find_path requires from_id and to_id")
            }
            let cap = min((arguments["max_hops"] as? Int) ?? 10, 25)
            let pathJSON = try findRelationshipPath(from: from, to: to, maxHops: cap)
            return ["content": [["type": "text", "text": pathJSON]]]
        case "submit_relationship_proposal":
            return try submitRelationshipProposal(arguments)
        case "dismiss_lead":
            return try dismissLead(arguments)
        case "flag_audit_override":
            return try flagAuditOverride(arguments)
        case "add_workbench_note":
            return try addWorkbenchNote(arguments)
        case "kick_off_research":
            return try kickOffResearch(arguments)
        case "get_run_status":
            return try getRunStatus(arguments)
        case "approve_pending_fact":
            return try approvePendingFact(arguments)
        case "inspect_approval_decision":
            return try inspectApprovalDecision(arguments)
        case _ where name == "get_run_status" || name.hasPrefix("ancestor://run_status/"):
            return try getRunStatus(arguments)
        default:
            throw MCPError.toolNotFound(name)
        }
    }

    // MARK: - Prompts

    func promptsList() -> [String: Any] {
        [
            "prompts": [
                [
                    "name": "research_profile",
                    "description": "Research a specific profile — provides full context and structured research task",
                    "arguments": [
                        ["name": "profile_id", "description": "Profile ID to research", "required": true],
                    ],
                ],
                [
                    "name": "find_ancestor",
                    "description": "Find a missing parent for a profile",
                    "arguments": [
                        ["name": "profile_id", "description": "Profile ID missing a parent", "required": true],
                        ["name": "role", "description": "father or mother", "required": true],
                    ],
                ],
            ]
        ]
    }

    func getPrompt(params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case "research_profile":
            let profileID = args["profile_id"] as? String ?? ""
            let context = (try? profileDetail(id: profileID)) ?? "{}"
            return [
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            "type": "text",
                            "text": """
                            Research this person and find additional evidence. Here is everything known about them:

                            \(context)

                            Search for:
                            1. Baptism/birth records in parish registers
                            2. Census appearances (1841-1921)
                            3. Marriage record
                            4. Death/burial record
                            5. Any other evidence (wills, newspapers, directories)

                            For each finding, use the submit_evidence tool with:
                            - The exact source URL
                            - The relevant text from the source
                            - Your reasoning connecting this source to this person

                            For any new people you discover (parents, siblings, spouses), use submit_lead.
                            """,
                        ],
                    ],
                ],
            ]
        default:
            return ["messages": []]
        }
    }

    // MARK: - Database Queries

    func treeSummary() throws -> String {
        try db.read { db in
            let profileCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profiles") ?? 0
            let relCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM relationships") ?? 0
            let pendingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_facts WHERE review_status = 'pending'") ?? 0
            let leadCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM leads WHERE status = 'new'") ?? 0

            let summary: [String: Any] = [
                "profiles": profileCount,
                "relationships": relCount,
                "pending_facts": pendingCount,
                "new_leads": leadCount,
            ]
            let data = try JSONSerialization.data(withJSONObject: summary, options: .prettyPrinted)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    func treeGaps() throws -> String {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, first_name, last_name, gender,
                       birth_date_original, birth_date_earliest,
                       death_date_original, death_date_earliest,
                       birth_location
                FROM profiles
                ORDER BY
                    CASE WHEN birth_date_original IS NULL THEN 0 ELSE 1 END +
                    CASE WHEN death_date_original IS NULL THEN 0 ELSE 1 END +
                    CASE WHEN birth_location IS NULL THEN 0 ELSE 1 END
                ASC
                """)

            let profiles = rows.map { row -> [String: Any] in
                var p: [String: Any] = ["id": row["id"] as String]
                p["name"] = "\(row["first_name"] as String? ?? "") \(row["last_name"] as String? ?? "")"
                if let b: String = row["birth_date_original"] { p["birth"] = b }
                if let d: String = row["death_date_original"] { p["death"] = d }
                if let l: String = row["birth_location"] { p["location"] = l }

                var missing: [String] = []
                if row["birth_date_original"] == nil { missing.append("birthDate") }
                if row["death_date_original"] == nil { missing.append("deathDate") }
                if row["birth_location"] == nil { missing.append("birthLocation") }
                p["missing"] = missing
                return p
            }

            let data = try JSONSerialization.data(withJSONObject: profiles, options: .prettyPrinted)
            return String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    func allProfiles() throws -> String {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, first_name, last_name, gender,
                       birth_date_original, birth_date_earliest, birth_date_latest,
                       death_date_original, death_date_earliest, death_date_latest,
                       birth_location, bio
                FROM profiles ORDER BY last_name, first_name
                """)

            let profiles = rows.map { row -> [String: Any] in
                var p: [String: Any] = [
                    "id": row["id"] as String,
                    "name": "\(row["first_name"] as String? ?? "") \(row["last_name"] as String? ?? "")",
                ]
                if let v: String = row["birth_date_original"] { p["birth"] = v }
                if let v: Int = row["birth_date_earliest"] { p["birth_year"] = v }
                if let v: String = row["death_date_original"] { p["death"] = v }
                if let v: Int = row["death_date_earliest"] { p["death_year"] = v }
                if let v: String = row["birth_location"] { p["location"] = v }
                if let v: String = row["gender"] { p["gender"] = v }
                return p
            }

            let data = try JSONSerialization.data(withJSONObject: profiles, options: .prettyPrinted)
            return String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    func profileDetail(id: String) throws -> String {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM profiles WHERE id = ?", arguments: [id]) else {
                return "{\"error\": \"profile not found\"}"
            }

            var p: [String: Any] = [
                "id": row["id"] as String,
                "first_name": row["first_name"] as String? ?? "",
                "last_name": row["last_name"] as String? ?? "",
            ]
            if let v: String = row["birth_date_original"] { p["birth_date"] = v }
            if let v: Int = row["birth_date_earliest"] { p["birth_year_earliest"] = v }
            if let v: Int = row["birth_date_latest"] { p["birth_year_latest"] = v }
            if let v: String = row["death_date_original"] { p["death_date"] = v }
            if let v: Int = row["death_date_earliest"] { p["death_year_earliest"] = v }
            if let v: String = row["birth_location"] { p["birth_location"] = v }
            if let v: String = row["gender"] { p["gender"] = v }
            if let v: String = row["bio"] { p["bio"] = v }

            // Relationships
            let rels = try Row.fetchAll(db, sql: """
                SELECT r.type, r.role, p.id, p.first_name, p.last_name,
                       p.birth_date_original, p.death_date_original
                FROM relationships r
                JOIN profiles p ON (r.to_id = p.id AND r.from_id = ?) OR (r.from_id = p.id AND r.to_id = ?)
                """, arguments: [id, id])

            var relationships: [[String: String]] = []
            for rel in rels {
                var r: [String: String] = [
                    "type": rel["type"] as String? ?? "",
                    "role": rel["role"] as String? ?? "",
                    "person": "\(rel["first_name"] as String? ?? "") \(rel["last_name"] as String? ?? "")",
                    "person_id": rel["id"] as String? ?? "",
                ]
                if let b: String = rel["birth_date_original"] { r["birth"] = b }
                if let d: String = rel["death_date_original"] { r["death"] = d }
                relationships.append(r)
            }
            p["relationships"] = relationships

            // Field sources — what's confirmed with source provenance
            let fieldSources = try Row.fetchAll(db, sql: """
                SELECT field, raw, origin FROM field_sources WHERE entity_id = ?
                """, arguments: [id])
            var confirmedFacts: [[String: String]] = []
            for fs in fieldSources {
                confirmedFacts.append([
                    "field": fs["field"] as String? ?? "",
                    "value": fs["raw"] as String? ?? "",
                    "source": fs["origin"] as String? ?? "",
                ])
            }
            p["confirmed_facts"] = confirmedFacts

            // Active leads for this profile
            let leadRows = try Row.fetchAll(db, sql: """
                SELECT name, relationship, status, evidence, birth_year, death_year
                FROM leads WHERE profile_id = ? ORDER BY created_at DESC
                """, arguments: [id])
            p["leads"] = leadRows.map { lead -> [String: Any] in
                var l: [String: Any] = [
                    "name": lead["name"] as String? ?? "",
                    "status": lead["status"] as String? ?? "",
                    "evidence": lead["evidence"] as String? ?? "",
                ]
                if let r: String = lead["relationship"] { l["relationship"] = r }
                if let y: Int = lead["birth_year"] { l["birth_year"] = y }
                if let y: Int = lead["death_year"] { l["death_year"] = y }
                return l
            }

            // Cited URLs from previous FR sessions (for source-recycling detection)
            let urlRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT source_url FROM pending_facts
                WHERE profile_id = ? AND source_url IS NOT NULL
                """, arguments: [id])
            p["cited_urls"] = urlRows.compactMap { $0["source_url"] as String? }

            // Research history
            let runs = try Row.fetchAll(db, sql: """
                SELECT mode, completed_at, fact_count, lead_count, cluster_count, gps_score
                FROM research_runs WHERE profile_id = ? ORDER BY completed_at DESC LIMIT 5
                """, arguments: [id])

            p["research_history"] = runs.map { run -> [String: Any] in
                var r: [String: Any] = [
                    "mode": run["mode"] as String? ?? "",
                    "facts": run["fact_count"] as Int? ?? 0,
                    "leads": run["lead_count"] as Int? ?? 0,
                    "clusters": run["cluster_count"] as Int? ?? 0,
                ]
                if let gps: Int = run["gps_score"] { r["gps"] = gps }
                return r
            }

            // Negative searches
            let negatives = try Row.fetchAll(db, sql: """
                SELECT source_id, record_type, searched_at
                FROM negative_searches WHERE profile_id = ? ORDER BY searched_at DESC
                """, arguments: [id])

            p["negative_searches"] = negatives.map { neg -> [String: String] in
                [
                    "source": neg["source_id"] as String? ?? "",
                    "type": neg["record_type"] as String? ?? "",
                ]
            }

            let data = try JSONSerialization.data(withJSONObject: p, options: .prettyPrinted)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    func searchProfiles(query: String) throws -> String {
        let q = "%\(query)%"
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, first_name, last_name, birth_date_original, death_date_original, birth_location
                FROM profiles
                WHERE first_name LIKE ? OR last_name LIKE ?
                ORDER BY last_name, first_name
                """, arguments: [q, q])

            let results = rows.map { row -> [String: Any] in
                var p: [String: Any] = [
                    "id": row["id"] as String,
                    "name": "\(row["first_name"] as String? ?? "") \(row["last_name"] as String? ?? "")",
                ]
                if let v: String = row["birth_date_original"] { p["birth"] = v }
                if let v: String = row["death_date_original"] { p["death"] = v }
                if let v: String = row["birth_location"] { p["location"] = v }
                return p
            }

            let data = try JSONSerialization.data(withJSONObject: results, options: .prettyPrinted)
            return String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    // MARK: - Evidence Submission

    func submitEvidence(_ args: [String: Any]) throws -> [String: Any] {
        guard let profileID = args["profile_id"] as? String,
              let field = args["field"] as? String,
              let value = args["value"] as? String,
              let sourceURL = args["source_url"] as? String,
              let sourceTitle = args["source_title"] as? String,
              let evidenceText = args["evidence_text"] as? String,
              let reasoning = args["reasoning"] as? String,
              let confidence = args["confidence"] as? String else {
            throw MCPError.invalidParams("missing required fields for submit_evidence")
        }

        // Validate field is in the accepted vocabulary
        let validFields: Set<String> = [
            "birthDate", "deathDate", "baptismDate", "burialDate",
            "birthLocation", "deathLocation", "marriageDate", "marriageLocation",
            "occupation", "address", "religion",
        ]
        guard validFields.contains(field) else {
            return [
                "content": [["type": "text", "text": "Field '\(field)' not supported. Use submit_narrative_finding for unstructured evidence, or submit_lead for new people."]]
            ]
        }

        // Idempotency key (§13) — deterministic ID from content
        let id = idempotencyKey(profileID: profileID, field: field, value: value, sourceURL: sourceURL)

        // Cap evidence_text at 200 chars (§5.4)
        let cappedEvidence = String(evidenceText.prefix(200))

        let sourcesJSON = try String(
            data: JSONSerialization.data(withJSONObject: [
                "source_url": sourceURL,
                "source_title": sourceTitle,
                "evidence_text": cappedEvidence,
                "reasoning": reasoning,
                "confidence": confidence,
                "agent": "field-researcher",
            ]),
            encoding: .utf8
        ) ?? "{}"

        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO pending_facts
                (id, profile_id, fact_kind, value_json, sources_json, review_status, created_at,
                 source_url, source_title, evidence_text, reasoning, agent_id, verification_status)
                VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, 'field-researcher', 'pending')
                """, arguments: [
                    id, profileID, field, value, sourcesJSON, Date(),
                    sourceURL, sourceTitle, cappedEvidence, reasoning,
                ])
        }

        return [
            "content": [
                [
                    "type": "text",
                    "text": "Evidence submitted: \(field) = \(value) for profile \(profileID). ID: \(id). Status: pending human review. The app will verify the source URL and score this through the 4-gate pipeline before presenting for review.",
                ]
            ]
        ]
    }

    func submitNarrativeFinding(_ args: [String: Any]) throws -> [String: Any] {
        guard let profileID = args["profile_id"] as? String,
              let category = args["category"] as? String,
              let description = args["description"] as? String,
              let sourceURL = args["source_url"] as? String,
              let sourceTitle = args["source_title"] as? String,
              let evidenceText = args["evidence_text"] as? String,
              let reasoning = args["reasoning"] as? String else {
            throw MCPError.invalidParams("missing required fields for submit_narrative_finding")
        }

        let dateOrPeriod = args["date_or_period"] as? String
        let id = idempotencyKey(profileID: profileID, field: category, value: description, sourceURL: sourceURL)
        let cappedEvidence = String(evidenceText.prefix(200))
        let cappedDescription = String(description.prefix(500))

        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO narrative_findings
                (id, profile_id, category, description, date_or_period,
                 source_url, source_title, evidence_text, reasoning,
                 agent_id, verification_status, submitted_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'field-researcher', 'pending', ?)
                """, arguments: [
                    id, profileID, category, cappedDescription, dateOrPeriod,
                    sourceURL, sourceTitle, cappedEvidence, reasoning, Date(),
                ])
        }

        return [
            "content": [
                [
                    "type": "text",
                    "text": "Narrative finding submitted: \(category) for profile \(profileID). ID: \(id). Status: pending verification.",
                ]
            ]
        ]
    }

    func submitLead(_ args: [String: Any]) throws -> [String: Any] {
        guard let sourceProfileID = args["source_profile_id"] as? String,
              let name = args["name"] as? String,
              let evidence = args["evidence"] as? String,
              let sourceURL = args["source_url"] as? String else {
            throw MCPError.invalidParams("missing required fields for submit_lead")
        }

        let id = "lead_fr_\(name.hashValue)_\(Date().timeIntervalSince1970)"
        let relationship = args["relationship"] as? String
        let birthYear = args["birth_year"] as? Int
        let deathYear = args["death_year"] as? Int

        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO leads
                (id, profile_id, name, surname, given_name, birth_year, death_year,
                 relationship, source, status, evidence, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'discovery', 'new', ?, ?)
                """, arguments: [
                    id, sourceProfileID, name,
                    name.split(separator: " ").last.map(String.init),
                    name.split(separator: " ").first.map(String.init),
                    birthYear, deathYear, relationship,
                    "\(evidence) [source: \(sourceURL)]", Date(),
                ])
        }

        return [
            "content": [
                [
                    "type": "text",
                    "text": "Lead submitted: \(name)\(relationship.map { " (\($0))" } ?? "") for profile \(sourceProfileID). ID: \(id). Status: new.",
                ]
            ]
        ]
    }

    // MARK: - Tier 2 Firewall-Safe Writes

    /// Propose a parent or spouse relationship between two existing
    /// profiles. Row lands in `pending_relationships` for human accept/
    /// reject — the app never auto-applies. Idempotent via deterministic
    /// id from the (from, to, type, role, source_url) tuple, so the same
    /// proposal submitted twice doesn't duplicate.
    func submitRelationshipProposal(_ args: [String: Any]) throws -> [String: Any] {
        guard let from = args["from_profile_id"] as? String,
              let to = args["to_profile_id"] as? String,
              let relType = args["rel_type"] as? String,
              let sourceURL = args["source_url"] as? String,
              let evidenceText = args["evidence_text"] as? String,
              let reasoning = args["reasoning"] as? String else {
            throw MCPError.invalidParams("missing required fields for submit_relationship_proposal")
        }
        guard relType == "parent" || relType == "spouse" else {
            throw MCPError.invalidParams("rel_type must be 'parent' or 'spouse'")
        }
        let role = args["role"] as? String
        let subtype = (args["subtype"] as? String) ?? "biological"
        let sourceTitle = args["source_title"] as? String

        let id = idempotencyKey(
            profileID: from + "|" + to,
            field: relType,
            value: role ?? "",
            sourceURL: sourceURL
        )
        let cappedEvidence = String(evidenceText.prefix(200))

        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO pending_relationships
                (id, from_profile_id, to_profile_id, rel_type, role, subtype,
                 review_status, created_at,
                 source_url, source_title, evidence_text, reasoning, agent_id)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, 'field-researcher')
                """, arguments: [
                    id, from, to, relType, role, subtype, Date(),
                    sourceURL, sourceTitle, cappedEvidence, reasoning,
                ])
        }

        return [
            "content": [
                [
                    "type": "text",
                    "text": "Relationship proposal submitted: \(from) → [\(relType)\(role.map { " (\($0))" } ?? "")] → \(to). ID: \(id). Status: pending human review.",
                ]
            ]
        ]
    }

    /// Mark a lead as dismissed. Pure state transition — no facts written.
    /// Idempotent (DOA on re-dismiss because the WHERE clause already finds
    /// `status = 'dismissed'`).
    func dismissLead(_ args: [String: Any]) throws -> [String: Any] {
        guard let leadID = args["lead_id"] as? String else {
            throw MCPError.invalidParams("dismiss_lead requires lead_id")
        }
        try db.write { db in
            try db.execute(sql: """
                UPDATE leads
                SET status = 'dismissed', resolved_at = ?, resolution = 'dismissed'
                WHERE id = ?
                """, arguments: [Date(), leadID])
        }
        return [
            "content": [[ "type": "text", "text": "Lead \(leadID) dismissed." ]]
        ]
    }

    /// Propose muting or snoozing an audit rule. Same firewall pattern as
    /// pending_facts — the row is inserted with `enabled = 0` (i.e. mute
    /// proposed) but the app gates whether the proposal actually takes
    /// effect during the next audit pass. The reason is stashed inside
    /// thresholds_json so it travels with the row without a new column.
    func flagAuditOverride(_ args: [String: Any]) throws -> [String: Any] {
        guard let ruleID = args["rule_id"] as? String,
              let scopeKind = args["scope_kind"] as? String,
              let reason = args["reason"] as? String else {
            throw MCPError.invalidParams("flag_audit_override requires rule_id, scope_kind, reason")
        }
        guard scopeKind == "global" || scopeKind == "profile" else {
            throw MCPError.invalidParams("scope_kind must be 'global' or 'profile'")
        }
        let scopeProfileID = args["scope_profile_id"] as? String
        if scopeKind == "profile" && (scopeProfileID ?? "").isEmpty {
            throw MCPError.invalidParams("profile-scope override requires scope_profile_id")
        }
        let snoozedUntilString = args["snoozed_until"] as? String
        let snoozedUntil: Date? = snoozedUntilString.flatMap { ISO8601DateFormatter().date(from: $0) }

        let id = idempotencyKey(
            profileID: scopeProfileID ?? "global",
            field: ruleID,
            value: scopeKind,
            sourceURL: snoozedUntilString ?? "permanent"
        )
        let thresholdsJSON: String = {
            let payload: [String: Any] = ["reason": reason, "agent": "field-researcher"]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let s = String(data: data, encoding: .utf8) else { return "{}" }
            return s
        }()

        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO audit_rule_overrides
                (id, rule_id, scope_kind, scope_profile_id, enabled,
                 snoozed_until, thresholds_json)
                VALUES (?, ?, ?, ?, 0, ?, ?)
                """, arguments: [
                    id, ruleID, scopeKind, scopeProfileID,
                    snoozedUntil, thresholdsJSON,
                ])
        }
        let until = snoozedUntilString.map { " until \($0)" } ?? " (permanent)"
        return [
            "content": [
                [
                    "type": "text",
                    "text": "Audit override flagged for rule '\(ruleID)' at scope '\(scopeKind)'\(until). ID: \(id).",
                ]
            ]
        ]
    }

    /// Attach a research note to a profile or relationship. Notes are
    /// user-scoped commentary; they don't assert facts and aren't gated
    /// by the firewall. Idempotent via deterministic ID over the content
    /// + attachment so re-submitting the same note doesn't duplicate.
    func addWorkbenchNote(_ args: [String: Any]) throws -> [String: Any] {
        guard let kind = args["attachment_kind"] as? String,
              let attachmentID = args["attachment_id"] as? String,
              let content = args["content"] as? String else {
            throw MCPError.invalidParams("add_workbench_note requires attachment_kind, attachment_id, content")
        }
        guard kind == "profile" || kind == "relationship" else {
            throw MCPError.invalidParams("attachment_kind must be 'profile' or 'relationship'")
        }
        let tag = (args["tag"] as? String) ?? "observation"
        let attachedTo: String = {
            // Mirror the in-app NoteAttachment JSON shape: { kind, id }.
            let payload: [String: Any] = ["kind": kind, "id": attachmentID]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let s = String(data: data, encoding: .utf8) else { return "{}" }
            return s
        }()

        let id = idempotencyKey(
            profileID: attachmentID,
            field: "note",
            value: content,
            sourceURL: tag
        )

        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO workbench_notes
                (id, content, tag, attached_to, attachment_kind, attachment_id,
                 created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    id, content, tag, attachedTo, kind, attachmentID,
                    Date(), Date(),
                ])
        }
        return [
            "content": [
                [
                    "type": "text",
                    "text": "Workbench note added (\(tag)) on \(kind) \(attachmentID). ID: \(id).",
                ]
            ]
        ]
    }

    // MARK: - Tier 3 Pipeline Orchestration

    /// Enqueue a research run. Mutually-exclusive `profile_id` / `lead_id`.
    /// The app's watcher dequeues, fires the pipeline, and updates the
    /// row's status; the caller polls `get_run_status` for completion.
    func kickOffResearch(_ args: [String: Any]) throws -> [String: Any] {
        let profileID = (args["profile_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let leadID = (args["lead_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard profileID != nil || leadID != nil else {
            throw MCPError.invalidParams("kick_off_research requires either profile_id or lead_id")
        }
        if profileID != nil && leadID != nil {
            throw MCPError.invalidParams("profile_id and lead_id are mutually exclusive")
        }

        let mode = (args["mode"] as? String) ?? "extend"
        let scope = (args["scope"] as? String) ?? "county"
        let autoAccept = (args["auto_accept"] as? String) ?? "none"

        let modeValid: Set<String> = ["verify", "extend", "discover", "all"]
        let scopeValid: Set<String> = ["parish", "district", "county", "adjacent", "national"]
        let autoAcceptValid: Set<String> = ["none", "confirmed"]
        guard modeValid.contains(mode) else {
            throw MCPError.invalidParams("mode must be one of: verify, extend, discover, all")
        }
        guard scopeValid.contains(scope) else {
            throw MCPError.invalidParams("scope must be one of: parish, district, county, adjacent, national")
        }
        guard autoAcceptValid.contains(autoAccept) else {
            throw MCPError.invalidParams("auto_accept must be one of: none, confirmed")
        }

        let id = "req_\(UUID().uuidString)"
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO research_run_requests
                (id, profile_id, lead_id, mode, scope, status,
                 created_at, requested_by, auto_accept)
                VALUES (?, ?, ?, ?, ?, 'queued', ?, 'mcp', ?)
                """, arguments: [id, profileID, leadID, mode, scope, Date(), autoAccept])
        }

        let autoNote = autoAccept == "confirmed"
            ? " Auto-accept ON (Debug build required; ignored otherwise)."
            : ""
        return [
            "content": [
                [
                    "type": "text",
                    "text": "Research run queued. request_id: \(id). Target: \(profileID.map { "profile \($0)" } ?? "lead \(leadID ?? "?")"). Mode: \(mode), scope: \(scope).\(autoNote) Poll get_run_status for completion.",
                ]
            ]
        ]
    }

    /// Poll the watcher-set status for a queued research request.
    func getRunStatus(_ args: [String: Any]) throws -> [String: Any] {
        guard let requestID = args["request_id"] as? String else {
            throw MCPError.invalidParams("get_run_status requires request_id")
        }
        let text: String = try db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, profile_id, lead_id, mode, scope, status, run_id,
                       error, created_at, started_at, completed_at
                FROM research_run_requests WHERE id = ?
                """, arguments: [requestID]) else {
                return Self.jsonString(["error": "request_not_found", "request_id": requestID])
            }
            var payload: [String: Any] = [
                "request_id": row["id"] as String? ?? "",
                "status": row["status"] as String? ?? "queued",
                "mode": row["mode"] as String? ?? "",
                "scope": row["scope"] as String? ?? "",
            ]
            if let v: String = row["profile_id"] { payload["profile_id"] = v }
            if let v: String = row["lead_id"] { payload["lead_id"] = v }
            if let v: String = row["run_id"] { payload["run_id"] = v }
            if let v: String = row["error"] { payload["error"] = v }
            if let d: Date = row["created_at"] {
                payload["created_at"] = ISO8601DateFormatter().string(from: d)
            }
            if let d: Date = row["started_at"] {
                payload["started_at"] = ISO8601DateFormatter().string(from: d)
            }
            if let d: Date = row["completed_at"] {
                payload["completed_at"] = ISO8601DateFormatter().string(from: d)
            }
            return Self.jsonString(payload)
        }
        return ["content": [["type": "text", "text": text]]]
    }

    // MARK: - Tier 1 Read Queries

    /// Every spouse + parent edge attached to the profile, with the other
    /// party's name and dates inlined so the caller doesn't have to fan out
    /// a second query per edge.
    func relationshipsForProfile(id: String) throws -> String {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.id AS rel_id, r.type, r.role, r.subtype,
                       r.marriage_date_original, r.marriage_location,
                       r.divorce_date_original,
                       r.from_id, r.to_id,
                       p.id AS other_id, p.first_name, p.last_name,
                       p.birth_date_original, p.death_date_original
                FROM relationships r
                JOIN profiles p ON (
                    (r.to_id = p.id AND r.from_id = ?) OR
                    (r.from_id = p.id AND r.to_id = ?)
                )
                """, arguments: [id, id])

            let edges = rows.map { row -> [String: Any] in
                var e: [String: Any] = [
                    "relationship_id": row["rel_id"] as String? ?? "",
                    "type": row["type"] as String? ?? "",
                    "subtype": row["subtype"] as String? ?? "",
                    "other_id": row["other_id"] as String? ?? "",
                    "other_name": "\(row["first_name"] as String? ?? "") \(row["last_name"] as String? ?? "")",
                    "direction": (row["from_id"] as String?) == id ? "outgoing" : "incoming",
                ]
                if let r: String = row["role"] { e["role"] = r }
                if let v: String = row["marriage_date_original"] { e["marriage_date"] = v }
                if let v: String = row["marriage_location"] { e["marriage_location"] = v }
                if let v: String = row["divorce_date_original"] { e["divorce_date"] = v }
                if let v: String = row["birth_date_original"] { e["other_birth"] = v }
                if let v: String = row["death_date_original"] { e["other_death"] = v }
                return e
            }

            return Self.jsonString(edges)
        }
    }

    /// Past pipeline runs for one profile — what was tried, when, and what
    /// it produced. Useful for "have I already researched this person?" or
    /// "what mode gave the best GPS score?" questions from a script.
    func researchRunsForProfile(id: String) throws -> String {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, mode, started_at, completed_at,
                       fact_count, lead_count, cluster_count, gps_score
                FROM research_runs
                WHERE profile_id = ?
                ORDER BY completed_at DESC
                """, arguments: [id])

            let runs = rows.map { row -> [String: Any] in
                var r: [String: Any] = [
                    "id": row["id"] as String? ?? "",
                    "mode": row["mode"] as String? ?? "",
                    "facts": row["fact_count"] as Int? ?? 0,
                    "leads": row["lead_count"] as Int? ?? 0,
                    "clusters": row["cluster_count"] as Int? ?? 0,
                ]
                if let s: Date = row["started_at"] {
                    r["started_at"] = ISO8601DateFormatter().string(from: s)
                }
                if let c: Date = row["completed_at"] {
                    r["completed_at"] = ISO8601DateFormatter().string(from: c)
                }
                if let gps: Int = row["gps_score"] { r["gps"] = gps }
                return r
            }

            return Self.jsonString(runs)
        }
    }

    /// Full leads queue. Optional status filter ("new", "investigating",
    /// "investigated", "promoted", "dismissed"). Surfaces the same fields
    /// the Leads tab renders so a caller can decide what to investigate.
    func leadsList(status: String?) throws -> String {
        try db.read { db in
            let rows: [Row]
            if let status, !status.isEmpty {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, profile_id, name, surname, given_name,
                           birth_year, death_year, relationship, source, status,
                           evidence, created_at, investigated_at, resolved_at, resolution
                    FROM leads WHERE status = ?
                    ORDER BY created_at DESC
                    """, arguments: [status])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, profile_id, name, surname, given_name,
                           birth_year, death_year, relationship, source, status,
                           evidence, created_at, investigated_at, resolved_at, resolution
                    FROM leads ORDER BY created_at DESC
                    """)
            }

            let leads = rows.map { row -> [String: Any] in
                var l: [String: Any] = [
                    "id": row["id"] as String? ?? "",
                    "profile_id": row["profile_id"] as String? ?? "",
                    "name": row["name"] as String? ?? "",
                    "status": row["status"] as String? ?? "",
                    "source": row["source"] as String? ?? "",
                ]
                if let v: String = row["surname"] { l["surname"] = v }
                if let v: String = row["given_name"] { l["given_name"] = v }
                if let v: Int = row["birth_year"] { l["birth_year"] = v }
                if let v: Int = row["death_year"] { l["death_year"] = v }
                if let v: String = row["relationship"] { l["relationship"] = v }
                if let v: String = row["evidence"] { l["evidence"] = v }
                if let v: String = row["resolution"] { l["resolution"] = v }
                return l
            }

            return Self.jsonString(leads)
        }
    }

    /// Pending-facts queue for a profile — submitted evidence not yet
    /// applied to the profile fields. The firewall lives here; the caller
    /// sees what's waiting on human review.
    func pendingFactsForProfile(id: String) throws -> String {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, fact_kind, value_json, review_status, created_at,
                       source_url, source_title, evidence_text, reasoning,
                       agent_id, verification_status
                FROM pending_facts
                WHERE profile_id = ?
                ORDER BY created_at DESC
                """, arguments: [id])

            let facts = rows.map { row -> [String: Any] in
                var f: [String: Any] = [
                    "id": row["id"] as String? ?? "",
                    "field": row["fact_kind"] as String? ?? "",
                    "value": row["value_json"] as String? ?? "",
                    "review_status": row["review_status"] as String? ?? "pending",
                    "verification_status": row["verification_status"] as String? ?? "pending",
                ]
                if let v: String = row["source_url"] { f["source_url"] = v }
                if let v: String = row["source_title"] { f["source_title"] = v }
                if let v: String = row["evidence_text"] { f["evidence_text"] = v }
                if let v: String = row["reasoning"] { f["reasoning"] = v }
                if let v: String = row["agent_id"] { f["agent"] = v }
                if let d: Date = row["created_at"] {
                    f["created_at"] = ISO8601DateFormatter().string(from: d)
                }
                return f
            }

            return Self.jsonString(facts)
        }
    }

    /// Evidence records — the per-profile archive of every scored source
    /// record across every research run. Same payload the UI uses for the
    /// "evidence" tab; lets a script walk citations programmatically.
    func evidenceForProfile(id: String) throws -> String {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, source_id, source_record_id, record_type, verdict,
                       citation_full, citation_url, scored_at
                FROM evidence_records
                WHERE profile_id = ?
                ORDER BY scored_at DESC
                """, arguments: [id])

            let records = rows.map { row -> [String: Any] in
                var r: [String: Any] = [
                    "id": row["id"] as String? ?? "",
                    "source": row["source_id"] as String? ?? "",
                    "source_record_id": row["source_record_id"] as String? ?? "",
                    "record_type": row["record_type"] as String? ?? "",
                    "verdict": row["verdict"] as String? ?? "",
                ]
                if let v: String = row["citation_full"] { r["citation"] = v }
                if let v: String = row["citation_url"] { r["citation_url"] = v }
                if let d: Date = row["scored_at"] {
                    r["scored_at"] = ISO8601DateFormatter().string(from: d)
                }
                return r
            }

            return Self.jsonString(records)
        }
    }

    /// Life events attached to a profile (census / burial / probate / parish
    /// / military). Returns the typed event plus its date and location.
    func lifeEventsForProfile(id: String) throws -> String {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, type, date_original, date_earliest, date_latest,
                       end_date_original, location, description, confidence
                FROM life_events
                WHERE profile_id = ?
                ORDER BY date_earliest NULLS LAST, date_original
                """, arguments: [id])

            let events = rows.map { row -> [String: Any] in
                var e: [String: Any] = [
                    "id": row["id"] as String? ?? "",
                    "type": row["type"] as String? ?? "",
                    "confidence": row["confidence"] as Int? ?? 0,
                ]
                if let v: String = row["date_original"] { e["date"] = v }
                if let v: Int = row["date_earliest"] { e["year_earliest"] = v }
                if let v: Int = row["date_latest"] { e["year_latest"] = v }
                if let v: String = row["end_date_original"] { e["end_date"] = v }
                if let v: String = row["location"] { e["location"] = v }
                if let v: String = row["description"] { e["description"] = v }
                return e
            }

            return Self.jsonString(events)
        }
    }

    /// Lineage walk for a profile — direct ancestors (via parent edges
    /// where the profile is the `to_id`) and direct descendants (where the
    /// profile is the `from_id`). Bounded by `depth`. Cycle-safe via a
    /// visited set; ghost profiles included because they're real graph nodes.
    func lineage(id: String, depth: Int) throws -> String {
        try db.read { db in
            // Pull all parent edges once so the walk is O(N) over them.
            let edges = try Row.fetchAll(db, sql: """
                SELECT from_id, to_id, role
                FROM relationships WHERE type = 'parent'
                """)
            let profileNames = try Row.fetchAll(db, sql: """
                SELECT id, first_name, last_name, birth_date_original, death_date_original
                FROM profiles
                """)
            var nameByID: [String: [String: Any]] = [:]
            for p in profileNames {
                let pid: String = p["id"]
                var entry: [String: Any] = [
                    "id": pid,
                    "name": "\(p["first_name"] as String? ?? "") \(p["last_name"] as String? ?? "")",
                ]
                if let v: String = p["birth_date_original"] { entry["birth"] = v }
                if let v: String = p["death_date_original"] { entry["death"] = v }
                nameByID[pid] = entry
            }

            // parents[child_id] = [(parent_id, role)]; children[parent_id] = [child_id]
            var parents: [String: [(String, String?)]] = [:]
            var children: [String: [String]] = [:]
            for e in edges {
                let from: String = e["from_id"]
                let to: String = e["to_id"]
                let role: String? = e["role"]
                parents[to, default: []].append((from, role))
                children[from, default: []].append(to)
            }

            let ancestors = Self.walk(start: id, depth: depth, edges: parents, nameByID: nameByID)
            let descendants = Self.walkSimple(start: id, depth: depth, edges: children, nameByID: nameByID)
            let payload: [String: Any] = [
                "subject_id": id,
                "subject": nameByID[id] ?? ["id": id],
                "ancestors": ancestors,
                "descendants": descendants,
            ]
            return Self.jsonString(payload)
        }
    }

    /// Audit rule overrides (mutes, snoozes, per-profile threshold tweaks).
    /// Live audit findings aren't persisted — they're computed by
    /// `AuditEngine` in-process inside the app — so MCP can't return them
    /// here. The overrides themselves are useful context for a caller
    /// proposing fixes.
    /// Per-profile read of the `research_hypotheses` table (migration
    /// v26). Returns pipeline-generated hypotheses with verdict,
    /// evidence ids, reasoning, attempts counter, and history.
    /// User-rejected rows are excluded — they stay in the table for
    /// dedup but aren't surfaced via this resource. Empty until T12
    /// wires generators in; T11 ships the read path so external tooling
    /// can see hypothesis state immediately.
    func researchHypothesesForProfile(id: String) throws -> String {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, kind_discriminator, kind_payload, verdict,
                       is_model_assisted, supporting_evidence,
                       contradicting_evidence, reasoning, created_at,
                       last_tested_at, attempts, history
                FROM research_hypotheses
                WHERE subject_profile_id = ? AND user_rejected = 0
                ORDER BY last_tested_at DESC
                """, arguments: [id])
            let iso = ISO8601DateFormatter()
            let hypotheses = rows.map { row -> [String: Any] in
                var h: [String: Any] = [
                    "id": row["id"] as String? ?? "",
                    "kind": row["kind_discriminator"] as String? ?? "",
                    "verdict": row["verdict"] as String? ?? "",
                    "is_model_assisted": (row["is_model_assisted"] as Int? ?? 0) != 0,
                    "reasoning": row["reasoning"] as String? ?? "",
                    "attempts": row["attempts"] as Int? ?? 0,
                ]
                if let d: Date = row["created_at"] {
                    h["created_at"] = iso.string(from: d)
                }
                if let d: Date = row["last_tested_at"] {
                    h["last_tested_at"] = iso.string(from: d)
                }
                // Inline JSON payloads as raw strings — the consumer
                // (Claude, scripts) decides whether to parse.
                if let s: String = row["kind_payload"] { h["kind_payload"] = s }
                if let s: String = row["supporting_evidence"] { h["supporting_evidence"] = s }
                if let s: String = row["contradicting_evidence"] { h["contradicting_evidence"] = s }
                if let s: String = row["history"] { h["history"] = s }
                return h
            }
            return Self.jsonString([
                "profile_id": id,
                "count": hypotheses.count,
                "hypotheses": hypotheses,
            ])
        }
    }

    func auditOverrides() throws -> String {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, rule_id, scope_kind, scope_profile_id, enabled,
                       snoozed_until, thresholds_json
                FROM audit_rule_overrides
                """)
            let overrides = rows.map { row -> [String: Any] in
                var o: [String: Any] = [
                    "id": row["id"] as String? ?? "",
                    "rule": row["rule_id"] as String? ?? "",
                    "scope": row["scope_kind"] as String? ?? "",
                    "enabled": (row["enabled"] as Int? ?? 1) != 0,
                ]
                if let v: String = row["scope_profile_id"] { o["profile_id"] = v }
                if let d: Date = row["snoozed_until"] {
                    o["snoozed_until"] = ISO8601DateFormatter().string(from: d)
                }
                if let j: String = row["thresholds_json"], j != "{}" { o["thresholds"] = j }
                return o
            }
            return Self.jsonString(overrides)
        }
    }

    /// BFS over the parent + spouse edge set. Returns the chain of profile
    /// IDs and how each step connects (e.g. parent, spouse). Capped by
    /// `maxHops` to bound runtime on dense pedigrees.
    func findRelationshipPath(from: String, to: String, maxHops: Int) throws -> String {
        if from == to {
            return Self.jsonString(["path": [from], "hops": 0])
        }
        return try db.read { db in
            // Adjacency from all relationship edges (both directions).
            let rows = try Row.fetchAll(db, sql: """
                SELECT from_id, to_id, type, role FROM relationships
                """)
            var adj: [String: [(neighbour: String, label: String)]] = [:]
            for r in rows {
                let a: String = r["from_id"]
                let b: String = r["to_id"]
                let kind: String = r["type"]
                let role: String = r["role"] as String? ?? ""
                let forwardLabel = kind == "parent"
                    ? (role.isEmpty ? "parent-of" : "\(role)-of")
                    : "spouse"
                let backwardLabel = kind == "parent" ? "child-of" : "spouse"
                adj[a, default: []].append((b, forwardLabel))
                adj[b, default: []].append((a, backwardLabel))
            }

            var queue: [(node: String, path: [(String, String)], depth: Int)] = [(from, [], 0)]
            var visited: Set<String> = [from]
            while !queue.isEmpty {
                let head = queue.removeFirst()
                if head.depth >= maxHops { continue }
                for next in adj[head.node] ?? [] {
                    if visited.contains(next.neighbour) { continue }
                    let newPath = head.path + [(next.neighbour, next.label)]
                    if next.neighbour == to {
                        let nodes = [from] + newPath.map(\.0)
                        let steps = newPath.map { ["to": $0.0, "via": $0.1] }
                        let payload: [String: Any] = [
                            "path": nodes,
                            "steps": steps,
                            "hops": newPath.count,
                        ]
                        return Self.jsonString(payload)
                    }
                    visited.insert(next.neighbour)
                    queue.append((next.neighbour, newPath, head.depth + 1))
                }
            }
            return Self.jsonString(["path": NSNull(), "hops": NSNull(), "reason": "no path within \(maxHops) hops"])
        }
    }

    // MARK: - Lineage walk helpers

    /// Ancestor walk — preserves the parent role at each step so the
    /// caller knows which side of the family each link is on.
    private static func walk(
        start: String,
        depth: Int,
        edges: [String: [(String, String?)]],
        nameByID: [String: [String: Any]]
    ) -> [[String: Any]] {
        guard depth > 0 else { return [] }
        var out: [[String: Any]] = []
        for (parentID, role) in edges[start] ?? [] {
            var entry: [String: Any] = nameByID[parentID] ?? ["id": parentID]
            if let r = role { entry["role"] = r }
            entry["ancestors"] = walk(start: parentID, depth: depth - 1, edges: edges, nameByID: nameByID)
            out.append(entry)
        }
        return out
    }

    /// Descendant walk — no role marker (parent role applies to the parent,
    /// not the child).
    private static func walkSimple(
        start: String,
        depth: Int,
        edges: [String: [String]],
        nameByID: [String: [String: Any]]
    ) -> [[String: Any]] {
        guard depth > 0 else { return [] }
        var out: [[String: Any]] = []
        for childID in edges[start] ?? [] {
            var entry: [String: Any] = nameByID[childID] ?? ["id": childID]
            entry["descendants"] = walkSimple(start: childID, depth: depth - 1, edges: edges, nameByID: nameByID)
            out.append(entry)
        }
        return out
    }

    /// JSON-serialise a payload, returning a sentinel string on failure so
    /// the stdio loop always yields valid JSON.
    private static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"serialization_failed\"}"
        }
        return text
    }

    // MARK: - Helpers

    /// Deterministic ID from content for idempotency (§13).
    func idempotencyKey(profileID: String, field: String, value: String, sourceURL: String) -> String {
        let input = "\(profileID)|\(field)|\(value)|\(sourceURL)"
        // Simple hash — not cryptographic, just deterministic
        var hash: UInt64 = 5381
        for byte in input.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "fr_%016llx", hash)
    }

    func resource(_ uri: String, _ name: String, _ description: String) -> [String: String] {
        ["uri": uri, "name": name, "description": description, "mimeType": "application/json"]
    }

    func tool(name: String, description: String, properties: [String: [String: String]], required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ] as [String: Any],
        ]
    }

    // MARK: - Auto-approval (AUTO_APPROVAL_VIA_MCP_SPEC.md)
    //
    // The deterministic gate runs entirely inside the MCP package; it
    // does not import the app's research module. The implementation is
    // deliberately a *conservative subset* of what the app's full review
    // does — anything the gate cannot judge unambiguously refuses, and
    // the fact remains in `pending_facts` for normal human review.

    /// Fields the gate is allowed to commit. Names/gender/bio are
    /// excluded by design — identity-shaping or narrative, see the spec.
    static let autoApprovableFields: Set<String> = [
        "birthDate", "deathDate", "baptismDate", "burialDate",
        "birthLocation", "deathLocation",
        "marriageDate", "marriageLocation",
        "occupation", "address",
    ]

    /// URL hosts treated as primary or secondary trust tier. Conservative
    /// allow-list — anything off this list refuses with
    /// `trust_tier_insufficient`. Extend with care; each addition expands
    /// what the rules can commit without a human keystroke.
    static let trustedHosts: Set<String> = [
        "freebmd.org.uk", "www.freebmd.org.uk",
        "freecen.org.uk", "www.freecen.org.uk", "search.freecen.org.uk",
        "freereg.org.uk", "www.freereg.org.uk",
        "familysearch.org", "www.familysearch.org",
        "cwgc.org", "www.cwgc.org",
        "probatesearch.service.gov.uk",
        "wirksworth.org.uk", "www.wirksworth.org.uk",
        "findagrave.com", "www.findagrave.com",
    ]

    /// Runtime gate for the auto-approval write path. Default off.
    /// The MVP gate (trust tier + convergence + dispute + field-set)
    /// catches rule violations but not fabrications — an AI that
    /// asserts a value its source URL doesn't actually contain would
    /// pass every criterion. §14.B.1 (defensive hallucination
    /// re-check) closes that hole by re-fetching the URL at gate
    /// time. Until §14.B.1 ships, auto-approval is off by default.
    /// Set `ANCESTOR_MCP_AUTO_APPROVE=1` to enable for dev work.
    static func isAutoApprovalEnabled() -> Bool {
        let v = ProcessInfo.processInfo.environment["ANCESTOR_MCP_AUTO_APPROVE"]
        return v == "1" || v?.lowercased() == "true"
    }

    func approvePendingFact(_ args: [String: Any]) throws -> [String: Any] {
        guard let pendingFactID = args["pending_fact_id"] as? String else {
            throw MCPError.invalidParams("approve_pending_fact requires pending_fact_id")
        }

        guard Self.isAutoApprovalEnabled() else {
            let payload: [String: Any] = [
                "status": "refused",
                "reason": "auto_approval_gate_disabled",
                "detail": "Auto-approval is disabled by default pending §14.B.1 (defensive hallucination re-check). The MVP gate validates rule compliance, not source-value fidelity, so an AI hallucination would currently pass. Set ANCESTOR_MCP_AUTO_APPROVE=1 in the environment to override for dev work.",
                "pending_fact_id": pendingFactID,
                "still_pending": true,
            ]
            let json = (try? String(data: JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted), encoding: .utf8)) ?? "{}"
            return ["content": [["type": "text", "text": json]]]
        }

        let decision = try evaluateApproval(pendingFactID: pendingFactID)
        switch decision {
        case .refuse(let reason, let detail):
            let payload: [String: Any] = [
                "status": "refused",
                "reason": reason,
                "detail": detail,
                "pending_fact_id": pendingFactID,
                "still_pending": true,
            ]
            let json = (try? String(data: JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted), encoding: .utf8)) ?? "{}"
            return ["content": [["type": "text", "text": json]]]
        case .approve(let criteria):
            let committed = try commitPendingFact(pendingFactID: pendingFactID, criteria: criteria)
            var payload: [String: Any] = [
                "status": "approved",
                "pending_fact_id": pendingFactID,
                "criteria_met": criteria,
            ]
            payload["profile_id"] = committed.profileID
            payload["field"] = committed.field
            payload["value"] = committed.value
            payload["committed_at"] = ISO8601DateFormatter().string(from: committed.committedAt)
            let json = (try? String(data: JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted), encoding: .utf8)) ?? "{}"
            return ["content": [["type": "text", "text": json]]]
        }
    }

    func inspectApprovalDecision(_ args: [String: Any]) throws -> [String: Any] {
        guard let pendingFactID = args["pending_fact_id"] as? String else {
            throw MCPError.invalidParams("inspect_approval_decision requires pending_fact_id")
        }

        let decision = try evaluateApproval(pendingFactID: pendingFactID)
        let payload: [String: Any]
        switch decision {
        case .approve(let criteria):
            payload = [
                "status": "would_approve",
                "pending_fact_id": pendingFactID,
                "criteria_met": criteria,
            ]
        case .refuse(let reason, let detail):
            payload = [
                "status": "would_refuse",
                "pending_fact_id": pendingFactID,
                "reason": reason,
                "detail": detail,
            ]
        }
        let json = (try? String(data: JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted), encoding: .utf8)) ?? "{}"
        return ["content": [["type": "text", "text": json]]]
    }

    /// Outcome of evaluating a pending fact against the gate.
    enum ApprovalDecision {
        case approve(criteria: [String: Any])
        case refuse(reason: String, detail: String)
    }

    struct ApprovalCommit {
        let profileID: String
        let field: String
        let value: String
        let committedAt: Date
    }

    /// Read-only evaluation against the gate. Used by both
    /// `approve_pending_fact` and `inspect_approval_decision` — keeps
    /// the rule logic single-rooted so the dry-run can't drift from
    /// the live commit.
    func evaluateApproval(pendingFactID: String) throws -> ApprovalDecision {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM pending_facts WHERE id = ?", arguments: [pendingFactID]) else {
                return .refuse(
                    reason: "pending_fact_not_found",
                    detail: "No pending_facts row with id \(pendingFactID)."
                )
            }

            let factKind: String = row["fact_kind"] ?? ""
            let value: String = row["value_json"] ?? ""
            let profileID: String = row["profile_id"] ?? ""
            let sourceURL: String? = row["source_url"]
            let sourceTitle: String = row["source_title"] ?? ""
            let reviewStatus: String = row["review_status"] ?? "pending"

            // Already processed (accepted/rejected) — no-op refuse.
            guard reviewStatus == "pending" else {
                return .refuse(
                    reason: "pending_fact_already_processed",
                    detail: "Pending fact already in status '\(reviewStatus)'."
                )
            }

            // Auto-approvable field set.
            guard Self.autoApprovableFields.contains(factKind) else {
                return .refuse(
                    reason: "field_not_auto_approvable",
                    detail: "Field '\(factKind)' is excluded from auto-approval. Names, gender, and bio are always human-reviewed."
                )
            }

            // Trust tier — URL host must be in the trusted list.
            guard let url = sourceURL, !url.isEmpty,
                  let host = Self.urlHost(url) else {
                return .refuse(
                    reason: "trust_tier_insufficient",
                    detail: "Pending fact has no source URL to classify."
                )
            }
            guard Self.trustedHosts.contains(host) else {
                return .refuse(
                    reason: "trust_tier_insufficient",
                    detail: "Source host '\(host)' is not on the auto-approval trusted-host list."
                )
            }

            // Existing field_sources for this (profile, field): split into
            // corroborating (same value) vs. conflicting (different value).
            let profileField = Self.profileFieldFor(factKind: factKind)
            let existingRows = try Row.fetchAll(db, sql: """
                SELECT raw FROM field_sources
                WHERE entity_id = ? AND entity_kind = 'profile' AND field = ?
                """, arguments: [profileID, profileField])

            var corroboratingLineages: Set<String> = []
            var conflicts: [String] = []
            for r in existingRows {
                let raw: String = r["raw"] ?? ""
                let existingValue = Self.extractValueFromRaw(raw)
                if existingValue.isEmpty { continue }
                if Self.valuesMatch(existingValue, value, field: factKind) {
                    if let lineage = Self.lineageLabelFromRaw(raw) {
                        corroboratingLineages.insert(lineage)
                    }
                } else {
                    conflicts.append(existingValue)
                }
            }

            if !conflicts.isEmpty {
                return .refuse(
                    reason: "would_create_dispute",
                    detail: "Existing field value(s) [\(conflicts.joined(separator: "; "))] conflict with proposed '\(value)'."
                )
            }

            // Convergence: need at least 2 independent lineages. The
            // pending fact's own lineage (its URL host) counts once;
            // corroborating field_sources with distinct source titles
            // each count once more.
            var independentLineages = corroboratingLineages
            independentLineages.insert(host)

            guard independentLineages.count >= 2 else {
                return .refuse(
                    reason: "convergence_insufficient",
                    detail: "Need ≥ 2 independent lineages; found \(independentLineages.count) (\(independentLineages.sorted().joined(separator: ", "))). Pending fact must corroborate at least one existing source from a different lineage."
                )
            }

            return .approve(criteria: [
                "trustTier": "primary_or_secondary",
                "sourceHost": host,
                "sourceTitle": sourceTitle,
                "independentLineageCount": independentLineages.count,
                "lineages": independentLineages.sorted(),
                "wouldCreateDispute": false,
                "fieldAutoApprovable": true,
                "field": factKind,
                "value": value,
                "profileID": profileID,
            ])
        }
    }

    /// Commit the pending fact. Mirrors the app's `acceptFinding` write
    /// shape (profiles + field_sources + pending_facts update) plus the
    /// new approval metadata columns introduced by v28.
    func commitPendingFact(pendingFactID: String, criteria: [String: Any]) throws -> ApprovalCommit {
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM pending_facts WHERE id = ?", arguments: [pendingFactID]) else {
                throw MCPError.invalidParams("pending fact \(pendingFactID) disappeared between evaluation and commit")
            }

            let factKind: String = row["fact_kind"] ?? ""
            let value: String = row["value_json"] ?? ""
            let profileID: String = row["profile_id"] ?? ""
            let sourceTitle: String = row["source_title"] ?? ""

            // Apply to profile column where one exists. Occupation /
            // address don't map to a column (they're narrative life-event
            // details); the field_sources row still records the evidence.
            let (column, datePrefix) = Self.profileColumnFor(factKind: factKind)
            if let column = column {
                try db.execute(
                    sql: "UPDATE profiles SET \(column) = ? WHERE id = ?",
                    arguments: [value, profileID]
                )
                if !datePrefix.isEmpty, let year = Self.extractYear(from: value) {
                    try db.execute(
                        sql: "UPDATE profiles SET \(datePrefix)_earliest = ?, \(datePrefix)_latest = ? WHERE id = ?",
                        arguments: [year, year, profileID]
                    )
                }
            }

            // field_sources row — same shape as the app's acceptFinding.
            let profileField = Self.profileFieldFor(factKind: factKind)
            try db.execute(sql: """
                INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at)
                VALUES (?, 'profile', ?, 'field-researcher', ?, ?)
                """, arguments: [
                    profileID, profileField,
                    "\(value) [\(sourceTitle)]",
                    Date(),
                ])

            // pending_facts: accepted + approval metadata.
            let now = Date()
            let criteriaJSON = (try? String(
                data: JSONSerialization.data(withJSONObject: criteria, options: []),
                encoding: .utf8
            )) ?? "{}"
            try db.execute(sql: """
                UPDATE pending_facts SET
                    review_status = 'accepted',
                    verification_status = 'verified',
                    reviewed_at = ?,
                    approval_method = 'rules',
                    approval_rule_ids = ?,
                    approved_at = ?
                WHERE id = ?
                """, arguments: [now, criteriaJSON, now, pendingFactID])

            return ApprovalCommit(
                profileID: profileID,
                field: factKind,
                value: value,
                committedAt: now
            )
        }
    }

    // MARK: - Auto-approval helpers (pure, testable)

    static func urlHost(_ urlString: String) -> String? {
        URL(string: urlString)?.host?.lowercased()
    }

    /// Map a pending_facts.fact_kind to the corresponding
    /// `field_sources.field` value. Mirrors the app-side mapping in
    /// `PendingFactsReviewView.addFieldSource`.
    static func profileFieldFor(factKind: String) -> String {
        switch factKind {
        case "birthDate", "baptismDate": return "birthDate"
        case "deathDate", "burialDate": return "deathDate"
        case "birthLocation": return "birthLocation"
        case "deathLocation": return "deathLocation"
        case "marriageDate": return "marriageDate"
        case "marriageLocation": return "marriageLocation"
        default: return factKind
        }
    }

    /// Map a fact_kind to the (column, datePrefix) on `profiles` it
    /// writes. Returns (nil, "") for fields with no scalar column —
    /// those are narrative (occupation, address) and only land in
    /// field_sources.
    static func profileColumnFor(factKind: String) -> (String?, String) {
        switch factKind {
        case "birthDate", "baptismDate": return ("birth_date_original", "birth_date")
        case "deathDate", "burialDate": return ("death_date_original", "death_date")
        case "birthLocation": return ("birth_location", "")
        case "deathLocation": return ("death_location", "")
        default: return (nil, "")
        }
    }

    /// Extract a 4-digit year from a free-text date string. Mirrors
    /// `EvidenceFirewall.extractYear` semantics conservatively — first
    /// year in [1000, 2099] wins.
    static func extractYear(from value: String) -> Int? {
        let pattern = #"\b(1[0-9]{3}|20[0-9]{2})\b"#
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return Int(value[range])
    }

    /// `field_sources.raw` stores "VALUE [Source Title]" or just "VALUE".
    /// Pull the leading value out for comparison.
    static func extractValueFromRaw(_ raw: String) -> String {
        if let bracket = raw.firstIndex(of: "[") {
            return String(raw[..<bracket]).trimmingCharacters(in: .whitespaces)
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    /// `field_sources.raw` carries a trailing "[Source Title]" segment;
    /// this returns that label, used as a lineage proxy. Different
    /// source titles count as different lineages — crude, conservative,
    /// and biased toward refusing.
    static func lineageLabelFromRaw(_ raw: String) -> String? {
        guard let open = raw.firstIndex(of: "["),
              let close = raw.firstIndex(of: "]"),
              open < close else {
            return nil
        }
        let inner = raw[raw.index(after: open)..<close]
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    /// Whether two field values represent the same fact. Field-aware:
    /// date fields compare extracted years; everything else compares
    /// case-insensitively after trimming. Conservative — a value that
    /// is *less specific* (broader place, less specific date) than the
    /// existing one is treated as conflicting, not corroborating.
    static func valuesMatch(_ a: String, _ b: String, field: String) -> Bool {
        let aT = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bT = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if aT == bT { return true }
        if field.hasSuffix("Date") {
            if let aY = extractYear(from: a), let bY = extractYear(from: b) {
                return aY == bY
            }
        }
        return false
    }
}

enum MCPError: LocalizedError {
    case methodNotFound(String)
    case resourceNotFound(String)
    case toolNotFound(String)
    case invalidParams(String)

    var errorDescription: String? {
        switch self {
        case .methodNotFound(let m): "Method not found: \(m)"
        case .resourceNotFound(let r): "Resource not found: \(r)"
        case .toolNotFound(let t): "Tool not found: \(t)"
        case .invalidParams(let p): "Invalid parameters: \(p)"
        }
    }
}
