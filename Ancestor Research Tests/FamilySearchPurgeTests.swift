import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// v59 — FamilySearch was dropped as a record source (2026-08-07) but the old
/// FS record-search evidence was never purged, so it lingered in review as
/// description-less "Skipped" rows (owner report 2026-08-12, Mary Ward). The
/// purge removes ONLY FS record rows; other sources and the FS tree integration
/// are untouched.
@MainActor
struct FamilySearchPurgeTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func birthScored(id: String, sourceID: String) -> ScoredRecord {
        let rec = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: id, sourceID: sourceID, name: "Mary Ward",
                                 surname: "Ward", givenName: "Mary", rawFields: [:]),
            birthYear: 1885, birthDate: nil, birthPlace: nil, quarter: "Dec",
            district: "Ashborne", volume: "7b", page: "662", mothersMaidenName: nil))
        return ScoredRecord(id: id, record: rec, verdict: .lead, gates: [], summary: "s")
    }

    @Test func purgesFamilySearchEvidenceKeepsOtherSources() throws {
        let db = try makeDB()
        _ = try db.addProfile(
            Profile(id: "p", firstName: "Mary", lastName: "Ward", gender: .female,
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .gedcom)

        try db.saveEvidence(profileID: "p", scored: birthScored(id: "fs_b1", sourceID: "familysearch"),
                            citationFull: "FamilySearch record", citationURL: nil)
        try db.saveEvidence(profileID: "p", scored: birthScored(id: "bmd_b1", sourceID: "freebmd"),
                            citationFull: "FreeBMD record", citationURL: "https://www.freebmd.org.uk/x")

        // Precondition: both present.
        var evidence = try db.loadEvidenceForProfile("p")
        #expect(evidence.contains { $0.sourceID == "familysearch" })
        #expect(evidence.contains { $0.sourceID == "freebmd" })

        try db.purgeFamilySearchRecordEvidence()

        evidence = try db.loadEvidenceForProfile("p")
        #expect(!evidence.contains { $0.sourceID == "familysearch" }, "FS record evidence must be gone")
        #expect(evidence.contains { $0.sourceID == "freebmd" }, "other sources must be preserved")
    }

    @Test func purgeIsIdempotentAndSafeWhenNoFSRows() throws {
        let db = try makeDB()
        _ = try db.addProfile(
            Profile(id: "p", firstName: "Mary", lastName: "Ward", gender: .female,
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .gedcom)
        try db.saveEvidence(profileID: "p", scored: birthScored(id: "bmd_b1", sourceID: "freebmd"),
                            citationFull: "FreeBMD record", citationURL: nil)
        // Running it twice with no FS rows must not throw or remove anything.
        try db.purgeFamilySearchRecordEvidence()
        try db.purgeFamilySearchRecordEvidence()
        #expect(try db.loadEvidenceForProfile("p").contains { $0.sourceID == "freebmd" })
    }
}
