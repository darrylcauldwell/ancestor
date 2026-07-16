import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// EVIDENCE_ABSORPTION_SPEC Change 5 — the review preview lists every off-agenda
/// fact a record will land, read from the same `absorptionPlan` the write path
/// executes (so it can't over-promise), with the record's own primary event
/// excluded (the review row already names the record itself).
struct AbsorptionPreviewTests {

    private func common(_ id: String, _ src: String) -> RecordCommon {
        RecordCommon(id: id, sourceID: src, rawFields: [:])
    }

    @Test func censusPreviewListsEveryNuggetButNotTheCensusItself() {
        let preview = SourceRecord.census(CensusRecord(
            common: common("c", "freecen"), censusYear: 1891,
            birthYear: 1888, birthPlace: "Alport", birthCounty: "Derbyshire",
            occupation: "Colliery electrician", address: "3 Mill Lane"))
            .absorptionPreview(profileID: "p")

        #expect(preview.contains("birth place Alport, Derbyshire"))
        #expect(preview.contains("birth date 1888"))
        #expect(preview.contains("occupation Colliery electrician"))
        #expect(preview.contains("residence 3 Mill Lane"))
        // The record's own census event is NOT echoed as a nugget.
        #expect(!preview.contains { $0.hasPrefix("census") })
    }

    @Test func calculatedBirthDateReadsAsAbout() {
        // Death record aged 24 in 1951 → born about 1926–1927.
        let preview = SourceRecord.death(DeathRecord(
            common: common("d", "freebmd"), deathYear: 1951, age: 24))
            .absorptionPreview(profileID: "p")
        #expect(preview.contains("birth date about 1926–1927"))
    }

    @Test func findAGravePreviewShowsBothCorroboratedDates() {
        let preview = SourceRecord.burial(BurialRecord(
            common: common("g", "findagrave"),
            deathDate: "3 Jan 1951", birthDate: "15 Mar 1888",
            burialLocation: "Youlgreave", isVeteran: false))
            .absorptionPreview(profileID: "p")
        #expect(preview.contains("birth date 15 Mar 1888"))
        #expect(preview.contains("death date 3 Jan 1951"))
        #expect(!preview.contains { $0.hasPrefix("burial") })  // primary event excluded
    }

    @Test func marriagePreviewNamesTheSpouse() {
        let preview = SourceRecord.marriage(MarriageRecord(
            common: common("m", "freebmd"), marriageYear: 1916, marriageDate: nil,
            marriagePlace: nil, quarter: nil, district: "Bakewell", volume: nil, page: nil,
            spouseName: "Marshall")).absorptionPreview(profileID: "p")
        #expect(preview == ["marriage to Marshall"])
    }

    @Test func birthRecordPreviewShowsItsFields() {
        let preview = SourceRecord.birth(BirthRecord(
            common: common("b", "freebmd"), birthYear: 1888, birthPlace: "Bakewell"))
            .absorptionPreview(profileID: "p")
        #expect(preview.contains("birth date 1888"))
        #expect(preview.contains("birth place Bakewell"))
    }

    @Test func recordWithNoAbsorbableNuggetsPreviewsEmpty() {
        // A census with only its own event and nothing else to contribute.
        let preview = SourceRecord.census(CensusRecord(
            common: common("c", "freecen"), censusYear: 1891))
            .absorptionPreview(profileID: "p")
        #expect(preview.isEmpty)
    }
}
