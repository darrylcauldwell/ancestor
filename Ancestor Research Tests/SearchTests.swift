import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for M8 W6 (Search) — substring matching across each entity type,
/// case-insensitivity, snippet/title rendering for results, integration
/// with the existing FTS notes index.
struct SearchTests {

    private func makeNote(_ content: String, tag: NoteTag = .observation) -> WorkbenchNote {
        WorkbenchNote(
            id: UUID(), content: content, tag: tag,
            attachedTo: .project, createdAt: Date(), updatedAt: Date()
        )
    }

    private func makeQuestion(
        text: String, tried: String? = nil, resolution: String? = nil,
        status: QuestionStatus = .open
    ) -> OpenQuestion {
        OpenQuestion(
            id: UUID(), text: text, profileIDs: [],
            priority: .medium, status: status,
            triedSources: tried, promotedFrom: nil,
            createdAt: Date(), resolvedAt: nil, resolution: resolution
        )
    }

    private func makeHypothesis(
        reasoning: String,
        claim: HypothesisClaim = .existence(description: "test", relatedProfileIDs: []),
        supporting: [String] = [],
        contradicting: [String] = [],
        dismissalReason: String? = nil
    ) -> Hypothesis {
        Hypothesis(
            id: UUID(), claim: claim, confidence: .speculation,
            reasoning: reasoning,
            supportingEvidence: supporting,
            contradictingEvidence: contradicting,
            status: .active, createdAt: Date(),
            resolvedAt: nil, dismissalReason: dismissalReason
        )
    }

    private func makeFocus(title: String?) -> FocusSet {
        FocusSet(
            id: UUID(), title: title, profileIDs: [],
            createdAt: Date(), lastActiveAt: Date()
        )
    }

    // MARK: - Per-entity matching

    @Test func matches_emptyQueryReturnsEmpty() {
        let results = WorkbenchSearch.matches(
            query: "", notes: [makeNote("hello")],
            questions: [], hypotheses: [], focusSets: []
        )
        #expect(results.isEmpty)
    }

    @Test func matches_whitespaceQueryReturnsEmpty() {
        let results = WorkbenchSearch.matches(
            query: "   ", notes: [makeNote("hello")],
            questions: [], hypotheses: [], focusSets: []
        )
        #expect(results.isEmpty)
    }

    @Test func matches_caseInsensitive() {
        let n = makeNote("Wirksworth parish 1815")
        let results = WorkbenchSearch.matches(
            query: "WIRKSWORTH",
            notes: [n], questions: [], hypotheses: [], focusSets: []
        )
        #expect(results.count == 1)
        if case .note = results.first { /* ok */ } else {
            Issue.record("Expected note hit")
        }
    }

    @Test func matches_questionTextField() {
        let q = makeQuestion(text: "Who were William's parents?")
        let results = WorkbenchSearch.matches(
            query: "william",
            notes: [], questions: [q], hypotheses: [], focusSets: []
        )
        #expect(results.count == 1)
    }

    @Test func matches_questionTriedSourcesField() {
        let q = makeQuestion(text: "test", tried: "FreeBMD 1810-1820")
        let results = WorkbenchSearch.matches(
            query: "FreeBMD",
            notes: [], questions: [q], hypotheses: [], focusSets: []
        )
        #expect(results.count == 1)
    }

    @Test func matches_hypothesisReasoningField() {
        let h = makeHypothesis(reasoning: "Census shows the same household")
        let results = WorkbenchSearch.matches(
            query: "census",
            notes: [], questions: [], hypotheses: [h], focusSets: []
        )
        #expect(results.count == 1)
    }

    @Test func matches_hypothesisEvidenceArrays() {
        let h = makeHypothesis(
            reasoning: "x",
            supporting: ["FreeBMD birth match"],
            contradicting: []
        )
        let results = WorkbenchSearch.matches(
            query: "freebmd",
            notes: [], questions: [], hypotheses: [h], focusSets: []
        )
        #expect(results.count == 1)
    }

    @Test func matches_hypothesisClaimSummary() {
        let h = makeHypothesis(
            reasoning: "irrelevant",
            claim: .existence(description: "James, sibling who died young", relatedProfileIDs: [])
        )
        let results = WorkbenchSearch.matches(
            query: "James",
            notes: [], questions: [], hypotheses: [h], focusSets: []
        )
        #expect(results.count == 1)
    }

    @Test func matches_focusSetTitle() {
        let f = makeFocus(title: "Land family")
        let results = WorkbenchSearch.matches(
            query: "Land",
            notes: [], questions: [], hypotheses: [], focusSets: [f]
        )
        #expect(results.count == 1)
    }

    @Test func matches_skipsFocusSetWithoutTitle() {
        let f = makeFocus(title: nil)
        let results = WorkbenchSearch.matches(
            query: "untitled",
            notes: [], questions: [], hypotheses: [], focusSets: [f]
        )
        #expect(results.isEmpty)
    }

    @Test func matches_returnsMultipleEntityTypesAtOnce() {
        let results = WorkbenchSearch.matches(
            query: "test",
            notes: [makeNote("test note")],
            questions: [makeQuestion(text: "test question?")],
            hypotheses: [makeHypothesis(reasoning: "test reasoning")],
            focusSets: [makeFocus(title: "test focus")]
        )
        #expect(results.count == 4)
    }

    // MARK: - WorkbenchSearchResult formatting

    @Test func result_groupOrder_notesFirst() {
        let n = WorkbenchSearchResult.note(makeNote("x"))
        let q = WorkbenchSearchResult.question(makeQuestion(text: "x"))
        let h = WorkbenchSearchResult.hypothesis(makeHypothesis(reasoning: "x"))
        let f = WorkbenchSearchResult.focusSet(makeFocus(title: "x"))
        #expect(n.groupOrder < q.groupOrder)
        #expect(q.groupOrder < h.groupOrder)
        #expect(h.groupOrder < f.groupOrder)
    }

    @Test func result_id_disambiguatesByKind() {
        let id = UUID()
        let note = WorkbenchSearchResult.note(WorkbenchNote(
            id: id, content: "x", tag: .meta, attachedTo: .project,
            createdAt: Date(), updatedAt: Date()
        ))
        let question = WorkbenchSearchResult.question(OpenQuestion(
            id: id, text: "x", profileIDs: [],
            priority: .low, status: .open,
            triedSources: nil, promotedFrom: nil,
            createdAt: Date(), resolvedAt: nil, resolution: nil
        ))
        #expect(note.id != question.id)
    }

    @Test func result_focusSetSnippet_showsProfileCount() {
        let result = WorkbenchSearchResult.focusSet(FocusSet(
            id: UUID(), title: "x", profileIDs: ["a", "b", "c"],
            createdAt: Date(), lastActiveAt: Date()
        ))
        #expect(result.snippet.contains("3 profile"))
    }
}
