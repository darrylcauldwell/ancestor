import Testing
import Foundation
@testable import Ancestor_Research

/// DS-31 death-date exclusivity: a person dies once. When the subject's death
/// date is a CONFIRMED PRECISE calendar date, a same-name death/burial record
/// on a different date is a namesake → `.impossible`, not a lingering lead.
///
/// The live case is William Holmes (d. 19 Sep 1919, from GEDCOM), whose missing
/// birth anchor opens a 30-year birth window and floods Triage with ~20 CWGC
/// William Holmes casualties (1914–1918) + off-year FreeBMD deaths, every one a
/// namesake — previously all surviving as `.lead`.
struct DeathDateExclusivityTests {

    /// William's shape: no own birth date, so `fromProfile` derives the birth
    /// window from his son (1916 − 45 … 1916 − 18 = 1871–1898); death is the
    /// one confirmed precise fact.
    private func william(deathDateOriginal: String? = "19 Sep 1919") -> ResearchSubject {
        ResearchSubject(
            surname: "Holmes",
            givenName: "William",
            birthYearFrom: 1871,
            birthYearTo: 1898,
            deathYearFrom: 1919,
            deathYearTo: 1919,
            deathDateOriginal: deathDateOriginal,
            gender: .male,
            region: nil,
            mode: .all,
            homeChapmanCode: "DBY"
        )
    }

    private func cwgc(id: String = "cwgc_1", dateOfDeath: String, deathYear: Int, age: Int? = nil) -> SourceRecord {
        .military(MilitaryRecord(
            common: RecordCommon(
                id: id, sourceID: "cwgc",
                name: "William Holmes", surname: "Holmes", givenName: "William",
                detailURL: nil, rawFields: [:]
            ),
            rank: "Private", regiment: "Leicestershire Regiment",
            dateOfDeath: dateOfDeath, deathYear: deathYear, age: age
        ))
    }

    private func freebmdDeath(id: String = "fb_1", year: Int) -> SourceRecord {
        // FreeBMD death index rows carry a quarter + year, no calendar date.
        .death(DeathRecord(
            common: RecordCommon(
                id: id, sourceID: "freebmd",
                name: "William Holmes", surname: "Holmes", givenName: "William",
                detailURL: nil, rawFields: [:]
            ),
            deathYear: year, deathDate: nil, quarter: "Mar", district: "Belper"
        ))
    }

    private func classify(_ r: SourceRecord, _ s: ResearchSubject) -> ScoredRecord {
        RecordScorer.classify(record: r, subject: s, searchType: .death)
    }
    private func dateGate(_ scored: ScoredRecord) -> GateResult? {
        scored.gates.first { $0.gate == .date }
    }

    // MARK: - The sweep

    @Test func cwgcCasualtyInAnOffYearIsImpossible() {
        // Serjeant William Holmes, West Yorks, d. 29 May 1918 — precise date,
        // wrong year. He died once, in 1919. Namesake.
        let scored = classify(cwgc(dateOfDeath: "29 May 1918", deathYear: 1918), william())
        #expect(scored.verdict == .impossible)
        #expect(dateGate(scored)?.reason.contains("dies once") == true)
    }

    @Test func cwgcCasualtyMatchingDayAndMonthButWrongYearIsStillImpossible() {
        // 19 September 1918 shares William's day+month but not his year — the
        // seductive near-miss the ±1 window used to wave through as a lead.
        let scored = classify(cwgc(dateOfDeath: "19 September 1918", deathYear: 1918), william())
        #expect(scored.verdict == .impossible)
    }

    @Test func freebmdDeathInAWrongYearIsImpossible() {
        // FreeBMD "William B Holmes, Mar 1921" — year-only, wrong year.
        let scored = classify(freebmdDeath(year: 1921), william())
        #expect(scored.verdict == .impossible)
        #expect(dateGate(scored)?.reason.contains("dies once") == true)
    }

    // MARK: - What must survive

    @Test func theActualDeathDateIsNotSweptAway() {
        // A record on his confirmed date (±3 days slop) is the same event.
        let scored = classify(cwgc(dateOfDeath: "19 September 1919", deathYear: 1919), william())
        #expect(scored.verdict != .impossible)
        #expect(dateGate(scored)?.reason.contains("dies once") != true)
    }

    @Test func aSameYearRegistrationWithoutACalendarDateSurvives() {
        // FreeBMD death index in the right year, no full date — could be his
        // real registration. Must not be killed on year alone.
        let scored = classify(freebmdDeath(year: 1919), william())
        #expect(scored.verdict != .impossible)
    }

    // MARK: - Guardrails: the rule is gated on a PRECISE confirmed death

    @Test func aYearOnlyConfirmedDeathKeepsTheSofterFailBehaviour() {
        // When the death is known only to the year (no day/month), the year
        // itself may still move — so an off-year namesake stays a soft fail
        // (→ lead in .all mode), NOT the hard impossible.
        let scored = classify(freebmdDeath(year: 1921), william(deathDateOriginal: "1919"))
        #expect(scored.verdict != .impossible)
        #expect(dateGate(scored)?.outcome == .fail)
    }

    @Test func probateIsExemptFromTheHardRule() {
        // A grant lags death by months to years, so a probate record is never
        // hard-killed by date exclusivity — an out-of-tolerance year is a soft
        // fail, not impossible.
        let probate = SourceRecord.probate(ProbateRecord(
            common: RecordCommon(
                id: "prob_1", sourceID: "probate",
                name: "William Holmes", surname: "Holmes", givenName: "William",
                detailURL: nil, rawFields: [:]
            ),
            deathDate: nil, deathYear: 1925, probateDate: "1925"
        ))
        let scored = RecordScorer.classify(record: probate, subject: william(), searchType: .probate)
        #expect(scored.verdict != .impossible)
    }
}
