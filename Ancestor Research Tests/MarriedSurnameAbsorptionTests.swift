import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// Married-surname absorption (owner request 2026-07-21): applying a marriage
/// record now fills the female partner's married surname from the male
/// partner's, as part of the same absorption that fills the spouse edge —
/// cited to the record, gap-fill only. Previously this was left entirely to
/// the MarriedSurnameFromSpouseRule Tasks one-click; George Brooks's wife Mary
/// Vallance was added with no married surname and it never populated on apply.
@MainActor
struct MarriedSurnameAbsorptionTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
        }
        return db
    }

    private func person(_ id: String, first: String, last: String, gender: Gender,
                        married: String? = nil) -> Profile {
        Profile(id: id, externalIDs: [:], firstName: first, middleName: nil,
                lastName: last, marriedSurname: married, gender: gender, attributes: nil,
                birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func marriage(_ id: String, spouseSurname: String?) -> SourceRecord {
        .marriage(MarriageRecord(
            common: RecordCommon(id: id, sourceID: "freebmd", surname: "Brooks",
                                 givenName: "George", rawFields: [:]),
            marriageYear: 1938, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Belper", volume: "7b", page: "1000",
            spouseName: spouseSurname))
    }

    private func spouseEdge(_ from: String, _ to: String, db: ProjectDatabase) throws {
        _ = try db.addRelationship(Relationship(
            id: UUID(), from: from, to: to, type: .spouse, role: nil,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
    }

    /// Apply the marriage record to `subjectID` through the real apply path.
    private func apply(_ record: SourceRecord, to subjectID: String, db: ProjectDatabase) throws {
        let scored = ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
        let subject = try #require(try db.loadProfile(id: subjectID))
        _ = ApplyEngine.applyFactToSubject(scored, profile: subject, snapshot: try db.buildSnapshot(), db: db)
    }

    // MARK: - Tests

    /// The owner case: George Brooks (male subject) married to Mary Vallance
    /// (female, no married surname) — apply his marriage record → Mary gets
    /// married surname "Brooks".
    @Test func maleSubjectFillsWifeMarriedSurname() throws {
        let db = try makeDB()
        try db.addProfile(person("g", first: "George", last: "Brooks", gender: .male), source: .gedcom)
        try db.addProfile(person("m", first: "Mary", last: "Vallance", gender: .female), source: .gedcom)
        try spouseEdge("g", "m", db: db)

        try apply(marriage("mr1", spouseSurname: "Vallance"), to: "g", db: db)

        #expect(try #require(try db.loadProfile(id: "m")).marriedSurname == "Brooks")
        // The husband keeps his own surname — nothing written to him.
        #expect(try #require(try db.loadProfile(id: "g")).marriedSurname == nil)
    }

    /// Applying the woman's OWN marriage record fills HER married surname
    /// (she's the subject, the male partner is the surname source).
    @Test func femaleSubjectFillsOwnMarriedSurname() throws {
        let db = try makeDB()
        try db.addProfile(person("g", first: "George", last: "Brooks", gender: .male), source: .gedcom)
        try db.addProfile(person("m", first: "Mary", last: "Vallance", gender: .female), source: .gedcom)
        try spouseEdge("g", "m", db: db)

        try apply(marriage("mr1", spouseSurname: "Brooks"), to: "m", db: db)

        #expect(try #require(try db.loadProfile(id: "m")).marriedSurname == "Brooks")
    }

    /// Gap-fill only: a married surname already recorded is never overwritten.
    @Test func existingMarriedSurnameIsNotOverwritten() throws {
        let db = try makeDB()
        try db.addProfile(person("g", first: "George", last: "Brooks", gender: .male), source: .gedcom)
        try db.addProfile(person("m", first: "Mary", last: "Vallance", gender: .female, married: "Smith"), source: .manual)
        try spouseEdge("g", "m", db: db)

        try apply(marriage("mr1", spouseSurname: "Vallance"), to: "g", db: db)

        #expect(try #require(try db.loadProfile(id: "m")).marriedSurname == "Smith")
    }

    /// A same-surname couple gets no married-surname write (nothing to adopt).
    @Test func sameSurnamePartnerGetsNoWrite() throws {
        let db = try makeDB()
        try db.addProfile(person("g", first: "George", last: "Brooks", gender: .male), source: .gedcom)
        try db.addProfile(person("m", first: "Mary", last: "Brooks", gender: .female), source: .gedcom)
        try spouseEdge("g", "m", db: db)

        try apply(marriage("mr1", spouseSurname: "Brooks"), to: "g", db: db)

        #expect(try #require(try db.loadProfile(id: "m")).marriedSurname == nil)
    }

    /// Unknown-gender partner is not written (mirrors the audit's female-only
    /// convention).
    @Test func unknownGenderPartnerGetsNoWrite() throws {
        let db = try makeDB()
        try db.addProfile(person("g", first: "George", last: "Brooks", gender: .male), source: .gedcom)
        try db.addProfile(person("m", first: "Mary", last: "Vallance", gender: .unknown), source: .gedcom)
        try spouseEdge("g", "m", db: db)

        try apply(marriage("mr1", spouseSurname: "Vallance"), to: "g", db: db)

        #expect(try #require(try db.loadProfile(id: "m")).marriedSurname == nil)
    }

    /// No spouse edge → the record can't match a partner → no married-surname
    /// write (the DS-12 spouse-identity dispute path is separate).
    @Test func noSpouseEdgeNoWrite() throws {
        let db = try makeDB()
        try db.addProfile(person("g", first: "George", last: "Brooks", gender: .male), source: .gedcom)
        try db.addProfile(person("m", first: "Mary", last: "Vallance", gender: .female), source: .gedcom)
        // deliberately no edge

        try apply(marriage("mr1", spouseSurname: "Vallance"), to: "g", db: db)

        #expect(try #require(try db.loadProfile(id: "m")).marriedSurname == nil)
    }

    /// The written married surname carries the RECORD's source as provenance
    /// (evidence-tied), so it reads as derived from the marriage record.
    @Test func marriedSurnameCarriesRecordProvenance() throws {
        let db = try makeDB()
        try db.addProfile(person("g", first: "George", last: "Brooks", gender: .male), source: .gedcom)
        try db.addProfile(person("m", first: "Mary", last: "Vallance", gender: .female), source: .gedcom)
        try spouseEdge("g", "m", db: db)

        try apply(marriage("mr1", spouseSurname: "Vallance"), to: "g", db: db)

        let sources = try db.dbQueue.read { sql in
            try Row.fetchAll(sql, sql: "SELECT origin FROM field_sources WHERE entity_id = 'm' AND field = 'marriedSurname'")
                .map { $0["origin"] as String }
        }
        #expect(sources.contains("freebmd"))
    }
}
