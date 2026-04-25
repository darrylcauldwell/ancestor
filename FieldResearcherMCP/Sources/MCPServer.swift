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

    init(dbPath: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.readonly = false
        self.db = try DatabaseQueue(path: dbPath, configuration: config)
    }

    func run() async {
        // Read JSON-RPC messages from stdin, line by line
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let id = request["id"]
            let method = request["method"] as? String ?? ""
            let params = request["params"] as? [String: Any] ?? [:]

            let response: Any
            do {
                response = try await handle(method: method, params: params)
            } catch {
                response = ["error": ["code": -32603, "message": error.localizedDescription]]
            }

            let result: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": response,
            ]

            if let resultData = try? JSONSerialization.data(withJSONObject: result),
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
        case "initialized":
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
            ]
        ]
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
        case _ where uri.hasPrefix("ancestor://profile/"):
            let id = String(uri.dropFirst("ancestor://profile/".count))
            content = try profileDetail(id: id)
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

        let id = UUID().uuidString
        let sourcesJSON = try String(
            data: JSONSerialization.data(withJSONObject: [
                "source_url": sourceURL,
                "source_title": sourceTitle,
                "evidence_text": evidenceText,
                "reasoning": reasoning,
                "confidence": confidence,
                "agent": "field-researcher",
            ]),
            encoding: .utf8
        ) ?? "{}"

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO pending_facts (id, profile_id, fact_kind, value_json, sources_json, review_status, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', ?)
                """, arguments: [id, profileID, field, value, sourcesJSON, Date()])
        }

        return [
            "content": [
                [
                    "type": "text",
                    "text": "Evidence submitted: \(field) = \(value) for profile \(profileID). ID: \(id). Status: pending human review.",
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

    // MARK: - Helpers

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
