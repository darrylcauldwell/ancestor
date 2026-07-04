import Foundation
import os

/// Reasoning model-enhanced research interpreter with three capabilities:
/// 1. Cluster enhancement — reason about whether records belong together
/// 2. Disambiguation — "wrong person vs wrong tree" chain-of-thought
/// 3. Strategy suggestion — reason about which source to search next
///
/// Uses the local reasoning model selected in Settings (`ReasoningModel`).
/// All outputs are suggestions — the deterministic engine has final say.
/// When the model and deterministic engine disagree, deterministic wins.
nonisolated struct ResearchInterpreter {

    private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "Interpreter")

    // MARK: - Evidence Summary (GPS Criterion 5)

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

        // Parse JSON from reasoning output — lenient extraction so a
        // code-fenced or preambled response isn't silently discarded.
        guard let response = LocalInferenceService.extractJSONDictionary(from: raw),
              let sourceID = response["source_id"] as? String,
              let reason = response["reason"] as? String else { return nil }

        let recordType = (response["record_type"] as? String).flatMap { RecordType(rawValue: $0) }

        return StrategySuggestion(
            sourceID: sourceID,
            recordType: recordType,
            reason: reason
        )
    }

    // MARK: - Level 2 Query Strategist (Slice 13b)

    /// Ask the local reasoning model to pick the next focused query
    /// based on accumulated iteration state.
    ///
    /// Mirrors the Python `agent/strategist.py` approach: instead of
    /// the dispatcher's broad fan-out, the strategist looks at what
    /// the iteration loop has already learned (subject refinement,
    /// confirmed facts, hypothesis state, search history) and proposes
    /// ONE specific next query — surname + given + year window +
    /// district + source.
    ///
    /// **Determinism contract.** The MLX model only chooses what
    /// question to ask. The dispatcher runs the query deterministically;
    /// the scorer classifies results deterministically; the verdict
    /// emitter, convergence engine, and §14.3 auto-approval gate all
    /// remain rule-driven. AI proposes; rules decide.
    ///
    /// Returns nil when:
    ///   • the local model isn't loaded (caller falls back to normal
    ///     iteration-loop fan-out),
    ///   • the model's output didn't parse as a valid FocusedQuery
    ///     (treat as "no suggestion this round"),
    ///   • the strategist concluded nothing further is worth asking
    ///     (e.g. it explicitly returned `"give_up": true`).
    static func suggestNextFocusedQuery(
        subject: ResearchSubject,
        results: ResearchResult,
        household: [HouseholdMember],
        searched: [String],
        availableSources: [String]
    ) async -> FocusedQuery? {
        logger.notice("Level-2: attempting focused-query suggestion for \(subject.displayName)")
        let llm = LocalInferenceService.shared
        guard await llm.isAvailable else {
            logger.notice("Level-2: skipped — MLX model not available")
            return nil
        }

        let prompt = buildFocusedQueryPrompt(
            subject: subject, results: results,
            household: household, searched: searched,
            available: availableSources
        )
        guard let raw = await llm.reason(
            prompt: prompt,
            systemPrompt: Prompts.focusedQuerySystem,
            maxTokens: 384
        ) else {
            logger.notice("Level-2: skipped — model returned no text")
            return nil
        }
        logger.notice("Level-2 model output (\(raw.count) chars): \(raw)")

        return parseFocusedQuery(from: raw, subject: subject)
    }

    /// Parse the model's JSON output into a `FocusedQuery`. Defensive
    /// — any missing required field returns nil rather than producing
    /// a malformed query. The dispatcher's tolerance for empty fields
    /// matters here: surname is required, given+district+year window
    /// are all optional.
    private static func parseFocusedQuery(from raw: String, subject: ResearchSubject) -> FocusedQuery? {
        guard let obj = LocalInferenceService.extractJSONDictionary(from: raw)
        else {
            logger.notice("Level-2: parse failed — no JSON object found in output")
            return nil
        }
        // Explicit "give up" signal — model is telling us further
        // querying won't help.
        if obj["give_up"] as? Bool == true {
            let rationale = (obj["rationale"] as? String) ?? "(no rationale)"
            logger.notice("Level-2: model gave up — \(rationale)")
            return nil
        }

        guard let sourceID = (obj["source"] as? String)?.lowercased(),
              !sourceID.isEmpty,
              let recordTypeRaw = obj["record_type"] as? String,
              let recordType = RecordType(rawValue: recordTypeRaw.lowercased()),
              let surname = obj["surname"] as? String,
              !surname.trimmingCharacters(in: .whitespaces).isEmpty,
              let rationale = obj["rationale"] as? String
        else {
            logger.notice("Level-2: parse failed — missing required field(s) in \(obj.keys.sorted())")
            return nil
        }

        let given = (obj["given"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let yearFrom = obj["year_from"] as? Int
        let yearTo = obj["year_to"] as? Int
        let district = (obj["district"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }

        // Slice 13d — deterministic guard against the model picking a year
        // window that's impossible for this subject (observed: Qwen 2.5 14B
        // proposed a 1871 census for a person born 1883). Belt-and-braces:
        // we also constrain the prompt, but the parser is the last line of
        // defence. Uses the precise birth/death year when available so the
        // guard doesn't slack on subjects whose `birthYearFrom` has been
        // widened by the dispatcher. A 2-year grace lets census-just-before-birth
        // or probate-just-after-death through.
        if let from = yearFrom {
            let preciseBirth = preciseBirthYear(for: subject)
            let preciseDeath = preciseDeathYear(for: subject)
            let earliest = (preciseBirth ?? subject.birthYearFrom ?? 1800) - 2
            let latest = (preciseDeath
                          ?? subject.deathYearTo
                          ?? subject.deathYearFrom
                          ?? 2100) + 5
            if from < earliest || from > latest {
                logger.notice("Level-2: parse rejected — year_from \(from) outside subject lifespan ~\(preciseBirth ?? subject.birthYearFrom ?? 0)-\(preciseDeath ?? subject.deathYearFrom ?? 0)")
                return nil
            }
        }

        return FocusedQuery(
            sourceID: sourceID,
            recordType: recordType,
            surname: surname.trimmingCharacters(in: .whitespaces),
            givenName: given,
            yearFrom: yearFrom,
            yearTo: yearTo,
            district: district,
            rationale: rationale
        )
    }

    // MARK: - Candidate Comparison (cluster-review disambiguation prose)

    /// Generate a side-by-side disambiguation paragraph for two or more
    /// candidate clusters discovered for the same subject. Designed for the
    /// cluster-review UI's "Compare candidates" action. Returns nil when
    /// the model isn't loaded — the caller surfaces a hint to load it in
    /// Settings rather than silently failing.
    ///
    /// The prose lives strictly above the firewall: it explains the records
    /// in plain English, it never asserts new facts. The deterministic
    /// engine's scoring / clustering / verdicts are still the source of truth.
    static func compareCandidates(
        clusters: [LifeCluster],
        subject: ResearchSubject
    ) async -> String? {
        guard clusters.count >= 2 else { return nil }
        let llm = LocalInferenceService.shared
        guard await llm.isAvailable else { return nil }

        let prompt = buildCompareCandidatesPrompt(clusters: clusters, subject: subject)
        return await llm.reason(
            prompt: prompt,
            systemPrompt: Prompts.candidateComparisonSystem,
            maxTokens: 1024
        )
    }

    nonisolated private static func buildCompareCandidatesPrompt(
        clusters: [LifeCluster],
        subject: ResearchSubject
    ) -> String {
        var parts: [String] = []
        parts.append("Subject: \(subject.displayName)")
        if let birthFrom = subject.birthYearFrom {
            if let birthTo = subject.birthYearTo, birthTo != birthFrom {
                parts.append("Known birth-year range: \(birthFrom)–\(birthTo)")
            } else {
                parts.append("Known birth year: \(birthFrom)")
            }
        }
        if let surname = subject.surname { parts.append("Known surname: \(surname)") }
        parts.append("Home Chapman code: \(subject.homeChapmanCode)")

        parts.append("")
        parts.append("The deterministic research engine clustered the returned records into \(clusters.count) candidate lives. Each may or may not be the subject — your job is to compare them.")

        for (idx, cluster) in clusters.enumerated() {
            parts.append("")
            parts.append("=== Candidate \(idx + 1): \(cluster.displayName) ===")
            parts.append("Match quality (deterministic): \(cluster.matchQuality?.rawValue ?? "unknown")")
            if let by = cluster.impliedBirthYear { parts.append("Implied birth year: \(by)") }
            if let dy = cluster.impliedDeathYear { parts.append("Implied death year: \(dy)") }
            let districts = cluster.districts.sorted().joined(separator: ", ")
            if !districts.isEmpty { parts.append("Districts seen: \(districts)") }
            parts.append("Records (\(cluster.records.count)):")
            for rec in cluster.records {
                let verdict = rec.verdict.rawValue
                parts.append("  • [\(verdict)] \(rec.summary)")
            }
        }

        parts.append("")
        parts.append("""
For each candidate above, write 2–3 sentences plainly stating what the records actually say about that life and whether it fits the subject. Highlight what distinguishes the candidates from each other — specific dates, places, parents, occupations. Finish with a one-paragraph summary naming which candidate (if any) best matches the subject and why.

Be concrete, terse, and honest about uncertainty. Never invent facts that aren't in the records.
""")

        return parts.joined(separator: "\n")
    }

    // MARK: - Prompt Building

    /// UK census years (1931 records destroyed by fire; 1939 Register is
    /// not a census but is treated as one for query purposes here).
    private static let ukCensusYears: [Int] = [
        1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911, 1921, 1939
    ]

    /// Census years that fall within a subject's plausible lifespan.
    /// Used both in the prompt (to constrain the model) and in
    /// `parseFocusedQuery` (to reject impossible picks). Returns the
    /// full list if the subject's dates are unknown.
    private static func plausibleCensusYears(for subject: ResearchSubject) -> [Int] {
        let earliest = preciseBirthYear(for: subject) ?? subject.birthYearFrom ?? 1800
        // Allow a 1-year grace at the upper end so a census just after
        // a known death year still surfaces (the subject would be
        // missing from it, which is itself useful evidence).
        let latest = (preciseDeathYear(for: subject)
                      ?? subject.deathYearTo
                      ?? subject.deathYearFrom
                      ?? 2100) + 1
        return ukCensusYears.filter { $0 >= earliest && $0 <= latest }
    }

    /// Returns the precise birth year parsed from `birthDateOriginal`
    /// (e.g. "DEC 1883" → 1883), preferring it over `birthYearFrom`
    /// which gets widened for fan-out search. The strategist's age
    /// math has to use this, not the wide window, or it computes
    /// ages against the bottom of the range (observed: "approximately
    /// 22 years old in 1891" for a subject born 1883).
    private static func preciseBirthYear(for subject: ResearchSubject) -> Int? {
        extractYearFromOriginal(subject.birthDateOriginal)
    }

    private static func preciseDeathYear(for subject: ResearchSubject) -> Int? {
        extractYearFromOriginal(subject.deathDateOriginal)
    }

    /// Best-effort year extraction from a free-text GEDCOM date like
    /// "DEC 1883", "10 MAR 1937", "ABT 1879", "BET 1869 AND 1896".
    /// Returns the first 4-digit year found, nil otherwise. For BET-AND
    /// ranges we deliberately pick the EARLIER year — slice 13's job
    /// is to ask exploratory queries, and the earlier anchor errs
    /// toward including more candidate census years rather than fewer.
    private static func extractYearFromOriginal(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let pattern = #"\b(1[6-9]\d{2}|20\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let yearRange = Range(match.range(at: 1), in: raw) else { return nil }
        return Int(raw[yearRange])
    }

    /// Slice 13b prompt builder. Carries the BMD/census constants and
    /// the recent iteration state so the model has enough context to
    /// pick a useful next query without re-running the broad fan-out.
    private static func buildFocusedQueryPrompt(
        subject: ResearchSubject, results: ResearchResult,
        household: [HouseholdMember], searched: [String], available: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("SUBJECT: \(subject.displayName)")

        // Prefer the original GEDCOM date strings ("DEC 1883", "10 MAR 1937")
        // over the widened year window — `birthYearFrom`/`To` are used by
        // the dispatcher for fan-out search and lose precision, so they're
        // the wrong anchor for the strategist's age math.
        var known: [String] = []
        if let original = subject.birthDateOriginal {
            known.append("born \(original)")
        } else if let by = subject.birthYearFrom {
            known.append("born ~\(by)")
        }
        if let original = subject.deathDateOriginal {
            known.append("died \(original)")
        } else if let dy = subject.deathYearFrom {
            known.append("died ~\(dy)")
        }
        if let g = subject.gender { known.append("gender: \(g.rawValue)") }
        if let l = subject.deathLocation { known.append("died in: \(l)") }
        lines.append("KNOWN: \(known.isEmpty ? "minimal" : known.joined(separator: ", "))")

        // Slice 13d — give the model the deterministically computed list
        // of census years the subject could plausibly appear in. Previous
        // runs of Qwen 2.5 14B did the age arithmetic wrong (proposed
        // 1871 census for a person born 1883, and later "approximately
        // 22 years old in 1891" for the same subject), so we pre-compute
        // the valid universe AND the ages, eliminating the arithmetic step.
        // Uses the precise birth year from `birthDateOriginal` when
        // available, falling back to `birthYearFrom`.
        let anchorBirthYear = preciseBirthYear(for: subject) ?? subject.birthYearFrom
        if anchorBirthYear != nil || subject.deathYearFrom != nil {
            let candidates = plausibleCensusYears(for: subject)
            if !candidates.isEmpty {
                let ages = candidates.compactMap { year -> String? in
                    guard let by = anchorBirthYear else { return "\(year)" }
                    let age = year - by
                    return "\(year) (subject age ~\(age))"
                }
                lines.append("LIFESPAN: queries MUST be within the subject's lifespan.")
                lines.append("PLAUSIBLE CENSUS YEARS for this subject: \(ages.joined(separator: ", "))")
                lines.append("Use these exact (year, age) pairs — do not recompute the age yourself.")
            }
        }

        if !results.confirmedFacts.isEmpty {
            lines.append("\nCONFIRMED FACTS (\(results.confirmedFacts.count)):")
            for f in results.confirmedFacts.prefix(8) {
                lines.append("  - \(f.summary) [\(f.record.sourceID)]")
            }
        }

        // Hypothesis state — what we believe, what's contradicted, what's open.
        let supported = results.hypotheses.filter { $0.isDeterministicallySupported }
        let inconclusive = results.hypotheses.filter { $0.verdict == .inconclusive }
        let contradicted = results.hypotheses.filter { $0.verdict == .contradicted }
        if !supported.isEmpty {
            lines.append("\nSUPPORTED HYPOTHESES (\(supported.count)):")
            for h in supported.prefix(6) { lines.append("  - \(h.reasoning)") }
        }
        if !inconclusive.isEmpty {
            lines.append("\nINCONCLUSIVE HYPOTHESES (\(inconclusive.count)):")
            for h in inconclusive.prefix(4) { lines.append("  - \(h.reasoning)") }
        }
        if !contradicted.isEmpty {
            lines.append("\nCONTRADICTED (do not re-query the same way):")
            for h in contradicted.prefix(3) { lines.append("  - \(h.reasoning)") }
        }

        if !household.isEmpty {
            lines.append("\nHOUSEHOLD (\(household.count)):")
            for m in household.prefix(8) {
                lines.append("  - \(m.name), \(m.relationship), age \(m.age.map(String.init) ?? "?"), born \(m.birthPlace ?? "?")")
            }
        }

        lines.append("\nALREADY SEARCHED: \(searched.joined(separator: ", "))")
        lines.append("AVAILABLE SOURCES: \(available.joined(separator: ", "))")

        lines.append("""

        BMD/CENSUS CONSTANTS (apply when picking):
        - Civil registration starts 1837 (pre-1837 needs parish registers)
        - FreeBMD birth index carries mother's maiden name from Sep 1911 only
        - FreeBMD marriage index carries spouse surname from Sep 1912 only
        - Census years: 1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911
        - For a person born year Y, expect census records at Y+~7, Y+~17, etc.

        Pick ONE specific next query that builds on what's known. If the iteration
        loop already covered the obvious broad searches, find a NARROW question
        whose answer would advance the research — e.g. "census 1891 to see this
        person's household when they were ~7" or "Brooks marriages 1879-1882
        Belper to find the parents' wedding". Stay deterministic on
        constraints (Derbyshire, narrow window, exact district name).

        Return JSON ONLY:
        {
          "source": "freebmd|freecen|cwgc|findagrave|freereg|probate|wirksworth",
          "record_type": "birth|death|marriage|census|burial|probate|parish",
          "surname": "string (required)",
          "given": "string or null",
          "year_from": int or null,
          "year_to": int or null,
          "district": "string or null (e.g. Belper)",
          "rationale": "one sentence explaining why this query advances the research"
        }

        Or, if no further query would help:
        { "give_up": true, "rationale": "why" }
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

}

// MARK: - Result Types

nonisolated struct StrategySuggestion: Sendable {
    let sourceID: String
    let recordType: RecordType?
    let reason: String
}

// MARK: - Prompts

/// System prompts for LLM interactions.
/// Bundled as constants — can be moved to .txt resources later.
nonisolated enum Prompts {
    static let strategySystem = """
    You are a genealogical research strategist. Reason step by step about what has been found, \
    what gaps remain, and which source is most likely to fill them. Consider: \
    - Pre-1837 births won't be in civil registration (use parish records) \
    - Census years: 1841, 1851, 1861, 1871, 1881, 1891, 1901, 1911 \
    - Military-age males (born 1880-1927) may appear in CWGC \
    - Marriage records reveal maiden names and spouse identities \
    Respond with JSON: {"source_id": "...", "record_type": "...", "reason": "..."}
    """

    /// Slice 13b — Level-2 query strategist. The model picks ONE focused
    /// query based on iteration state. Determinism contract is encoded
    /// in the prompt: model proposes queries, deterministic engine
    /// decides truth.
    static let focusedQuerySystem = """
    You are a UK genealogy research strategist working alongside a deterministic \
    record-scoring engine. The engine has already fanned out broadly across all \
    sources for the subject this iteration. Your job: pick ONE narrow, specific \
    follow-up query that exploits something the engine has already learned \
    (a confirmed fact, a supported hypothesis, a household member's name, a \
    birth year that narrows the search window). \
    Think step by step. Be specific — name the source, the surname, the year \
    window (5-10 years), the district. Do not propose broad searches; the \
    engine already does those. Do not re-query something on the ALREADY \
    SEARCHED list. \
    \
    CRITICAL — date constraints: \
    1. The query year window MUST be inside the subject's lifespan. If the \
       user prompt lists PLAUSIBLE CENSUS YEARS, you MUST pick one of those \
       years (or skip the census option entirely) — do not invent a different \
       year, and do not pick a year before the subject was born. \
    2. Before choosing a year, compute the subject's age in that year explicitly. \
       For a person born 1883, the 1871 census is impossible (negative age). \
       The 1891 census shows them aged ~8; the 1901 census ~18. \
    3. If you cannot pick a query that satisfies these constraints, return \
       {"give_up": true, "rationale": "..."} instead of guessing. \
    \
    The deterministic engine still owns truth: your query is dispatched \
    verbatim, results are scored by the 4-gate rules, hypothesis verdicts are \
    rule-driven. You only choose what to ask next. \
    Respond with valid JSON only, matching the schema in the user prompt.
    """

    /// Prose-only disambiguation across multiple candidate clusters. No JSON,
    /// no chain-of-thought visible to the user (the model still uses <think>
    /// internally, stripped by `LocalInferenceService`). Output is rendered
    /// directly in a sheet, so the system prompt steers towards clarity and
    /// brevity rather than a structured response.
    static let candidateComparisonSystem = """
    You are a genealogical research assistant helping a researcher choose between candidate matches. \
    Reason carefully and concisely about each candidate. Focus on disambiguation — what makes one \
    candidate more or less likely to be the subject than another. Consider: \
    - Birth-year discrepancies of ±2 years are normal; ±5+ suggest different people \
    - Same registration district + same quarter + different vol/page = different people sharing a name \
    - Common names (Mary Smith, John Brown) often have multiple matches in the same county \
    - Census ages are self-reported and often rounded — don't over-weight small mismatches \
    - A maiden name in a birth record's mother field can identify or rule out a candidate immediately \
    Be concrete, terse, and honest about uncertainty. Never invent facts that aren't in the records. \
    Do not output JSON or markdown headings — plain prose paragraphs only.
    """
}
