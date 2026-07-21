import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// PROFILE_SOURCES_LEDGER_SPEC Changes 1+3+4 — per-record removal. Each test
/// applies a record through the REAL apply path (ApplyEngine + the caller's
/// life-event loop, mirroring applyRecord), then removes it and asserts the
/// directional inversion: sole-source values revert, corroborations drop
/// their row but keep the value, shared rows survive, life events vanish,
/// rejection memory is fed, and the ledger entry disappears.
@MainActor
struct RecordRemovalTests {

    // MARK: - Scaffolding

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
        }
        return db
    }

    private func profile(id: String = "p", first: String? = "George", birth: String? = nil) -> Profile {
        Profile(id: id, externalIDs: [:], firstName: first, middleName: nil,
                lastName: "Brooks", gender: .male, attributes: nil,
                birthDate: birth.map { GenealogicalDate(parsing: $0) }, birthLocation: nil,
                deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    private func birthRecord(_ id: String, year: Int, district: String = "Belper") -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(id: id, sourceID: "freebmd", surname: "Brooks",
                                 givenName: "George", rawFields: [:]),
            birthYear: year, birthDate: nil, birthPlace: district,
            quarter: "Dec", district: district, volume: "7a", page: "631",
            mothersMaidenName: nil))
    }

    private func censusRecord(_ id: String, year: Int) -> SourceRecord {
        .census(CensusRecord(
            common: RecordCommon(id: id, sourceID: "freecen", surname: "Brooks",
                                 givenName: "George", rawFields: [:]),
            censusYear: year, birthYear: year - 20))
    }

    private func marriageRecord(_ id: String, spouse: String?) -> SourceRecord {
        .marriage(MarriageRecord(
            common: RecordCommon(id: id, sourceID: "freebmd", surname: "Brooks",
                                 givenName: "George", rawFields: [:]),
            marriageYear: 1911, marriageDate: nil, marriagePlace: nil,
            quarter: "Dec", district: "Belper", volume: "7b", page: "1397",
            spouseName: spouse))
    }

    /// Apply through the real path (ApplyEngine + life-event loop, like
    /// applyRecord) and mark kept, then return the evidence row.
    private func applyAndKeep(_ record: SourceRecord, db: ProjectDatabase, profileID: String = "p") throws -> EvidenceRecord {
        let scored = ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
        try db.saveEvidence(profileID: profileID, scored: scored, citationFull: "test citation", citationURL: nil)
        try db.updateEvidenceUserStatus(profileID: profileID, sourceRecordIDs: [record.id], status: .savedAsLead)
        let subject = try #require(try db.loadProfile(id: profileID))
        _ = ApplyEngine.applyFactToSubject(scored, profile: subject, snapshot: try db.buildSnapshot(), db: db)
        for event in record.projectToLifeEvents(profileID: profileID) {
            _ = try db.addLifeEventIfAbsent(event)
        }
        return try #require(try db.loadEvidenceForProfile(profileID)
            .first { $0.sourceRecordID == record.id })
    }

    private func fieldSourceRows(_ db: ProjectDatabase, field: ProfileField, profileID: String = "p") throws -> [(origin: String, raw: String)] {
        try db.dbQueue.read { sql in
            try Row.fetchAll(sql, sql: "SELECT origin, raw FROM field_sources WHERE entity_id = ? AND field = ?",
                             arguments: [profileID, field.rawValue])
                .map { ($0["origin"] as String, $0["raw"] as String) }
        }
    }

    // MARK: - Change 3: directional revert

    /// Sole-source removal: the record set birth date + place on an empty
    /// profile; removal reverts both to empty and drops the rows.
    @Test func soleSourceRemovalRevertsToEmpty() throws {
        let db = try makeDB()
        try db.addProfile(profile(), source: .gedcom)
        let evidence = try applyAndKeep(birthRecord("b1", year: 1883), db: db)
        #expect(try #require(try db.loadProfile(id: "p")).birthDate?.original == "Dec 1883")

        let report = try db.removeAppliedRecord(evidence)

        let after = try #require(try db.loadProfile(id: "p"))
        #expect(after.birthDate == nil)
        #expect(after.birthLocation == nil)
        #expect(report.revertedFields.contains(.birthDate))
        #expect(report.revertedFields.contains(.birthLocation))
        #expect(try fieldSourceRows(db, field: .birthDate).isEmpty)
        #expect(try fieldSourceRows(db, field: .birthLocation).isEmpty)
    }

    /// Prior-value restore: a GEDCOM year-precision date was narrowed by the
    /// record; removal restores the import value (from field_changes) and the
    /// import's own provenance row survives.
    @Test func removalRestoresDisplacedImportValue() throws {
        let db = try makeDB()
        try db.addProfile(profile(birth: "1884"), source: .gedcom)
        let evidence = try applyAndKeep(birthRecord("b1", year: 1883), db: db)
        #expect(try #require(try db.loadProfile(id: "p")).birthDate?.original == "Dec 1883",
                "quarter-precision narrows the import year")

        let report = try db.removeAppliedRecord(evidence)

        let after = try #require(try db.loadProfile(id: "p"))
        #expect(after.birthDate?.original == "1884", "import value restored")
        #expect(report.revertedFields.contains(.birthDate))
        let rows = try fieldSourceRows(db, field: .birthDate)
        #expect(rows.contains { $0.origin == "gedcom" }, "import provenance survives")
        #expect(!rows.contains { $0.origin == "freebmd" })
    }

    /// Corroborating-only removal: the record's date was refused (equal
    /// precision) and landed as an alternative row — removal drops the row,
    /// the column value is untouched.
    @Test func corroboratingRemovalKeepsValueDropsRow() throws {
        let db = try makeDB()
        try db.addProfile(profile(birth: "Dec 1883"), source: .manual)
        let evidence = try applyAndKeep(birthRecord("b1", year: 1883), db: db)

        let report = try db.removeAppliedRecord(evidence)

        let after = try #require(try db.loadProfile(id: "p"))
        #expect(after.birthDate?.original == "Dec 1883", "user value untouched")
        #expect(!report.revertedFields.contains(.birthDate))
        #expect(!(try fieldSourceRows(db, field: .birthDate).contains { $0.origin == "freebmd" }))
    }

    /// Order safety: record A's value was later displaced by record B —
    /// removing A must not touch the column (B owns it).
    @Test func removalNeverRevertsAnotherRecordsValue() throws {
        let db = try makeDB()
        try db.addProfile(profile(), source: .gedcom)
        let evidenceA = try applyAndKeep(censusRecord("c1", year: 1901), db: db)   // implied birth, wide
        _ = try applyAndKeep(birthRecord("b1", year: 1883), db: db)                // precise, displaces

        let before = try #require(try db.loadProfile(id: "p")).birthDate?.original
        _ = try db.removeAppliedRecord(evidenceA)
        let after = try #require(try db.loadProfile(id: "p"))
        #expect(after.birthDate?.original == before, "record B's value stays live")
    }

    /// Shared corroboration: two kept records from the same source emit the
    /// same (field, value) — removing one keeps the shared row for the other.
    @Test func sharedCorroborationRowSurvives() throws {
        let db = try makeDB()
        try db.addProfile(profile(), source: .gedcom)
        let evidence1 = try applyAndKeep(birthRecord("b1", year: 1883), db: db)
        _ = try applyAndKeep(birthRecord("b2", year: 1883), db: db)  // same value, deduped row

        let report = try db.removeAppliedRecord(evidence1)

        #expect(report.sharedFields.contains(.birthDate))
        let rows = try fieldSourceRows(db, field: .birthDate)
        #expect(rows.contains { $0.origin == "freebmd" && $0.raw == "Dec 1883" },
                "the surviving record's corroboration row stays")
        let after = try #require(try db.loadProfile(id: "p"))
        #expect(after.birthDate?.original == "Dec 1883")
    }

    /// Life events minted by the record (census + occupation/residence
    /// discriminators) are deleted with it.
    @Test func removalDeletesRecordLifeEvents() throws {
        let db = try makeDB()
        try db.addProfile(profile(), source: .gedcom)
        let evidence = try applyAndKeep(censusRecord("c1", year: 1901), db: db)
        let before = try db.loadLifeEvents(profileID: "p")
        #expect(!before.isEmpty, "census projection minted events")

        let report = try db.removeAppliedRecord(evidence)

        #expect(report.deletedLifeEvents == before.count)
        #expect(try db.loadLifeEvents(profileID: "p").isEmpty)
    }

    /// Marriage-fill inversion: the record's date on the matched spouse edge
    /// is cleared on exact match.
    @Test func removalClearsMarriageFill() throws {
        let db = try makeDB()
        try db.addProfile(profile(), source: .gedcom)
        try db.addProfile(profile(id: "s", first: "Ida"), source: .gedcom)
        _ = try db.addRelationship(Relationship(
            id: UUID(), from: "p", to: "s", type: .spouse, role: nil,
            subtype: .biological, marriageDate: nil, marriageLocation: nil, divorceDate: nil))
        let evidence = try applyAndKeep(marriageRecord("m1", spouse: "Brooks"), db: db)

        let filled = try db.dbQueue.read { sql in
            try String.fetchOne(sql, sql: "SELECT marriage_date_original FROM relationships WHERE type='spouse'")
        }
        #expect(filled == "Dec 1911", "apply filled the edge")

        let report = try db.removeAppliedRecord(evidence)
        #expect(report.clearedMarriageDate)
        let after = try db.dbQueue.read { sql in
            try String.fetchOne(sql, sql: "SELECT marriage_date_original FROM relationships WHERE type='spouse'")
        }
        #expect(after == nil)
    }

    /// A record whose value coincides with a value some OTHER origin set
    /// (here a GEDCOM import) landed as an alternative-only row — removal must
    /// drop the row but NEVER clear the column, because the record never
    /// owned it. Guards the "column set by another origin" case.
    @Test func removalNeverClearsValueSetByAnotherOrigin() throws {
        let db = try makeDB()
        try db.addProfile(profile(birth: "Dec 1883"), source: .gedcom)  // gedcom row + column
        let evidence = try applyAndKeep(birthRecord("b1", year: 1883), db: db)  // freebmd "Dec 1883" == gedcom → alternative only

        let report = try db.removeAppliedRecord(evidence)

        let after = try #require(try db.loadProfile(id: "p"))
        #expect(after.birthDate?.original == "Dec 1883", "the GEDCOM value survives")
        #expect(!report.revertedFields.contains(.birthDate))
        let rows = try fieldSourceRows(db, field: .birthDate)
        #expect(rows.contains { $0.origin == "gedcom" }, "gedcom provenance intact")
        #expect(!rows.contains { $0.origin == "freebmd" }, "record's alternative row dropped")
    }

    // MARK: - Change 4: rejection memory + ledger

    /// Removal feeds both rejection stores and drops the ledger entry.
    @Test func removalFeedsRejectionMemoryAndLedger() throws {
        let db = try makeDB()
        try db.addProfile(profile(), source: .gedcom)
        let evidence = try applyAndKeep(birthRecord("b1", year: 1883), db: db)
        #expect(try ProfileSourcesLedger.entries(for: "p", db: db).count == 1)

        _ = try db.removeAppliedRecord(evidence)

        #expect(try db.loadRejections(profileID: "p").contains("b1"))
        #expect(try ProfileSourcesLedger.entries(for: "p", db: db).isEmpty,
                "discarded records leave the ledger")
        let status = try db.loadEvidenceForProfile("p").first { $0.sourceRecordID == "b1" }?.userStatus
        #expect(status == .discarded)
    }

    /// Open fieldValue disputes on a touched field are dissolved, and the
    /// conflict sweep does not resurrect a dispute from discarded evidence.
    @Test func removalDissolvesDisputesAndSweepHonoursDiscard() throws {
        let db = try makeDB()
        try db.addProfile(profile(), source: .gedcom)
        // A marriage record whose spouse surname matches no edge opens a
        // spouseIdentity dispute at apply time (DS-12).
        let evidence = try applyAndKeep(marriageRecord("m1", spouse: "Land"), db: db)
        #expect(try db.openDisputes(profileID: "p").isEmpty == false, "apply opened DS-12")

        let report = try db.removeAppliedRecord(evidence)
        #expect(report.dissolvedDisputes >= 1)
        #expect(try db.openDisputes(profileID: "p").isEmpty)

        // Force sweep must not re-derive from the now-discarded evidence.
        let snapshot = try db.buildSnapshot()
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)
        #expect(try db.openDisputes(profileID: "p").isEmpty,
                "discarded evidence no longer drives conflict detection")
    }

    /// Name-enrichment inversion: the fuller-name alternative row and the
    /// middle-name gap-fill are reverted with the record even though the
    /// current profile state would no longer emit those plan items.
    @Test func removalRevertsNameEnrichment() throws {
        let db = try makeDB()
        try db.addProfile(profile(first: "Geoff"), source: .manual)
        let record = SourceRecord.marriage(MarriageRecord(
            common: RecordCommon(id: "m1", sourceID: "freebmd", surname: "Bonsall",
                                 givenName: "GEOFFREY W", rawFields: [:]),
            marriageYear: 1955, marriageDate: nil, marriagePlace: nil,
            quarter: nil, district: "Bakewell", volume: nil, page: nil,
            spouseName: nil))
        let evidence = try applyAndKeep(record, db: db)
        var now = try #require(try db.loadProfile(id: "p"))
        #expect(now.middleName == "W", "gap-fill applied")
        #expect(try fieldSourceRows(db, field: .firstName).contains { $0.raw == "Geoffrey" })

        _ = try db.removeAppliedRecord(evidence)

        now = try #require(try db.loadProfile(id: "p"))
        #expect(now.firstName == "Geoff")
        #expect(now.middleName == nil, "gap-fill reverted to empty")
        #expect(!(try fieldSourceRows(db, field: .firstName).contains { $0.raw == "Geoffrey" }),
                "fuller-name alternative row removed")
    }

    /// A record that was never applied to this field (no matching rows) is a
    /// clean no-op on the profile columns.
    @Test func removalOfUnappliedItemsIsNoOp() throws {
        let db = try makeDB()
        try db.addProfile(profile(birth: "1884"), source: .gedcom)
        // Saved as lead but never applied — no field_sources rows exist.
        let record = birthRecord("b1", year: 1883)
        let scored = ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
        try db.saveEvidence(profileID: "p", scored: scored, citationFull: "c", citationURL: nil)
        try db.updateEvidenceUserStatus(profileID: "p", sourceRecordIDs: ["b1"], status: .savedAsLead)
        let evidence = try #require(try db.loadEvidenceForProfile("p").first)

        let report = try db.removeAppliedRecord(evidence)

        #expect(report.revertedFields.isEmpty)
        #expect(try #require(try db.loadProfile(id: "p")).birthDate?.original == "1884")
        #expect(try db.loadRejections(profileID: "p").contains("b1"),
                "rejection memory still recorded")
    }
}
