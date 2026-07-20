import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Death-record age gate: a childhood death must not be returned as a match for
/// a subject who demonstrably reached adulthood, and a recorded age wildly
/// outside the birth window is a different person, not a borderline misreport.
///
/// Anchored to the live Nora Beresford case (b.1907 Bakewell, married a Rose,
/// had children) where "Nora BERESFORD, Mar 1920, Chesterfield, age 4" — a
/// different child who died at four — came back as a lead.
struct DeathAgeImpossibleTests {

    private func subject(birthYear: Int = 1907, withFamily: Bool) -> ResearchSubject {
        let family: FamilyContext? = withFamily ? FamilyContext(
            spouseName: "Nora Rose", spouseSurname: "Rose", spouseGivenName: "Nora",
            spouseFatherSurname: nil, childNames: ["John Rose", "Mary Rose"],
            fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
            motherName: nil, motherSurname: nil, motherGivenName: nil
        ) : nil
        return ResearchSubject(
            surname: "Beresford", givenName: "Nora",
            birthYearFrom: birthYear, birthYearTo: birthYear,
            gender: .female, region: .englandAndWales,
            mode: .extend, familyContext: family)
    }

    private func deathRecord(year: Int, age: Int?) -> SourceRecord {
        .death(DeathRecord(
            common: RecordCommon(
                id: "death-\(year)-\(age.map(String.init) ?? "na")",
                sourceID: "freebmd", surname: "Beresford", givenName: "Nora",
                rawFields: [:]),
            deathYear: year, age: age, district: "Chesterfield"))
    }

    private func dateOutcome(_ result: ScoredRecord) -> GateOutcome? {
        result.gates.first { $0.gate == .date }?.outcome
    }

    /// (b) The reported case: recorded age 4, subject married + had children.
    @Test func recordedChildhoodDeathForParentIsImpossible() {
        let result = RecordScorer.classify(
            record: deathRecord(year: 1920, age: 4),
            subject: subject(withFamily: true), searchType: .death)
        #expect(dateOutcome(result) == .impossible)
        #expect(result.verdict == .impossible)
    }

    /// (b) The age-less burial twin ("Spital Cemetery, d.1920"): no recorded
    /// age, but implied age ≤13 for a subject who reached parenthood.
    @Test func agelessChildhoodBurialForParentIsImpossible() {
        let result = RecordScorer.classify(
            record: deathRecord(year: 1920, age: nil),
            subject: subject(withFamily: true), searchType: .burial)
        #expect(dateOutcome(result) == .impossible)
    }

    /// (a) Even WITHOUT family context, a recorded age wildly below the implied
    /// age (4 vs ~13) is a different person → impossible, not a lead.
    @Test func wildlyYoungRecordedAgeIsImpossibleWithoutFamily() {
        let result = RecordScorer.classify(
            record: deathRecord(year: 1920, age: 4),
            subject: subject(withFamily: false), searchType: .death)
        #expect(dateOutcome(result) == .impossible)
    }

    /// Regression: a genuine adult death still passes (age 80, born 1907).
    @Test func genuineAdultDeathStillPasses() {
        let result = RecordScorer.classify(
            record: deathRecord(year: 1987, age: 80),
            subject: subject(withFamily: true), searchType: .death)
        #expect(dateOutcome(result) == .pass)
        #expect(result.verdict != .impossible)
    }

    /// Regression: a borderline age mismatch (3 years off, no family) stays a
    /// reviewable .fail — NOT escalated to impossible.
    @Test func borderlineAgeMismatchStaysFail() {
        let result = RecordScorer.classify(
            record: deathRecord(year: 1920, age: 10),   // implied ~13, off by 3
            subject: subject(withFamily: false), searchType: .death)
        #expect(dateOutcome(result) == .fail)
        #expect(result.verdict != .impossible)
    }
}
