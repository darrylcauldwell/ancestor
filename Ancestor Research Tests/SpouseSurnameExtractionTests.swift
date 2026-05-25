import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for `ResearchPipeline.extractSpouseSurnames` — the helper
/// behind the post-marriage death-shape pivot (port of
/// `agent/pipeline.py:_expand_post_marriage_searches` regex path).
@MainActor
struct SpouseSurnameExtractionTests {

    private func marriageRecord(spouseName: String?) -> ScoredRecord {
        let m = MarriageRecord(
            common: RecordCommon(
                id: UUID().uuidString, sourceID: "freebmd",
                name: nil, surname: "BROOKS", givenName: "LILIAN MARY",
                detailURL: nil, rawFields: [:]
            ),
            marriageYear: 1939, marriageDate: nil, marriagePlace: nil,
            quarter: "Jun", district: "BELPER", volume: "7b", page: "1923",
            spouseName: spouseName
        )
        return ScoredRecord(
            id: m.common.id,
            record: .marriage(m),
            verdict: .fact,
            gates: [],
            summary: ""
        )
    }

    @Test func extractsSurnameFromUppercaseSpaceSeparatedSpouseName() {
        // FreeBMD post-Sep-1912 marriage row carries spouseName
        // like "REGINALD MAITLAND HOLMES" — surname is the last
        // whitespace-separated token.
        let facts = [marriageRecord(spouseName: "REGINALD MAITLAND HOLMES")]
        let surnames = ResearchPipeline.extractSpouseSurnames(from: facts)
        #expect(surnames == ["HOLMES"])
    }

    @Test func extractsSurnameFromMixedCaseName() {
        let facts = [marriageRecord(spouseName: "Reginald Maitland Holmes")]
        let surnames = ResearchPipeline.extractSpouseSurnames(from: facts)
        #expect(surnames == ["Holmes"])
    }

    @Test func extractsHyphenatedSurname() {
        // Preserve hyphens (Smyth-Jones is one surname, not two).
        let facts = [marriageRecord(spouseName: "JOHN SMYTH-JONES")]
        let surnames = ResearchPipeline.extractSpouseSurnames(from: facts)
        #expect(surnames == ["SMYTH-JONES"])
    }

    @Test func extractsApostropheSurname() {
        let facts = [marriageRecord(spouseName: "PATRICK O'BRIEN")]
        let surnames = ResearchPipeline.extractSpouseSurnames(from: facts)
        #expect(surnames == ["O'BRIEN"])
    }

    @Test func skipsRecordsWithNoSpouseName() {
        // Pre-Sep-1912 FreeBMD marriages don't carry spouse name —
        // spouseName is nil. Helper just skips them.
        let facts = [marriageRecord(spouseName: nil)]
        let surnames = ResearchPipeline.extractSpouseSurnames(from: facts)
        #expect(surnames.isEmpty)
    }

    @Test func skipsSingleTokenNamesTooShortForSurnames() {
        // A "name" of just "A" or "" can't be parsed safely.
        let facts = [marriageRecord(spouseName: "A")]
        let surnames = ResearchPipeline.extractSpouseSurnames(from: facts)
        #expect(surnames.isEmpty)
    }

    @Test func dedupesAcrossMultipleMarriages() {
        // Two marriages to different Holmeses — still one HOLMES
        // surname to pivot on. (Or remarriage to same surname.)
        let facts = [
            marriageRecord(spouseName: "REGINALD HOLMES"),
            marriageRecord(spouseName: "ALFRED HOLMES")
        ]
        let surnames = ResearchPipeline.extractSpouseSurnames(from: facts)
        #expect(surnames == ["HOLMES"])
    }
}
