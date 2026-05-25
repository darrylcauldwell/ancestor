import Testing
import Foundation
@testable import Ancestor_Research

/// Tests for the geography gate's BMD-record place-fallback chain
/// (RecordScorer.swift:487-507). Mirrors the Python reference in
/// `agent/scorer.py:273-281` — when a record carries no UK
/// registration district, the gate should consult the typed
/// place fields (`birthPlace`, `deathPlace`, `marriagePlace`) before
/// falling through to "no location data".
///
/// Anchored to the South Carolina FamilySearch birth record bug:
/// previously a `BirthRecord` with `birthPlace: "South Carolina"`
/// and no district silently soft-failed as "no location data" and
/// landed in Triage; it should hard-fail as non-UK and be
/// filtered out at the verdict layer.
@MainActor
struct GeographyGateBMDFallbackTests {

    private func subject() -> ResearchSubject {
        ResearchSubject(
            surname: "Cauldwell",
            givenName: "Ernest",
            birthYearFrom: 1919, birthYearTo: 1919,
            gender: .male,
            region: .county("Derbyshire"),
            mode: .extend,
            homeChapmanCode: "DBY"
        )
    }

    private func common(_ id: String) -> RecordCommon {
        RecordCommon(
            id: id,
            sourceID: "familysearch",
            name: "Ernest Cauldwell",
            surname: "Cauldwell",
            givenName: "Ernest",
            detailURL: nil,
            rawFields: [:]
        )
    }

    // MARK: - Birth records

    @Test func birthRecordWithUSPlaceFailsGeographyAsForeign() {
        let record = SourceRecord.birth(BirthRecord(
            common: common("fs-ernest-sc"),
            birthYear: 1920, birthDate: nil,
            birthPlace: "Newberry, South Carolina, United States",
            quarter: nil, district: nil, volume: nil, page: nil,
            mothersMaidenName: nil
        ))
        let result = RecordScorer.classify(record: record, subject: subject(), searchType: .birth)
        // The geography gate should fail (not softFail) because the
        // location is obviously non-UK. The verdict logic translates
        // geography .fail into .impossible so the record drops out of
        // clustering rather than cluttering Triage as a soft lead.
        #expect(result.verdict == .impossible,
                "South Carolina birth should be impossible for DBY-home subject, got \(result.verdict)")
    }

    @Test func birthRecordWithDerbyshirePlacePassesGeography() {
        let record = SourceRecord.birth(BirthRecord(
            common: common("fs-ernest-dby"),
            birthYear: 1919, birthDate: nil,
            birthPlace: "Loscoe, Derbyshire, England",
            quarter: nil, district: nil, volume: nil, page: nil,
            mothersMaidenName: nil
        ))
        let result = RecordScorer.classify(record: record, subject: subject(), searchType: .birth)
        // Derbyshire place must pass — the same fallback path that
        // catches foreign locations must let local ones through.
        let geographyOutcome = result.gates.first(where: { $0.gate == .geography })?.outcome
        #expect(geographyOutcome == .pass,
                "Derbyshire birth should pass geography, got \(String(describing: geographyOutcome))")
    }

    // MARK: - Death records

    @Test func deathRecordWithUSPlaceFailsGeographyAsForeign() {
        let record = SourceRecord.death(DeathRecord(
            common: common("fs-ernest-d-us"),
            deathYear: 2020, deathDate: nil,
            deathPlace: "Newberry, South Carolina, United States",
            age: nil, quarter: nil, district: nil, volume: nil, page: nil,
            spouseSurname: nil
        ))
        let result = RecordScorer.classify(record: record, subject: subject(), searchType: .death)
        // Symmetric to birth — death-place fallback closes the same
        // hole on death records without a UK district.
        #expect(result.verdict == .impossible,
                "South Carolina death should be impossible, got \(result.verdict)")
    }

    // MARK: - Marriage records

    @Test func marriageRecordWithUSPlaceFailsGeographyAsForeign() {
        let record = SourceRecord.marriage(MarriageRecord(
            common: common("fs-ernest-m-us"),
            marriageYear: 1946, marriageDate: nil,
            marriagePlace: "Newberry, South Carolina, United States",
            quarter: nil, district: nil, volume: nil, page: nil,
            spouseName: nil
        ))
        let result = RecordScorer.classify(record: record, subject: subject(), searchType: .marriage)
        #expect(result.verdict == .impossible,
                "South Carolina marriage should be impossible, got \(result.verdict)")
    }

    // MARK: - Regression: no-location case still soft-fails

    @Test func birthRecordWithoutPlaceStillSoftFails() {
        // Records that genuinely have no location data should keep the
        // old "no location data" softFail behaviour — the fix is only
        // about reading the place when it's there, not about changing
        // the no-data path.
        let record = SourceRecord.birth(BirthRecord(
            common: common("fs-ernest-noloc"),
            birthYear: 1919, birthDate: nil,
            birthPlace: nil,
            quarter: nil, district: nil, volume: nil, page: nil,
            mothersMaidenName: nil
        ))
        let result = RecordScorer.classify(record: record, subject: subject(), searchType: .birth)
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .softFail)
        #expect(geo?.reason == "no location data")
    }
}
