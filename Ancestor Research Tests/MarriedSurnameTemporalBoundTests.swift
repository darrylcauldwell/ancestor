import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// The married-surname axis of the name gate is bounded in TIME: a woman's
/// married surname is an acceptable match only for a record dated at/after her
/// marriage. Before it she was recorded under her maiden name, so a record
/// carrying the married surname that predates the marriage is a namesake.
///
/// Anchored to the worst-class scorer defect from live dogfooding (it silently
/// fuses two women): an 1891 census "Mary E HOLMES" — born Holmes, an unmarried
/// daughter of a Holmes head — matched a subject who only *became* Holmes by a
/// 1915 marriage. Maiden surname "Ward"; married surname "Holmes" from 1915.
struct MarriedSurnameTemporalBoundTests {

    private func subject(
        maiden: String = "Ward",
        married: String? = "Holmes",
        marriedFrom: Int? = 1915,
        birthYear: Int = 1890
    ) -> ResearchSubject {
        ResearchSubject(
            surname: maiden,
            marriedSurname: married,
            marriedSurnameEffectiveFrom: marriedFrom,
            givenName: "Mary",
            birthYearFrom: birthYear,
            birthYearTo: birthYear,
            gender: .female,
            region: .englandAndWales,
            mode: .extend
        )
    }

    private func census(surname: String, year: Int) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(
                id: "census-\(surname)-\(year)",
                sourceID: "freecen",
                name: nil, surname: surname, givenName: "Mary",
                detailURL: nil, rawFields: [:]
            ),
            censusYear: year, age: year - 1890, birthYear: 1890,
            birthPlace: "Belper", birthCounty: "Derbyshire",
            relationship: "Head", occupation: nil,
            address: nil, parish: nil, district: "Belper", household: nil
        ))
    }

    private func nameOutcome(_ record: SourceRecord, _ subject: ResearchSubject) -> GateOutcome? {
        RecordScorer.classify(record: record, subject: subject, searchType: .census)
            .gates.first { $0.gate == .name }?.outcome
    }

    /// The fix: a census carrying the MARRIED surname but dated BEFORE the
    /// marriage must NOT match on that surname — maiden "Ward" ≠ "Holmes", so
    /// the name gate fails and the namesake never fuses in.
    @Test func preMarriageCensusRejectsMarriedSurname() {
        #expect(nameOutcome(census(surname: "Holmes", year: 1891), subject()) == .fail)
    }

    /// A census dated AT/AFTER the marriage still accepts the married surname —
    /// by then she really is Holmes.
    @Test func postMarriageCensusAcceptsMarriedSurname() {
        #expect(nameOutcome(census(surname: "Holmes", year: 1921), subject()) == .pass)
    }

    /// The bound restricts only the married axis, never the maiden name: a
    /// pre-marriage census under the maiden surname always matches.
    @Test func maidenSurnameMatchesRegardlessOfDate() {
        #expect(nameOutcome(census(surname: "Ward", year: 1891), subject()) == .pass)
    }

    /// Conservative fallback: with no known marriage year, no bound is applied —
    /// the married surname stays acceptable (no regression to the death-shape /
    /// census married-axis widening that predates this fix).
    @Test func unknownMarriageYearAppliesNoBound() {
        #expect(nameOutcome(census(surname: "Holmes", year: 1891),
                            subject(marriedFrom: nil)) == .pass)
    }
}
