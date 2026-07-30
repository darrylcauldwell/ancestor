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
    private(set) var db: DatabaseQueue

    /// The project DB path (argv[1], or the last successful
    /// `switch_project`). Retained so the §14.B.1 hallucination re-check
    /// can derive the app's page-cache directory from it.
    private(set) var dbPath: String

    /// Supported schema version range (§12).
    static let supportedSchemaVersions = 3...5

    /// Open + validate a project database (shared by init and
    /// `switch_project` so a switch can never land on a database the
    /// server would have refused at launch).
    static func openValidatedDatabase(at path: String) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.readonly = false
        let queue = try DatabaseQueue(path: path, configuration: config)
        try queue.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            if !tables.contains("leads") {
                throw MCPError.invalidParams("Database schema too old (no leads table). Update the app first.")
            }
        }
        return queue
    }

    init(dbPath: String) throws {
        self.dbPath = dbPath
        self.db = try Self.openValidatedDatabase(at: dbPath)
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

            // Re-open the database connection per request so every read reflects
            // the app's latest committed writes. A single long-lived reader
            // connection (opened once at launch) goes stale across app
            // relaunches — the reader freezes on the writer's restart and never
            // self-heals — which silently served hours-old data. A fresh
            // connection always reads the current committed state. Falls back to
            // the existing connection if a transient re-open fails; requests are
            // handled serially so reassigning `db` here is safe.
            if let fresh = try? Self.openValidatedDatabase(at: dbPath) {
                self.db = fresh
            }

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
                // MC1 — a caller mistake must not read as a server crash:
                // invalid params get their proper JSON-RPC code (-32602)
                // instead of collapsing into -32603 "internal error".
                switch error {
                case MCPError.methodNotFound: code = -32601
                case MCPError.invalidParams, MCPError.toolNotFound, MCPError.resourceNotFound: code = -32602
                default: code = -32603
                }
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
            return try await callTool(params: params)

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
        case _ where uri.hasPrefix("ancestor://profile/") && uri.hasSuffix("/disputes"):
            // CL6 — the dispute ledger as its own resource (the T9 dossier
            // read contract §4.8.6).
            let trimmed = uri.dropFirst("ancestor://profile/".count)
            let id = String(trimmed.dropLast("/disputes".count))
            content = try disputesResource(profileID: id)
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
                    name: "switch_project",
                    description: "Rebind this server to a SIBLING project database (same projects directory it was launched from) without a restart. Pass the project UUID or sqlite filename. Validates the target exactly as launch does (schema check) before swapping; on failure the current binding is untouched. Returns the old and new project names + paths. Solves the argv-bound single-project limitation for multi-project research sessions.",
                    properties: [
                        "project": ["type": "string", "description": "Target project UUID (with or without .sqlite) or bare filename within the current projects directory. Path separators are refused."],
                    ],
                    required: ["project"]
                ),
                tool(
                    name: "list_projects",
                    description: "List every sibling project in the projects directory: filename (UUID), display name, profile/relationship counts, and file size. Admin/triage aid — e.g. to spot empty or leaked projects before cleanup. Read-only.",
                    properties: [:],
                    required: []
                ),
                tool(
                    name: "delete_project",
                    description: "PERMANENTLY delete a sibling project's sqlite file (and its -wal/-shm sidecars). DESTRUCTIVE and irreversible. Refuses to delete the project the server is currently bound to (switch away first) and refuses path separators. Requires confirm='true' as an explicit second key. Returns the deleted project's name + profile count so the caller can verify what was removed.",
                    properties: [
                        "project": ["type": "string", "description": "Target project UUID or filename (sibling only; path separators refused)."],
                        "confirm": ["type": "string", "description": "Must be exactly 'true' — a deliberate guard against accidental deletion."],
                    ],
                    required: ["project", "confirm"]
                ),
                tool(
                    name: "submit_hypothesis",
                    description: "Seed a user hypothesis (a hunch, e.g. \"I think this person's parents were called Bob & Sue\") for the research engine to test. A hunch is a search directive, never data — it creates no profile, no edge, no field, no citation; it steers targeted probes whose findings face the standard verdict pipeline. Validates synchronously and INSERTs one user_hypothesis_seeds row (the app's watcher materialises it into a research hypothesis with origin=user); returns seed_id, or a structured refusal reason (no_name_hints | profile_not_found | no_subject_birth_estimate | previously_rejected). Hunches accumulate between runs: follow with kick_off_research to test them. Distinct from submit_evidence — family testimony you can cite is evidence, not a hunch.",
                    properties: [
                        "profile_id": ["type": "string", "description": "Profile ID the hunch is about (the child whose parents are hinted)"],
                        "kind": ["type": "string", "description": "Hypothesis kind. Only \"parent_candidates\" is supported."],
                        "father_given": ["type": "string", "description": "Hinted father's given name (optional; nicknames fine — \"Bob\" matches \"Robert\")"],
                        "father_surname": ["type": "string", "description": "Hinted father's surname (optional; defaults to the subject's surname at probe time)"],
                        "mother_given": ["type": "string", "description": "Hinted mother's given name (optional)"],
                        "mother_maiden_surname": ["type": "string", "description": "Hinted mother's MAIDEN surname (optional)"],
                        "marriage_window_start": ["type": "integer", "description": "Earliest parents' marriage year (optional; derived as subject birth year − 30 when absent)"],
                        "marriage_window_end": ["type": "integer", "description": "Latest parents' marriage year (optional; derived as subject birth year + 1 when absent)"],
                    ],
                    required: ["profile_id", "kind"]
                ),
                tool(
                    name: "get_run_status",
                    description: "Poll the status of a queued research run. Returns status (queued | running | completed | failed), run_id when completed, and error when failed.",
                    properties: [
                        "request_id": ["type": "string", "description": "The id returned by kick_off_research"],
                    ],
                    required: ["request_id"]
                ),
                tool(
                    name: "get_research_result",
                    description: "Return the §3 eval-harness envelope for a completed research run (SWIFT_MCP_EVAL_BACKEND_SPEC #Change4). Reads research_runs.result_json — verdicts plus future hypothesis / citation fields. Errors when the run id is unknown or the run completed before envelope persistence shipped (empty result_json).",
                    properties: [
                        "run_id": ["type": "string", "description": "The run_id returned by get_run_status once status == completed"],
                    ],
                    required: ["run_id"]
                ),
                tool(
                    name: "get_scored_records",
                    description: "Return the per-record verdict and identifying fields for records the pipeline scored for a profile, read from evidence_records. Useful when get_profile's aggregate counts aren't enough — e.g. \"which of these marriages landed as .fact vs .lead?\". Surfaces the salient identifying fields (year, district, vol/page, surname, plus marriage-specific partnerSurnameFromSamePage) alongside the verdict and citation. Also surfaces user_status (unreviewed | discarded | saved_as_lead — respect prior human verdicts: never re-propose discarded records) and the per-gate breakdown (gates object, when the app has stored it) showing which of the four gates (name / date / geography / family) held a record back.",
                    properties: [
                        "profile_id": ["type": "string", "description": "Profile ID to look up scored records for"],
                        "record_type": ["type": "string", "description": "Optional filter: birth | death | marriage | census | burial | military | probate | parish | pedigree"],
                        "verdict": ["type": "string", "description": "Optional filter: fact | lead | impossible"],
                        "limit": ["type": "integer", "description": "Max rows (default 50, max 500). Newest scored first."],
                    ],
                    required: ["profile_id"]
                ),
                // Auto-approval — see AncestorApp/AUTO_APPROVAL_VIA_MCP_SPEC.md.
                // Rules' authority extends to commit when the gate evaluator
                // says unambiguous; ambiguous facts still go to human review.
                tool(
                    name: "approve_pending_fact",
                    description: "Approve a pending fact via the deterministic gate. Commits to the profile + field_sources only if the fact passes every criterion (trust tier, convergence with existing sources, no would-be dispute, field is in the auto-approvable set) AND the §14.B.1 defensive hallucination re-check confirms the claimed value/evidence actually appears on the cited page. Refuses with a reason code otherwise; the fact stays pending for human review. NOTE: still disabled by default — set ANCESTOR_MCP_AUTO_APPROVE=1 in the server's environment to enable; the §14.B.1 re-check then runs before commit. Use inspect_approval_decision to test gate logic without the env override.",
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
                tool(
                    name: "promote_lead",
                    description: "Promote a lead to a real profile + relationship edge. Creates a new profiles row from the lead's name/birth/death/relationship fields and a relationships row connecting it to the lead's source profile. Restricted to father/mother/spouse (unambiguous gender + edge direction); child/sibling refuse with reason. Gated by the expansion-bound (#Change7) and promote-time dedup (#Change3) checks. Still disabled by default — set ANCESTOR_MCP_AUTO_APPROVE=1 to enable. Marks the lead as resolved on success.",
                    properties: [
                        "lead_id": ["type": "string", "description": "The leads row id to promote."],
                    ],
                    required: ["lead_id"]
                ),
                // FamilySearch (WL7 — FAMILYSEARCH_TREES_WRITE_SPEC). Reads are
                // plain DB reads of the v52/v53 tables; the two request tools
                // only STAGE rows — the app's watcher executes them with the
                // app's own FamilySearch auth (the MCP server never makes
                // network calls). Request-driven uploads stop at
                // uploaded-but-hidden; visibility/privacy are in-app consents.
                tool(
                    name: "get_audit_findings",
                    description: "Read the persisted Health audit findings (v55 snapshot written each time the app runs its audit pass). Returns rule_id, severity (error | warning | info), message, profile_id (null = tree-level) and computed_at — report the computed_at to the user, findings are only as fresh as the app's last audit pass. Optional filters: profile_id, severity.",
                    properties: [
                        "profile_id": ["type": "string", "description": "Optional: findings for one profile only."],
                        "severity": ["type": "string", "description": "Optional filter: error | warning | info."],
                        "limit": ["type": "integer", "description": "Max rows (default 100, max 500)."],
                    ],
                    required: []
                ),
                tool(
                    name: "get_fs_upload_status",
                    description: "Read the FamilySearch User Tree upload run(s): tree ID, phase (created | uploading | finalized | failed), counts of persons/relationships/sources uploaded, and privacy once finalized. Newest first.",
                    properties: [
                        "limit": ["type": "integer", "description": "Max runs to return (default 5, max 50)."],
                    ],
                    required: []
                ),
                tool(
                    name: "get_fs_person_links",
                    description: "Read the local-profile → FamilySearch person-ID (pid) links written by tree uploads. Optionally filter to one profile.",
                    properties: [
                        "profile_id": ["type": "string", "description": "Optional: only links for this profile."],
                        "limit": ["type": "integer", "description": "Max rows (default 100, max 500). Newest first."],
                    ],
                    required: []
                ),
                tool(
                    name: "get_fs_hints",
                    description: "Read FamilySearch-sourced hint leads for a profile (leads joined to their FamilySearch evidence records): lead status, identifying fields, scorer verdict, and the FamilySearch citation URL.",
                    properties: [
                        "profile_id": ["type": "string", "description": "Profile whose FamilySearch hint leads to return."],
                        "limit": ["type": "integer", "description": "Max rows (default 50, max 500). Newest first."],
                    ],
                    required: ["profile_id"]
                ),
                tool(
                    name: "get_fs_request_status",
                    description: "Poll staged FamilySearch action requests (from request_fs_hints / request_fs_upload). With request_id returns that request; without, the latest 10. Status queued | running | completed | failed; note carries the outcome summary or error.",
                    properties: [
                        "request_id": ["type": "string", "description": "Optional: the id returned by a request_fs_* tool."],
                    ],
                    required: []
                ),
                tool(
                    name: "request_fs_hints",
                    description: "Stage a FamilySearch hints fetch for one profile. The app (running, project open, signed in to FamilySearch) executes it with its own auth; resulting leads land in Triage. Returns a request_id — poll get_fs_request_status, then read get_fs_hints.",
                    properties: [
                        "profile_id": ["type": "string", "description": "Profile to fetch FamilySearch record hints for."],
                    ],
                    required: ["profile_id"]
                ),
                tool(
                    name: "request_fs_upload",
                    description: "Stage a FamilySearch User Tree upload of the whole local tree (deceased persons only; living people never upload). The app executes it with its own auth, resumable and idempotent — re-requesting continues an interrupted upload. The tree is uploaded HIDDEN; finalizing (visibility + privacy) is an in-app wizard consent and cannot be triggered from here. Returns a request_id — poll get_fs_request_status and get_fs_upload_status.",
                    properties: [
                        "tree_name": ["type": "string", "description": "Optional tree name (defaults to the project name)."],
                        "tree_description": ["type": "string", "description": "Optional tree description."],
                    ],
                    required: []
                ),
            ]
        ]
    }

    func callTool(params: [String: Any]) async throws -> [String: Any] {
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
        case "list_projects":
            let listResult = try listProjects()
            let listData = (try? JSONSerialization.data(withJSONObject: listResult, options: [.sortedKeys, .prettyPrinted])) ?? Data()
            return ["content": [["type": "text", "text": String(data: listData, encoding: .utf8) ?? "[]"]]]
        case "delete_project":
            let delResult = try deleteProject(arguments)
            let delData = (try? JSONSerialization.data(withJSONObject: delResult, options: [.sortedKeys, .prettyPrinted])) ?? Data()
            return ["content": [["type": "text", "text": String(data: delData, encoding: .utf8) ?? "{}"]]]
        case "switch_project":
            let result = try switchProject(arguments)
            let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return ["content": [["type": "text", "text": text]]]
        case "submit_hypothesis":
            return try submitHypothesis(arguments)
        case "get_run_status":
            return try getRunStatus(arguments)
        case "get_research_result":
            return try getResearchResult(arguments)
        case "get_scored_records":
            return try getScoredRecords(arguments)
        case "approve_pending_fact":
            return try await approvePendingFact(arguments)
        case "inspect_approval_decision":
            return try inspectApprovalDecision(arguments)
        case "promote_lead":
            return try promoteLead(arguments)
        case "get_audit_findings":
            return ["content": [["type": "text", "text": try getAuditFindingsResponseText(arguments)]]]
        case "get_fs_upload_status":
            return ["content": [["type": "text", "text": try getFSUploadStatusResponseText(arguments)]]]
        case "get_fs_person_links":
            return ["content": [["type": "text", "text": try getFSPersonLinksResponseText(arguments)]]]
        case "get_fs_hints":
            return ["content": [["type": "text", "text": try getFSHintsResponseText(arguments)]]]
        case "get_fs_request_status":
            return ["content": [["type": "text", "text": try getFSRequestStatusResponseText(arguments)]]]
        case "request_fs_hints":
            return ["content": [["type": "text", "text": try requestFSHintsResponseText(arguments)]]]
        case "request_fs_upload":
            return ["content": [["type": "text", "text": try requestFSUploadResponseText(arguments)]]]
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
                [
                    "name": "research_lifecycle",
                    "description": "Walk the full research loop for a profile: trigger a run, poll it, read back what was found, and summarise for the user",
                    "arguments": [
                        ["name": "profile_id", "description": "Profile ID to research", "required": true],
                    ],
                ],
            ]
        ]
    }

    /// String projection of `getPrompt` for tests (Sendable across the
    /// actor boundary — same pattern as the *ResponseText helpers).
    func getPromptResponseText(_ params: [String: Any]) -> String {
        Self.jsonString(getPrompt(params: params))
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
        case "find_ancestor":
            // MC1 — was advertised in prompts/list but unimplemented: every
            // request silently returned {"messages": []}.
            let profileID = args["profile_id"] as? String ?? ""
            let role = (args["role"] as? String ?? "parent").lowercased()
            let context = (try? profileDetail(id: profileID)) ?? "{}"
            return [
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            "type": "text",
                            "text": """
                            This person is missing their \(role). Here is everything known about them, \
                            including leads already gathered and searches that came back empty:

                            \(context)

                            Work out who the \(role) most plausibly was:
                            1. Check the leads list first — parent-inferred leads (from birth-index \
                            mother's-maiden-name columns) and census household leads (Head/Wife of the \
                            subject's childhood household) are the strongest starting points.
                            2. Check confirmed facts for a mother's maiden name on the subject.
                            3. If the evidence is thin, trigger kick_off_research (mode "discover") on the \
                            profile, poll get_run_status, then re-read the leads.
                            4. Present the candidate(s) with your reasoning and the supporting citations. \
                            Do NOT assert a parent as fact — candidates are reviewed and applied by the \
                            user in the app.
                            """,
                        ],
                    ],
                ],
            ]
        case "research_lifecycle":
            let profileID = args["profile_id"] as? String ?? ""
            return [
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            "type": "text",
                            "text": """
                            Run the research loop for profile \(profileID) and report what it finds:
                            1. get_profile — capture what is currently known (facts, leads, negative searches).
                            2. kick_off_research with profile_id "\(profileID)" (default mode/scope unless the \
                            user asked otherwise). Note the request_id. The Ancestor Research app must be \
                            RUNNING with this project open — if the request stays queued for more than ~30 \
                            seconds, tell the user to open the app.
                            3. Poll get_run_status until completed or failed.
                            4. On completion: get_research_result for the run envelope, then \
                            get_scored_records and a fresh get_profile to see what changed.
                            5. Summarise NEW findings only (compare against step 1): new facts by verdict, \
                            new leads worth attention, and searches that came back empty. Anything that \
                            changes the tree is reviewed and applied by the user in the app — say so when \
                            relevant.
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
                WHERE is_deleted = 0
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
            // MC1: soft-deleted rows were leaking into this list resource
            // (get_profile filters them; the list didn't) — an assistant would
            // confidently discuss deleted people. MC2: names split into
            // first/last (surname analytics need them separate) +
            // death_location added. Compact JSON — this is the set-query
            // workhorse and pretty-printing ~doubles its token cost.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, first_name, last_name, gender,
                       birth_date_original, birth_date_earliest, birth_date_latest,
                       death_date_original, death_date_earliest, death_date_latest,
                       birth_location, death_location, bio
                FROM profiles WHERE is_deleted = 0 ORDER BY last_name, first_name
                """)

            let profiles = rows.map { row -> [String: Any] in
                var p: [String: Any] = [
                    "id": row["id"] as String,
                    "name": "\(row["first_name"] as String? ?? "") \(row["last_name"] as String? ?? "")",
                ]
                if let v: String = row["first_name"] { p["first_name"] = v }
                if let v: String = row["last_name"] { p["last_name"] = v }
                if let v: String = row["birth_date_original"] { p["birth"] = v }
                if let v: Int = row["birth_date_earliest"] { p["birth_year"] = v }
                if let v: String = row["death_date_original"] { p["death"] = v }
                if let v: Int = row["death_date_earliest"] { p["death_year"] = v }
                if let v: String = row["birth_location"] { p["location"] = v }
                if let v: String = row["death_location"] { p["death_location"] = v }
                if let v: String = row["gender"] { p["gender"] = v }
                return p
            }

            let data = try JSONSerialization.data(withJSONObject: profiles, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    /// CL6 — full dispute ledger for one profile (open + resolved), the
    /// read contract the future dossier renders. Read-only.
    func disputesResource(profileID: String) throws -> String {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT kind, field, severity, detected_by, competing_sources,
                       resolution, resolved_at, ladder_trace, witness_summary
                FROM field_disputes WHERE entity_id = ? ORDER BY rowid
                """, arguments: [profileID])
            let payload: [[String: Any]] = rows.map { d in
                var out: [String: Any] = [
                    "kind": d["kind"] as String? ?? "fieldValue",
                    "field": d["field"] as String? ?? "",
                    "status": (d["resolution"] as String?) == nil ? "open" : "resolved",
                ]
                if let v: String = d["severity"] { out["severity"] = v }
                if let v: String = d["detected_by"] { out["detected_by"] = v }
                if let v: String = d["competing_sources"] { out["competing_sources"] = v }
                if let v: String = d["resolution"] { out["resolution"] = v }
                if let v: String = d["ladder_trace"] { out["ladder_trace"] = v }
                if let v: String = d["witness_summary"] { out["witness_summary"] = v }
                return out
            }
            let data = (try? JSONSerialization.data(
                withJSONObject: ["profile_id": profileID, "disputes": payload],
                options: [.sortedKeys])) ?? Data()
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    func profileDetail(id: String) throws -> String {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM profiles WHERE id = ? AND is_deleted = 0", arguments: [id]) else {
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

            // CONFLICT_LAYER_SPEC CL6 (§4.8.5) — read-only dispute ledger:
            // open + resolved, with kind/field/severity/reasoning-bearing
            // columns. Writes stay app-side (Evidence Firewall unchanged).
            let profileRowID: String = row["id"]
            let disputeRows = try Row.fetchAll(db, sql: """
                SELECT kind, field, severity, detected_by, resolution, resolved_at, ladder_trace
                FROM field_disputes WHERE entity_id = ? ORDER BY rowid
                """, arguments: [profileRowID])
            if !disputeRows.isEmpty {
                p["disputes"] = disputeRows.map { d -> [String: Any] in
                    var out: [String: Any] = [
                        "kind": d["kind"] as String? ?? "fieldValue",
                        "field": d["field"] as String? ?? "",
                        "status": (d["resolution"] as String?) == nil ? "open" : "resolved",
                    ]
                    if let v: String = d["severity"] { out["severity"] = v }
                    if let v: String = d["detected_by"] { out["detected_by"] = v }
                    if let v: String = d["ladder_trace"] { out["ladder_trace"] = v }
                    return out
                }
            }
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
                SELECT id, name, relationship, status, evidence, birth_year, death_year
                FROM leads WHERE profile_id = ? ORDER BY created_at DESC
                """, arguments: [id])
            p["leads"] = leadRows.map { lead -> [String: Any] in
                var l: [String: Any] = [
                    // `id` is required so an agent that reads a lead here can
                    // act on it via promote_lead / dismiss_lead without a
                    // second round-trip through the ancestor://leads resource.
                    "id": lead["id"] as String? ?? "",
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
        // MC1 — tokenised AND-matching. The old shape wrapped the WHOLE query
        // in one %…% and tested it against first_name OR last_name separately,
        // so any multi-token query ("William Henry Keyworth") returned [].
        // Each token now matches anywhere in the concatenated name, which also
        // covers middle names and the married surname (UK convention: many
        // women are only findable by it).
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "[]" }
        let nameExpr = """
            (COALESCE(first_name,'') || ' ' || COALESCE(middle_name,'') || ' ' || \
            COALESCE(last_name,'') || ' ' || COALESCE(married_surname,''))
            """
        let clause = tokens.map { _ in "\(nameExpr) LIKE ?" }.joined(separator: " AND ")
        let arguments = StatementArguments(tokens.map { "%\($0)%" })
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, first_name, last_name, birth_date_original, death_date_original, birth_location
                FROM profiles
                WHERE \(clause) AND is_deleted = 0
                ORDER BY last_name, first_name
                """, arguments: arguments)

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

    /// Promote a lead to a real profile + relationship edge.
    ///
    /// Gated by the same `ANCESTOR_MCP_AUTO_APPROVE` env var as
    /// `approve_pending_fact` — the lead came from `submit_lead` (an
    /// external write) and promoting it would synthesise an entire
    /// new profile row from name + dates the submitter chose. The
    /// auto-gate disclaimer about defensive hallucination re-check
    /// applies symmetrically.
    ///
    /// Restricted to relationships with unambiguous gender + edge
    /// direction: `father`, `mother`, `spouse`. `child` and `sibling`
    /// refuse with a reason — child's gender is undetermined from
    /// the relationship label alone, and sibling-of edges aren't
    /// representable in the relationships schema (would need an
    /// implied shared parent).
    func promoteLead(_ args: [String: Any]) throws -> [String: Any] {
        guard let leadID = args["lead_id"] as? String else {
            throw MCPError.invalidParams("promote_lead requires lead_id")
        }

        guard Self.isAutoApprovalEnabled() else {
            return refusePromote(
                leadID: leadID,
                reason: "auto_approval_gate_disabled",
                detail: "Auto-approval is disabled by default. Set ANCESTOR_MCP_AUTO_APPROVE=1 in the server's environment to enable."
            )
        }

        return try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM leads WHERE id = ?", arguments: [leadID]) else {
                return refusePromote(leadID: leadID, reason: "lead_not_found", detail: "No lead row with that id.")
            }

            let status: String = row["status"] ?? ""
            guard status == "new" else {
                return refusePromote(
                    leadID: leadID,
                    reason: "lead_not_open",
                    detail: "Lead status is '\(status)'; only 'new' leads can be promoted."
                )
            }

            let sourceProfileID: String = row["profile_id"] ?? ""
            let leadRelationship: String = (row["relationship"] ?? "").lowercased()
            guard ["father", "mother", "spouse"].contains(leadRelationship) else {
                return refusePromote(
                    leadID: leadID,
                    reason: "relationship_not_promotable",
                    detail: "promote_lead supports father, mother, spouse. Got '\(leadRelationship)'."
                )
            }

            let givenName: String? = row["given_name"]
            let surname: String? = row["surname"]
            var birthYear: Int? = row["birth_year"]
            let deathYear: Int? = row["death_year"]
            let evidence: String = row["evidence"] ?? ""

            // Derive estimated birth-year range for parent/spouse leads
            // that lack one (the common case for `.parentInferred`
            // emitters — the BMD index doesn't carry parents' birth
            // years). Without this the promoted profile has no date
            // window for the engine's downstream research dispatcher,
            // and source plugins produce broad unfocused queries that
            // either time out or return thousands of false candidates.
            //
            // Rule:
            //   * father/mother: parent typically born child's year − 35
            //     ± 15. Encoded as a (-50, -20) range.
            //   * spouse: same age cohort as the source profile, ±15.
            //
            // Only fires when the lead itself carries no birth_year. If
            // the lead emitter (or human-submitted lead) already set a
            // year, that's trusted as-is.
            var birthYearEarliest: Int? = birthYear
            var birthYearLatest: Int? = birthYear
            var birthYearQualifier: String? = birthYear == nil ? nil : "estimate"
            if birthYear == nil {
                let sourceBirthYear: Int? = try Row.fetchOne(
                    db,
                    sql: "SELECT birth_date_earliest FROM profiles WHERE id = ?",
                    arguments: [sourceProfileID]
                )?["birth_date_earliest"]
                if let cby = sourceBirthYear {
                    switch leadRelationship {
                    case "father", "mother":
                        birthYearEarliest = cby - 50
                        birthYearLatest = cby - 20
                        birthYearQualifier = "estimate"
                    case "spouse":
                        birthYearEarliest = cby - 15
                        birthYearLatest = cby + 15
                        birthYearQualifier = "estimate"
                    default:
                        break
                    }
                    // Mid-range as the canonical birth_year value.
                    if let e = birthYearEarliest, let l = birthYearLatest {
                        birthYear = (e + l) / 2
                    }
                }
            }

            // Derive gender from relationship label (+ source profile for spouse).
            let gender: String
            switch leadRelationship {
            case "father": gender = "male"
            case "mother": gender = "female"
            case "spouse":
                // Inverse of the source profile's gender, when known.
                let sourceGender: String? = try Row.fetchOne(
                    db, sql: "SELECT gender FROM profiles WHERE id = ?", arguments: [sourceProfileID]
                )?["gender"]
                switch (sourceGender ?? "").lowercased() {
                case "male": gender = "female"
                case "female": gender = "male"
                default: gender = "unknown"
                }
            default: gender = "unknown"
            }

            // Pre-existing-promotion guard: if this lead was already
            // resolved earlier, don't double-write. Belt-and-braces on
            // top of the `status == 'new'` check above.
            if let existingResolution: String = row["resolution"], !existingResolution.isEmpty {
                return refusePromote(
                    leadID: leadID,
                    reason: "lead_already_resolved",
                    detail: "Lead resolution = '\(existingResolution)'."
                )
            }

            // Expansion bound (ENGINE_FOUNDATION_SPEC #Change7): before
            // INSERT, refuse leads whose generator sits too far from the
            // probands/seeds so an autonomous run stops burning budget on
            // peripheral kin while the core tree still has gaps. Pure
            // deterministic gate on WHICH leads promote — never a scorer
            // verdict change. Seeds = the project's home person; no home
            // person ⇒ no anchor ⇒ bound not applied (fail-open).
            let expansionPolicyRaw: String? = try Row.fetchOne(
                db, sql: "SELECT expansion_policy FROM project_meta LIMIT 1"
            )?["expansion_policy"]
            let homePersonID: String? = try Row.fetchOne(
                db, sql: "SELECT home_person_id FROM project_meta LIMIT 1"
            )?["home_person_id"]
            let seedIDs = [homePersonID].compactMap { $0 }.filter { !$0.isEmpty }
            let edgeRows = try Row.fetchAll(
                db, sql: "SELECT from_id, to_id, type FROM relationships"
            )
            let edges: [MCPHandler.GraphEdge] = edgeRows.map {
                MCPHandler.GraphEdge(from: $0["from_id"] ?? "", to: $0["to_id"] ?? "", type: $0["type"] ?? "")
            }
            let boundOutcome = MCPHandler.decideExpansionBound(
                policy: MCPHandler.ExpansionPolicy.parse(expansionPolicyRaw),
                edges: edges,
                seedIDs: seedIDs,
                generatorID: sourceProfileID
            )
            guard boundOutcome.permitsPromotion else {
                return refusePromote(
                    leadID: leadID,
                    reason: boundOutcome.code,
                    detail: boundOutcome.detail
                )
            }

            // Dedup gate (ENGINE_FOUNDATION_SPEC #Change3): before INSERT,
            // see whether an existing profile already represents this
            // person. Avoids the Jennifer Holmes case from the cross-day
            // run, where a surname-only lead promoted a duplicate of a
            // rich existing profile.
            let dedupDecision: MCPHandler.DedupDecision
            if let surname = surname, !surname.isEmpty {
                let candidateRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, first_name, last_name,
                               birth_date_earliest, birth_date_latest
                        FROM profiles
                        WHERE LOWER(last_name) = LOWER(?) AND is_deleted = 0
                        """,
                    arguments: [surname]
                )
                let candidates: [MCPHandler.DedupCandidate] = candidateRows.map { r in
                    MCPHandler.DedupCandidate(
                        profileID: r["id"] ?? "",
                        firstName: r["first_name"],
                        lastName: r["last_name"],
                        birthYearEarliest: r["birth_date_earliest"],
                        birthYearLatest: r["birth_date_latest"]
                    )
                }
                dedupDecision = MCPHandler.decideDedup(
                    leadGivenName: givenName,
                    leadBirthYearEarliest: birthYearEarliest,
                    leadBirthYearLatest: birthYearLatest,
                    candidates: candidates
                )
            } else {
                dedupDecision = .noMatch
            }

            let now = Date()
            let targetProfileID: String
            let wasMatched: Bool

            switch dedupDecision {
            case .matched(let existingID):
                targetProfileID = existingID
                wasMatched = true
            case .noMatch, .multipleMatches:
                let newProfileID = "@FR_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))@"
                try db.execute(sql: """
                    INSERT INTO profiles
                    (id, external_ids, first_name, last_name, gender,
                     birth_date_original, birth_date_earliest, birth_date_latest, birth_date_qualifier,
                     death_date_original, death_date_earliest, death_date_latest, death_date_qualifier,
                     bio, attributes, is_deleted, mothers_maiden_name, married_surname)
                    VALUES (?, '{}', ?, ?, ?,
                            ?, ?, ?, ?,
                            ?, ?, ?, ?,
                            ?, '{}', 0, NULL, NULL)
                    """, arguments: [
                        newProfileID, givenName, surname, gender,
                        birthYear.map { String($0) }, birthYearEarliest, birthYearLatest, birthYearQualifier,
                        deathYear.map { String($0) }, deathYear, deathYear, deathYear == nil ? nil : "estimate",
                        "Promoted from lead \(leadID). Evidence: \(String(evidence.prefix(400)))",
                    ])
                targetProfileID = newProfileID
                wasMatched = false
            }

            // Compute relationship endpoints using the target profile id
            // (matched-existing or newly-inserted).
            let relType: String
            let role: String?
            let fromID: String
            let toID: String
            switch leadRelationship {
            case "father":
                relType = "parent"; role = "father"
                fromID = targetProfileID; toID = sourceProfileID
            case "mother":
                relType = "parent"; role = "mother"
                fromID = targetProfileID; toID = sourceProfileID
            case "spouse":
                relType = "spouse"; role = nil
                // Convention from existing data: husband first when known.
                if gender == "male" {
                    fromID = targetProfileID; toID = sourceProfileID
                } else {
                    fromID = sourceProfileID; toID = targetProfileID
                }
            default:
                // Unreachable — guarded above.
                return refusePromote(leadID: leadID, reason: "unreachable", detail: "")
            }

            // Relationship-edge dedup: if the asserted edge already exists
            // (matched-existing case where the tree is fully linked),
            // don't duplicate it. Otherwise INSERT — a matched profile
            // may still be missing the asserted relationship if the lead
            // came from a different research path.
            let existingRelID: String?
            if let r = role {
                existingRelID = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM relationships
                        WHERE from_id = ? AND to_id = ? AND type = ? AND role = ?
                        """,
                    arguments: [fromID, toID, relType, r]
                )?["id"]
            } else {
                existingRelID = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM relationships
                        WHERE from_id = ? AND to_id = ? AND type = ? AND role IS NULL
                        """,
                    arguments: [fromID, toID, relType]
                )?["id"]
            }

            let relID: String
            let relInserted: Bool
            if let er = existingRelID {
                relID = er
                relInserted = false
            } else {
                relID = UUID().uuidString.uppercased()
                try db.execute(sql: """
                    INSERT INTO relationships
                    (id, from_id, to_id, type, role, subtype)
                    VALUES (?, ?, ?, ?, ?, 'unknown')
                    """, arguments: [relID, fromID, toID, relType, role])
                relInserted = true
            }

            // Mark the lead as resolved. The resolution string is the
            // audit-log entry for the dedup decision.
            let resolutionString = wasMatched
                ? "matched_existing_\(targetProfileID)"
                : "promoted_to_\(targetProfileID)"
            // 'promoted' — must be a LeadStatus rawValue. The previous
            // 'resolved' was not one, so the in-app loaders' status guard
            // silently DROPPED every MCP-promoted lead from every surface
            // (CAMPAIGN_REVIEW_SPEC Change 1). The dedup audit detail
            // (matched_existing_/promoted_to_) stays in `resolution`.
            try db.execute(sql: """
                UPDATE leads
                SET status = 'promoted', resolved_at = ?, resolution = ?
                WHERE id = ?
                """, arguments: [now, resolutionString, leadID])

            let payload: [String: Any] = [
                "status": wasMatched ? "matched_existing" : "promoted",
                "lead_id": leadID,
                "new_profile_id": targetProfileID,
                "matched": wasMatched,
                "new_relationship_id": relInserted ? relID : NSNull(),
                "existing_relationship_id": relInserted ? NSNull() : relID,
                "rel_type": relType,
                "role": role ?? NSNull(),
                "source_profile_id": sourceProfileID,
                "gender": gender,
            ]
            let json = (try? String(data: JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted), encoding: .utf8)) ?? "{}"
            return ["content": [["type": "text", "text": json]]]
        }
    }

    private func refusePromote(leadID: String, reason: String, detail: String) -> [String: Any] {
        let payload: [String: Any] = [
            "status": "refused",
            "lead_id": leadID,
            "reason": reason,
            "detail": detail,
        ]
        let json = (try? String(data: JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted), encoding: .utf8)) ?? "{}"
        return ["content": [["type": "text", "text": json]]]
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
    /// Rebind to a sibling project DB (runtime project switch — the
    /// long-noted argv-binding gap). Sibling-only by construction: the
    /// target resolves within the CURRENT dbPath's parent directory, and
    /// any path separator in the argument is refused, so the server can
    /// never be steered outside the projects directory it was launched
    /// against. Validation is the same as launch; a failed switch leaves
    /// the current binding untouched.
    /// List sibling projects with name + counts (admin/triage). Read-only;
    /// opens each DB briefly with foreign keys off (list-only, no writes).
    func listProjects() throws -> [[String: Any]] {
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension == "sqlite" } ?? []
        var out: [[String: Any]] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var row: [String: Any] = [
                "file": url.lastPathComponent,
                "size_bytes": (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                "is_current": url.path == dbPath,
            ]
            if let q = try? DatabaseQueue(path: url.path) {
                try? q.read { db in
                    row["name"] = try String.fetchOne(db, sql: "SELECT name FROM project_meta LIMIT 1") ?? "(unnamed)"
                    row["profiles"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profiles WHERE is_deleted = 0") ?? 0
                    row["relationships"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM relationships") ?? 0
                }
            } else {
                row["name"] = "(unreadable)"
            }
            out.append(row)
        }
        return out
    }

    /// Permanently delete a sibling project. Guards: sibling-only (no path
    /// separators), never the current binding, explicit confirm='true'.
    func deleteProject(_ args: [String: Any]) throws -> [String: Any] {
        guard let raw = (args["project"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            throw MCPError.invalidParams("delete_project requires 'project'")
        }
        guard (args["confirm"] as? String) == "true" else {
            return ["status": "refused", "reason": "not_confirmed", "detail": "Pass confirm='true' to delete — this is irreversible."]
        }
        guard !raw.contains("/"), !raw.contains(".."), !raw.contains("\\") else {
            throw MCPError.invalidParams("'project' must be a bare UUID or filename — path separators are refused")
        }
        let filename = raw.hasSuffix(".sqlite") ? raw : raw + ".sqlite"
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let target = dir.appendingPathComponent(filename)
        guard target.path != dbPath else {
            return ["status": "refused", "reason": "is_current_project", "detail": "Cannot delete the project the server is bound to — switch_project away first."]
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            return ["status": "refused", "reason": "project_not_found", "detail": "No sibling project '\(filename)'."]
        }
        // Capture identity before deletion so the caller can verify.
        var name = "(unnamed)"; var profiles = 0
        if let q = try? DatabaseQueue(path: target.path) {
            try? q.read { db in
                name = try String.fetchOne(db, sql: "SELECT name FROM project_meta LIMIT 1") ?? "(unnamed)"
                profiles = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profiles") ?? 0
            }
        }
        try FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(filename + "-wal"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(filename + "-shm"))
        return ["status": "deleted", "file": filename, "name": name, "profiles": profiles]
    }

    /// Sendable projections for cross-actor callers (tests).
    func listProjectsJSON() throws -> String {
        let data = (try? JSONSerialization.data(withJSONObject: try listProjects(), options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }
    func deleteProjectStatus(project: String, confirm: String?) throws -> String {
        var args: [String: Any] = ["project": project]
        if let confirm { args["confirm"] = confirm }
        let r = try deleteProject(args)
        // Refusals carry a machine reason; success carries status "deleted".
        return (r["reason"] as? String) ?? (r["status"] as? String) ?? "unknown"
    }

    func switchProject(_ args: [String: Any]) throws -> [String: Any] {
        guard let raw = (args["project"] as? String)?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else {
            throw MCPError.invalidParams("switch_project requires 'project' (UUID or filename)")
        }
        guard !raw.contains("/"), !raw.contains(".."), !raw.contains("\\") else {
            throw MCPError.invalidParams("'project' must be a bare UUID or filename — path separators are refused")
        }
        let filename = raw.hasSuffix(".sqlite") ? raw : raw + ".sqlite"
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let target = dir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: target.path) else {
            return [
                "status": "refused",
                "reason": "project_not_found",
                "detail": "No sibling project '\(filename)' in \(dir.path)",
            ]
        }
        guard target.path != dbPath else {
            return ["status": "no_op", "detail": "Already bound to \(filename)"]
        }

        func projectName(in queue: DatabaseQueue) -> String {
            (try? queue.read { db in
                try String.fetchOne(db, sql: "SELECT name FROM project_meta LIMIT 1")
            }).flatMap { $0 } ?? "(unnamed)"
        }

        let oldName = projectName(in: db)
        let oldPath = dbPath
        // Validate BEFORE swapping — a bad target must not unbind us.
        let newQueue = try Self.openValidatedDatabase(at: target.path)
        db = newQueue
        dbPath = target.path
        return [
            "status": "switched",
            "from": ["name": oldName, "path": oldPath],
            "to": ["name": projectName(in: newQueue), "path": target.path],
        ]
    }

    /// Sendable projection of `switchProject` for cross-actor callers
    /// (tests): status + destination project name.
    func switchProjectStatus(project: String) throws -> (status: String, toName: String?) {
        let result = try switchProject(["project": project])
        let to = result["to"] as? [String: String]
        return (result["status"] as? String ?? "unknown", to?["name"])
    }

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

    // MARK: - submit_hypothesis (RESEARCH_PIPELINE_SPEC §5.15, Decision E2)

    /// Seed a user hypothesis. Validates synchronously (read-only checks
    /// per §5.15.2), INSERTs one `user_hypothesis_seeds` row (v32), and
    /// returns the seed_id; the app-side watcher materialises the seed
    /// into a `research_hypotheses` row with `origin = 'user'`.
    ///
    /// **Firewall.** Writes `user_hypothesis_seeds` ONLY — orchestration,
    /// the same tier as `research_run_requests`. Reads: `profiles`
    /// (existence, birth estimate), `research_hypotheses` (rejection
    /// check). The evidence-write set (`pending_facts` + `leads`) is
    /// untouched; a hunch is a search directive, never data.
    func submitHypothesis(_ args: [String: Any]) throws -> [String: Any] {
        guard let profileID = args["profile_id"] as? String, !profileID.isEmpty else {
            throw MCPError.invalidParams("submit_hypothesis requires profile_id")
        }
        guard let kind = args["kind"] as? String else {
            throw MCPError.invalidParams("submit_hypothesis requires kind")
        }
        guard kind == "parent_candidates" else {
            throw MCPError.invalidParams("kind must be \"parent_candidates\" (only supported value this epic)")
        }

        let fatherGiven = Self.trimmedHint(args["father_given"])
        let fatherSurname = Self.trimmedHint(args["father_surname"])
        let motherGiven = Self.trimmedHint(args["mother_given"])
        let motherMaidenSurname = Self.trimmedHint(args["mother_maiden_surname"])
        let windowStart = args["marriage_window_start"] as? Int
        let windowEnd = args["marriage_window_end"] as? Int

        // Read-only lookups for validation (§5.15.2): the profile's
        // existence + birth-year estimate, done here so the pure
        // validator stays unit-testable without a live SQLite.
        let profileRow: (exists: Bool, birthEarliest: Int?, birthLatest: Int?) = try db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT birth_date_earliest, birth_date_latest
                FROM profiles WHERE id = ? AND is_deleted = 0
                """, arguments: [profileID]) else {
                return (false, nil, nil)
            }
            return (true, row["birth_date_earliest"], row["birth_date_latest"])
        }

        let validation = Self.validateHypothesisSeed(
            profileID: profileID,
            profileExists: profileRow.exists,
            birthYearEarliest: profileRow.birthEarliest,
            birthYearLatest: profileRow.birthLatest,
            fatherGiven: fatherGiven,
            fatherSurname: fatherSurname,
            motherGiven: motherGiven,
            motherMaidenSurname: motherMaidenSurname,
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        let identityKey: String
        switch validation {
        case .refused(let reason):
            return refuseHypothesisSeed(profileID: profileID, reason: reason)
        case .valid(let key, _, _):
            identityKey = key
        }

        // Rejection memory (§5.15.2): the user dismissed this exact hunch;
        // re-seeding must be a deliberate un-reject, not a silent revival.
        let isRejected = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT user_rejected FROM research_hypotheses WHERE id = ?
                """, arguments: [identityKey]) ?? 0
        }
        if isRejected != 0 {
            return refuseHypothesisSeed(profileID: profileID, reason: "previously_rejected")
        }

        // Payload records exactly what the caller asserted — derived
        // window bounds are NOT persisted (§5.15.1); the watcher
        // re-derives them at materialisation time.
        var payload: [String: Any] = [:]
        if let fatherGiven { payload["father_given"] = fatherGiven }
        if let fatherSurname { payload["father_surname"] = fatherSurname }
        if let motherGiven { payload["mother_given"] = motherGiven }
        if let motherMaidenSurname { payload["mother_maiden_surname"] = motherMaidenSurname }
        if let windowStart { payload["marriage_window_start"] = windowStart }
        if let windowEnd { payload["marriage_window_end"] = windowEnd }
        let payloadJSON = (try? String(
            data: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            encoding: .utf8
        )) ?? "{}"

        let seedID = "seed_\(UUID().uuidString)"
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO user_hypothesis_seeds
                (id, profile_id, kind_discriminator, payload, status,
                 requested_by, created_at)
                VALUES (?, ?, 'parentCandidates', ?, 'queued', 'mcp', ?)
                """, arguments: [seedID, profileID, payloadJSON, Date()])
        }

        let result: [String: Any] = [
            "status": "queued",
            "seed_id": seedID,
            "profile_id": profileID,
        ]
        let json = (try? String(data: JSONSerialization.data(withJSONObject: result, options: .prettyPrinted), encoding: .utf8)) ?? "{}"
        return ["content": [["type": "text", "text": json]]]
    }

    /// Structured refusal (§5.15.7): reason code + nothing written.
    private func refuseHypothesisSeed(profileID: String, reason: String) -> [String: Any] {
        let payload: [String: Any] = [
            "status": "refused",
            "profile_id": profileID,
            "reason": reason,
        ]
        let json = (try? String(data: JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted), encoding: .utf8)) ?? "{}"
        return ["content": [["type": "text", "text": json]]]
    }

    /// Empty-after-trim hints are not assertions — normalise to nil.
    static func trimmedHint(_ value: Any?) -> String? {
        guard let s = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !s.isEmpty else { return nil }
        return s
    }

    /// Pure §5.15.2 validation core for `submit_hypothesis` — profile
    /// facts are pre-fetched by the caller so this is unit-testable
    /// without a live SQLite (same pattern as `decideDedup`). The
    /// rejection-memory check needs the resolved identity key, so it
    /// stays with the caller's SQL.
    enum HypothesisSeedValidation: Equatable {
        case refused(reason: String)
        case valid(identityKey: String, windowStart: Int, windowEnd: Int)
    }

    static func validateHypothesisSeed(
        profileID: String,
        profileExists: Bool,
        birthYearEarliest: Int?,
        birthYearLatest: Int?,
        fatherGiven: String?,
        fatherSurname: String?,
        motherGiven: String?,
        motherMaidenSurname: String?,
        windowStart: Int?,
        windowEnd: Int?
    ) -> HypothesisSeedValidation {
        // §5.15.2 rule 1 — at least one of the four name hints non-empty.
        guard fatherGiven != nil || fatherSurname != nil
                || motherGiven != nil || motherMaidenSurname != nil else {
            return .refused(reason: "no_name_hints")
        }
        // §5.15.2 rule 2 — profile must exist.
        guard profileExists else {
            return .refused(reason: "profile_not_found")
        }
        // §5.15.2 rule 3 — derivable marriage window. User bounds win
        // where given; missing bounds default from the birth estimate
        // (birthYear − 30 … birthYear + 1, mirroring `.parentMarriage`).
        let birthEstimate = birthYearEarliest ?? birthYearLatest
        let lower = windowStart ?? birthEstimate.map { $0 - 30 }
        let upper = windowEnd ?? birthEstimate.map { $0 + 1 }
        guard let lower, let upper else {
            return .refused(reason: "no_subject_birth_estimate")
        }
        guard lower <= upper else {
            return .refused(reason: "invalid_window")
        }
        return .valid(
            identityKey: parentCandidatesIdentityKey(
                profileID: profileID,
                fatherGiven: fatherGiven, fatherSurname: fatherSurname,
                motherGiven: motherGiven, motherMaidenSurname: motherMaidenSurname,
                windowStart: lower, windowEnd: upper
            ),
            windowStart: lower,
            windowEnd: upper
        )
    }

    /// Mirror of `HypothesisKind.identityKey` for `.parentCandidates`
    /// (canonical implementation:
    /// `AncestorKit/Sources/AncestorKit/Research/ResearchHypothesis.swift`
    /// — this package doesn't depend on AncestorKit, so keep the two in
    /// sync by hand). nil hints normalise to "" (§5.15.1).
    static func parentCandidatesIdentityKey(
        profileID: String,
        fatherGiven: String?,
        fatherSurname: String?,
        motherGiven: String?,
        motherMaidenSurname: String?,
        windowStart: Int,
        windowEnd: Int
    ) -> String {
        "parentCandidates:\(profileID):\(fatherGiven?.uppercased() ?? "")x\(fatherSurname?.uppercased() ?? "")x\(motherGiven?.uppercased() ?? "")x\(motherMaidenSurname?.uppercased() ?? ""):\(windowStart)-\(windowEnd)"
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

    /// Return the per-run §3 envelope for a completed research run.
    /// Reads `research_runs.result_json` (populated by
    /// `RunRequestWatcher.persistResult` from v29 onward) and surfaces
    /// it verbatim to the caller. The harness consumes it as the
    /// `swift-mcp` backend's response shape; the column is plain text
    /// to keep storage simple, so the tool just round-trips it.
    func getResearchResult(_ args: [String: Any]) throws -> [String: Any] {
        guard let runID = args["run_id"] as? String else {
            throw MCPError.invalidParams("get_research_result requires run_id")
        }
        let text: String = try db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT result_json FROM research_runs WHERE id = ?
                """, arguments: [runID]) else {
                return Self.jsonString([
                    "error": "run_not_found",
                    "run_id": runID,
                ])
            }
            let resultJSON: String = row["result_json"] ?? ""
            if resultJSON.isEmpty {
                // Older runs (pre-#Change3) and freshly-queued runs
                // both land here. Surface both as "envelope not
                // available" — the caller should poll get_run_status
                // first to confirm completion.
                return Self.jsonString([
                    "error": "envelope_not_available",
                    "run_id": runID,
                    "reason": "result_json empty — run pre-dates #Change3 or hasn't completed",
                ])
            }
            return resultJSON
        }
        return ["content": [["type": "text", "text": text]]]
    }

    /// Per-record verdict + identifying fields for everything the scorer
    /// touched on a profile, read from `evidence_records`. The aggregate
    /// counts on `get_profile` / `research_runs` tell you "458 scored → 0
    /// facts" but never which specific records landed where; this surfaces
    /// each record's verdict and citation.
    ///
    /// Reads `evidence_records` — the live per-profile archive the app
    /// writes after each run. The salient identifying fields come out of
    /// the stored `record_json`; for marriages the `marriage` block surfaces
    /// `partnerSurnameFromSamePage` alongside vol/page so same-page-couple
    /// debugging is trivial. `gates_json` (v44) carries the per-gate
    /// breakdown when present, and `user_status` (v16) carries the human's
    /// prior verdict on the record — both are surfaced.
    ///
    /// `record_type` and `verdict` are optional server-side filters; the
    /// limit clamps to [1, 500] (default 50). Rows return newest-first.
    func getScoredRecords(_ args: [String: Any]) throws -> [String: Any] {
        guard let profileID = args["profile_id"] as? String, !profileID.isEmpty else {
            throw MCPError.invalidParams("get_scored_records requires profile_id")
        }
        let typeFilter = (args["record_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let verdictFilter = (args["verdict"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let limit = max(1, min((args["limit"] as? Int) ?? 50, 500))

        let json: String = try db.read { db in
            var sql = """
                SELECT id,
                       source_id,
                       source_record_id,
                       record_type,
                       verdict,
                       record_json,
                       citation_full,
                       citation_url,
                       scored_at,
                       user_status,
                       gates_json
                FROM evidence_records
                WHERE profile_id = ?
                """
            var arguments: [DatabaseValueConvertible] = [profileID]
            if let t = typeFilter {
                sql += " AND record_type = ?"
                arguments.append(t)
            }
            if let v = verdictFilter {
                sql += " AND verdict = ?"
                arguments.append(v)
            }
            sql += " ORDER BY scored_at DESC LIMIT ?"
            arguments.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            let out = rows.map { Self.scoredRecordPayload(row: $0) }
            return Self.jsonString(out)
        }
        return ["content": [["type": "text", "text": json]]]
    }

    /// Build the JSON payload for one `evidence_records` row: verdict,
    /// identity, citation, the human's prior `user_status`, and the stored
    /// per-gate breakdown (`gates_json`, v44) when present.
    private static func scoredRecordPayload(row: Row) -> [String: Any] {
        var payload: [String: Any] = [
            "evidence_record_id": row["id"] as String? ?? "",
            "verdict": row["verdict"] as String? ?? "",
        ]
        if let scoredAt: Date = row["scored_at"] {
            payload["scored_at"] = ISO8601DateFormatter().string(from: scoredAt)
        }
        if let t: String = row["record_type"] { payload["record_type"] = t }
        if let u: String = row["user_status"] { payload["user_status"] = u }
        if let g: String = row["gates_json"], !g.isEmpty,
           let gatesData = g.data(using: .utf8),
           let gates = try? JSONSerialization.jsonObject(with: gatesData) {
            payload["gates"] = gates
        }
        if let s: String = row["source_id"] { payload["source_id"] = s }
        if let sr: String = row["source_record_id"] { payload["source_record_id"] = sr }
        if let c: String = row["citation_full"], !c.isEmpty { payload["citation_full"] = c }
        if let u: String = row["citation_url"], !u.isEmpty { payload["citation_url"] = u }

        // Parse the stored SourceRecord JSON to surface the salient identifying
        // fields. The on-disk shape is Swift's default Codable for the
        // SourceRecord enum: `{ "marriage": { "common": {...}, "marriageYear": 1911, ... } }`.
        if let rawJSON: String = row["record_json"],
           let data = rawJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Common fields (any record type)
            for (caseKey, body) in parsed {
                guard let body = body as? [String: Any] else { continue }
                if let common = body["common"] as? [String: Any] {
                    var commonOut: [String: Any] = [:]
                    if let s = common["surname"] as? String, !s.isEmpty { commonOut["surname"] = s }
                    if let g = common["givenName"] as? String, !g.isEmpty { commonOut["givenName"] = g }
                    if !commonOut.isEmpty { payload["name"] = commonOut }
                }
                // Marriage-specific carve-out — the field that drove this tool's
                // creation. Keep it as a structured block so callers don't have to
                // parse it out themselves.
                if caseKey == "marriage" {
                    var m: [String: Any] = [:]
                    if let y = body["marriageYear"] as? Int { m["year"] = y }
                    if let q = body["quarter"] as? String, !q.isEmpty { m["quarter"] = q }
                    if let d = body["district"] as? String, !d.isEmpty { m["district"] = d }
                    if let v = body["volume"] as? String, !v.isEmpty { m["volume"] = v }
                    if let p = body["page"] as? String, !p.isEmpty { m["page"] = p }
                    if let s = body["spouseName"] as? String, !s.isEmpty { m["spouseName"] = s }
                    if let pp = body["partnerSurnameFromSamePage"] as? String, !pp.isEmpty {
                        m["partnerSurnameFromSamePage"] = pp
                    }
                    if !m.isEmpty { payload["marriage"] = m }
                }
                break  // SourceRecord has exactly one case-key
            }
        }
        return payload
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

    // MARK: - Audit findings (MC4)

    /// Health audit findings from the v55 snapshot the app persists after each
    /// audit pass. `computed_at` makes staleness honest — the MCP server never
    /// computes audits itself (AuditEngine runs in-app).
    func getAuditFindingsResponseText(_ args: [String: Any]) throws -> String {
        let limit = max(1, min((args["limit"] as? Int) ?? 100, 500))
        let profileID = (args["profile_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let severity = (args["severity"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let iso = ISO8601DateFormatter()
        do {
            let payload: [[String: Any]] = try db.read { dbConn in
                var sql = "SELECT id, rule_id, profile_id, severity, message, computed_at FROM audit_findings"
                var clauses: [String] = []
                var arguments: [DatabaseValueConvertible] = []
                if let profileID { clauses.append("profile_id = ?"); arguments.append(profileID) }
                if let severity { clauses.append("severity = ?"); arguments.append(severity) }
                if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
                sql += """
                     ORDER BY CASE severity WHEN 'error' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, rule_id LIMIT ?
                    """
                arguments.append(limit)
                let rows = try Row.fetchAll(dbConn, sql: sql, arguments: StatementArguments(arguments))
                return rows.map { row in
                    var entry: [String: Any] = [
                        "rule_id": row["rule_id"] as String? ?? "",
                        "severity": row["severity"] as String? ?? "",
                        "message": row["message"] as String? ?? "",
                    ]
                    if let v: String = row["profile_id"] { entry["profile_id"] = v }
                    if let v: Date = row["computed_at"] { entry["computed_at"] = iso.string(from: v) }
                    return entry
                }
            }
            if payload.isEmpty {
                return Self.jsonString(["findings": [], "note": "No persisted findings — the app writes this snapshot when its Health audit runs; open the app's Health tab to refresh."])
            }
            return Self.jsonString(payload)
        } catch where Self.isMissingTable(error) {
            return Self.fsSchemaOutOfDate
        }
    }

    // MARK: - FamilySearch tools (WL7)
    //
    // Reads target the v52/v53 tables the app's write leg maintains; the two
    // request tools stage rows the app's RunRequestWatcher executes with the
    // APP's FamilySearch auth. This server never talks to FamilySearch —
    // one binary owns the key and tokens. A project database that predates
    // the FS migrations gets a friendly schema_out_of_date payload, not a
    // raw SQL error.

    private static let fsSchemaOutOfDate =
        "{\"error\": \"schema_out_of_date\", \"detail\": \"This project database predates the FamilySearch tables — open the project in the Ancestor Research app once to run migrations, then retry.\"}"

    private nonisolated static func isMissingTable(_ error: Error) -> Bool {
        String(describing: error).lowercased().contains("no such table")
    }

    func getFSUploadStatusResponseText(_ args: [String: Any]) throws -> String {
        let limit = max(1, min((args["limit"] as? Int) ?? 5, 50))
        let iso = ISO8601DateFormatter()
        do {
            let payload: [[String: Any]] = try db.read { dbConn in
                let rows = try Row.fetchAll(dbConn, sql: """
                    SELECT id, environment, fs_group_id, fs_tree_id, tree_name, tree_description,
                           starting_profile_id, private, phase, started_at, finalized_at,
                           persons_uploaded, relationships_uploaded, sources_uploaded
                    FROM familysearch_tree_uploads
                    ORDER BY started_at DESC LIMIT ?
                    """, arguments: [limit])
                return rows.map { row in
                    var entry: [String: Any] = [
                        "run_id": row["id"] as String? ?? "",
                        "environment": row["environment"] as String? ?? "",
                        "phase": row["phase"] as String? ?? "",
                        "tree_name": row["tree_name"] as String? ?? "",
                        "persons_uploaded": row["persons_uploaded"] as Int? ?? 0,
                        "relationships_uploaded": row["relationships_uploaded"] as Int? ?? 0,
                        "sources_uploaded": row["sources_uploaded"] as Int? ?? 0,
                    ]
                    if let v: String = row["fs_tree_id"] { entry["fs_tree_id"] = v }
                    if let v: String = row["fs_group_id"] { entry["fs_group_id"] = v }
                    if let v: String = row["starting_profile_id"] { entry["starting_profile_id"] = v }
                    if let v: Bool = row["private"] { entry["private"] = v }
                    if let v: Date = row["started_at"] { entry["started_at"] = iso.string(from: v) }
                    if let v: Date = row["finalized_at"] { entry["finalized_at"] = iso.string(from: v) }
                    return entry
                }
            }
            return Self.jsonString(payload)
        } catch where Self.isMissingTable(error) {
            return Self.fsSchemaOutOfDate
        }
    }

    func getFSPersonLinksResponseText(_ args: [String: Any]) throws -> String {
        let limit = max(1, min((args["limit"] as? Int) ?? 100, 500))
        let profileID = args["profile_id"] as? String
        let iso = ISO8601DateFormatter()
        do {
            let payload: [[String: Any]] = try db.read { dbConn in
                var sql = """
                    SELECT profile_id, fs_tree_id, fs_pid, status, superseded_by, uploaded_at
                    FROM familysearch_person_links
                    """
                var arguments: [DatabaseValueConvertible] = []
                if let profileID, !profileID.isEmpty {
                    sql += " WHERE profile_id = ?"
                    arguments.append(profileID)
                }
                sql += " ORDER BY uploaded_at DESC LIMIT ?"
                arguments.append(limit)
                let rows = try Row.fetchAll(dbConn, sql: sql, arguments: StatementArguments(arguments))
                return rows.map { row in
                    var entry: [String: Any] = [
                        "profile_id": row["profile_id"] as String? ?? "",
                        "fs_tree_id": row["fs_tree_id"] as String? ?? "",
                        "fs_pid": row["fs_pid"] as String? ?? "",
                        "status": row["status"] as String? ?? "",
                    ]
                    if let v: String = row["superseded_by"] { entry["superseded_by"] = v }
                    if let v: Date = row["uploaded_at"] { entry["uploaded_at"] = iso.string(from: v) }
                    return entry
                }
            }
            return Self.jsonString(payload)
        } catch where Self.isMissingTable(error) {
            return Self.fsSchemaOutOfDate
        }
    }

    func getFSHintsResponseText(_ args: [String: Any]) throws -> String {
        guard let profileID = args["profile_id"] as? String, !profileID.isEmpty else {
            throw MCPError.invalidParams("get_fs_hints requires profile_id")
        }
        let limit = max(1, min((args["limit"] as? Int) ?? 50, 500))
        let iso = ISO8601DateFormatter()
        // Canonical lead→record join: a scored lead's id is
        // 'lead_' + evidence_records.source_record_id (same join the app's
        // backfillLeadAgePlace uses); source_id = 'familysearch' scopes to FS.
        let payload: [[String: Any]] = try db.read { dbConn in
            let rows = try Row.fetchAll(dbConn, sql: """
                SELECT l.id, l.name, l.surname, l.given_name, l.birth_year, l.death_year,
                       l.status, l.evidence, l.created_at, l.place,
                       e.verdict, e.record_type, e.citation_url
                FROM leads l
                JOIN evidence_records e
                  ON l.id = 'lead_' || e.source_record_id AND l.profile_id = e.profile_id
                WHERE l.profile_id = ? AND e.source_id = 'familysearch'
                ORDER BY l.created_at DESC LIMIT ?
                """, arguments: [profileID, limit])
            return rows.map { row in
                var entry: [String: Any] = [
                    "lead_id": row["id"] as String? ?? "",
                    "name": row["name"] as String? ?? "",
                    "status": row["status"] as String? ?? "",
                    "verdict": row["verdict"] as String? ?? "",
                    "record_type": row["record_type"] as String? ?? "",
                    "evidence": row["evidence"] as String? ?? "",
                ]
                if let v: Int = row["birth_year"] { entry["birth_year"] = v }
                if let v: Int = row["death_year"] { entry["death_year"] = v }
                if let v: String = row["place"] { entry["place"] = v }
                if let v: String = row["citation_url"] { entry["citation_url"] = v }
                if let v: Date = row["created_at"] { entry["created_at"] = iso.string(from: v) }
                return entry
            }
        }
        return Self.jsonString(payload)
    }

    func getFSRequestStatusResponseText(_ args: [String: Any]) throws -> String {
        let requestID = args["request_id"] as? String
        let iso = ISO8601DateFormatter()
        do {
            let payload: [[String: Any]] = try db.read { dbConn in
                let rows: [Row]
                if let requestID, !requestID.isEmpty {
                    rows = try Row.fetchAll(dbConn, sql: """
                        SELECT * FROM fs_action_requests WHERE id = ?
                        """, arguments: [requestID])
                } else {
                    rows = try Row.fetchAll(dbConn, sql: """
                        SELECT * FROM fs_action_requests ORDER BY created_at DESC LIMIT 10
                        """)
                }
                return rows.map { row in
                    var entry: [String: Any] = [
                        "request_id": row["id"] as String? ?? "",
                        "kind": row["kind"] as String? ?? "",
                        "status": row["status"] as String? ?? "",
                    ]
                    if let v: String = row["profile_id"] { entry["profile_id"] = v }
                    if let v: String = row["tree_name"] { entry["tree_name"] = v }
                    if let v: String = row["note"] { entry["note"] = v }
                    if let v: Date = row["created_at"] { entry["created_at"] = iso.string(from: v) }
                    if let v: Date = row["completed_at"] { entry["completed_at"] = iso.string(from: v) }
                    return entry
                }
            }
            if let requestID, payload.isEmpty {
                return Self.jsonString(["error": "request_not_found", "request_id": requestID])
            }
            return Self.jsonString(payload)
        } catch where Self.isMissingTable(error) {
            return Self.fsSchemaOutOfDate
        }
    }

    func requestFSHintsResponseText(_ args: [String: Any]) throws -> String {
        guard let profileID = args["profile_id"] as? String, !profileID.isEmpty else {
            throw MCPError.invalidParams("request_fs_hints requires profile_id")
        }
        do {
            return try db.write { dbConn in
                guard try Row.fetchOne(dbConn, sql: "SELECT id FROM profiles WHERE id = ?",
                                       arguments: [profileID]) != nil else {
                    return Self.jsonString(["error": "profile_not_found", "profile_id": profileID])
                }
                if let existing = try Row.fetchOne(dbConn, sql: """
                    SELECT id, status FROM fs_action_requests
                    WHERE kind = 'hints' AND profile_id = ? AND status IN ('queued', 'running')
                    LIMIT 1
                    """, arguments: [profileID]) {
                    let id: String = existing["id"]
                    return "A hints request for this profile is already \(existing["status"] as String? ?? "queued") — request_id: \(id). Poll get_fs_request_status."
                }
                let id = "fsreq_\(UUID().uuidString)"
                try dbConn.execute(sql: """
                    INSERT INTO fs_action_requests (id, kind, profile_id, status, requested_by, created_at)
                    VALUES (?, 'hints', ?, 'queued', 'mcp', ?)
                    """, arguments: [id, profileID, Date()])
                return "FamilySearch hints request queued. request_id: \(id). The app executes it with its own FamilySearch sign-in; resulting leads land in Triage. Needs the app running with this project open and a FamilySearch session. Poll get_fs_request_status, then read get_fs_hints."
            }
        } catch where Self.isMissingTable(error) {
            return Self.fsSchemaOutOfDate
        }
    }

    func requestFSUploadResponseText(_ args: [String: Any]) throws -> String {
        let treeName = args["tree_name"] as? String
        let treeDescription = args["tree_description"] as? String
        do {
            return try db.write { dbConn in
                if let existing = try Row.fetchOne(dbConn, sql: """
                    SELECT id, status FROM fs_action_requests
                    WHERE kind = 'upload' AND status IN ('queued', 'running')
                    LIMIT 1
                    """) {
                    let id: String = existing["id"]
                    return "An upload request is already \(existing["status"] as String? ?? "queued") — request_id: \(id). Uploads are resumable; wait for it rather than stacking another. Poll get_fs_request_status."
                }
                let id = "fsreq_\(UUID().uuidString)"
                try dbConn.execute(sql: """
                    INSERT INTO fs_action_requests (id, kind, tree_name, tree_description, status, requested_by, created_at)
                    VALUES (?, 'upload', ?, ?, 'queued', 'mcp', ?)
                    """, arguments: [id, treeName, treeDescription, Date()])
                return "FamilySearch tree-upload request queued. request_id: \(id). The app uploads deceased persons only, resumably, with its own FamilySearch sign-in — and the tree stays HIDDEN: finalizing (visibility + privacy) is an in-app wizard consent. Poll get_fs_request_status and get_fs_upload_status."
            }
        } catch where Self.isMissingTable(error) {
            return Self.fsSchemaOutOfDate
        }
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

    /// §14.3.4 carve-out (RESEARCH_PIPELINE_SPEC §5.14.5).
    /// Pure predicate: returns true iff the pending fact is eligible
    /// for the SubjectSpouseMarriage-strategy fast path — fact_kind
    /// "firstName", agent_id "subject-spouse-marriage", and the
    /// subject's existing `first_name` is empty (recovery, not
    /// correction). When true, `evaluateApproval` bypasses the
    /// auto-approvable-field check and the convergence-≥2-lineages
    /// check; other §14.3 gates still apply.
    ///
    /// Extracted as a static for unit testing — the live gate's profile
    /// lookup happens inline in `evaluateApproval` so the test doesn't
    /// need a database fixture.
    static func isSubjectSpouseMarriageCarveOut(
        factKind: String,
        agentID: String,
        existingFirstName: String?
    ) -> Bool {
        guard factKind == "firstName" else { return false }
        guard agentID == "subject-spouse-marriage" else { return false }
        let trimmed = (existingFirstName ?? "")
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
    }

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

    /// Runtime gate for the auto-approval write path. Default off — and
    /// this change does NOT alter that default (§14.B.1 is an ADDITIONAL
    /// gate, not a reason to enable auto-approval).
    /// The §14.3 gate (trust tier + convergence + dispute + field-set)
    /// catches rule violations but not fabrications — an AI that
    /// asserts a value its source URL doesn't actually contain would
    /// pass every criterion. The §14.B.1 defensive hallucination re-check
    /// (`runHallucinationRecheck`) now closes that hole: when auto-approve
    /// is enabled AND the §14.3 gate passes, the commit path re-fetches
    /// the cited page (page-cache first) and confirms the claim before
    /// committing. Set `ANCESTOR_MCP_AUTO_APPROVE=1` to enable for dev work.
    static func isAutoApprovalEnabled() -> Bool {
        let v = ProcessInfo.processInfo.environment["ANCESTOR_MCP_AUTO_APPROVE"]
        return v == "1" || v?.lowercased() == "true"
    }

    /// §14.B.1 defensive hallucination re-check for one pending fact.
    ///
    /// Reads the pending fact's cited URL + claimed value + evidence excerpt
    /// from the `pending_facts` row, then runs the deterministic
    /// `MCPHallucinationRecheck` against the app's on-disk page-cache. Injectable
    /// `pages` for tests; production derives the app's page-cache dir from the
    /// project DB path (BOUNCES on cache-miss — see `CachingPageProvider`).
    func runHallucinationRecheck(
        pendingFactID: String,
        pages: (any PageProvider)? = nil
    ) async throws -> MCPHallucinationRecheck.AuditEntry {
        let claim: MCPHallucinationRecheck.Claim = try await db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM pending_facts WHERE id = ?", arguments: [pendingFactID])
            return MCPHallucinationRecheck.Claim(
                profileID: row?["profile_id"] ?? "",
                field: row?["fact_kind"] ?? "",
                value: row?["value_json"] ?? "",
                sourceURL: row?["source_url"] ?? "",
                evidenceText: row?["evidence_text"] ?? ""
            )
        }

        let provider: any PageProvider
        if let pages {
            provider = pages
        } else if let cacheDir = CachingPageProvider.cacheDirectory(forProjectDBPath: dbPath) {
            provider = CachingPageProvider(cacheDirectory: cacheDir)
        } else {
            // No derivable cache dir → conservative bounce (empty provider,
            // always a cache-miss). Can't verify → don't auto-approve.
            provider = CachingPageProvider(cacheDirectory: URL(fileURLWithPath: "/nonexistent"))
        }

        return await MCPHallucinationRecheck.recheck(claim: claim, pages: provider)
    }

    /// The inner JSON payload string of a tool response
    /// (`content[0].text`). `Sendable`, so it can cross the actor boundary —
    /// used by the run loop's stdout path and by tests that assert on the
    /// response without pulling the non-Sendable `[String: Any]` across.
    static func toolResponseText(_ response: [String: Any]) -> String {
        guard let content = response["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else { return "{}" }
        return text
    }

    /// Convenience for the run loop / tests: run `approve_pending_fact` and
    /// return its inner JSON payload string (`Sendable`).
    func approvePendingFactResponseText(_ args: [String: Any]) async throws -> String {
        Self.toolResponseText(try await approvePendingFact(args))
    }

    /// Convenience for tests: run `get_scored_records` and return its inner
    /// JSON payload string (`Sendable`).
    func getScoredRecordsResponseText(_ args: [String: Any]) throws -> String {
        Self.toolResponseText(try getScoredRecords(args))
    }

    func approvePendingFact(_ args: [String: Any]) async throws -> [String: Any] {
        guard let pendingFactID = args["pending_fact_id"] as? String else {
            throw MCPError.invalidParams("approve_pending_fact requires pending_fact_id")
        }

        guard Self.isAutoApprovalEnabled() else {
            let payload: [String: Any] = [
                "status": "refused",
                "reason": "auto_approval_gate_disabled",
                "detail": "Auto-approval is disabled by default. When enabled, commit is double-gated: the deterministic §14.3 gate (rule compliance) AND the §14.B.1 defensive hallucination re-check (re-fetches the cited page and confirms the claimed value/evidence actually appears — source-value fidelity). Set ANCESTOR_MCP_AUTO_APPROVE=1 in the environment to override for dev work.",
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
            // §14.B.1 defensive hallucination re-check — the ADDITIONAL gate.
            // Runs only here: auto-approve is already enabled AND the §14.3
            // deterministic gate has passed. Independently re-fetches the cited
            // page (page-cache first) and confirms the specific claim actually
            // appears before allowing the commit. On .bounced the fact is NOT
            // committed and stays pending for human review.
            let recheck = try await runHallucinationRecheck(pendingFactID: pendingFactID)
            if case .bounced(let flag) = recheck.decision {
                let payload: [String: Any] = [
                    "status": "refused",
                    "reason": "hallucination_recheck_failed",
                    "detail": "§14.B.1 re-check bounced (\(flag.rawValue)): the claimed value/evidence could not be independently confirmed on the cited page. Fact left in pending_facts for human review.",
                    "pending_fact_id": pendingFactID,
                    "hallucination_flag": flag.rawValue,
                    "served_from_cache": recheck.servedFromCache,
                    "still_pending": true,
                ]
                let json = (try? String(data: JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted), encoding: .utf8)) ?? "{}"
                return ["content": [["type": "text", "text": json]]]
            }

            let committed = try commitPendingFact(pendingFactID: pendingFactID, criteria: criteria)
            var payload: [String: Any] = [
                "status": "approved",
                "pending_fact_id": pendingFactID,
                "criteria_met": criteria,
                "hallucination_recheck": "approved",
                "recheck_served_from_cache": recheck.servedFromCache,
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
    /// Sendable projection of `evaluateApproval` for cross-actor callers
    /// (tests): the refusal reason string, or nil when the gate approves.
    func approvalRefusalReason(pendingFactID: String) throws -> String? {
        if case .refuse(let reason, _) = try evaluateApproval(pendingFactID: pendingFactID) {
            return reason
        }
        return nil
    }

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
            let agentID: String = row["agent_id"] ?? ""

            // Already processed (accepted/rejected) — no-op refuse.
            guard reviewStatus == "pending" else {
                return .refuse(
                    reason: "pending_fact_already_processed",
                    detail: "Pending fact already in status '\(reviewStatus)'."
                )
            }

            // §14.3.4 carve-out (RESEARCH_PIPELINE_SPEC §5.14.5): when
            // the pending fact came from a `.subjectSpouseMarriage`
            // hypothesis write-back AND the subject's `first_name` is
            // currently empty (recovery, not correction), the gate
            // relaxes (a) the auto-approvable field set to include
            // `firstName`, and (b) convergence requirement (the
            // groom-side/bride-side BMD index reference-tuple match IS
            // the within-source convergence check). All other gates
            // (trust tier ≥ transcription, no-dispute, hallucination)
            // continue to apply.
            let existingFirstName: String? = try? Row.fetchOne(
                db, sql: "SELECT first_name FROM profiles WHERE id = ?",
                arguments: [profileID]
            )?["first_name"]
            let isCarveOut = Self.isSubjectSpouseMarriageCarveOut(
                factKind: factKind,
                agentID: agentID,
                existingFirstName: existingFirstName
            )

            // Auto-approvable field set — bypassed for the carve-out.
            if !isCarveOut {
                guard Self.autoApprovableFields.contains(factKind) else {
                    return .refuse(
                        reason: "field_not_auto_approvable",
                        detail: "Field '\(factKind)' is excluded from auto-approval. Names, gender, and bio are always human-reviewed."
                    )
                }
            }

            // CONFLICT_LAYER_SPEC CL6 (§4.8.5) — an OPEN dispute on the
            // target profile refuses auto-approval outright: field-level
            // disputes on the target field, and structural kinds
            // (timeline/parentRole/spouseIdentity) that field_sources
            // recomputation cannot see. Human resolves first.
            // Defensive on pre-v41 databases: no field_disputes table
            // means no dispute ledger exists to consult — not a failure.
            let openDisputeRows = (try? Row.fetchAll(db, sql: """
                SELECT kind, field FROM field_disputes
                WHERE entity_id = ? AND resolution IS NULL
                """, arguments: [profileID])) ?? []
            for row in openDisputeRows {
                let kind: String = row["kind"] ?? "fieldValue"
                let field: String = row["field"] ?? ""
                let blocks = (kind == "fieldValue" && field == factKind)
                    || kind == "timeline" || kind == "parentRole" || kind == "spouseIdentity"
                if blocks {
                    return .refuse(
                        reason: "open_dispute_on_target",
                        detail: "Open \(kind) dispute ('\(field)') on this profile — auto-approval refuses until the conflict is resolved by the human."
                    )
                }
            }

            // Trust tier — URL host must be in the trusted list. The
            // trusted-host list already includes FreeBMD (transcription
            // tier), so the carve-out doesn't need to relax this gate;
            // it just needs the existing list, which §5.14.5 (iii)
            // requires.
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
            //
            // Carve-out (§5.14.5): the BMD reference-tuple match IS the
            // structural convergence check. When the pending fact came
            // from a `.subjectSpouseMarriage` write-back, single-source
            // convergence is sufficient — the agreement between
            // groom-side and bride-side BMD index entries already
            // cross-validated the marriage at hypothesis-grade time.
            var independentLineages = corroboratingLineages
            independentLineages.insert(host)

            if !isCarveOut {
                guard independentLineages.count >= 2 else {
                    return .refuse(
                        reason: "convergence_insufficient",
                        detail: "Need ≥ 2 independent lineages; found \(independentLineages.count) (\(independentLineages.sorted().joined(separator: ", "))). Pending fact must corroborate at least one existing source from a different lineage."
                    )
                }
            }

            return .approve(criteria: [
                "trustTier": isCarveOut ? "transcription_via_carveout" : "primary_or_secondary",
                "sourceHost": host,
                "sourceTitle": sourceTitle,
                "independentLineageCount": independentLineages.count,
                "lineages": independentLineages.sorted(),
                "carveOut": isCarveOut ? "subject_spouse_marriage" : NSNull(),
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

    // MARK: - Expansion bound at promote-time (ENGINE_FOUNDATION_SPEC #Change7)

    /// A single parent/child or spouse edge, as fetched from the
    /// `relationships` table. Mirrors the columns the SQL BFS needs so the
    /// bound logic is unit-testable without a live SQLite. `type` is
    /// "parent" or "spouse"; for a parent edge `from` is the parent and
    /// `to` is the child (matching the app's convention).
    struct GraphEdge: Equatable {
        let from: String
        let to: String
        let type: String   // "parent" | "spouse"
    }

    /// Which bound a project applies. Mirrors AncestorKit's
    /// `ExpansionPolicy`; the MCP is a standalone package (no AncestorKit
    /// dependency), so the rule is duplicated deliberately and both sides
    /// share the `config.yaml` / wire-string contract.
    enum ExpansionPolicy: Equatable {
        case collateralDepth(hops: Int)
        case generationalDistance(generations: Int)

        static let defaultGenerations = 4

        /// Parse the compact wire string ("generational:4" / "collateral:2")
        /// stored in `project_meta.expansion_policy`. nil (or unrecognised)
        /// → the engine default.
        static func parse(_ raw: String?) -> ExpansionPolicy {
            guard let raw else { return .generationalDistance(generations: defaultGenerations) }
            let parts = raw.trimmingCharacters(in: .whitespaces).lowercased()
                .split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[1]), n >= 0 else {
                return .generationalDistance(generations: defaultGenerations)
            }
            switch parts[0] {
            case "collateral": return .collateralDepth(hops: n)
            case "generational": return .generationalDistance(generations: n)
            default: return .generationalDistance(generations: defaultGenerations)
            }
        }
    }

    /// Queryable outcome of the bound check. Codes match AncestorKit's
    /// `ExpansionBoundReason.code`.
    enum ExpansionBoundOutcome: Equatable {
        case withinBounds(measuredDistance: Int)
        case outsideCollateralBound(limit: Int, measuredDistance: Int)
        case outsideGenerationalBound(limit: Int, measuredDistance: Int)
        case noSeedConfigured
        case generatorUnreachable

        var permitsPromotion: Bool {
            switch self {
            case .withinBounds, .noSeedConfigured: return true
            default: return false
            }
        }

        var code: String {
            switch self {
            case .withinBounds: return "within_bounds"
            case .outsideCollateralBound: return "outside_collateral_bound"
            case .outsideGenerationalBound: return "outside_generational_bound"
            case .noSeedConfigured: return "no_seed_configured"
            case .generatorUnreachable: return "generator_unreachable"
            }
        }

        var detail: String {
            switch self {
            case .withinBounds(let d):
                return "Within bounds (measured distance \(d))."
            case .outsideCollateralBound(let limit, let d):
                return "Outside collateral bound: generator is \(d) collateral hops from the nearest proband (limit \(limit))."
            case .outsideGenerationalBound(let limit, let d):
                return "Outside generational bound: generator is \(d) generations from the nearest seed (limit \(limit))."
            case .noSeedConfigured:
                return "No proband/seed configured — expansion bound not applied."
            case .generatorUnreachable:
                return "Generator profile is not reachable from any seed — outside the core tree."
            }
        }
    }

    /// Decide whether a `promote_lead` INSERT is within the project's
    /// expansion bound, given the full edge set, the seed (home-person)
    /// IDs, and the generator profile the new node attaches to.
    ///
    /// Pure — no SQLite. Mirrors `ExpansionBounds.evaluate` in AncestorKit:
    ///  - generational: 0-1 BFS, parent/child = 1, spouse = 0.
    ///  - collateral: turn-counting BFS, direct ancestors/descendants of a
    ///    proband = depth 0; each up→down turn or spouse hop = +1.
    /// Empty seeds → `.noSeedConfigured` (fail-open). Empty generator or a
    /// generator not in any edge but with seeds present →
    /// `.noSeedConfigured` too (no tree anchor to bound against).
    static func decideExpansionBound(
        policy: ExpansionPolicy,
        edges: [GraphEdge],
        seedIDs: [String],
        generatorID: String
    ) -> ExpansionBoundOutcome {
        guard !seedIDs.isEmpty else { return .noSeedConfigured }
        guard !generatorID.isEmpty else { return .noSeedConfigured }

        // Promoted node = one hop beyond its generator, so its distance is
        // generator distance + 1 (mirrors AncestorKit's ExpansionBounds).
        switch policy {
        case .generationalDistance(let generations):
            guard let d = nearestGenerationalDistance(
                edges: edges, seeds: seedIDs, target: generatorID
            ) else { return .generatorUnreachable }
            let promoted = d + 1
            return promoted <= generations
                ? .withinBounds(measuredDistance: promoted)
                : .outsideGenerationalBound(limit: generations, measuredDistance: promoted)

        case .collateralDepth(let hops):
            guard let d = nearestCollateralDepth(
                edges: edges, seeds: seedIDs, target: generatorID
            ) else { return .generatorUnreachable }
            let promoted = d + 1
            return promoted <= hops
                ? .withinBounds(measuredDistance: promoted)
                : .outsideCollateralBound(limit: hops, measuredDistance: promoted)
        }
    }

    // -- generational distance (spouse = 0, parent/child = 1) --

    private static func nearestGenerationalDistance(
        edges: [GraphEdge], seeds: [String], target: String
    ) -> Int? {
        var best: Int?
        for seed in seeds {
            if let d = generationalDistance(edges: edges, from: seed, to: target) {
                best = best.map { min($0, d) } ?? d
            }
        }
        return best
    }

    private static func generationalDistance(
        edges: [GraphEdge], from seed: String, to target: String
    ) -> Int? {
        var distance: [String: Int] = [seed: 0]
        var frontier: [(id: String, dist: Int)] = [(seed, 0)]
        while !frontier.isEmpty {
            frontier.sort { $0.dist != $1.dist ? $0.dist < $1.dist : $0.id < $1.id }
            let current = frontier.removeFirst()
            if current.dist > (distance[current.id] ?? .max) { continue }
            if current.id == target { return current.dist }
            for (nID, w) in genNeighbours(edges: edges, of: current.id) {
                let nd = current.dist + w
                if nd < (distance[nID] ?? .max) {
                    distance[nID] = nd
                    frontier.append((nID, nd))
                }
            }
        }
        return distance[target]
    }

    private static func genNeighbours(edges: [GraphEdge], of id: String) -> [(String, Int)] {
        var out: [(String, Int)] = []
        for e in edges where e.type == "parent" && e.to == id { out.append((e.from, 1)) }   // parent
        for e in edges where e.type == "parent" && e.from == id { out.append((e.to, 1)) }    // child
        for e in edges where e.type == "spouse" && (e.from == id || e.to == id) {
            out.append((e.from == id ? e.to : e.from, 0))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    // -- collateral depth (turn-counting) --

    private enum WalkDir: Hashable { case start, up, down }
    private struct WalkState: Hashable { let id: String; let dir: WalkDir }

    private static func nearestCollateralDepth(
        edges: [GraphEdge], seeds: [String], target: String
    ) -> Int? {
        var best: Int?
        for p in seeds {
            if let d = collateralDepth(edges: edges, from: p, to: target) {
                best = best.map { min($0, d) } ?? d
            }
        }
        return best
    }

    private static func collateralDepth(
        edges: [GraphEdge], from proband: String, to target: String
    ) -> Int? {
        let start = WalkState(id: proband, dir: .start)
        var cost: [WalkState: Int] = [start: 0]
        var frontier: [(state: WalkState, cost: Int)] = [(start, 0)]
        while !frontier.isEmpty {
            frontier.sort {
                $0.cost != $1.cost ? $0.cost < $1.cost
                    : ($0.state.id != $1.state.id ? $0.state.id < $1.state.id
                        : $0.state.dir.hashValue < $1.state.dir.hashValue)
            }
            let cur = frontier.removeFirst()
            if cur.cost > (cost[cur.state] ?? .max) { continue }
            if cur.state.id == target { return cur.cost }
            for (next, turn) in collateralNeighbours(edges: edges, of: cur.state) {
                let nc = cur.cost + turn
                if nc < (cost[next] ?? .max) {
                    cost[next] = nc
                    frontier.append((next, nc))
                }
            }
        }
        return cost.filter { $0.key.id == target }.values.min()
    }

    private static func collateralNeighbours(
        edges: [GraphEdge], of state: WalkState
    ) -> [(WalkState, Int)] {
        var out: [(WalkState, Int)] = []
        // parents
        let parents = edges.filter { $0.type == "parent" && $0.to == state.id }
            .map(\.from).sorted()
        for p in parents {
            out.append((WalkState(id: p, dir: .up), state.dir == .down ? 1 : 0))
        }
        // children
        let children = edges.filter { $0.type == "parent" && $0.from == state.id }
            .map(\.to).sorted()
        for c in children {
            out.append((WalkState(id: c, dir: .down), state.dir == .up ? 1 : 0))
        }
        // spouses
        let spouses = edges.filter { $0.type == "spouse" && ($0.from == state.id || $0.to == state.id) }
            .map { $0.from == state.id ? $0.to : $0.from }.sorted()
        for s in spouses {
            out.append((WalkState(id: s, dir: .down), 1))
        }
        return out
    }

    // MARK: - Dedup at promote-time (ENGINE_FOUNDATION_SPEC #Change3)

    /// Same-surname candidate row used by `decideDedup`. Mirrors the
    /// columns selected from `profiles` so the matching logic can be
    /// unit-tested without a live SQLite.
    struct DedupCandidate: Equatable {
        let profileID: String
        let firstName: String?
        let lastName: String?
        let birthYearEarliest: Int?
        let birthYearLatest: Int?
    }

    enum DedupDecision: Equatable {
        case noMatch
        case matched(profileID: String)
        case multipleMatches
    }

    /// Decide whether a `promote_lead` INSERT should dedup against an
    /// existing profile, given pre-fetched same-surname candidates.
    ///
    /// Per ENGINE_FOUNDATION_SPEC #Change3:
    /// - Strict path: lead and candidate both have `givenName` → exact
    ///   (case-insensitive) match + year overlap.
    /// - Asymmetric path: either side lacks `givenName` → year overlap
    ///   alone (surname is already enforced by the caller's SQL filter).
    /// - Exactly one match → dedup. Multiple → INSERT new
    ///   (split-don't-merge per CLAUDE.md).
    static func decideDedup(
        leadGivenName: String?,
        leadBirthYearEarliest: Int?,
        leadBirthYearLatest: Int?,
        candidates: [DedupCandidate]
    ) -> DedupDecision {
        let leadGiven = (leadGivenName ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        let leadHasGiven = !leadGiven.isEmpty

        let matched: [String] = candidates.compactMap { c in
            let candGiven = (c.firstName ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            let candHasGiven = !candGiven.isEmpty

            guard yearWindowsOverlap(
                aEarliest: leadBirthYearEarliest, aLatest: leadBirthYearLatest,
                bEarliest: c.birthYearEarliest, bLatest: c.birthYearLatest
            ) else { return nil }

            if leadHasGiven && candHasGiven {
                return leadGiven == candGiven ? c.profileID : nil
            }
            // Asymmetric or both-surname-only: surname (by SQL) + year
            // overlap is the whole match.
            return c.profileID
        }

        switch matched.count {
        case 0: return .noMatch
        case 1: return .matched(profileID: matched[0])
        default: return .multipleMatches
        }
    }

    /// True when window [aEarliest…aLatest] (with ±2-year fudge) overlaps
    /// [bEarliest…bLatest]. If either window has no year information at
    /// all, returns true (the surname match is the only signal — accept
    /// the candidate set bound by the SQL filter and let the count gate
    /// in `decideDedup` decide).
    static func yearWindowsOverlap(
        aEarliest: Int?, aLatest: Int?,
        bEarliest: Int?, bLatest: Int?
    ) -> Bool {
        let aHasYear = aEarliest != nil || aLatest != nil
        let bHasYear = bEarliest != nil || bLatest != nil
        guard aHasYear, bHasYear else { return true }

        let aE = (aEarliest ?? aLatest!) - 2
        let aL = (aLatest ?? aEarliest!) + 2
        let bE = bEarliest ?? bLatest!
        let bL = bLatest ?? bEarliest!

        return aE <= bL && aL >= bE
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
