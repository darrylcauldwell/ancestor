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
