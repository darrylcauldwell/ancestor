import Foundation
import os
import GRDB

/// Orchestrates the in-app Field Researcher. Builds context from the tree,
/// runs multi-turn conversations with the Claude API, extracts structured
/// findings, and feeds them through the Evidence Firewall.
actor FieldResearcherService {
    private let api: ClaudeAPIClient
    private let db: ProjectDatabase
    private let snapshot: FamilyGraphSnapshot
    private let sourceInfoMap: [String: SourceInfo]
    private let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "FieldResearcher")

    private var sessionBudget: Double
    private(set) var findings: [FieldResearchFinding] = []
    private(set) var narrativeFindings: [NarrativeFinding] = []
    private(set) var leads: [FieldResearchLead] = []
    private(set) var isRunning = false
    private(set) var currentTurn = 0
    private(set) var statusMessage = ""

    init(
        api: ClaudeAPIClient,
        db: ProjectDatabase,
        snapshot: FamilyGraphSnapshot,
        sourceInfoMap: [String: SourceInfo],
        sessionBudget: Double = 0.50
    ) {
        self.api = api
        self.db = db
        self.snapshot = snapshot
        self.sourceInfoMap = sourceInfoMap
        self.sessionBudget = sessionBudget
    }

    // MARK: - Research a Profile

    /// Research a specific profile. Multi-turn conversation with tool use.
    func research(profileID: String) async -> FieldResearchResult {
        guard let profile = snapshot.profiles[profileID] else {
            return FieldResearchResult(profileID: profileID, findings: [], narrativeFindings: [], leads: [], turns: 0, cost: 0)
        }

        isRunning = true
        findings = []
        narrativeFindings = []
        leads = []
        currentTurn = 0
        statusMessage = "Building context..."
        await api.resetSessionCost()

        let context = buildContext(profile: profile)
        let tools = buildTools()

        var messages: [ConversationMessage] = [
            ConversationMessage(role: "user", content: .text(context))
        ]

        // Multi-turn loop — up to 8 turns
        let maxTurns = 8
        for turn in 1...maxTurns {
            currentTurn = turn
            statusMessage = "Turn \(turn)/\(maxTurns) — reasoning..."

            // Budget check (§10 — soft warn at 75%, hard stop at 100%)
            let cost = await api.estimatedCost
            let budget = self.sessionBudget
            if cost >= budget {
                logger.info("Budget exceeded: $\(cost) >= $\(budget)")
                statusMessage = "Budget limit reached"
                break
            }
            if cost >= budget * 0.75 {
                logger.info("Budget warning: $\(cost) approaching $\(budget)")
            }

            do {
                let response = try await api.send(
                    system: FieldResearchPrompts.systemPrompt,
                    messages: messages,
                    tools: tools
                )

                // Process tool calls
                if response.hasToolCalls {
                    // Add assistant message with tool use blocks
                    var assistantBlocks: [ConversationMessage.ContentBlock] = []
                    if !response.text.isEmpty {
                        assistantBlocks.append(.text(response.text))
                    }
                    for call in response.toolCalls {
                        assistantBlocks.append(.toolUse(id: call.id, name: call.name, input: call.input))
                    }
                    messages.append(ConversationMessage(role: "assistant", content: .mixed(assistantBlocks)))

                    // Handle each tool call
                    var resultBlocks: [ConversationMessage.ContentBlock] = []
                    for call in response.toolCalls {
                        let result = handleToolCall(call, profileID: profileID)
                        resultBlocks.append(.toolResult(toolUseID: call.id, content: result))
                    }
                    messages.append(ConversationMessage(role: "user", content: .mixed(resultBlocks)))
                } else {
                    // No tool calls — model is done or just giving text
                    if response.isEndTurn {
                        break
                    }
                    // Add response and prompt for more
                    messages.append(ConversationMessage(role: "assistant", content: .text(response.text)))
                    messages.append(ConversationMessage(role: "user", content: .text(
                        "Continue searching. If you have found everything available, use submit_finding for each result and then stop."
                    )))
                }
            } catch {
                logger.error("API error on turn \(turn): \(error.localizedDescription)")
                statusMessage = "Error: \(error.localizedDescription)"
                break
            }
        }

        isRunning = false
        let finalCost = await api.estimatedCost
        statusMessage = "Complete — \(findings.count) findings, \(leads.count) leads"

        // Persist session
        await persistSession(profileID: profileID, cost: finalCost)

        return FieldResearchResult(
            profileID: profileID,
            findings: findings,
            narrativeFindings: narrativeFindings,
            leads: leads,
            turns: currentTurn,
            cost: finalCost
        )
    }

    // MARK: - Context Building

    private func buildContext(profile: Profile) -> String {
        let comp = snapshot.completeness(for: profile.id)
        let parents = snapshot.parentsOf(profile.id)
        let spouses = snapshot.spousesOf(profile.id)
        let children = snapshot.childrenOf(profile.id)
        let siblings = snapshot.siblingsOf(profile.id)

        var lines: [String] = []
        lines.append("Research \(profile.displayName).")
        lines.append("")

        // Identity
        lines.append("## Known Facts")
        if let b = profile.birthDate?.original { lines.append("- Birth: \(b)") }
        if let bl = profile.birthLocation { lines.append("- Birth location: \(bl)") }
        if let d = profile.deathDate?.original { lines.append("- Death: \(d)") }
        if let dl = profile.deathLocation { lines.append("- Death location: \(dl)") }
        if let g = profile.gender { lines.append("- Gender: \(g.rawValue)") }

        // Missing fields
        if !comp.missing.isEmpty {
            lines.append("")
            lines.append("## Missing (priority research targets)")
            for check in comp.missing {
                lines.append("- \(check.label)")
            }
        }

        // Relationships
        if !parents.isEmpty || !spouses.isEmpty || !children.isEmpty {
            lines.append("")
            lines.append("## Family")
            for p in parents { lines.append("- Parent: \(p.displayName)\(p.birthDate.map { " (b.\($0.original))" } ?? "")") }
            for s in spouses { lines.append("- Spouse: \(s.displayName)\(s.birthDate.map { " (b.\($0.original))" } ?? "")") }
            for c in children { lines.append("- Child: \(c.displayName)\(c.birthDate.map { " (b.\($0.original))" } ?? "")") }
            for s in siblings { lines.append("- Sibling: \(s.displayName)\(s.birthDate.map { " (b.\($0.original))" } ?? "")") }
        }

        // Negative searches
        if let negatives = try? db.loadNegativeSearches(profileID: profile.id), !negatives.isEmpty {
            lines.append("")
            lines.append("## Already Searched (no results)")
            for neg in negatives {
                lines.append("- \(neg.sourceID) (\(neg.recordType))")
            }
        }

        // Confirmed sources
        let fieldSources = profile.sources
        if !fieldSources.isEmpty {
            lines.append("")
            lines.append("## Existing Source Citations")
            for (field, sources) in fieldSources {
                for source in sources {
                    lines.append("- \(field.rawValue): \(source.raw) [\(source.origin.identifier)]")
                }
            }
        }

        lines.append("")
        lines.append("## Research Instructions")
        lines.append("Search for evidence about this person. For each finding, use submit_finding with the source URL and exact evidence text.")
        lines.append("For new people you discover (parents, siblings, spouses not yet in the tree), use submit_lead.")
        lines.append("For biographical details that don't fit a specific field (occupations from directories, newspaper mentions, wills), use submit_narrative_finding.")
        lines.append("Focus on sources the structured pipeline hasn't covered: parish registers, newspapers, directories, local history sites.")
        lines.append("")
        lines.append(FieldResearchPrompts.derbyshireContext)

        return lines.joined(separator: "\n")
    }

    // MARK: - Tool Definitions

    private func buildTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "submit_finding",
                description: "Submit a structured research finding for a specific profile field. The app will verify the URL, score the finding, and present it for human review.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "field": ["type": "string", "description": "Field: birthDate, deathDate, baptismDate, burialDate, birthLocation, deathLocation, marriageDate, marriageLocation, occupation, address, religion"],
                        "value": ["type": "string", "description": "The proposed value"],
                        "source_url": ["type": "string", "description": "URL where found"],
                        "source_title": ["type": "string", "description": "Source name"],
                        "evidence_text": ["type": "string", "description": "Exact text from source (max 200 chars)"],
                        "reasoning": ["type": "string", "description": "How you connected this to this person"],
                    ] as [String: Any],
                    "required": ["field", "value", "source_url", "source_title", "evidence_text", "reasoning"],
                ] as [String: Any]
            ),
            ClaudeTool(
                name: "submit_narrative_finding",
                description: "Submit unstructured biographical evidence: apprenticeships, wills, newspaper mentions, emigration records, trade directory entries, etc.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "category": ["type": "string", "description": "Category: apprenticeship, will_probate, newspaper, emigration, military_service, education, land_property, poor_law, trade_directory, inscription, other"],
                        "description": ["type": "string", "description": "What was found (max 500 chars)"],
                        "date_or_period": ["type": "string", "description": "When this applied"],
                        "source_url": ["type": "string", "description": "URL where found"],
                        "source_title": ["type": "string", "description": "Source name"],
                        "evidence_text": ["type": "string", "description": "Exact text (max 200 chars)"],
                        "reasoning": ["type": "string", "description": "How connected to this person"],
                    ] as [String: Any],
                    "required": ["category", "description", "source_url", "source_title", "evidence_text", "reasoning"],
                ] as [String: Any]
            ),
            ClaudeTool(
                name: "submit_lead",
                description: "Submit a newly discovered person who may be related to the profile being researched.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Full name"],
                        "relationship": ["type": "string", "description": "Relationship: father, mother, spouse, child, sibling"],
                        "birth_year": ["type": "integer", "description": "Approximate birth year"],
                        "death_year": ["type": "integer", "description": "Approximate death year"],
                        "evidence": ["type": "string", "description": "Evidence for this person"],
                        "source_url": ["type": "string", "description": "URL where found"],
                    ] as [String: Any],
                    "required": ["name", "evidence", "source_url"],
                ] as [String: Any]
            ),
            ClaudeTool(
                name: "check_tree",
                description: "Check if a person is already in the tree. Use before submitting leads to avoid duplicates.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Name to search for"],
                    ] as [String: Any],
                    "required": ["name"],
                ] as [String: Any]
            ),
        ]
    }

    // MARK: - Tool Call Handling

    private func handleToolCall(_ call: ClaudeToolCall, profileID: String) -> String {
        switch call.name {
        case "submit_finding":
            return handleSubmitFinding(call.input, profileID: profileID)
        case "submit_narrative_finding":
            return handleSubmitNarrativeFinding(call.input, profileID: profileID)
        case "submit_lead":
            return handleSubmitLead(call.input, profileID: profileID)
        case "check_tree":
            return handleCheckTree(call.input)
        default:
            return "Unknown tool: \(call.name)"
        }
    }

    private func handleSubmitFinding(_ input: [String: Any], profileID: String) -> String {
        guard let field = input["field"] as? String,
              let value = input["value"] as? String,
              let sourceURL = input["source_url"] as? String,
              let sourceTitle = input["source_title"] as? String,
              let evidenceText = input["evidence_text"] as? String,
              let reasoning = input["reasoning"] as? String else {
            return "Error: missing required fields"
        }

        let finding = FieldResearchFinding(
            field: field, value: value,
            sourceURL: sourceURL, sourceTitle: sourceTitle,
            evidenceText: String(evidenceText.prefix(200)),
            reasoning: reasoning
        )
        findings.append(finding)

        // Write to pending_facts
        let id = EvidenceFirewall.idempotencyKey(
            profileID: profileID, field: field, value: value, sourceURL: sourceURL
        )
        let tier = SourceTierRegistry.lookup(url: sourceURL)

        let cappedText = String(evidenceText.prefix(200))
        let trustRaw = tier.trustTier.rawValue
        let directRaw = tier.directness.rawValue
        let now = Date()
        do {
            try db.dbQueue.write { writeDB in
                try writeDB.execute(sql: """
                    INSERT OR IGNORE INTO pending_facts
                    (id, profile_id, fact_kind, value_json, sources_json, review_status, created_at,
                     source_url, source_title, evidence_text, reasoning, agent_id, verification_status,
                     source_trust_tier, source_directness)
                    VALUES (?, ?, ?, ?, '{}', 'pending', ?, ?, ?, ?, ?, 'field-researcher', 'pending', ?, ?)
                    """, arguments: [
                        id, profileID, field, value, now,
                        sourceURL, sourceTitle, cappedText, reasoning,
                        trustRaw, directRaw,
                    ])
            }
        } catch {
            return "Error saving: \(error.localizedDescription)"
        }

        return "Finding recorded: \(field) = \(value). Source tier: \(tier.description). Will be verified and scored by the app."
    }

    private func handleSubmitNarrativeFinding(_ input: [String: Any], profileID: String) -> String {
        guard let category = input["category"] as? String,
              let description = input["description"] as? String,
              let sourceURL = input["source_url"] as? String,
              let sourceTitle = input["source_title"] as? String,
              let evidenceText = input["evidence_text"] as? String,
              let reasoning = input["reasoning"] as? String else {
            return "Error: missing required fields"
        }

        let dateOrPeriod = input["date_or_period"] as? String
        let id = EvidenceFirewall.idempotencyKey(
            profileID: profileID, field: category, value: description, sourceURL: sourceURL
        )

        let finding = NarrativeFinding(
            id: id, profileID: profileID, category: category,
            description: String(description.prefix(500)),
            dateOrPeriod: dateOrPeriod, sourceURL: sourceURL,
            sourceTitle: sourceTitle,
            evidenceText: String(evidenceText.prefix(200)),
            reasoning: reasoning, agentID: "field-researcher",
            submittedAt: Date(), verificationStatus: .pending
        )
        narrativeFindings.append(finding)
        try? db.saveNarrativeFinding(finding)

        return "Narrative finding recorded: \(category) — \(String(description.prefix(80)))"
    }

    private func handleSubmitLead(_ input: [String: Any], profileID: String) -> String {
        guard let name = input["name"] as? String,
              let evidence = input["evidence"] as? String,
              let sourceURL = input["source_url"] as? String else {
            return "Error: missing required fields"
        }

        let lead = FieldResearchLead(
            name: name,
            relationship: input["relationship"] as? String,
            birthYear: input["birth_year"] as? Int,
            deathYear: input["death_year"] as? Int,
            evidence: evidence,
            sourceURL: sourceURL
        )
        leads.append(lead)

        // Check for existing match
        let existingMatch = snapshot.profiles.values.first { p in
            ScoringRules.nameSimilarity(p.displayName.uppercased(), name.uppercased()) >= 0.7
        }

        // Write to leads table
        let id = "lead_fr_\(name.hashValue)_\(Int(Date().timeIntervalSince1970))"
        try? db.saveLead(Lead(
            id: id, profileID: profileID, name: name,
            surname: name.split(separator: " ").last.map(String.init),
            givenName: name.split(separator: " ").first.map(String.init),
            birthYear: lead.birthYear, deathYear: lead.deathYear,
            relationship: lead.relationship, source: .discovery,
            status: .new, evidence: "\(evidence) [source: \(sourceURL)]",
            createdAt: Date()
        ))

        if let match = existingMatch {
            return "Lead recorded: \(name). NOTE: possible match to existing profile '\(match.displayName)' — the app will prompt to merge or keep separate."
        }
        return "Lead recorded: \(name)\(lead.relationship.map { " (\($0))" } ?? "")"
    }

    private func handleCheckTree(_ input: [String: Any]) -> String {
        guard let name = input["name"] as? String else {
            return "Error: name required"
        }

        let matches = snapshot.profiles.values.filter { p in
            ScoringRules.nameSimilarity(p.displayName.uppercased(), name.uppercased()) >= 0.7
        }

        if matches.isEmpty {
            return "No match found for '\(name)' in the tree."
        }

        let descriptions = matches.prefix(5).map { p in
            "\(p.displayName)\(p.birthDate.map { " (b.\($0.original))" } ?? "")"
        }
        return "Found \(matches.count) match(es): \(descriptions.joined(separator: "; "))"
    }

    // MARK: - Session Persistence

    private func persistSession(profileID: String, cost: Double) async {
        let tokens = await getTokenCounts()
        let findingsCount = findings.count
        saveSession(
            db: db, profileID: profileID, cost: cost,
            tokensInput: tokens.input, tokensOutput: tokens.output,
            findingsCount: findingsCount
        )
    }

    /// Nonisolated helper to write session data without actor isolation issues.
    nonisolated private func saveSession(
        db: ProjectDatabase, profileID: String, cost: Double,
        tokensInput: Int, tokensOutput: Int, findingsCount: Int
    ) {
        let id = UUID().uuidString
        let now = Date()
        try? db.dbQueue.write { writeDB in
            try writeDB.execute(sql: """
                INSERT INTO field_researcher_sessions
                (id, profile_id, agent_id, started_at, completed_at,
                 tokens_input, tokens_output, estimated_cost,
                 findings_submitted, findings_accepted)
                VALUES (?, ?, 'field-researcher', ?, ?, ?, ?, ?, ?, 0)
                """, arguments: [
                    id, profileID, now, now,
                    tokensInput, tokensOutput, cost, findingsCount,
                ])
        }
    }

    private func getTokenCounts() async -> (input: Int, output: Int) {
        let input = await api.sessionTokensInput
        let output = await api.sessionTokensOutput
        return (input, output)
    }
}

// MARK: - Result Types

nonisolated struct FieldResearchResult: Sendable {
    let profileID: String
    let findings: [FieldResearchFinding]
    let narrativeFindings: [NarrativeFinding]
    let leads: [FieldResearchLead]
    let turns: Int
    let cost: Double
}

nonisolated struct FieldResearchFinding: Sendable {
    let field: String
    let value: String
    let sourceURL: String
    let sourceTitle: String
    let evidenceText: String
    let reasoning: String
}

nonisolated struct FieldResearchLead: Sendable {
    let name: String
    let relationship: String?
    let birthYear: Int?
    let deathYear: Int?
    let evidence: String
    let sourceURL: String
}
