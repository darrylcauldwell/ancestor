import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// Census-year exclusivity: a person is in exactly one place on census night, so
/// once the subject has an APPLIED census for a year, a same-year census
/// candidate whose household page differs is a namesake at another address —
/// the date gate rejects it as impossible (sibling of the death-once check).
/// Owner dogfood: an applied 1891 census at one address should knock out rival
/// 1891 candidates elsewhere.
struct CensusYearExclusivityTests {

    private let appliedURL = "https://www.freecen.org.uk/search_records/AAA/applied-1891"

    private func subject(applied: [Int: Set<String>]) -> ResearchSubject {
        ResearchSubject(
            surname: "Ward", givenName: "Mary",
            birthYearFrom: 1850, birthYearTo: 1850,
            appliedCensusIdentitiesByYear: applied,
            gender: .female, region: .englandAndWales, mode: .extend)
    }

    private func census(year: Int, url: String?) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(
                id: "c-\(year)-\(url ?? "none")", sourceID: "freecen",
                name: nil, surname: "Ward", givenName: "Mary",
                detailURL: url, rawFields: [:]),
            censusYear: year, age: year - 1850, birthYear: 1850,
            birthPlace: "Belper", birthCounty: "Derbyshire",
            relationship: "Head", occupation: nil,
            address: nil, parish: nil, district: "Belper", household: nil))
    }

    private func dateOutcome(_ record: SourceRecord, _ subject: ResearchSubject) -> GateOutcome? {
        RecordScorer.classify(record: record, subject: subject, searchType: .census)
            .gates.first { $0.gate == .date }?.outcome
    }

    /// The fix: with an applied 1891 census, a DIFFERENT-address 1891 census is
    /// impossible.
    @Test func differentAddressSameYearIsImpossible() {
        let s = subject(applied: [1891: [appliedURL]])
        #expect(dateOutcome(census(year: 1891, url: "https://www.freecen.org.uk/x/other-1891"), s) == .impossible)
    }

    /// The SAME census (same household page) is not knocked out — it passes the
    /// birth-year check.
    @Test func sameHouseholdPageIsNotExcluded() {
        let s = subject(applied: [1891: [appliedURL]])
        #expect(dateOutcome(census(year: 1891, url: appliedURL), s) == .pass)
    }

    /// A different year (no applied census) is unaffected.
    @Test func differentYearUnaffected() {
        let s = subject(applied: [1891: [appliedURL]])
        #expect(dateOutcome(census(year: 1901, url: "https://www.freecen.org.uk/x/other-1901"), s) == .pass)
    }

    /// Conservative: a candidate with no household-page URL can't be proven to
    /// differ, so it is never excluded (falls through to the birth-year check).
    @Test func candidateWithoutURLIsNotExcluded() {
        let s = subject(applied: [1891: [appliedURL]])
        #expect(dateOutcome(census(year: 1891, url: nil), s) == .pass)
    }

    /// No applied census at all → the exclusivity bound never fires.
    @Test func noAppliedCensusNoBound() {
        let s = subject(applied: [:])
        #expect(dateOutcome(census(year: 1891, url: "https://www.freecen.org.uk/x/any-1891"), s) == .pass)
    }
}
