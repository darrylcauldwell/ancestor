import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// EV21 (owner dogfood 2026-08-26) — a pre-1912 marriage index record could
/// never apply.
///
/// The GRO marriage index does not print the partner before the September 1912
/// quarter, so `spouseName` is nil on every earlier entry. The DS-12 repair
/// covered "the record STATES a spouse the tree doesn't know"; nothing covered
/// "the record states no spouse at all", and that leg fell through to a bare
/// `return` — no write, no failure, no trace — while the evidence row was
/// stamped applied and rendered a green "Applied" badge.
///
/// Live case: the owner applied a verified FreeBMD marriage for Hannah Hewkin
/// (Jun quarter 1858, Chesterfield, 7b/741). Nothing reached the profile: no
/// marriage date or location on the spouse edge, no fact, no event. Control:
/// Emma Gladwin's post-1912 marriage, which names its partner, applied fine.
///
/// These tests pin the whole outcome contract:
///   • names nobody + exactly one spouse edge → fill it (the human's call)
///   • names nobody + zero or 2+ spouse edges → write nothing, REPORT it
///     ("when in doubt, split" — a wrong marriage is invisible and unfixable)
///   • names a MISMATCHING spouse → the DS-12 dispute still opens, untouched
///   • an apply that reports failures never leaves the row stamped applied
@MainActor
struct MarriageApplyOutcomeTests {

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

    private func spouseEdge(_ a: String, _ b: String, db: ProjectDatabase) throws {
        try db.addRelationship(Relationship(
            id: UUID(), from: a, to: b, type: .spouse, role: nil,
            subtype: .unknown, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
    }

    /// The live fixture: Hannah Hewkin's own FreeBMD marriage row, Jun quarter
    /// 1858, Chesterfield 7b/741. A pre-1912 GRO index entry, so it names NO
    /// partner — `spouseName` nil, no same-page recovery, no cross-profile
    /// corroboration. This is the shape every marriage before Sep 1912 has.
    private func hannahsMarriage(id: String = "hewkin-1858-7b-741") -> SourceRecord {
        .marriage(MarriageRecord(
            common: RecordCommon(
                id: id, sourceID: "freebmd", name: "Hannah Hewkin",
                surname: "Hewkin", givenName: "Hannah",
                detailURL: "https://www.freebmd.org.uk/cgi/information.pl?r=\(id)",
                rawFields: [:]),
            marriageYear: 1858, marriageDate: nil, marriagePlace: nil,
            quarter: "Jun", district: "Chesterfield", volume: "7b", page: "741",
            spouseName: nil))
    }

    /// A post-Sep-1912 row, which DOES print the partner surname.
    private func statedSpouseMarriage(_ spouseSurname: String) -> SourceRecord {
        .marriage(MarriageRecord(
            common: RecordCommon(
                id: "post1912-m1", sourceID: "freebmd", name: "Emma Gladwin",
                surname: "Gladwin", givenName: "Emma",
                detailURL: "https://www.freebmd.org.uk/cgi/information.pl?r=post1912-m1",
                rawFields: [:]),
            marriageYear: 1920, marriageDate: nil, marriagePlace: nil,
            quarter: "Mar", district: "Worksop", volume: "7b", page: "1300",
            spouseName: spouseSurname))
    }

    private func scored(_ record: SourceRecord) -> ScoredRecord {
        ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
    }

    @discardableResult
    private func apply(
        _ record: SourceRecord, to subjectID: String, db: ProjectDatabase
    ) throws -> [ApplyEngine.WriteFailure] {
        let subject = try #require(try db.loadProfile(id: subjectID))
        return ApplyEngine.applyFactToSubject(
            scored(record), profile: subject, snapshot: try db.buildSnapshot(), db: db)
    }

    private func spouseEdges(_ db: ProjectDatabase) throws -> [Relationship] {
        try db.buildSnapshot().relationships.filter { $0.type == .spouse }
    }

    // MARK: - The defect

    /// EV21 core: a record naming no partner, and exactly ONE spouse on the
    /// tree. There is nothing to choose between, so the marriage lands on that
    /// edge — date AND place. Before the fix this wrote nothing at all.
    @Test func preNineteenTwelveMarriageFillsTheOnlySpouseEdge() throws {
        let db = try makeDB()
        try db.addProfile(person("hannah", first: "Hannah", last: "Hewkin", gender: .female), source: .gedcom)
        try db.addProfile(person("husband", first: "William", last: "Gladwin", gender: .male), source: .gedcom)
        try spouseEdge("hannah", "husband", db: db)

        let failures = try apply(hannahsMarriage(), to: "hannah", db: db)

        #expect(failures.isEmpty, "an unambiguous fill reports no failure")
        let edge = try #require(try spouseEdges(db).first)
        #expect(edge.marriageDate?.bestYear == 1858, "the registration year reached the spouse edge")
        #expect(edge.marriageDate?.original.contains("1858") == true)
        #expect(edge.marriageLocation == "Chesterfield",
                "the registration district reached the spouse edge")
    }

    /// The evidence row is stamped applied only because something landed —
    /// this is the half that made the defect invisible.
    @Test func successfulPreNineteenTwelveApplyStampsTheEvidenceRow() throws {
        let db = try makeDB()
        try db.addProfile(person("hannah", first: "Hannah", last: "Hewkin", gender: .female), source: .gedcom)
        try db.addProfile(person("husband", first: "William", last: "Gladwin", gender: .male), source: .gedcom)
        try spouseEdge("hannah", "husband", db: db)
        let record = hannahsMarriage()
        try db.saveEvidence(profileID: "hannah", scored: scored(record),
                            citationFull: "FreeBMD marriage index", citationURL: nil)

        try apply(record, to: "hannah", db: db)

        let row = try #require(try db.loadEvidenceForProfile("hannah").first)
        #expect(row.appliedAt != nil, "a marriage that landed IS applied")
    }

    // MARK: - Ambiguity is reported, never guessed

    /// TWO spouses and a record that names neither. Guessing is not recoverable
    /// by the user, so nothing is written — but the outcome says why.
    @Test func twoSpouseEdgesWriteNothingAndReportTheAmbiguity() throws {
        let db = try makeDB()
        try db.addProfile(person("hannah", first: "Hannah", last: "Hewkin", gender: .female), source: .gedcom)
        try db.addProfile(person("first", first: "William", last: "Gladwin", gender: .male), source: .gedcom)
        try db.addProfile(person("second", first: "George", last: "Wheatman", gender: .male), source: .gedcom)
        try spouseEdge("hannah", "first", db: db)
        try spouseEdge("hannah", "second", db: db)

        let failures = try apply(hannahsMarriage(), to: "hannah", db: db)

        let untouched = try spouseEdges(db).allSatisfy {
            $0.marriageDate == nil && $0.marriageLocation == nil
        }
        #expect(untouched, "neither marriage was guessed at")
        #expect(failures.count == 1, "the no-op is reported exactly once")
        let message = failures.first?.error.localizedDescription ?? ""
        #expect(message.contains("2 linked spouses"), "the report names the ambiguity: \(message)")
    }

    /// NO spouse on the tree. Nothing to fill, and the report says what the
    /// user has to do first.
    @Test func zeroSpouseEdgesWriteNothingAndReportIt() throws {
        let db = try makeDB()
        try db.addProfile(person("hannah", first: "Hannah", last: "Hewkin", gender: .female), source: .gedcom)

        let failures = try apply(hannahsMarriage(), to: "hannah", db: db)

        #expect(try spouseEdges(db).isEmpty)
        #expect(failures.count == 1, "the no-op is reported, not swallowed")
        let message = failures.first?.error.localizedDescription ?? ""
        #expect(message.contains("no spouse linked"), "the report names the gap: \(message)")
        // No dispute either — "nobody is named" is an ambiguity, not two
        // sources disagreeing. DS-12 stays reserved for a STATED mismatch.
        #expect(try db.openDisputes(profileID: "hannah").isEmpty)
    }

    /// A marriage that landed nothing must not wear the applied stamp — the
    /// green badge over zero writes is the whole reason EV21 went unnoticed.
    @Test func aMarriageThatLandedNothingIsNotStampedApplied() throws {
        let db = try makeDB()
        try db.addProfile(person("hannah", first: "Hannah", last: "Hewkin", gender: .female), source: .gedcom)
        let record = hannahsMarriage()
        try db.saveEvidence(profileID: "hannah", scored: scored(record),
                            citationFull: "FreeBMD marriage index", citationURL: nil)

        try apply(record, to: "hannah", db: db)

        let row = try #require(try db.loadEvidenceForProfile("hannah").first)
        let hannah = try db.loadProfile(id: "hannah")
        #expect(row.appliedAt == nil, "nothing was written, so nothing may claim it was")
        #expect(row.wasApplied(to: hannah) == false, "the badge the ledger reads must agree")
    }

    // MARK: - DS-12 is untouched (mandatory regression guard)

    /// A post-1912 record STATING a spouse the tree doesn't know still opens
    /// the F4b spouse-identity dispute. The EV21 single-edge fill must not
    /// swallow this: the record names somebody, so "there's only one spouse,
    /// use it" is exactly the wrong answer.
    @Test func statedMismatchingSpouseStillOpensTheDSTwelveDispute() throws {
        let db = try makeDB()
        try db.addProfile(person("emma", first: "Emma", last: "Gladwin", gender: .female), source: .gedcom)
        try db.addProfile(person("husband", first: "Joseph", last: "Marshall", gender: .male), source: .gedcom)
        try spouseEdge("emma", "husband", db: db)

        // The record names SANDERS; the tree's only spouse is MARSHALL.
        let failures = try apply(statedSpouseMarriage("Sanders"), to: "emma", db: db)

        let disputes = try db.openDisputes(profileID: "emma")
        #expect(disputes.count == 1, "the DS-12 spouse-identity dispute still opens")
        #expect(disputes.first?.kind == .spouseIdentity)
        #expect(disputes.first?.field == "spouse")
        let reportedMismatch = failures.contains { $0.what == "Marriage record spouse mismatch" }
        #expect(reportedMismatch, "and it still reports on the outcome channel")
        let edge = try #require(try spouseEdges(db).first)
        #expect(edge.marriageDate == nil,
                "the wrong-person record is NOT written onto the only spouse edge")
    }

    /// The same guard from the other direction: a stated spouse that DOES
    /// match still fills the edge, so the DS-12 path costs nothing.
    @Test func statedMatchingSpouseStillFillsTheEdge() throws {
        let db = try makeDB()
        try db.addProfile(person("emma", first: "Emma", last: "Gladwin", gender: .female), source: .gedcom)
        try db.addProfile(person("husband", first: "Joseph", last: "Marshall", gender: .male), source: .gedcom)
        try spouseEdge("emma", "husband", db: db)

        let failures = try apply(statedSpouseMarriage("Marshall"), to: "emma", db: db)

        #expect(failures.isEmpty)
        let edge = try #require(try spouseEdges(db).first)
        #expect(edge.marriageDate?.bestYear == 1920)
        #expect(edge.marriageLocation == "Worksop")
        #expect(try db.openDisputes(profileID: "emma").isEmpty)
    }

    // MARK: - The call sites stop discarding the outcome

    /// EV21 root cause 2: `applyEvidenceRecord` dropped the engine's result
    /// with `_ =` and stamped `saved_as_lead` unconditionally. An apply that
    /// reported failures must leave the row where it was.
    @Test func applyEvidenceRecordDoesNotStampAFailedApply() throws {
        let db = try makeDB()
        try db.addProfile(person("hannah", first: "Hannah", last: "Hewkin", gender: .female), source: .gedcom)
        let record = hannahsMarriage()
        try db.saveEvidence(profileID: "hannah", scored: scored(record),
                            citationFull: "FreeBMD marriage index", citationURL: nil)

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()
        appState.applyEvidenceRecord(sourceRecordID: record.id, profileID: "hannah")

        let row = try #require(try db.loadEvidenceForProfile("hannah").first)
        #expect(row.userStatus != .savedAsLead,
                "a record that wrote nothing must not move into the applied bucket")
        #expect(appState.errorMessage != nil, "and the user is told why")
    }

    /// Positive control for the same call site — a successful apply behaves
    /// exactly as before: stamped, and the marriage on the edge.
    @Test func applyEvidenceRecordStillStampsASuccessfulApply() throws {
        let db = try makeDB()
        try db.addProfile(person("hannah", first: "Hannah", last: "Hewkin", gender: .female), source: .gedcom)
        try db.addProfile(person("husband", first: "William", last: "Gladwin", gender: .male), source: .gedcom)
        try spouseEdge("hannah", "husband", db: db)
        let record = hannahsMarriage()
        try db.saveEvidence(profileID: "hannah", scored: scored(record),
                            citationFull: "FreeBMD marriage index", citationURL: nil)

        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = try db.buildSnapshot()
        appState.applyEvidenceRecord(sourceRecordID: record.id, profileID: "hannah")

        let row = try #require(try db.loadEvidenceForProfile("hannah").first)
        #expect(row.userStatus == .savedAsLead)
        #expect(appState.errorMessage == nil)
        let edge = try #require(try spouseEdges(db).first)
        #expect(edge.marriageDate?.bestYear == 1858)
        #expect(edge.marriageLocation == "Chesterfield")
    }
}
