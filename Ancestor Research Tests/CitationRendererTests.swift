import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// A citation must name the repository the record actually came from.
/// The per-type templates assume each type's original provider, which held
/// until FamilySearch (an every-type source) arrived — live find 2026-07-15:
/// Barbara Ayre's FS Northumberland parish record was cited as
/// "England & Wales, GRO Death Index".
struct CitationRendererTests {

    private func fsCommon(id: String = "fs1") -> RecordCommon {
        RecordCommon(
            id: id, sourceID: "familysearch", name: "Barbara Ayre",
            surname: "Ayre", givenName: "Barbara",
            detailURL: "https://www.familysearch.org/ark:/61903/1:1:p_224007479700",
            rawFields: [
                "ark": "https://www.familysearch.org/ark:/61903/1:1:p_224007479700",
                "collection.title":
                    "Entry for John Ayre, \"England, Northumberland, Parish Registers, 1538-1950\"",
            ]
        )
    }

    @Test func familySearchDeathCitesItsCollectionNotGROIndex() {
        let record = SourceRecord.death(DeathRecord(
            common: fsCommon(), deathYear: 1978, deathDate: nil, deathPlace: nil,
            age: nil, quarter: nil, district: nil, volume: nil, page: nil,
            spouseSurname: nil))
        let citation = CitationRenderer.cite(record)
        #expect(citation.full.contains("FamilySearch"))
        // The quoted collection is extracted from FS's "Entry for X, ..." title.
        #expect(citation.full.contains("England, Northumberland, Parish Registers, 1538-1950"))
        #expect(!citation.full.contains("GRO"))
        #expect(citation.full.contains("1978"))
        #expect(citation.url == "https://www.familysearch.org/ark:/61903/1:1:p_224007479700")
        #expect(citation.short.contains("FamilySearch"))
    }

    @Test func familySearchCensusIsNotCitedAsFreeCen() {
        let record = SourceRecord.census(CensusRecord(
            common: fsCommon(id: "fs2"), censusYear: 1911, age: nil, birthYear: nil,
            birthPlace: nil, birthCounty: nil, relationship: nil, occupation: nil,
            address: nil, parish: nil, district: nil, household: nil))
        let citation = CitationRenderer.cite(record)
        #expect(citation.full.contains("FamilySearch"))
        #expect(!citation.full.contains("FreeCen"))
        #expect(citation.full.contains("1911"))
    }

    @Test func familySearchWithoutCollectionTitleStillCitesFamilySearch() {
        let bare = RecordCommon(
            id: "fs3", sourceID: "familysearch", name: "Barbara Ayre",
            surname: "Ayre", givenName: "Barbara",
            detailURL: "https://www.familysearch.org/ark:/61903/1:1:XXXX",
            rawFields: [:])
        let record = SourceRecord.death(DeathRecord(
            common: bare, deathYear: nil, deathDate: nil, deathPlace: nil,
            age: nil, quarter: nil, district: nil, volume: nil, page: nil,
            spouseSurname: nil))
        let citation = CitationRenderer.cite(record)
        #expect(citation.full.contains("FamilySearch"))
        #expect(citation.full.contains("ark:/61903"))
        #expect(!citation.full.contains("GRO"))
    }

    @Test func freebmdTemplateUnchanged() {
        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d1", sourceID: "freebmd", name: nil,
                                 surname: "Ayre", givenName: "Barbara",
                                 detailURL: nil, rawFields: [:]),
            deathYear: 1981, deathDate: nil, deathPlace: nil, age: nil,
            quarter: "Mar", district: "Derby", volume: nil, page: nil,
            spouseSurname: nil))
        let citation = CitationRenderer.cite(record)
        #expect(citation.full.contains("FreeBMD"))
        #expect(!citation.full.contains("FamilySearch"))
    }
}
