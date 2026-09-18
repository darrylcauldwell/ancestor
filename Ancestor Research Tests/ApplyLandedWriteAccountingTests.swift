import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// EV21 follow-up (review M2) — `landedSomething` must count write OUTCOMES,
/// not plan items.
///
/// EV21's contract is that "an apply whose plan had work to do and landed
/// literally none of it is not an apply, and must not wear the badge". But the
/// `.dateField`/`.stringField` plan items set `landedSomething = true` at the
/// call site, before the write's outcome was known: `attempt` swallows every
/// throw from `editProfile`/`recordAlternativeFact`/the citation attach into
/// the failures array without affecting the flag. A birth apply whose every
/// SQLite write failed (locked DB, disk full, constraint violation) therefore
/// still stamped `applied_at` — a green "Applied" badge over zero writes, the
/// exact state EV21 is named for — while `reportApplyOutcome` correctly
/// withheld the user-status stamp, leaving the two columns in permanent
/// disagreement.
///
/// These tests break the persistence layer underneath a field apply (the
/// tables the field writes need are renamed away; `evidence_records` stays
/// intact so the stamp COULD land) and pin that the stamp follows the writes.
@MainActor
struct ApplyLandedWriteAccountingTests {

    // MARK: - Fixtures

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

    private func person(
        _ id: String, first: String, last: String, gender: Gender
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:], firstName: first, middleName: nil,
            lastName: last, marriedSurname: nil, gender: gender, attributes: nil,
            birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    /// A plain FreeBMD birth index row: its whole plan is one `.dateField`
    /// (no birthplace, no district, no name enrichment, and — unlike a
    /// census/burial — no `.lifeEvent` item to count unconditionally).
    private func birthRecord(id: String = "gladwin-1858-birth") -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(
                id: id, sourceID: "freebmd", name: "Emma Gladwin",
                surname: "Gladwin", givenName: "Emma",
                detailURL: "https://www.freebmd.org.uk/cgi/information.pl?r=\(id)",
                rawFields: [:]),
            birthYear: 1858, quarter: "Dec"))
    }

    private func scored(_ record: SourceRecord) -> ScoredRecord {
        ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
    }

    /// Break every table the field executors write (`transactions` feeds both
    /// `editProfile` and `recordAlternativeFact`; `field_sources` feeds the
    /// citation attach) while leaving `evidence_records` — and so the
    /// `applied_at` stamp — perfectly writable. RENAME, not DROP, so foreign
    /// keys can't interfere with the sabotage.
    private func breakFieldWrites(_ db: ProjectDatabase) throws {
        try db.dbQueue.write { sql in
            try sql.execute(sql: "ALTER TABLE transactions RENAME TO transactions_broken")
            try sql.execute(sql: "ALTER TABLE field_sources RENAME TO field_sources_broken")
        }
    }

    // MARK: - The defect

    /// The M2 core: every write of the birth apply throws, so nothing reaches
    /// the profile — and the evidence row must NOT be stamped applied, even
    /// though `markEvidenceApplied` itself would have succeeded.
    @Test func aFullyFailedFieldApplyIsNotStampedApplied() throws {
        let db = try makeDB()
        try db.addProfile(person("emma", first: "Emma", last: "Gladwin", gender: .female), source: .gedcom)
        let record = birthRecord()
        try db.saveEvidence(profileID: "emma", scored: scored(record),
                            citationFull: "FreeBMD birth index", citationURL: nil)
        let emma = try #require(try db.loadProfile(id: "emma"))
        let snapshot = try db.buildSnapshot()
        try breakFieldWrites(db)

        let failures = ApplyEngine.applyFactToSubject(
            scored(record), profile: emma, snapshot: snapshot, db: db)

        #expect(!failures.isEmpty, "every failed write is reported, never swallowed")
        let row = try #require(try db.loadEvidenceForProfile("emma").first)
        #expect(row.appliedAt == nil,
                "zero writes landed, so the row must not claim it was applied")
    }

    /// Control: the identical apply with a healthy database lands the birth
    /// date AND stamps the row — the fix must not under-count real writes.
    @Test func aSuccessfulFieldApplyStillStampsTheEvidenceRow() throws {
        let db = try makeDB()
        try db.addProfile(person("emma", first: "Emma", last: "Gladwin", gender: .female), source: .gedcom)
        let record = birthRecord()
        try db.saveEvidence(profileID: "emma", scored: scored(record),
                            citationFull: "FreeBMD birth index", citationURL: nil)
        let emma = try #require(try db.loadProfile(id: "emma"))

        let failures = ApplyEngine.applyFactToSubject(
            scored(record), profile: emma, snapshot: try db.buildSnapshot(), db: db)

        #expect(failures.isEmpty)
        let applied = try #require(try db.loadProfile(id: "emma"))
        #expect(applied.birthDate?.bestYear == 1858, "the registration year reached the profile")
        let row = try #require(try db.loadEvidenceForProfile("emma").first)
        #expect(row.appliedAt != nil, "a birth that landed IS applied")
    }
}
