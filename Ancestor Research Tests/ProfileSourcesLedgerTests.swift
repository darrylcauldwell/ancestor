import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// PROFILE_SOURCES_LEDGER_SPEC Change 2 — the read-only per-profile ledger:
/// kept records surface with what they establish, read from evidence_records
/// with no research run; discarded/unreviewed rows are excluded.
@MainActor
struct ProfileSourcesLedgerTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
        }
        return db
    }

    private func birth(_ id: String, year: Int, quarter: String, district: String,
                       vol: String, page: String) -> ScoredRecord {
        let common = RecordCommon(id: id, sourceID: "freebmd", name: nil,
                                  surname: "BROOKS", givenName: "GEORGE HERBERT",
                                  detailURL: nil, rawFields: [:])
        let record = SourceRecord.birth(BirthRecord(
            common: common, birthYear: year, birthDate: nil, birthPlace: district,
            quarter: quarter, district: district, volume: vol, page: page,
            mothersMaidenName: nil))
        return ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
    }

    @Test func ledgerListsKeptRecordsAndWhatTheyEstablish() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "p1", firstName: "George Herbert", lastName: "Brooks",
            gender: .male, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)

        let kept = birth("freebmd_birth_7a_631", year: 1883, quarter: "Dec",
                         district: "Belper", vol: "7a", page: "631")
        let discarded = birth("freebmd_birth_7a_602", year: 1884, quarter: "Mar",
                              district: "Belper", vol: "7a", page: "602")
        try db.saveEvidence(profileID: "p1", scored: kept,
                            citationFull: "FreeBMD, George Herbert Brooks, Dec 1883, Belper, 7a/631",
                            citationURL: "https://freebmd/631")
        try db.saveEvidence(profileID: "p1", scored: discarded,
                            citationFull: "FreeBMD, George Brooks, Mar 1884, Belper, 7a/602",
                            citationURL: nil)
        try db.updateEvidenceUserStatus(profileID: "p1", sourceRecordIDs: [kept.record.id], status: .savedAsLead)
        try db.updateEvidenceUserStatus(profileID: "p1", sourceRecordIDs: [discarded.record.id], status: .discarded)

        let entries = try ProfileSourcesLedger.entries(for: "p1", db: db)
        // Only the KEPT record is in the ledger — discarded is excluded.
        #expect(entries.map(\.id) == ["freebmd_birth_7a_631"])
        let e = entries[0]
        #expect(e.sourceID == "freebmd")
        #expect(e.recordType == .birth)
        #expect(e.citation.contains("7a/631"))
        // It shows WHAT it establishes — same absorptionPlan the write path runs,
        // so the ledger can never claim a fact the apply wouldn't land.
        #expect(e.establishes.contains { $0.contains("birth place Belper") })
        #expect(e.establishes.contains { $0.hasPrefix("birth date") })
    }

    @Test func gedcomOnlyProfileHasNoResearchRecords() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "p2", firstName: "Jane", lastName: "Doe",
            gender: .female, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        // No research applied → an empty ledger (the view shows an "imported,
        // no research records yet" state). No crash, no fabricated rows.
        #expect(try ProfileSourcesLedger.entries(for: "p2", db: db).isEmpty)
    }
}
