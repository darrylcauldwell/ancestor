import Foundation
import os

/// MLX-driven extraction of structured facts and narratives from a
/// prose-corpus page. Spec §10.
///
/// Given one `ProseCandidate` plus the markdown body of its page, the
/// extractor builds a per-call prompt (subject + source + content),
/// hands it to the injected `ProseExtractionLLM`, parses the JSON
/// response, and returns `PendingFact` / `NarrativeFinding` values
/// ready to drop into the project DB. The extractor never writes to
/// the DB itself — call sites (P6 wiring in `ResearchViewModel`)
/// route results through `ProjectDatabase.savePendingFact` /
/// `saveNarrativeFinding`, which is where the Evidence Firewall
/// becomes the next gate.
///
/// The extractor is pure orchestration — no MLX dependency in the
/// type itself, no DB calls, no I/O beyond the injected LLM call.
/// That keeps it unit-testable against a `MockProseExtractionLLM`
/// in `ProseCorpusExtractorTests`.
nonisolated struct ProseCorpusExtractor {
    let llm: any ProseExtractionLLM
    /// Injectable clock so tests can pin `submittedAt`. Production
    /// passes `Date.init`.
    let now: @Sendable () -> Date

    init(
        llm: any ProseExtractionLLM,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.llm = llm
        self.now = now
    }

    private static let logger = Logger(subsystem: "dev.dreamfold.Ancestor-Research", category: "ProseCorpusExtractor")

    /// Hard cap on the CONTENT block sent to the model. Spec §10.1
    /// calls 24 KB the v1 threshold based on DeepSeek-R1 7B's
    /// effective context plus prompt overhead. Above this the spec
    /// calls for section-boundary splitting; v1 takes the head-
    /// truncate path with a logged warning so the user knows a long
    /// page was clipped.
    static let maxContentBytes: Int = 24 * 1024

    /// Run the extraction loop. Reads the system prompt from the
    /// bundle (falling back to the inline default if the resource
    /// is missing), builds the user prompt from subject + candidate
    /// + body, calls the LLM, parses the result, and returns the
    /// derived facts/narratives. Returns an empty result when the
    /// LLM returns nil or the response can't be parsed —
    /// caller-side this just means "the page produced no facts",
    /// which is the same outcome as a clean empty-arrays response.
    func extract(
        candidate: ProseCandidate,
        body: String,
        subject: ResearchSubject,
        profileID: String
    ) async -> ExtractionResult {
        let systemPrompt = Self.loadSystemPrompt()
        let userPrompt = Self.buildUserPrompt(
            subject: subject,
            candidate: candidate,
            body: body
        )

        guard let rawText = await llm.extractText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            Self.logger.info("Prose extractor returned no text for \(candidate.id, privacy: .public)")
            return ExtractionResult(facts: [], narratives: [])
        }

        guard let object = Self.parseJSONObject(from: rawText) else {
            Self.logger.warning("Prose extractor returned non-parseable JSON for \(candidate.id, privacy: .public)")
            return ExtractionResult(facts: [], narratives: [])
        }

        let factsRaw = (object["facts"] as? [[String: Any]]) ?? []
        let narrativesRaw = (object["narratives"] as? [[String: Any]]) ?? []

        var facts: [PendingFact] = []
        for raw in factsRaw {
            if let fact = makePendingFact(
                raw: raw,
                candidate: candidate,
                body: body,
                profileID: profileID
            ) {
                facts.append(fact)
            }
        }

        var narratives: [NarrativeFinding] = []
        for raw in narrativesRaw {
            if let narrative = makeNarrativeFinding(
                raw: raw,
                candidate: candidate,
                body: body,
                profileID: profileID
            ) {
                narratives.append(narrative)
            }
        }
        return ExtractionResult(facts: facts, narratives: narratives)
    }

    // MARK: - Prompt assembly

    /// Build the user prompt block per spec §10.1. Subject + Source
    /// + Content. The TASK section lives in the system prompt
    /// (loadSystemPrompt); the user prompt carries only the run-
    /// specific data so the model's instruction context stays
    /// stable run-to-run.
    nonisolated static func buildUserPrompt(
        subject: ResearchSubject,
        candidate: ProseCandidate,
        body: String
    ) -> String {
        let surname = subject.surname ?? "(unknown)"
        let given = subject.givenName ?? "(unknown)"
        let born: String
        if let f = subject.birthYearFrom, let t = subject.birthYearTo, f != t {
            born = "\(f)-\(t)"
        } else if let f = subject.birthYearFrom {
            born = "\(f)"
        } else {
            born = "(unknown)"
        }
        let region: String
        if let r = subject.region {
            switch r {
            case .englandAndWales:        region = "England & Wales"
            case .scotland:               region = "Scotland"
            case .ireland:                region = "Ireland"
            case .commonwealthMilitary:   region = "Commonwealth military"
            case .county(let c):          region = c
            case .parish(let p, let c):   region = "\(p), \(c)"
            }
        } else {
            region = "(unknown)"
        }

        let title = candidate.title ?? "(no title)"

        // Truncate to maxContentBytes by byte count, not character
        // count, since byte limit matches MLX's tokeniser more
        // closely than character count.
        let truncated: String
        if body.utf8.count > maxContentBytes {
            // Conservatively head-truncate. Spec §10.1's section-
            // boundary splitter is future work — for v1 we log and
            // drop the tail. Most realistic genealogy pages fit
            // comfortably under 24 KB.
            let prefixBytes = Data(body.utf8.prefix(maxContentBytes))
            truncated = String(data: prefixBytes, encoding: .utf8) ?? body
            Self.logger.info("Truncated prose body for \(candidate.id, privacy: .public) from \(body.utf8.count) to \(prefixBytes.count) bytes")
        } else {
            truncated = body
        }

        return """
        SUBJECT
          surname: \(surname)
          given:   \(given)
          born:    \(born)
          region:  \(region)

        SOURCE
          url:   \(candidate.sourceURL)
          title: \(title)

        CONTENT
        \(truncated)
        """
    }

    /// Load `Resources/Prompts/prose_extraction_system.txt` from the
    /// app bundle. Falls back to the inline default below if the
    /// resource is missing — keeps the extractor working in test
    /// targets that don't bundle resources.
    nonisolated static func loadSystemPrompt() -> String {
        if let url = Bundle.main.url(
            forResource: "prose_extraction_system",
            withExtension: "txt",
            subdirectory: "Prompts"
        ) ?? Bundle.main.url(
            forResource: "prose_extraction_system",
            withExtension: "txt"
        ), let data = try? Data(contentsOf: url), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return inlineFallbackSystemPrompt
    }

    /// Mirrors the bundled prompt — kept inline as a fallback for
    /// test targets where the resource isn't packaged. Production
    /// always uses the bundled .txt so the prompt can be tuned
    /// without recompiling.
    nonisolated static let inlineFallbackSystemPrompt = """
    You are a genealogical fact extractor. Return JSON with `facts` (kind, value, evidence_text, reasoning) and `narratives` (category, description, date_or_period, evidence_text, reasoning). `evidence_text` must be a verbatim substring of CONTENT (≤200 chars). Extract only facts about the SUBJECT.
    """

    // MARK: - Conversion

    /// Build a `PendingFact` from one element of the LLM's `facts`
    /// array. Returns nil for malformed entries — missing required
    /// fields, `evidence_text` not a substring of CONTENT (catches
    /// the simplest hallucinations before they hit the Evidence
    /// Firewall), unrecognised `kind`.
    private func makePendingFact(
        raw: [String: Any],
        candidate: ProseCandidate,
        body: String,
        profileID: String
    ) -> PendingFact? {
        guard let kind = raw["kind"] as? String, Self.allowedFactKinds.contains(kind) else { return nil }
        guard let value = raw["value"] as? String, !value.isEmpty else { return nil }
        guard let evidenceText = raw["evidence_text"] as? String, !evidenceText.isEmpty else { return nil }
        let reasoning = (raw["reasoning"] as? String) ?? ""

        // Pre-firewall hallucination filter — body substring check.
        // The Evidence Firewall's `verifyURL(...)` would catch this
        // too, but only after a network round-trip. Filtering here
        // is cheap, catches fabricated quotes that never had a
        // chance of being in the page, and matches spec AC-M5.
        let cappedEvidence = String(evidenceText.prefix(200))
        guard body.contains(cappedEvidence) else {
            Self.logger.warning("Prose extractor produced non-substring evidence_text for \(candidate.id, privacy: .public); dropping fact \(kind)")
            return nil
        }

        let agentID = "prose-extractor:\(candidate.sourceID)"
        let id = EvidenceFirewall.idempotencyKey(
            profileID: profileID,
            field: kind,
            value: value,
            sourceURL: candidate.sourceURL
        )
        return PendingFact(
            id: id,
            profileID: profileID,
            field: kind,
            value: value,
            sourceURL: candidate.sourceURL,
            sourceTitle: candidate.title ?? "",
            evidenceText: cappedEvidence,
            reasoning: reasoning,
            confidence: "low",  // MLX-from-prose is the most derivative agent — let scorer demote
            agentID: agentID,
            submittedAt: now(),
            verificationStatus: .pending
        )
    }

    /// Build a `NarrativeFinding` from one element of the LLM's
    /// `narratives` array. Same substring-check rule as facts.
    private func makeNarrativeFinding(
        raw: [String: Any],
        candidate: ProseCandidate,
        body: String,
        profileID: String
    ) -> NarrativeFinding? {
        guard let category = raw["category"] as? String, !category.isEmpty else { return nil }
        guard let description = raw["description"] as? String, !description.isEmpty else { return nil }
        guard let evidenceText = raw["evidence_text"] as? String, !evidenceText.isEmpty else { return nil }
        let reasoning = (raw["reasoning"] as? String) ?? ""
        let dateOrPeriod = raw["date_or_period"] as? String

        let cappedEvidence = String(evidenceText.prefix(200))
        guard body.contains(cappedEvidence) else {
            Self.logger.warning("Prose extractor produced non-substring evidence_text for narrative \(candidate.id, privacy: .public); dropping")
            return nil
        }
        let agentID = "prose-extractor:\(candidate.sourceID)"
        let id = EvidenceFirewall.idempotencyKey(
            profileID: profileID,
            field: "narrative:\(category)",
            value: String(description.prefix(80)),
            sourceURL: candidate.sourceURL
        )
        return NarrativeFinding(
            id: id,
            profileID: profileID,
            category: category,
            description: String(description.prefix(500)),
            dateOrPeriod: dateOrPeriod,
            sourceURL: candidate.sourceURL,
            sourceTitle: candidate.title ?? "",
            evidenceText: cappedEvidence,
            reasoning: reasoning,
            agentID: agentID,
            submittedAt: now(),
            verificationStatus: .pending
        )
    }

    /// `kind` values the spec §10.1 explicitly enumerates. Anything
    /// else from the model is dropped — keeps the pipeline's
    /// downstream field handling honest.
    nonisolated static let allowedFactKinds: Set<String> = [
        "birth_year", "death_year", "marriage_year",
        "spouse", "occupation", "residence",
    ]

    // MARK: - JSON parsing

    /// Parse a JSON object from arbitrary LLM text. Handles raw JSON,
    /// fenced code blocks (```json…``` and bare ```…```), and a
    /// fallback `{...}` slice. Mirrors `LocalInferenceService`'s
    /// internal `extractJSON` so the extractor stays self-contained
    /// and doesn't have to surface a non-Sendable `Any?` across the
    /// LLM actor boundary.
    nonisolated static func parseJSONObject(from text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        if let jsonStart = text.range(of: "```json"),
           let blockEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) {
            let jsonText = String(text[jsonStart.upperBound..<blockEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonText.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
        if let start = text.range(of: "```") {
            let afterStart = text[start.upperBound...]
            if let end = afterStart.range(of: "```") {
                let jsonText = String(afterStart[..<end.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let data = jsonText.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return obj
                }
            }
        }
        if let startIdx = text.firstIndex(of: "{"),
           let endIdx = text.lastIndex(of: "}"),
           startIdx < endIdx {
            let jsonText = String(text[startIdx...endIdx])
            if let data = jsonText.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
        return nil
    }
}

// MARK: - LLM abstraction

/// Minimal seam over `LocalInferenceService` so the extractor can be
/// unit-tested without MLX. Returns raw response text (`String?`)
/// rather than parsed JSON (`Any?`) because `Any` isn't `Sendable`
/// and the LLM call crosses an actor boundary; the extractor
/// re-parses the JSON locally via `parseJSONObject(from:)`.
nonisolated protocol ProseExtractionLLM: Sendable {
    func extractText(systemPrompt: String, userPrompt: String) async -> String?
}

/// Production implementation that routes through the shared MLX
/// reasoning service.
nonisolated struct DefaultProseExtractionLLM: ProseExtractionLLM {
    func extractText(systemPrompt: String, userPrompt: String) async -> String? {
        await LocalInferenceService.shared.reason(
            prompt: userPrompt,
            systemPrompt: systemPrompt
        )
    }
}

// MARK: - Result

/// What the extractor returns per candidate. Lists are empty when
/// the page has nothing to say about the subject — the caller
/// distinguishes "ran successfully, found nothing" (this shape with
/// both empties) from "the LLM is unavailable" (the call site
/// short-circuits before reaching `extract(...)`).
nonisolated struct ExtractionResult: Sendable {
    let facts: [PendingFact]
    let narratives: [NarrativeFinding]
}
