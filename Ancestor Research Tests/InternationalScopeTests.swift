import Testing
import Foundation
@testable import Ancestor_Research

/// DS-11 / DS-19 — the "International" scope tier. Foreign inclusion is an
/// explicit opt-in: at International the geography gate soft-fails
/// obviously-foreign places (→ reviewable `.lead`) instead of hard-failing
/// them, and the marker list recognises US states / Canadian provinces named
/// without their country. National and below are unchanged (Triage-clean).
struct InternationalScopeTests {

    // MARK: - Scope ordering

    @Test func internationalIsTheWidestScope() {
        #expect(ResearchScope.national < ResearchScope.international)
        #expect(ResearchScope.allCases.max() == .international)
    }

    // MARK: - Gate behaviour

    @Test func foreignPlaceHardFailsByDefault() {
        // National run (includeForeignRecords = false): a South Carolina
        // census hard-fails → impossible. Also exercises the DS-11 marker
        // (a US state named without "United States").
        let result = RecordScorer.classify(
            record: census(birthCounty: "Charleston, South Carolina"),
            subject: subject(includeForeign: false),
            searchType: .census
        )
        #expect(geo(result) == .fail)
        #expect(result.verdict == .impossible)
    }

    @Test func foreignPlaceSoftFailsAtInternational() {
        // International run: the same record soft-fails → surfaces as a lead.
        let result = RecordScorer.classify(
            record: census(birthCounty: "Charleston, South Carolina"),
            subject: subject(includeForeign: true),
            searchType: .census
        )
        #expect(geo(result) == .softFail,
                "at International a foreign place must soft-fail, not hard-fail — got \(String(describing: geo(result)))")
        #expect(result.verdict != .impossible, "it should survive as a reviewable lead")
    }

    @Test func canadianProvinceIsRecognisedForeign() {
        let result = RecordScorer.classify(
            record: census(birthCounty: "Toronto, Ontario"),
            subject: subject(includeForeign: false),
            searchType: .census
        )
        #expect(geo(result) == .fail)
    }

    @Test func ukPlaceIsUnaffectedAtInternational() {
        // International must not change UK behaviour — a home-county place
        // still passes geography.
        let result = RecordScorer.classify(
            record: census(birthCounty: "Derbyshire"),
            subject: subject(includeForeign: true, chapman: "DBY"),
            searchType: .census
        )
        #expect(geo(result) == .pass)
    }

    @Test func ukCollidingStateNameIsNotFlaggedForeign() {
        // "Washington" is deliberately excluded from the marker list — it is
        // a real UK place (Tyne & Wear). It must not hard-fail on a National
        // run just because Washington is also a US state.
        let result = RecordScorer.classify(
            record: census(birthCounty: "Washington"),
            subject: subject(includeForeign: false, chapman: "DBY"),
            searchType: .census
        )
        #expect(geo(result) != .fail, "a UK-colliding name must not be treated as foreign")
    }

    // MARK: - Fixtures

    private func subject(includeForeign: Bool, chapman: String = "") -> ResearchSubject {
        var s = ResearchSubject(
            surname: "Smith", givenName: "John",
            birthYearFrom: 1868, birthYearTo: 1872,
            gender: .male, region: .englandAndWales, mode: .extend,
            familyContext: FamilyContext(
                spouseName: nil, spouseSurname: nil, spouseGivenName: nil,
                spouseFatherSurname: nil, childNames: [],
                fatherName: nil, fatherSurname: nil, fatherGivenName: nil,
                motherName: nil, motherSurname: nil, motherGivenName: nil),
            homeChapmanCode: chapman)
        s.includeForeignRecords = includeForeign
        return s
    }

    private func census(birthCounty: String) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(
                id: "cen-\(birthCounty)", sourceID: "freecen", name: nil,
                surname: "Smith", givenName: "John", detailURL: nil, rawFields: [:]),
            censusYear: 1901, age: 31, birthYear: 1870,
            birthPlace: birthCounty, birthCounty: birthCounty, relationship: nil,
            occupation: nil, address: nil, parish: nil, district: nil, household: nil))
    }

    private func geo(_ result: ScoredRecord) -> GateOutcome? {
        result.gates.first { $0.gate == .geography }?.outcome
    }
}
