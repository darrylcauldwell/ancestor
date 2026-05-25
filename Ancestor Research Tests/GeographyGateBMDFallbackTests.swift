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

    @Test func birthRecordFromForeignCollectionFailsByCollectionTitle() {
        // The persona itself has no birth date, no birth place — only
        // the FamilySearch collection.title identifies it as US (NUMIDENT
        // is the Social Security Numerical Identification Files). The
        // persona-side fallback chain yields empty; without the
        // collection-level check the gate would softFail as "no
        // location data" and the record would land in Triage as a
        // weak lead.
        let common = RecordCommon(
            id: "fs-numident-x",
            sourceID: "familysearch",
            name: "Ernest Caldwell",
            surname: "Caldwell",
            givenName: "Ernest",
            detailURL: nil,
            rawFields: [
                "collection.title": "United States, Social Security Numerical Identification Files (NUMIDENT), 1936-2007",
                "household.role": "parent"
            ]
        )
        let record = SourceRecord.birth(BirthRecord(
            common: common,
            birthYear: nil, birthDate: nil,
            birthPlace: nil,
            quarter: nil, district: nil, volume: nil, page: nil,
            mothersMaidenName: nil
        ))
        let result = RecordScorer.classify(record: record, subject: subject(), searchType: .birth)
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .fail,
                "NUMIDENT collection title should fail geography even when persona has no place data")
        #expect(geo?.reason.contains("non-UK collection") == true,
                "Reason should mention collection-level rejection, got \(String(describing: geo?.reason))")
    }

    @Test func censusRecordFromForeignCollectionFailsEvenWhenPersonaPlaceIsUSStateAlone() {
        // Anchored to the Kathleen Caldwell West Virginia 1949 census
        // bug. The persona-level birth place is "West Virginia" — not
        // in foreignCountryTokens (only "united states"/"usa" are), so
        // the persona fallback would softFail with "location: West
        // Virginia" instead of failing. The collection title carries
        // "United States, Census, 1949" — the hoisted check fires
        // BEFORE persona fallback so this never reaches the
        // softFail path.
        let common = RecordCommon(
            id: "fs-uscensus-wv",
            sourceID: "familysearch",
            name: "Kathleen Caldwell",
            surname: "Caldwell",
            givenName: "Kathleen",
            detailURL: nil,
            rawFields: [
                "collection.title": "United States, Census, 1949",
                "fact.Census.place": "West Virginia, United States"
            ]
        )
        let record = SourceRecord.census(CensusRecord(
            common: common,
            censusYear: 1949,
            age: nil,
            birthYear: 1916,
            birthPlace: "West Virginia",
            birthCounty: nil,
            relationship: "principal",
            occupation: nil,
            address: nil, parish: nil, district: nil,
            household: nil
        ))
        let result = RecordScorer.classify(
            record: record,
            subject: subject(),
            searchType: .census
        )
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .fail,
                "US-collection census should fail geography even with persona-level US-state birth place, got \(String(describing: geo?.outcome))")
        #expect(geo?.reason.contains("non-UK collection") == true,
                "Reason should call out collection-level rejection, got \(String(describing: geo?.reason))")
    }

    @Test func birthRecordFromUSImmigrationManifestFailsViaFactPlace() {
        // Anchored to the Reginald Holmes 1916 bug. The collection
        // title carries only state names ("New York, New York
        // Passenger and Crew Lists") — no "United States" verbatim,
        // so the collection-only check misses it. The persona's
        // Place is "British" (nationality, not a location), and the
        // birthPlace persona fallback yields "British" which isn't
        // in the foreign-tokens whitelist. The "United States" marker
        // is on `fact.Immigration.place`. Scanning .place raw fields
        // catches this.
        let common = RecordCommon(
            id: "fs-immigration-ny",
            sourceID: "familysearch",
            name: "Reginald Holmes",
            surname: "Holmes",
            givenName: "Reginald",
            detailURL: nil,
            rawFields: [
                "collection.title": "Entry for Reginald Holmes, 'New York, New York Passenger and Crew Lists, 1909, 1925-1958'",
                "fact.Birth.date.formal": "+1916",
                "fact.Immigration.date.formal": "+1943",
                "fact.Immigration.place": "New York City, New York, United States"
            ]
        )
        let record = SourceRecord.birth(BirthRecord(
            common: common,
            birthYear: 1916, birthDate: "1916",
            birthPlace: "British",
            quarter: nil, district: nil, volume: nil, page: nil,
            mothersMaidenName: nil
        ))
        let result = RecordScorer.classify(record: record, subject: subject(), searchType: .birth)
        let geo = result.gates.first(where: { $0.gate == .geography })
        #expect(geo?.outcome == .fail,
                "Immigration record with US fact.place should fail geography, got \(String(describing: geo?.outcome))")
        #expect(geo?.reason.contains("non-UK") == true,
                "Reason should call out non-UK metadata, got \(String(describing: geo?.reason))")
    }

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
