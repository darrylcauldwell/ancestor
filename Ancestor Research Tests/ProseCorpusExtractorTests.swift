import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the prose-extractor contract from spec §10:
///
/// - User prompt shape (subject + source + content with 24 KB body cap).
/// - JSON parsing across the standard LLM-output shapes (raw, fenced).
/// - PendingFact / NarrativeFinding construction with the
///   `prose-extractor:<source_id>` agent ID and idempotency keying.
/// - The hallucination-rejection rule: `evidence_text` MUST be a
///   verbatim substring of the supplied body, otherwise the fact /
///   narrative is dropped before it ever reaches the Evidence
///   Firewall (AC-M5 + cheap upfront filter).
struct ProseCorpusExtractorTests {

    // MARK: - Mock LLM

    /// Returns canned text — tests pin the JSON shape that
    /// `LocalInferenceService.reason` would otherwise produce.
    private struct MockLLM: ProseExtractionLLM {
        let response: String?
        func extractText(systemPrompt: String, userPrompt: String) async -> String? {
            response
        }
    }

    // MARK: - Helpers

    private func makeCandidate(sourceID: String = "wirksworth", title: String? = "Cauldwell page") -> ProseCandidate {
        ProseCandidate(
            sourceID: sourceID,
            pageHash: "deadbeefcafe1234",
            sourceURL: "http://www.wirksworth.org.uk/CAULDW1.htm",
            title: title,
            surnameHits: 5,
            yearHits: 2,
            placeHits: 1
        )
    }

    private func makeSubject() -> ResearchSubject {
        ResearchSubject(
            profileID: "p-1",
            surname: "Cauldwell",
            givenName: "Thomas",
            birthYearFrom: 1780,
            birthYearTo: 1790,
            deathYearFrom: nil,
            deathYearTo: nil,
            gender: nil,
            region: .parish("Wirksworth", county: "Derbyshire"),
            mode: .discover
        )
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_750_000_000)
    private var fixedClock: @Sendable () -> Date { { Date(timeIntervalSince1970: 1_750_000_000) } }

    // MARK: - JSON parsing

    @Test func parsesPlainJSONObject() {
        let raw = #"{ "facts": [], "narratives": [] }"#
        #expect(ProseCorpusExtractor.parseJSONObject(from: raw) != nil)
    }

    @Test func parsesFencedJSONBlock() {
        let raw = """
        Some preamble.
        ```json
        { "facts": [], "narratives": [] }
        ```
        """
        #expect(ProseCorpusExtractor.parseJSONObject(from: raw) != nil)
    }

    @Test func parsesBareFencedBlock() {
        let raw = """
        ```
        { "facts": [], "narratives": [] }
        ```
        """
        #expect(ProseCorpusExtractor.parseJSONObject(from: raw) != nil)
    }

    @Test func parsesObjectSliceFromNoisyText() {
        // Sometimes the model emits commentary alongside the JSON.
        let raw = "Sure, here you go: { \"facts\": [], \"narratives\": [] } end."
        #expect(ProseCorpusExtractor.parseJSONObject(from: raw) != nil)
    }

    @Test func returnsNilForUnparseableText() {
        #expect(ProseCorpusExtractor.parseJSONObject(from: "no json here") == nil)
    }

    // MARK: - User prompt assembly

    @Test func userPromptIncludesSubjectAndSourceBlocks() {
        let subject = makeSubject()
        let candidate = makeCandidate()
        let prompt = ProseCorpusExtractor.buildUserPrompt(
            subject: subject,
            candidate: candidate,
            body: "Page body."
        )
        #expect(prompt.contains("surname: Cauldwell"))
        #expect(prompt.contains("given:   Thomas"))
        #expect(prompt.contains("born:    1780-1790"))
        #expect(prompt.contains("region:  Wirksworth, Derbyshire"))
        #expect(prompt.contains(candidate.sourceURL))
        #expect(prompt.contains("Page body."))
    }

    @Test func userPromptTruncatesOversizedBody() {
        let subject = makeSubject()
        let candidate = makeCandidate()
        // 30 KB body — above the 24 KB cap.
        let body = String(repeating: "a", count: 30 * 1024)
        let prompt = ProseCorpusExtractor.buildUserPrompt(
            subject: subject,
            candidate: candidate,
            body: body
        )
        // Body section is the suffix of the prompt; check it ends up
        // ≤ maxContentBytes (plus headers).
        let bodyOnly = prompt.components(separatedBy: "CONTENT\n").last ?? ""
        #expect(bodyOnly.utf8.count <= ProseCorpusExtractor.maxContentBytes)
    }

    // MARK: - extract — empty / null responses

    @Test func extractReturnsEmptyOnNilLLMResponse() async {
        let extractor = ProseCorpusExtractor(llm: MockLLM(response: nil), now: fixedClock)
        let result = await extractor.extract(
            candidate: makeCandidate(),
            body: "any body",
            subject: makeSubject(),
            profileID: "p-1"
        )
        #expect(result.facts.isEmpty)
        #expect(result.narratives.isEmpty)
    }

    @Test func extractReturnsEmptyOnEmptyArraysJSON() async {
        let extractor = ProseCorpusExtractor(
            llm: MockLLM(response: "{\"facts\": [], \"narratives\": []}"),
            now: fixedClock
        )
        let result = await extractor.extract(
            candidate: makeCandidate(),
            body: "any body",
            subject: makeSubject(),
            profileID: "p-1"
        )
        #expect(result.facts.isEmpty)
        #expect(result.narratives.isEmpty)
    }

    @Test func extractReturnsEmptyOnNonObjectJSON() async {
        // Array at top level — not the {facts, narratives} object the
        // extractor expects. Should not crash; should return empty.
        let extractor = ProseCorpusExtractor(
            llm: MockLLM(response: "[1, 2, 3]"),
            now: fixedClock
        )
        let result = await extractor.extract(
            candidate: makeCandidate(),
            body: "any body",
            subject: makeSubject(),
            profileID: "p-1"
        )
        #expect(result.facts.isEmpty)
        #expect(result.narratives.isEmpty)
    }

    // MARK: - extract — happy path

    @Test func extractProducesPendingFactWithExpectedFields() async {
        let body = "Thomas Cauldwell was born at Wirksworth in 1782 and died 1856."
        let json = """
        {
            "facts": [
                {
                    "kind": "birth_year",
                    "value": "1782",
                    "evidence_text": "Thomas Cauldwell was born at Wirksworth in 1782",
                    "reasoning": "The page states he was born in 1782."
                }
            ],
            "narratives": []
        }
        """
        let extractor = ProseCorpusExtractor(llm: MockLLM(response: json), now: fixedClock)
        let candidate = makeCandidate()
        let result = await extractor.extract(
            candidate: candidate,
            body: body,
            subject: makeSubject(),
            profileID: "p-1"
        )
        #expect(result.facts.count == 1)
        let fact = result.facts[0]
        #expect(fact.field == "birth_year")
        #expect(fact.value == "1782")
        #expect(fact.sourceURL == candidate.sourceURL)
        #expect(fact.sourceTitle == candidate.title)
        #expect(fact.evidenceText == "Thomas Cauldwell was born at Wirksworth in 1782")
        #expect(fact.agentID == "prose-extractor:wirksworth")
        #expect(fact.confidence == "low")
        #expect(fact.profileID == "p-1")
        #expect(fact.submittedAt == fixedDate)
    }

    @Test func extractProducesNarrativeFindingWithExpectedFields() async {
        let body = "He was apprenticed to a cordwainer in 1797 and stayed for seven years."
        let json = """
        {
            "facts": [],
            "narratives": [
                {
                    "category": "apprenticeship",
                    "description": "Apprenticed to a cordwainer from 1797.",
                    "date_or_period": "1797-1804",
                    "evidence_text": "apprenticed to a cordwainer in 1797",
                    "reasoning": "Direct statement of apprenticeship date."
                }
            ]
        }
        """
        let extractor = ProseCorpusExtractor(llm: MockLLM(response: json), now: fixedClock)
        let candidate = makeCandidate()
        let result = await extractor.extract(
            candidate: candidate,
            body: body,
            subject: makeSubject(),
            profileID: "p-1"
        )
        #expect(result.narratives.count == 1)
        let narrative = result.narratives[0]
        #expect(narrative.category == "apprenticeship")
        #expect(narrative.dateOrPeriod == "1797-1804")
        #expect(narrative.agentID == "prose-extractor:wirksworth")
        #expect(narrative.description.contains("cordwainer"))
        #expect(narrative.profileID == "p-1")
    }

    // MARK: - extract — hallucination filter (AC-M5)

    @Test func extractDropsFactWhoseEvidenceTextIsNotInBody() async {
        // The model fabricated a quote that doesn't appear in the
        // body. The pre-firewall substring check must drop it.
        let body = "Thomas Cauldwell of Wirksworth."
        let json = """
        {
            "facts": [
                {
                    "kind": "birth_year",
                    "value": "1782",
                    "evidence_text": "Thomas Cauldwell, born 1782 at the parish church.",
                    "reasoning": "Made up."
                }
            ],
            "narratives": []
        }
        """
        let extractor = ProseCorpusExtractor(llm: MockLLM(response: json), now: fixedClock)
        let result = await extractor.extract(
            candidate: makeCandidate(),
            body: body,
            subject: makeSubject(),
            profileID: "p-1"
        )
        #expect(result.facts.isEmpty)
    }

    @Test func extractDropsFactWithUnknownKind() async {
        let body = "Cauldwell was a parish constable."
        let json = """
        {
            "facts": [
                {
                    "kind": "favourite_colour",
                    "value": "blue",
                    "evidence_text": "Cauldwell was a parish constable.",
                    "reasoning": "Imagined."
                }
            ],
            "narratives": []
        }
        """
        let extractor = ProseCorpusExtractor(llm: MockLLM(response: json), now: fixedClock)
        let result = await extractor.extract(
            candidate: makeCandidate(),
            body: body,
            subject: makeSubject(),
            profileID: "p-1"
        )
        #expect(result.facts.isEmpty)
    }

    @Test func extractDropsNarrativeWhoseEvidenceTextIsNotInBody() async {
        let body = "Short page."
        let json = """
        {
            "facts": [],
            "narratives": [
                {
                    "category": "will_probate",
                    "description": "Made a will in 1820.",
                    "date_or_period": "1820",
                    "evidence_text": "His will, dated 1820, mentions several siblings.",
                    "reasoning": "Hallucinated."
                }
            ]
        }
        """
        let extractor = ProseCorpusExtractor(llm: MockLLM(response: json), now: fixedClock)
        let result = await extractor.extract(
            candidate: makeCandidate(),
            body: body,
            subject: makeSubject(),
            profileID: "p-1"
        )
        #expect(result.narratives.isEmpty)
    }

    @Test func extractCapsLongEvidenceTextAt200Chars() async {
        // Build a body where 250 chars of "X" appear verbatim. The
        // LLM "quotes" all 250; the extractor stores only the first
        // 200 because that's the firewall's column cap. The
        // substring check uses the full 250-char text against the
        // body to verify it was actually present (which it is).
        let bodyChunk = String(repeating: "X", count: 250)
        let body = "Prefix \(bodyChunk) suffix."
        let json = """
        {
            "facts": [
                {
                    "kind": "occupation",
                    "value": "weaver",
                    "evidence_text": "\(bodyChunk)",
                    "reasoning": "He was a weaver."
                }
            ],
            "narratives": []
        }
        """
        let extractor = ProseCorpusExtractor(llm: MockLLM(response: json), now: fixedClock)
        let result = await extractor.extract(
            candidate: makeCandidate(),
            body: body,
            subject: makeSubject(),
            profileID: "p-1"
        )
        #expect(result.facts.count == 1)
        #expect(result.facts[0].evidenceText.count == 200)
    }

    // MARK: - Idempotency

    @Test func extractProducesStableIDAcrossRunsForSameInputs() async {
        let body = "Thomas Cauldwell was born at Wirksworth in 1782."
        let json = """
        {
            "facts": [
                {
                    "kind": "birth_year",
                    "value": "1782",
                    "evidence_text": "Thomas Cauldwell was born at Wirksworth in 1782",
                    "reasoning": "Stated."
                }
            ],
            "narratives": []
        }
        """
        let extractor = ProseCorpusExtractor(llm: MockLLM(response: json), now: fixedClock)
        let first = await extractor.extract(
            candidate: makeCandidate(),
            body: body, subject: makeSubject(), profileID: "p-1"
        )
        let second = await extractor.extract(
            candidate: makeCandidate(),
            body: body, subject: makeSubject(), profileID: "p-1"
        )
        #expect(first.facts.first?.id == second.facts.first?.id)
    }
}
