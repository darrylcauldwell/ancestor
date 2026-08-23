import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// A census record knows which census it belongs to, so its evidence can sit
/// with that census's life event instead of in a second list.
///
/// Owner request 2026-08-23: a census appeared TWICE on a profile — as a fact
/// context beside birth and death, and again under life events. The ledger
/// groups by FACT ("what backs this birth year?"), life events group by EVENT
/// ("what happened to him?"), and a census is honestly both. But splitting one
/// census's records across two places is how the wrong one gets applied, and
/// that happened twice in one evening on Samuel Holmes.
@MainActor
struct CensusRecordYearTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(
                sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)",
                arguments: [Date()])
        }
        return db
    }

    private func census(_ id: String, year: Int) -> ScoredRecord {
        ScoredRecord(
            id: id,
            record: .census(CensusRecord(
                common: RecordCommon(id: id, sourceID: "freecen", name: "Samuel HOLMES",
                                     surname: "HOLMES", givenName: "Samuel",
                                     detailURL: "https://freecen/\(id)", rawFields: [:]),
                censusYear: year, age: 14, birthYear: year - 14,
                birthPlace: "Rowsley", district: "Bakewell")),
            verdict: .lead, gates: [], summary: "")
    }

    @Test func aCensusRecordCarriesItsYear() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "sam", firstName: "Samuel", lastName: "Holmes",
            gender: .male, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        try db.saveEvidence(profileID: "sam", scored: census("c1", year: 1861),
                            citationFull: "1861, Bakewell.", citationURL: "https://freecen/c1")

        let row = try #require(try ProfileSourcesLedger.allRecords(for: "sam", db: db).first)
        #expect(row.censusYear == 1861)
    }

    /// Records for different censuses are separable — that is what lets each
    /// life event show its own evidence rather than all of it.
    @Test func recordsSeparateByCensusYear() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "sam", firstName: "Samuel", lastName: "Holmes",
            gender: .male, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        try db.saveEvidence(profileID: "sam", scored: census("a", year: 1861),
                            citationFull: "1861 Bakewell, born Rowsley.", citationURL: "https://freecen/a")
        try db.saveEvidence(profileID: "sam", scored: census("b", year: 1891),
                            citationFull: "1891 Bakewell, born Stanton.", citationURL: "https://freecen/b")

        let records = try ProfileSourcesLedger.allRecords(for: "sam", db: db)
        #expect(records.filter { $0.censusYear == 1861 }.count == 1)
        #expect(records.filter { $0.censusYear == 1891 }.count == 1)
    }

    /// A FreeREG church marriage is typed .parish — the spouse row's filter
    /// must still catch it. Mary Stevenson's Youlgreave wedding, the record
    /// whose detail names both fathers, was invisible beside the very spouse
    /// edge it attests while the civil index entry sat there alone.
    @Test func aParishMarriageIsRecognisedForTheSpouseRow() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "mary", firstName: "Mary", lastName: "Stevenson",
            gender: .female, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        let record = SourceRecord.parish(ParishRecord(
            common: RecordCommon(id: "m", sourceID: "freereg", name: "Jacob HOLMES",
                                 surname: "HOLMES", givenName: "Jacob",
                                 detailURL: "https://freereg/m",
                                 rawFields: ["co_persons": "Mary STEVENSON"]),
            eventType: "marriage", eventDate: "19 Jan 1846", eventYear: 1846,
            parish: "Youlgreave", county: "Derbyshire"))
        try db.saveEvidence(profileID: "mary",
                            scored: ScoredRecord(id: "m", record: record,
                                                 verdict: .lead, gates: [], summary: ""),
                            citationFull: "Youlgreave Parish Register, marriage of Jacob HOLMES, 1846.",
                            citationURL: "https://freereg/m")
        let row = try #require(try ProfileSourcesLedger.allRecords(for: "mary", db: db).first)
        #expect(row.isParishMarriage, "a church marriage must reach the spouse row's evidence")
        // …and a baptism must NOT: it belongs to the birth story, not the spouse row.
        #expect(!ProfileSourcesLedger.isParishMarriage(.parish(ParishRecord(
            common: RecordCommon(id: "b", sourceID: "freereg", name: "Mary STEPHENSON",
                                 surname: "STEPHENSON", givenName: "Mary",
                                 detailURL: nil, rawFields: [:]),
            eventType: "baptism", eventYear: 1823))))
    }

    /// Non-census records carry no census year, so they never land under a
    /// census event.
    @Test func nonCensusRecordsCarryNoCensusYear() {
        let birth = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "b", sourceID: "freebmd", name: "Samuel Holmes",
                                 surname: "Holmes", givenName: "Samuel",
                                 detailURL: nil, rawFields: [:]),
            birthYear: 1847))
        #expect(ProfileSourcesLedger.censusYear(of: birth) == nil)
    }

    /// A census whose year didn't survive parsing yields nil rather than 0 —
    /// otherwise it would file itself under a "year 0" event. The Derby record
    /// rendered as "0 census · 5 in the household" for exactly this reason.
    @Test func aYearlessCensusYieldsNilNotZero() {
        let broken = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: "x", sourceID: "freecen", name: "Samuel HOLMES",
                                 surname: "HOLMES", givenName: "Samuel",
                                 detailURL: nil, rawFields: [:]),
            censusYear: 0))
        #expect(ProfileSourcesLedger.censusYear(of: broken) == nil)
    }
}
