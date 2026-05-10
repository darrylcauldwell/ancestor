import Foundation

/// Assembles a biographical narrative from confirmed facts and research results.
/// Uses deterministic templates with optional reasoning model enhancement.
nonisolated struct NarrativeAssembler {

    /// Assemble a biography from research results for a profile.
    static func assemble(
        profile: Profile,
        result: ResearchResult,
        sourceInfoMap: [String: SourceInfo]
    ) async -> Biography {
        var events: [NarrativeLifeEvent] = []

        // Extract events from clusters
        for cluster in result.clusters where cluster.confidence >= .moderate {
            for scored in cluster.records where scored.verdict == .fact {
                if let event = extractEvent(from: scored) {
                    events.append(event)
                }
            }
        }

        // Sort chronologically
        events.sort { ($0.year ?? 0) < ($1.year ?? 0) }

        // Build narrative text
        let narrative = await buildNarrative(
            profile: profile, events: events, sourceInfoMap: sourceInfoMap
        )

        // Build timeline
        let timeline = events.map { event in
            TimelineEntry(
                year: event.year,
                label: event.type.rawValue.capitalized,
                description: event.description,
                sourceID: event.sourceID,
                citation: event.citation
            )
        }

        return Biography(
            profileID: profile.id,
            narrative: narrative,
            timeline: timeline,
            events: events,
            generatedAt: Date()
        )
    }

    /// Build narrative text — uses reasoning model if available, else deterministic template.
    private static func buildNarrative(
        profile: Profile,
        events: [NarrativeLifeEvent],
        sourceInfoMap: [String: SourceInfo]
    ) async -> String {
        // Try reasoning model
        let llm = LocalInferenceService.shared
        if await llm.isAvailable {
            let prompt = buildNarrativePrompt(profile: profile, events: events)
            if let response = await llm.reason(
                prompt: prompt,
                systemPrompt: "You are a genealogical biographer. Write a concise, factual biography from the provided life events. Use past tense. Cite sources parenthetically. Never invent facts.",
                maxTokens: 1024
            ) {
                return response
            }
        }

        // Deterministic template fallback
        return templateNarrative(profile: profile, events: events)
    }

    private static func buildNarrativePrompt(profile: Profile, events: [NarrativeLifeEvent]) -> String {
        var lines = ["Write a biography for \(profile.displayName) from these events:"]
        for event in events {
            lines.append("- \(event.type.rawValue): \(event.description) [\(event.sourceID)]")
        }
        lines.append("\nWrite 3-5 sentences. Cite sources in parentheses.")
        return lines.joined(separator: "\n")
    }

    /// Deterministic template narrative — always available.
    static func templateNarrative(profile: Profile, events: [NarrativeLifeEvent]) -> String {
        let name = profile.displayName
        var parts: [String] = []

        let births = events.filter { $0.type == .birth }
        let deaths = events.filter { $0.type == .death }
        let marriages = events.filter { $0.type == .marriage }
        let census = events.filter { $0.type == .census }

        if let birth = births.first {
            parts.append("\(name) was born\(birth.year.map { " in \($0)" } ?? "")\(birth.location.map { " in \($0)" } ?? "").")
        }

        for marriage in marriages {
            parts.append("\(profile.firstName ?? name) married\(marriage.description.isEmpty ? "" : " \(marriage.description)")\(marriage.year.map { " in \($0)" } ?? "").")
        }

        if !census.isEmpty {
            let years = census.compactMap(\.year).sorted()
            parts.append("\(profile.firstName ?? name) appears in the \(years.map(String.init).joined(separator: ", ")) census\(years.count == 1 ? "" : "es").")
        }

        if let death = deaths.first {
            parts.append("\(profile.firstName ?? name) died\(death.year.map { " in \($0)" } ?? "")\(death.location.map { " in \($0)" } ?? "").")
        }

        return parts.isEmpty ? "No biographical information available for \(name)." : parts.joined(separator: " ")
    }

    // MARK: - Event Extraction

    private static func extractEvent(from scored: ScoredRecord) -> NarrativeLifeEvent? {
        let citation = CitationRenderer.cite(scored.record)
        switch scored.record {
        case .birth(let r):
            return NarrativeLifeEvent(type: .birth, year: r.birthYear, location: r.district ?? r.birthPlace,
                           description: citation.short, sourceID: scored.record.sourceID, citation: citation)
        case .death(let r):
            return NarrativeLifeEvent(type: .death, year: r.deathYear, location: r.district ?? r.deathPlace,
                           description: citation.short, sourceID: scored.record.sourceID, citation: citation)
        case .marriage(let r):
            return NarrativeLifeEvent(type: .marriage, year: r.marriageYear, location: r.district,
                           description: r.spouseName ?? citation.short, sourceID: scored.record.sourceID, citation: citation)
        case .census(let r):
            return NarrativeLifeEvent(type: .census, year: r.censusYear, location: r.parish ?? r.district,
                           description: "age \(r.age.map(String.init) ?? "?"), \(r.occupation ?? "")", sourceID: scored.record.sourceID, citation: citation)
        case .military(let r):
            return NarrativeLifeEvent(type: .military, year: r.deathYear, location: r.cemetery,
                           description: "\(r.rank ?? "") \(r.regiment ?? "")", sourceID: scored.record.sourceID, citation: citation)
        case .burial(let r):
            return NarrativeLifeEvent(type: .burial, year: r.deathYear, location: r.cemetery,
                           description: citation.short, sourceID: scored.record.sourceID, citation: citation)
        case .probate(let r):
            return NarrativeLifeEvent(type: .probate, year: r.deathYear, location: r.address,
                           description: "\(r.grantType ?? "probate") \(r.probateDate ?? "")", sourceID: scored.record.sourceID, citation: citation)
        default:
            return nil
        }
    }
}

// MARK: - Types

nonisolated struct Biography: Sendable {
    let profileID: String
    let narrative: String
    let timeline: [TimelineEntry]
    let events: [NarrativeLifeEvent]
    let generatedAt: Date
}

nonisolated struct TimelineEntry: Identifiable, Sendable {
    let id = UUID()
    let year: Int?
    let label: String
    let description: String
    let sourceID: String
    let citation: RenderedCitation
}

nonisolated struct NarrativeLifeEvent: Sendable {
    let type: NarrativeLifeEventType
    let year: Int?
    let location: String?
    let description: String
    let sourceID: String
    let citation: RenderedCitation
}

nonisolated enum NarrativeLifeEventType: String, Sendable {
    case birth, death, marriage, census, military, burial, probate, baptism
}
