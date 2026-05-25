import Testing
import Foundation
@testable import Ancestor_Research

/// ENGINE_FOUNDATION_SPEC #Change4 — pure aggregation of per-gate
/// attrition counts across a hop's scored records. The hard work is
/// already done by the scorer (each `ScoredRecord` carries its
/// `gates: [GateResult]`); these tests pin the aggregation logic.
struct ScorerAttritionTests {

    // MARK: - Empty / trivial cases

    @Test func emptyRecordsProducesAllZeros() {
        let a = ScorerAttrition.from([])
        #expect(a.candidatesEntered == 0)
        #expect(a.namePassed == 0)
        #expect(a.datePassed == 0)
        #expect(a.geographyPassed == 0)
        #expect(a.familyContextPassed == 0)
        #expect(a.familyContextEvaluated == 0)
        #expect(a.factCount == 0)
        #expect(a.leadCount == 0)
        #expect(a.impossibleCount == 0)
    }

    @Test func singleFactRecordCountsCorrectly() {
        let a = ScorerAttrition.from([
            scored(id: "1", verdict: .fact, gates: [
                gate(.name, .pass),
                gate(.date, .pass),
                gate(.geography, .pass)
            ])
        ])
        #expect(a.candidatesEntered == 1)
        #expect(a.namePassed == 1)
        #expect(a.datePassed == 1)
        #expect(a.geographyPassed == 1)
        #expect(a.factCount == 1)
    }

    // MARK: - Verdict distribution

    @Test func verdictCountsSumToCandidatesEntered() {
        let a = ScorerAttrition.from([
            scored(id: "1", verdict: .fact, gates: []),
            scored(id: "2", verdict: .lead, gates: []),
            scored(id: "3", verdict: .lead, gates: []),
            scored(id: "4", verdict: .impossible, gates: [])
        ])
        #expect(a.candidatesEntered == 4)
        #expect(a.factCount == 1)
        #expect(a.leadCount == 2)
        #expect(a.impossibleCount == 1)
        #expect(a.factCount + a.leadCount + a.impossibleCount == a.candidatesEntered)
    }

    // MARK: - Gate-pass attrition

    @Test func namePassCountsOnlyPassOutcomes() {
        let a = ScorerAttrition.from([
            scored(id: "1", verdict: .lead, gates: [gate(.name, .pass)]),
            scored(id: "2", verdict: .impossible, gates: [gate(.name, .fail)]),
            scored(id: "3", verdict: .lead, gates: [gate(.name, .pass)]),
            scored(id: "4", verdict: .lead, gates: [gate(.name, .softFail)])
        ])
        #expect(a.namePassed == 2,
                "Only `.pass` counts; .fail/.softFail/.skip do not — got \(a.namePassed)")
    }

    @Test func datePassCountsImpossibleAsNotPassed() {
        // `.impossible` short-circuits the verdict but the record is
        // still counted as entered and the gate did not "pass."
        let a = ScorerAttrition.from([
            scored(id: "1", verdict: .impossible, gates: [gate(.date, .impossible)]),
            scored(id: "2", verdict: .lead, gates: [gate(.date, .pass)]),
            scored(id: "3", verdict: .lead, gates: [gate(.date, .fail)])
        ])
        #expect(a.datePassed == 1)
        #expect(a.candidatesEntered == 3)
        #expect(a.impossibleCount == 1)
    }

    @Test func geographyPassExcludesSoftFails() {
        // Geography soft-fails (non-local UK) explicitly don't count
        // — the activity feed wants to show "actually passed" not
        // "didn't reject."
        let a = ScorerAttrition.from([
            scored(id: "1", verdict: .lead, gates: [gate(.geography, .pass)]),
            scored(id: "2", verdict: .lead, gates: [gate(.geography, .softFail)]),
            scored(id: "3", verdict: .lead, gates: [gate(.geography, .pass)])
        ])
        #expect(a.geographyPassed == 2)
    }

    // MARK: - Family-context skip/evaluate distinction

    @Test func familyContextEvaluatedExcludesRecordsWithoutTheGate() {
        // Records without a family-context gate (e.g. a non-census
        // record where the gate `.skip`s and the scorer doesn't even
        // append it) shouldn't inflate the denominator.
        let a = ScorerAttrition.from([
            scored(id: "1", verdict: .lead, gates: [gate(.name, .pass)]),
            scored(id: "2", verdict: .lead, gates: [
                gate(.name, .pass), gate(.familyContext, .pass)
            ]),
            scored(id: "3", verdict: .lead, gates: [
                gate(.name, .pass), gate(.familyContext, .softFail)
            ])
        ])
        #expect(a.familyContextEvaluated == 2,
                "Only the 2 records with a familyContext gate count toward evaluated denominator")
        #expect(a.familyContextPassed == 1,
                "Only the .pass outcome counts toward familyContextPassed")
    }

    // MARK: - Human summary

    @Test func humanSummaryNonEmpty() {
        let a = ScorerAttrition.from([
            scored(id: "1", verdict: .fact, gates: []),
            scored(id: "2", verdict: .lead, gates: []),
            scored(id: "3", verdict: .impossible, gates: [])
        ])
        let summary = a.humanSummary
        #expect(summary.contains("3 scored"))
        #expect(summary.contains("1 facts"))
        #expect(summary.contains("1 leads"))
        #expect(summary.contains("1 impossible"))
        #expect(summary.contains("33% fact"))
    }

    @Test func humanSummaryForEmptyHop() {
        let a = ScorerAttrition.from([])
        #expect(a.humanSummary == "0 candidates scored")
    }

    // MARK: - Realistic thin-vs-rich shape

    @Test func thinSubjectShape_highPassThroughAtGatesNoFacts() {
        // Empirical Phase A shape: thin subject → most records pass
        // name + date (gates skip when nothing to compare against) →
        // but verdict-cap from #Change1 means no .fact emitted.
        // Attrition shows the brake is doing its job downstream.
        let records: [ScoredRecord] = (1...10).map { i in
            scored(id: "thin-\(i)", verdict: .lead, gates: [
                gate(.name, .pass),
                gate(.date, .pass),
                gate(.geography, .pass)
            ])
        }
        let a = ScorerAttrition.from(records)
        #expect(a.candidatesEntered == 10)
        #expect(a.namePassed == 10)
        #expect(a.datePassed == 10)
        #expect(a.geographyPassed == 10)
        #expect(a.factCount == 0,
                "Thin-subject hop should have zero facts even when all gates pass")
        #expect(a.leadCount == 10)
    }

    @Test func richSubjectShape_strongAttritionEarlyGates() {
        // Rich subject: name + date filter heavily, fewer survive to
        // .fact. Realistic Ernest Cauldwell-style hop.
        let records: [ScoredRecord] = [
            scored(id: "good-1", verdict: .fact, gates: [
                gate(.name, .pass), gate(.date, .pass), gate(.geography, .pass)
            ]),
            scored(id: "good-2", verdict: .fact, gates: [
                gate(.name, .pass), gate(.date, .pass), gate(.geography, .pass)
            ]),
            scored(id: "bad-name", verdict: .impossible, gates: [
                gate(.name, .fail), gate(.date, .skip), gate(.geography, .skip)
            ]),
            scored(id: "bad-name2", verdict: .impossible, gates: [
                gate(.name, .fail), gate(.date, .skip), gate(.geography, .skip)
            ]),
            scored(id: "bad-date", verdict: .impossible, gates: [
                gate(.name, .pass), gate(.date, .impossible), gate(.geography, .skip)
            ]),
        ]
        let a = ScorerAttrition.from(records)
        #expect(a.candidatesEntered == 5)
        #expect(a.namePassed == 3,
                "3 records cleared name; 2 hit hard name-fail")
        #expect(a.datePassed == 2)
        #expect(a.geographyPassed == 2)
        #expect(a.factCount == 2)
        #expect(a.impossibleCount == 3)
    }

    // MARK: - Fixtures

    private func gate(_ which: ScoringGate, _ outcome: GateOutcome) -> GateResult {
        GateResult(gate: which, outcome: outcome, reason: "test")
    }

    private func scored(
        id: String,
        verdict: RecordVerdict,
        gates: [GateResult]
    ) -> ScoredRecord {
        ScoredRecord(
            id: id,
            record: minimalBirthRecord(id: id),
            verdict: verdict,
            gates: gates,
            summary: "test record \(id)"
        )
    }

    private func minimalBirthRecord(id: String) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(
                id: id, sourceID: "freebmd", name: nil,
                surname: "Holmes", givenName: nil,
                detailURL: nil, rawFields: [:]
            ),
            birthYear: 1942, birthDate: nil, birthPlace: nil,
            quarter: nil, district: "Belper", volume: nil, page: nil,
            mothersMaidenName: nil
        ))
    }
}
