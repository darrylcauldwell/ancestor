import Foundation
import os

/// Reasoning model-enhanced research interpreter with three capabilities:
/// 1. Cluster enhancement — reason about whether records belong together
/// 2. Disambiguation — "wrong person vs wrong tree" chain-of-thought
/// 3. Strategy suggestion — reason about which source to search next
///
/// Uses DeepSeek-R1 (reasoning model with <think> tags), not a generic LLM.
/// All outputs are suggestions — the deterministic engine has final say.
/// When the model and deterministic engine disagree, deterministic wins.
nonisolated struct ResearchInterpreter {

    private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "Interpreter")

    // MARK: - Evidence Summary (GPS Criterion 5)

    /// Generate a per-fact evidence summary — the "soundly reasoned conclusion."
    /// Uses LLM if available, falls back to deterministic template.
    static func evidenceSummary(
        for cluster: LifeCluster,
        subject: ResearchSubject,
        sourceInfoMap: [String: SourceInfo]
    ) async -> String {
        // Try LLM first
        let llm = LocalInferenceService.shared
        if await llm.isAvailable {
            let prompt = buildEvidenceSummaryPrompt(cluster: cluster, subject: subject)
            if let response = await llm.reason(
                prompt: prompt,
                systemPrompt: Prompts.evidenceSummarySystem,
                maxTokens: 512
            ) {
                return response
            }
        }

        // Deterministic template fallback
        return deterministicEvidenceSummary(cluster: cluster, subject: subject, sourceInfoMap: sourceInfoMap)
    }

    /// Deterministic template for evidence summary — always available.
    static func deterministicEvidenceSummary(
        cluster: LifeCluster,
        subject: ResearchSubject,
        sourceInfoMap: [String: SourceInfo]
    ) -> String {
        let name = subject.displayName
        var parts: [String] = []

        // Birth evidence
        if let birthYear = cluster.impliedBirthYear {
            let birthRecords = cluster.records.filter {
                if case .birth = $0.record { return true }
                if case .parish(let r) = $0.record, r.eventType?.lowercased() == "baptism" { return true }
                return false
            }
            let sources = birthRecords.map { $0.record.sourceID.uppercased() }
            if !sources.isEmpty {
                parts.append("Birth year \(birthYear) is established by \(sources.joined(separator: " and ")).")
            }

            // Census corroboration
            let censusRecords = cluster.records.compactMap { scored -> String? in
                if case .census(let r) = scored.record {
                    let impliedBirth = r.birthYear ?? (r.age.map { r.censusYear - $0 })
                    if let ib = impliedBirth {
                        return "\(r.censusYear) census age \(r.age ?? 0) (implying birth ~\(ib))"
                    }
                }
                return nil
            }
            if !censusRecords.isEmpty {
                parts.append("Corroborated by \(censusRecords.joined(separator: ", ")).")
            }
        }

        // Death evidence
        if let deathYear = cluster.impliedDeathYear {
            let deathRecords = cluster.records.filter {
                switch $0.record {
                case .death, .burial, .military, .probate: return true
                default: return false
                }
            }
            let sources = deathRecords.map { $0.record.sourceID.uppercased() }
            if !sources.isEmpty {
                parts.append("Death ~\(deathYear) supported by \(sources.joined(separator: ", ")).")
            }
        }

        // Location evidence
        let districts = cluster.districts
        if !districts.isEmpty {
            parts.append("All records in \(districts.sorted().joined(separator: ", ")).")
        }

        // Convergence
        let factRecords = cluster.records.filter { $0.verdict == .fact }.map(\.record)
        let convergence = ConvergenceEngine.score(records: factRecords, sourceInfoMap: sourceInfoMap)
        parts.append("Evidence convergence: \(convergence.rawValue).")

        if parts.isEmpty {
            return "Insufficient evidence for a reasoned conclusion about \(name)."
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Strategy Suggestion

    /// Suggest which source to search next based on current results.
    /// Returns nil if LLM unavailable or no suggestion.
    static func suggestNextSearch(
        subject: ResearchSubject,
        currentResults: ResearchResult,
        availableSources: [String]
    ) async -> StrategySuggestion? {
        let llm = LocalInferenceService.shared
        guard await llm.isAvailable else { return nil }

        let prompt = buildStrategyPrompt(subject: subject, results: currentResults, sources: availableSources)
        guard let raw = await llm.reason(
            prompt: prompt,
            systemPrompt: Prompts.strategySystem,
            maxTokens: 256
        ) else { return nil }

        // Parse JSON from reasoning output
        guard let data = raw.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sourceID = response["source_id"] as? String,
              let reason = response["reason"] as? String else { return nil }

        let recordType = (response["record_type"] as? String).flatMap { RecordType(rawValue: $0) }

        return StrategySuggestion(
            sourceID: sourceID,
            recordType: recordType,
            reason: reason
        )
    }

    // MARK: - Cluster Enhancement

    /// Ask the LLM to evaluate whether records in a cluster belong together.
    /// Returns a confidence adjustment suggestion (not a final decision).
    static func evaluateCluster(
        _ cluster: LifeCluster,
        subject: ResearchSubject
    ) async -> ClusterEvaluation? {
        let llm = LocalInferenceService.shared
        guard await llm.isAvailable else { return nil }

        let prompt = buildClusterEvalPrompt(cluster: cluster, subject: subject)
        guard let raw = await llm.reason(
            prompt: prompt,
            systemPrompt: Prompts.clusterEvalSystem,
            maxTokens: 512
        ) else { return nil }

        guard let data = raw.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let assessment = response["assessment"] as? String ?? "unknown"
        let reasoning = response["reasoning"] as? String ?? ""
        // RESEARCH_CONFIDENCE_SPEC §8 — AI-suggested confidence parsing is
        // currently out of scope (mapping LLM tier strings into the three-
        // axis model needs its own design pass). Drop the parse rather than
        // resurrect the old ClusterConfidence enum just to hold a string.
        _ = response["confidence"]

        return ClusterEvaluation(
            assessment: assessment,
            reasoning: reasoning
        )
    }

    // MARK: - Disambiguation

    /// Ask the LLM: is this a wrong person or wrong tree?
    static func disambiguate(
        cluster: LifeCluster,
        subject: ResearchSubject,
        conflict: String
    ) async -> DisambiguationResult? {
        let llm = LocalInferenceService.shared
        guard await llm.isAvailable else { return nil }

        let prompt = buildDisambiguationPrompt(cluster: cluster, subject: subject, conflict: conflict)
        guard let raw = await llm.reason(
            prompt: prompt,
            systemPrompt: Prompts.disambiguationSystem,
            maxTokens: 512
        ) else { return nil }

        guard let data = raw.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let verdict = response["verdict"] as? String ?? "uncertain"
        let reasoning = response["reasoning"] as? String ?? ""

        return DisambiguationResult(verdict: verdict, reasoning: reasoning)
    }

    // MARK: - Rich Strategy (matches Python strategist.suggest_strategy)

    /// Ask the reasoning model to analyse research progress and suggest a full strategy.
    /// Returns insights, multiple specific searches with parameters, and questions.
    /// Ported from Python strategist.py.
    static func suggestStrategy(
        subject: ResearchSubject,
        currentResults: ResearchResult,
        householdMembers: [HouseholdMember],
        searchedSources: [String],
        availableSources: [String]
    ) async -> ResearchStrategy? {
        let llm = LocalInferenceService.shared
        guard await llm.isAvailable else { return nil }

        let prompt = buildRichStrategyPrompt(
            subject: subject, results: currentResults,
            household: householdMembers, searched: searchedSources,
            available: availableSources
        )
        guard let raw = await llm.reason(
            prompt: prompt,
            systemPrompt: Prompts.richStrategySystem,
            maxTokens: 1024
        ) else { return nil }

        guard let data = raw.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let insights = response["insights"] as? [String] ?? []
        let questions = response["questions"] as? [String] ?? []

        var searches: [StrategySearch] = []
        if let searchList = response["searches"] as? [[String: Any]] {
            for s in searchList {
                searches.append(StrategySearch(
                    description: s["description"] as? String ?? "",
                    source: s["source"] as? String ?? "",
                    parameters: s["parameters"] as? [String: String] ?? [:],
                    reasoning: s["reasoning"] as? String ?? ""
                ))
            }
        }

        return ResearchStrategy(insights: insights, searches: searches, questions: questions)
    }

    // MARK: - Lead Clustering (matches Python investigator.cluster_leads)

    /// Group related leads by family key — leads about the same family
    /// are investigated together so the model sees the whole picture.
    static func clusterLeads(_ leads: [Lead]) -> [LeadCluster] {
        // Group by family key: extract from relationship or surname
        var groups: [String: [Lead]] = [:]
        for lead in leads where lead.status == .new || lead.status == .investigated {
            let key = extractFamilyKey(lead)
            groups[key, default: []].append(lead)
        }

        return groups.map { key, members in
            LeadCluster(
                familyKey: key,
                leads: members.sorted { ($0.birthYear ?? 0) < ($1.birthYear ?? 0) },
                totalPriority: members.count
            )
        }.sorted { $0.totalPriority > $1.totalPriority }
    }

    /// Extract family grouping key from a lead. Ported from Python _extract_family_key.
    private static func extractFamilyKey(_ lead: Lead) -> String {
        // Try to extract "child of X Y" or "spouse of X Y" from evidence
        let pattern = #"(?:child|sibling|spouse|parent) of (\w+ \w+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lead.evidence, range: NSRange(lead.evidence.startIndex..., in: lead.evidence)),
           let range = Range(match.range(at: 1), in: lead.evidence) {
            return String(lead.evidence[range])
        }
        // Fall back to surname
        return lead.surname?.uppercased() ?? "UNKNOWN"
    }

    // MARK: - LLM-Guided Investigation Loop (matches Python investigator.investigate_cluster)

    /// Investigate a cluster of related leads using reasoning model guidance.
    /// Multi-iteration loop where the model suggests searches, the pipeline
    /// executes them, and results feed back for the next iteration.
    static func investigateLeadCluster(
        cluster: LeadCluster,
        snapshot: FamilyGraphSnapshot,
        sources: [any RecordSource],
        sourceInfoMap: [String: SourceInfo],
        maxIterations: Int = 3
    ) async -> LeadInvestigationResult {
        let llm = LocalInferenceService.shared
        var reasoningLog: [String] = []
        var searchesExecuted: [StrategySearch] = []
        var factsFound = 0

        for iteration in 1...maxIterations {
            // Build context showing all leads in the cluster
            let context = buildClusterInvestigationPrompt(cluster: cluster, snapshot: snapshot, iteration: iteration)

            // Ask model for search suggestions
            guard await llm.isAvailable,
                  let raw = await llm.reason(
                      prompt: context,
                      systemPrompt: Prompts.clusterInvestigationSystem,
                      maxTokens: 512
                  ) else {
                reasoningLog.append("Iteration \(iteration): model unavailable, stopping")
                break
            }

            guard let data = raw.data(using: .utf8),
                  let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                reasoningLog.append("Iteration \(iteration): could not parse response")
                break
            }

            let reasoning = response["reasoning"] as? String ?? ""
            reasoningLog.append("Iteration \(iteration): \(reasoning)")

            // Check if resolved
            if response["resolved"] as? Bool == true {
                break
            }

            // Parse suggested searches
            guard let suggestions = response["searches"] as? [[String: Any]], !suggestions.isEmpty else {
                break
            }

            for s in suggestions {
                let search = StrategySearch(
                    description: s["description"] as? String ?? "",
                    source: s["source"] as? String ?? "",
                    parameters: s["parameters"] as? [String: String] ?? [:],
                    reasoning: s["reasoning"] as? String ?? ""
                )
                searchesExecuted.append(search)

                // Execute via the dispatcher
                if let sourceID = search.source.nilIfEmpty,
                   let surname = search.parameters["surname"]?.nilIfEmpty {
                    let query = RecordQuery(
                        surname: surname,
                        givenName: search.parameters["given"],
                        recordType: RecordType(rawValue: search.parameters["event"] ?? "birth") ?? .birth,
                        yearFrom: search.parameters["year_start"].flatMap(Int.init),
                        yearTo: search.parameters["year_end"].flatMap(Int.init),
                        gender: nil, region: .englandAndWales,
                        sourceParams: .generic
                    )
                    for source in sources where source.sourceID == sourceID {
                        let result = await source.search(query)
                        factsFound += result.records.count
                    }
                }
            }
        }

        return LeadInvestigationResult(
            familyKey: cluster.familyKey,
            leadCount: cluster.leads.count,
            iterations: min(maxIterations, reasoningLog.count),
            reasoningLog: reasoningLog,
            searchesExecuted: searchesExecuted,
            factsFound: factsFound
        )
    }

    // MARK: - Prompt Building

    private static func buildEvidenceSummaryPrompt(cluster: LifeCluster, subject: ResearchSubject) -> String {
        var lines = ["Summarise the evidence for \(subject.displayName):"]
        for scored in cluster.records {
            let citation = CitationRenderer.cite(scored.record)
            lines.append("- [\(scored.verdict.rawValue)] \(citation.short)")
        }
        lines.append("\nWrite a 2-3 sentence evidence summary explaining why this cluster represents one person.")
        return lines.joined(separator: "\n")
    }

    private static func buildRichStrategyPrompt(
        subject: ResearchSubject, results: ResearchResult,
        household: [HouseholdMember], searched: [String], available: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("PERSON: \(subject.displayName)")
        var known: [String] = []
        if let by = subject.birthYearFrom { known.append("born ~\(by)") }
        if let dy = subject.deathYearFrom { known.append("died ~\(dy)") }
        if let g = subject.gender { known.append("gender: \(g.rawValue)") }
        lines.append("KNOWN: \(known.isEmpty ? "minimal information" : known.joined(separator: ", "))")

        if !results.confirmedFacts.isEmpty {
            lines.append("\nCONFIRMED FACTS (\(results.confirmedFacts.count)):")
            for f in results.confirmedFacts {
                lines.append("  - \(f.summary) [\(f.record.sourceID)]")
            }
        }

        if !household.isEmpty {
            lines.append("\nHOUSEHOLD MEMBERS FROM CENSUS (\(household.count)):")
            for m in household {
                lines.append("  - \(m.name), \(m.relationship), age \(m.age.map(String.init) ?? "?"), born \(m.birthPlace ?? "?")")
            }
        }

        lines.append("\nALREADY SEARCHED: \(searched.joined(separator: ", "))")
        lines.append("AVAILABLE SOURCES: \(available.joined(separator: ", "))")

        lines.append("""

        Review this research progress. Return JSON:
        {
            "insights": ["non-obvious observations showing step-by-step reasoning"],
            "searches": [
                {
                    "description": "what to search for",
                    "source": "freebmd|freecen|cwgc|findagrave|freereg|probate|wirksworth",
                    "parameters": {"surname": "...", "given": "...", "year_start": 0, "year_end": 0, "event": "births|deaths|marriages", "district": "..."},
                    "reasoning": "chain of logic for why this search matters"
                }
            ],
            "questions": ["things needing human judgement"]
        }
        """)

        return lines.joined(separator: "\n")
    }

    private static func buildClusterInvestigationPrompt(
        cluster: LeadCluster, snapshot: FamilyGraphSnapshot, iteration: Int
    ) -> String {
        var lines: [String] = []
        lines.append("INVESTIGATING FAMILY: \(cluster.familyKey)")
        lines.append("Leads to resolve: \(cluster.leads.count)")
        lines.append("Iteration: \(iteration)")
        lines.append("")
        lines.append("PEOPLE TO CONFIRM:")
        for lead in cluster.leads {
            let birth = lead.birthYear.map { "b.~\($0)" } ?? "b.?"
            lines.append("  - \(lead.name), \(lead.relationship ?? "unknown"), \(birth)")
            lines.append("    Evidence: \(lead.evidence)")
        }
        lines.append("""

        Suggest specific searches to confirm these people. Return JSON:
        {
            "reasoning": "your analysis of this family group",
            "resolved": false,
            "searches": [
                {
                    "description": "what to search",
                    "source": "freebmd|freecen|freereg|probate",
                    "parameters": {"surname": "...", "given": "...", "year_start": 0, "year_end": 0, "event": "births"},
                    "reasoning": "why"
                }
            ]
        }
        """)
        return lines.joined(separator: "\n")
    }

    private static func buildStrategyPrompt(subject: ResearchSubject, results: ResearchResult, sources: [String]) -> String {
        """
        Person: \(subject.displayName), born ~\(subject.birthYearFrom.map(String.init) ?? "?"), died ~\(subject.deathYearFrom.map(String.init) ?? "?")
        Facts found: \(results.confirmedFacts.count)
        Leads: \(results.leads.count)
        Sources already searched: \(Set(results.allScoredRecords.map(\.record.sourceID)).sorted().joined(separator: ", "))
        Available sources not yet searched: \(sources.joined(separator: ", "))

        Which source should be searched next and for what record type? Return JSON: {"source_id": "...", "record_type": "...", "reason": "..."}
        """
    }

    private static func buildClusterEvalPrompt(cluster: LifeCluster, subject: ResearchSubject) -> String {
        var lines = ["Evaluate whether these records belong to \(subject.displayName):"]
        for scored in cluster.records {
            lines.append("- \(scored.summary) [\(scored.verdict.rawValue)]")
        }
        lines.append("\nReturn JSON: {\"assessment\": \"same_person|different_people|uncertain\", \"confidence\": \"strong|moderate|weak|ambiguous\", \"reasoning\": \"...\"}")
        return lines.joined(separator: "\n")
    }

    private static func buildDisambiguationPrompt(cluster: LifeCluster, subject: ResearchSubject, conflict: String) -> String {
        """
        Person: \(subject.displayName)
        Conflict: \(conflict)
        Records: \(cluster.records.map(\.summary).joined(separator: "; "))

        Is this conflict because of a wrong person (different individual with same name) or wrong tree (our data is incorrect)?
        Return JSON: {"verdict": "wrong_person|wrong_tree|uncertain", "reasoning": "..."}
        """
    }
}

// MARK: - Result Types

nonisolated struct StrategySuggestion: Sendable {
    let sourceID: String
    let recordType: RecordType?
    let reason: String
}

/// Rich strategy result — matches Python strategist.suggest_strategy() output.
nonisolated struct ResearchStrategy: Sendable {
    let insights: [String]           // Non-obvious observations with reasoning
    let searches: [StrategySearch]   // Specific searches with parameters
    let questions: [String]          // Things needing human judgement
}

nonisolated struct StrategySearch: Sendable {
    let description: String
    let source: String               // freebmd, freecen, etc.
    let parameters: [String: String] // surname, given, year_start, year_end, event, district
    let reasoning: String
}

/// A group of related leads to investigate together.
nonisolated struct LeadCluster: Sendable {
    let familyKey: String
    let leads: [Lead]
    let totalPriority: Int
}

/// Result of investigating a lead cluster.
nonisolated struct LeadInvestigationResult: Sendable {
    let familyKey: String
    let leadCount: Int
    let iterations: Int
    let reasoningLog: [String]
    let searchesExecuted: [StrategySearch]
    let factsFound: Int
}

nonisolated private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

nonisolated struct ClusterEvaluation: Sendable {
    let assessment: String      // same_person, different_people, uncertain
    let reasoning: String
}

nonisolated struct DisambiguationResult: Sendable {
    let verdict: String         // wrong_person, wrong_tree, uncertain
    let reasoning: String
}

// MARK: - Prompts

/// System prompts for LLM interactions.
/// Bundled as constants — can be moved to .txt resources later.
nonisolated enum Prompts {
    static let evidenceSummarySystem = """
    You are a genealogical evidence analyst applying the Genealogical Proof Standard. \
    Reason step by step through the evidence. For each source, state what it establishes. \
    Then reason about how sources corroborate or contradict each other. \
    Conclude with a 2-3 sentence evidence summary. \
    Be precise about dates, places, and relationships. Never invent facts not in the records.
    """

    static let strategySystem = """
    You are a genealogical research strategist. Reason step by step about what has been found, \
    what gaps remain, and which source is most likely to fill them. Consider: \
    - Pre-1837 births won't be in civil registration (use parish records) \
    - Census years: 1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911 \
    - Military-age males (born 1880-1927) may appear in CWGC \
    - Marriage records reveal maiden names and spouse identities \
    Respond with JSON: {"source_id": "...", "record_type": "...", "reason": "..."}
    """

    static let clusterEvalSystem = """
    You are a genealogical record analyst. Reason step by step about whether these records \
    belong to the same person. Consider: \
    - Name spelling variations were common (CAULDWELL/CALDWELL, ELIZABETH/ELIZA) \
    - Census ages were self-reported and often rounded (especially 1841) \
    - People moved between registration districts but stayed in the same county \
    - Household continuity (same spouse/children across censuses) is strong evidence \
    Respond with JSON: {"assessment": "same_person|different_people|uncertain", \
    "confidence": "strong|moderate|weak|ambiguous", "reasoning": "..."}
    """

    /// Rich strategy — matches Python strategist.py system prompt.
    static let richStrategySystem = """
    You are an experienced English genealogist reviewing a family's research progress. \
    Your job is to spot non-obvious connections and suggest specific searches. \
    Think step by step. Chain through the logic of what relationships tell you: \
    - Census "Mother-in-Law" means mother of the spouse — their surname reveals the maiden name \
    - A missing person from later censuses might have died, moved, enlisted, or married \
    - A gap between children might indicate infant deaths worth searching for \
    - Witnesses on marriage certificates are often family members \
    - Parish registers before 1837 are the only source for births, marriages, and deaths \
    Be specific. Don't say "search for birth records." Say "search FreeBMD births for \
    Elizabeth BARKER, Belper district, 1858-1864." Give names, sources, date ranges, districts. \
    Use narrow date ranges (5-10 years max). Only suggest searches not already done. \
    Respond with valid JSON only.
    """

    /// Cluster investigation — matches Python investigator.py system prompt.
    static let clusterInvestigationSystem = """
    You are a genealogist investigating a family group. You see multiple people who need \
    to be confirmed through record searches. Consider them TOGETHER — evidence for one \
    person often reveals information about others in the same household. \
    Suggest specific searches that would confirm or reject these people. \
    Focus on: census records showing the family together, birth/baptism records naming parents, \
    marriage records revealing spouse surnames. \
    Respond with valid JSON only.
    """

    static let disambiguationSystem = """
    You are a genealogical disambiguation expert. Reason step by step about whether a conflict \
    means the records are about a different person (wrong person) or the tree data is incorrect \
    (wrong tree). Consider: \
    - Common names in the same area often belong to different people (Thomas Smith in Belper) \
    - Census age discrepancies of ±2 years are normal, ±5+ suggests different person \
    - Same registration district + same quarter + different page = different person \
    Respond with JSON: {"verdict": "wrong_person|wrong_tree|uncertain", "reasoning": "..."}
    """
}
