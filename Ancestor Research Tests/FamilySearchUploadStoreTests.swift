import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
@testable import AncestorKit

/// v52 upload bookkeeping (WL3 — FAMILYSEARCH_TREES_WRITE_SPEC §5): run
/// round-trip + resume anchor, person-link upsert + E1 dual-write, entity
/// links, and the resume queries the orchestrator is built on.
struct FamilySearchUploadStoreTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func seedProfile(_ id: String, into db: ProjectDatabase) throws {
        let profile = Profile(
            id: id, firstName: "Ernest", lastName: "Cauldwell", gender: .male,
            birthDate: GenealogicalDate(parsing: "1887"),
            deathDate: GenealogicalDate(parsing: "1955"),
            isDeleted: false, sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
    }

    @Test func uploadRunRoundTripsAndUpserts() throws {
        let db = try makeTempDB()
        var run = FSTreeUploadRecord(
            id: UUID().uuidString, environment: "beta", fsGroupID: nil, fsTreeID: nil,
            treeName: "Cauldwell Tree", treeDescription: "test", startingProfileID: nil,
            isPrivate: nil, phase: "created", startedAt: Date(), finalizedAt: nil,
            personsUploaded: 0, relationshipsUploaded: 0, sourcesUploaded: 0)
        try db.saveFamilySearchUploadRun(run)

        run.fsGroupID = "9MMN-C68"
        run.fsTreeID = "9NMM-9D6C"
        run.phase = "uploading"
        run.personsUploaded = 12
        try db.saveFamilySearchUploadRun(run)   // upsert, same id

        let loaded = try #require(try db.latestFamilySearchUploadRun(environment: "beta"))
        #expect(loaded.id == run.id)
        #expect(loaded.fsTreeID == "9NMM-9D6C")
        #expect(loaded.phase == "uploading")
        #expect(loaded.personsUploaded == 12)
        #expect(loaded.isPrivate == nil)
        #expect(try db.latestFamilySearchUploadRun(environment: "production") == nil)
    }

    @Test func personLinkUpsertsAndFeedsResumeQuery() throws {
        let db = try makeTempDB()
        try seedProfile("@I1@", into: db)
        try seedProfile("@I2@", into: db)
        try db.recordFamilySearchPersonLink(profileID: "@I1@", fsTreeID: "T1", fsPID: "AAAA-111")
        try db.recordFamilySearchPersonLink(profileID: "@I2@", fsTreeID: "T1", fsPID: "BBBB-222")
        try db.recordFamilySearchPersonLink(profileID: "@I1@", fsTreeID: "T1", fsPID: "AAAA-999")  // re-record wins

        let links = try db.familySearchPersonLinks(fsTreeID: "T1")
        #expect(links == ["@I1@": "AAAA-999", "@I2@": "BBBB-222"])
        #expect(try db.familySearchPersonLinks(fsTreeID: "OTHER").isEmpty)
    }

    @Test func personLinkDualWritesE1ExternalIdentifier() throws {
        let db = try makeTempDB()
        try seedProfile("@I1@", into: db)
        try db.recordFamilySearchPersonLink(profileID: "@I1@", fsTreeID: "T1", fsPID: "KWCH-9X2")

        let profile = try #require(try db.buildSnapshot().profiles["@I1@"])
        #expect(profile.externalIDs["familysearch"] == "KWCH-9X2")
        let record = try #require(profile.externalIdentifiers.first { $0.system == "familysearch" })
        #expect(record.value == "KWCH-9X2")
    }

    @Test func entityLinksKeyByKindAndTree() throws {
        let db = try makeTempDB()
        try db.recordFamilySearchEntityLink(localKey: "couple|@A@+@B@", fsTreeID: "T1", kind: "couple", fsID: "R1")
        try db.recordFamilySearchEntityLink(localKey: "cit|abc", fsTreeID: "T1", kind: "sourceDescription", fsID: "SD1")
        try db.recordFamilySearchEntityLink(localKey: "couple|@A@+@B@", fsTreeID: "T2", kind: "couple", fsID: "R9")

        #expect(try db.familySearchEntityLinks(fsTreeID: "T1", kind: "couple") == ["couple|@A@+@B@": "R1"])
        #expect(try db.familySearchEntityLinks(fsTreeID: "T1", kind: "sourceDescription") == ["cit|abc": "SD1"])
        #expect(try db.familySearchEntityLinks(fsTreeID: "T2", kind: "couple") == ["couple|@A@+@B@": "R9"])
    }

    @Test func fsActionRequestsDequeueOldestFirstAndClaimAtomically() throws {
        let db = try makeTempDB()
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                INSERT INTO fs_action_requests (id, kind, profile_id, status, requested_by, created_at)
                VALUES ('fsreq_2', 'hints', '@I2@', 'queued', 'mcp', ?),
                       ('fsreq_1', 'hints', '@I1@', 'queued', 'mcp', ?)
                """, arguments: [Date(timeIntervalSince1970: 200), Date(timeIntervalSince1970: 100)])
        }
        let first = try #require(db.dequeueFSActionRequest())
        #expect(first.id == "fsreq_1")   // oldest first
        #expect(first.kind == "hints")
        #expect(first.profileID == "@I1@")
        let second = try #require(db.dequeueFSActionRequest())
        #expect(second.id == "fsreq_2")  // fsreq_1 was claimed (running), not re-served
        #expect(db.dequeueFSActionRequest() == nil)
    }

    @Test func fsActionCompletionAndFailureWriteNotes() throws {
        let db = try makeTempDB()
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                INSERT INTO fs_action_requests (id, kind, status, requested_by, created_at)
                VALUES ('fsreq_a', 'upload', 'queued', 'mcp', ?), ('fsreq_b', 'upload', 'queued', 'mcp', ?)
                """, arguments: [Date(), Date()])
        }
        db.markFSActionCompleted(id: "fsreq_a", note: "Uploaded HIDDEN to tree T1")
        db.markFSActionFailed(id: "fsreq_b", note: "Not signed in")
        let rows = try db.dbQueue.read { conn in
            try Row.fetchAll(conn, sql: "SELECT id, status, note, completed_at FROM fs_action_requests ORDER BY id")
        }
        #expect(rows[0]["status"] as String == "completed")
        #expect((rows[0]["note"] as String).contains("HIDDEN"))
        #expect(rows[1]["status"] as String == "failed")
        #expect(rows[1]["completed_at"] as Date? != nil)
    }

    @Test func personLinkCascadesWhenProfileIsHardDeleted() throws {
        let db = try makeTempDB()
        try seedProfile("@I1@", into: db)
        try db.recordFamilySearchPersonLink(profileID: "@I1@", fsTreeID: "T1", fsPID: "AAAA-111")
        try db.dbQueue.write { conn in
            try conn.execute(sql: "DELETE FROM profiles WHERE id = '@I1@'")
        }
        #expect(try db.familySearchPersonLinks(fsTreeID: "T1").isEmpty)
    }
}
