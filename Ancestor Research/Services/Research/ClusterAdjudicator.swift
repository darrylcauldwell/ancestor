import Foundation

/// Phase 4 of the lead-discovery pivot (`AncestorApp/LEAD_DISCOVERY_SPEC.md`):
/// bounded AI adjudication of borderline emergent clusters, plus deterministic
/// cluster narration.
///
/// The sandwich holds on both halves:
/// - **Narration is deterministic** — a one-line summary formatted from the
///   leads' own fields. No model, no hallucination risk (PROSE_CORPUS
///   zero-hallucination doctrine), always available.
/// - **Adjudication is advisory only** — the local MLX model is asked whether a
///   low-confidence (yearless) cluster's records plausibly describe one person,
///   and its verdict renders as a badge with reasoning. It never merges, splits,
///   promotes, or demotes a cluster; the deterministic engine's structure is
///   untouched. No model loaded → nil → no badge, panel fully functional.
nonisolated enum ClusterAdjudicator {

    // MARK: - Verdict

    enum Assessment: String, Sendable {
        case plausiblyOnePerson = "one"
        case likelyMultiplePeople = "multiple"
    }

    struct Verdict: Sendable, Equatable {
        let assessment: Assessment
        let reasoning: String
    }

    // MARK: - Deterministic narration

    /// One-line cluster summary — pure formatting of lead facts, most-informative
    /// first: name, birth/death span, event kinds, distinct places. This IS the
    /// Phase 4 narration; it is deliberately template-built, not model-built.
    static func summary(_ cluster: LeadDiscoveryEngine.EmergentCluster) -> String {
        var parts: [String] = []

        if let by = cluster.birthYear {
            let deaths = cluster.leads.compactMap { $0.deathYear }
            if let died = deaths.min() {
                parts.append("b~\(by)–d~\(died)")
            } else {
                parts.append("b~\(by)")
            }
        }

        let kinds = eventKinds(cluster)
        if !kinds.isEmpty {
            parts.append(kinds.joined(separator: " + "))
        }

        let places = distinctPlaces(cluster)
        if !places.isEmpty {
            let shown = places.prefix(3).joined(separator: ", ")
            parts.append(places.count > 3 ? "\(shown) +\(places.count - 3) more" : shown)
        }

        if cluster.coherence.originProfileCount > 1 {
            parts.append("surfaced by \(cluster.coherence.originProfileCount) relatives")
        }

        return parts.joined(separator: " · ")
    }

    /// Distinct event kinds across the cluster's leads, stable order.
    static func eventKinds(_ cluster: LeadDiscoveryEngine.EmergentCluster) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for lead in cluster.leads {
            let hay = (lead.evidence + " " + (lead.relationship ?? "")).lowercased()
            let kind: String
            if hay.contains("marriage") || hay.contains("spouse") { kind = "marriage" }
            else if hay.contains("death") || hay.contains("probate") || hay.contains("burial") { kind = "death" }
            else if hay.contains("census") { kind = "census" }
            else if hay.contains("birth") || hay.contains("christen") || hay.contains("baptis") { kind = "birth" }
            else { continue }
            if seen.insert(kind).inserted { ordered.append(kind) }
        }
        return ordered
    }

    /// Distinct non-empty places across the cluster's leads, stable order.
    static func distinctPlaces(_ cluster: LeadDiscoveryEngine.EmergentCluster) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for lead in cluster.leads {
            guard let p = lead.place?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { continue }
            if seen.insert(p.uppercased()).inserted { ordered.append(p) }
        }
        return ordered
    }

    // MARK: - Prompt (testable in isolation)

    /// Cap the leads listed in the prompt so a 50-member Thompson blob can't
    /// blow the token budget; the model is told how many were omitted.
    static let promptLeadCap = 12

    static func prompt(for cluster: LeadDiscoveryEngine.EmergentCluster) -> String {
        var lines: [String] = []
        lines.append("These \(cluster.leads.count) genealogical records were grouped because they share the surname \(cluster.surname) and their details do not contradict each other. Judge whether they plausibly describe ONE person or MULTIPLE different people.")
        lines.append("")
        for (i, lead) in cluster.leads.prefix(promptLeadCap).enumerated() {
            var bits: [String] = ["\(i + 1). \(lead.name)"]
            if let by = lead.birthYear { bits.append("born ~\(by)") }
            if let dy = lead.deathYear { bits.append("died \(dy)") }
            if let age = lead.ageAtDeath { bits.append("aged \(age)") }
            if let place = lead.place, !place.isEmpty { bits.append("at \(place)") }
            if !lead.evidence.isEmpty { bits.append("— \(lead.evidence)") }
            lines.append(bits.joined(separator: ", "))
        }
        if cluster.leads.count > promptLeadCap {
            lines.append("…and \(cluster.leads.count - promptLeadCap) more similar records.")
        }
        lines.append("")
        lines.append(#"Consider: incompatible life events, geographic spread, occupation/rank differences, and whether the sheer number of same-name records suggests namesakes. Reply with ONLY JSON: {"verdict": "one" or "multiple", "reason": "<one sentence>"}"#)
        return lines.joined(separator: "\n")
    }

    static let systemPrompt = "You are a careful genealogist. You judge whether grouped records describe one person or several namesakes. You are skeptical: common names in different places usually mean different people. Reply with only the requested JSON."

    // MARK: - Parse (testable in isolation)

    static func parseVerdict(fromRaw raw: String) -> Verdict? {
        guard let dict = LocalInferenceService.extractJSONDictionary(from: raw),
              let verdictString = dict["verdict"] as? String,
              let assessment = Assessment(rawValue: verdictString.lowercased()),
              let reason = dict["reason"] as? String,
              !reason.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return Verdict(assessment: assessment, reasoning: reason)
    }

    // MARK: - Adjudicate (model call — house fallback pattern)

    /// Ask the local model for an advisory verdict. nil when no model is loaded
    /// or the reply is unusable — the caller shows no badge and nothing else
    /// changes (deterministic fallback = the panel as it already is).
    static func adjudicate(_ cluster: LeadDiscoveryEngine.EmergentCluster) async -> Verdict? {
        let llm = LocalInferenceService.shared
        guard await llm.isAvailable else { return nil }
        guard let raw = await llm.reason(
            prompt: prompt(for: cluster),
            systemPrompt: systemPrompt,
            maxTokens: 256
        ) else { return nil }
        return parseVerdict(fromRaw: raw)
    }
}
