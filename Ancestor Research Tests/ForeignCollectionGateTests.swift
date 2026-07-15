import Testing
import AncestorKit
@testable import Ancestor_Research

/// Live find 2026-07-15: 'E Anna Marshall', US 1950 census, reached a
/// CONFIRMED cluster against a Derbyshire subject. The foreign-metadata
/// check existed and 'united states' was in the catalogue, but the
/// tokenizer only stripped commas/periods/slashes — the quote in
/// 'Household of <Unknown>, "United States, Census, 1950"' hid the token
/// behind a boundary character. Every non-alphanumeric is a separator now.
struct ForeignCollectionGateTests {

    private func subjectDBY() -> ResearchSubject {
        ResearchSubject(
            profileID: nil, surname: "Twyford", givenName: "Elsie",
            birthYearFrom: 1917, birthYearTo: 1917,
            deathYearFrom: 2011, deathYearTo: 2011,
            gender: .female, region: .county("Derbyshire"), mode: .adaptive,
            familyContext: nil, homeChapmanCode: "DBY")
    }

    @Test func quotedForeignCollectionTitleHardFailsGeography() {
        let record = SourceRecord.census(CensusRecord(
            common: RecordCommon(
                id: "us1", sourceID: "familysearch", name: "E Anna Marshall",
                surname: "Marshall", givenName: "E Anna", detailURL: nil,
                rawFields: [
                    "collection.title": "Household of <Unknown>, \"United States, Census, 1950\"",
                ]),
            censusYear: 1950, age: 68, birthYear: nil, birthPlace: "Ps",
            birthCounty: nil, relationship: "Wife", occupation: nil,
            address: nil, parish: nil, district: nil, household: nil))

        let scored = RecordScorer.classify(
            record: record, subject: subjectDBY(), searchType: .census)
        #expect(scored.verdict == .impossible,
                "a US-collection record must be impossible against a UK-anchored subject; got \(scored.verdict)")
        let geo = scored.gates.first { $0.gate == .geography }
        #expect(geo?.outcome == .fail, "geography must hard-fail on the collection's country")
    }

    @Test func ukQuotedCollectionTitleIsNotForeign() {
        // Barbara's Northumberland title carries the same quote pattern —
        // must NOT trip the foreign check.
        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(
                id: "uk1", sourceID: "familysearch", name: "Barbara Ayre",
                surname: "Ayre", givenName: "Barbara", detailURL: nil,
                rawFields: [
                    "collection.title": "Entry for John Ayre, \"England, Northumberland, Parish Registers, 1538-1950\"",
                ]),
            deathYear: 1978, deathDate: nil, deathPlace: nil, age: nil,
            quarter: nil, district: nil, volume: nil, page: nil, spouseSurname: nil))
        let scored = RecordScorer.classify(
            record: record, subject: subjectDBY(), searchType: .death)
        let geo = scored.gates.first { $0.gate == .geography }
        #expect(geo?.outcome != .fail || !(geo?.reason.contains("non-UK") ?? false),
                "a UK collection must not trip the foreign check; got \(geo?.reason ?? "nil")")
    }
}
