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
        let suggestedConfidence = (response["confidence"] as? String).flatMap { ClusterConfidence(rawValue: $0) }

        return ClusterEvaluation(
            assessment: assessment,
            reasoning: reasoning,
            suggestedConfidence: suggestedConfidence
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

nonisolated struct ClusterEvaluation: Sendable {
    let assessment: String      // same_person, different_people, uncertain
    let reasoning: String
    let suggestedConfidence: ClusterConfidence?
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
