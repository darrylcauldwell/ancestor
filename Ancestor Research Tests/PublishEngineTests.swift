import Testing
import Foundation
import CloudKit
import GRDB
import AncestorKit
@testable import Ancestor_Research

// PUBLISHER_SPEC Change 4 — offline engine tests. The CloudKit seams are
// injected, so everything here runs hermetically: store diffing
// (update-in-place, presence deletes, checksum skip), the second-Mac
// generation guard, and the full orchestration against a fake cloud.
@MainActor
struct PublishEngineTests {

    // MARK: - Fixtures

    private func makeWorkspace() throws -> (db: ProjectDatabase, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("media"), withIntermediateDirectories: true)
        let db = try ProjectDatabase(path: dir.appendingPathComponent("p.sqlite").path)
        let george = Profile(
            id: "@G@", externalIDs: [:], firstName: "George", lastName: "Brooks",
            gender: .male,
            birthDate: GenealogicalDate(parsing: "1883"), birthLocation: "Belper",
            deathDate: GenealogicalDate(parsing: "1946"), deathLocation: "Derby",
            isDeleted: false, sources: [:], disputes: [:])
        let ida = Profile(
            id: "@I@", externalIDs: [:], firstName: "Ida", lastName: "Land",
            gender: .female,
            birthDate: GenealogicalDate(parsing: "1888"), birthLocation: "Belper",
            deathDate: GenealogicalDate(parsing: "1970"), deathLocation: "Belper",
            isDeleted: false, sources: [:], disputes: [:])
        _ = try db.addProfile(george, source: SourceOrigin(identifier: "gedcom"))
        _ = try db.addProfile(ida, source: SourceOrigin(identifier: "gedcom"))
        _ = try db.addRelationship(Relationship(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
            from: "@G@", to: "@I@", type: .spouse, role: nil, subtype: .biological,
            marriageDate: GenealogicalDate(parsing: "1912"),
            marriageLocation: "Belper", divorceDate: nil))
        return (db, dir)
    }

    private func offlineSeams(serverGeneration: Int? = nil) -> PublishCloudSeams {
        PublishCloudSeams(
            accountStatus: { .available },
            serverGeneration: { _ in serverGeneration }
        )
    }

    private func project(db: ProjectDatabase, generation: Int) throws -> (PublishedTree, String) {
        var (inputs, identity) = try PublishInputs.load(
            db: db, now: Date(timeIntervalSince1970: 1_780_000_000), generation: generation)
        let tree = PublishedTree.project(inputs, identity: &identity)
        let manifestID = identity.uuid(
            kind: PublishEngine.manifestIdentityKind,
            canonicalID: PublishEngine.manifestIdentityCanonical)
        try db.savePublishedIDs(identity.minted)
        return (tree, manifestID)
    }

    // MARK: - Store diffing

    @Test func firstApplyInsertsEverythingSecondApplyTouchesNothing() throws {
        let (db, dir) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PublishedStore.open(at: dir.appendingPathComponent("s.publish.sqlite"))
        let (tree, manifestID) = try project(db: db, generation: 1)

        let first = try store.apply(tree: tree, manifestID: manifestID,
                                    mediaSourceDirectory: dir.appendingPathComponent("media"))
        #expect(first.inserted == 4 && first.updated == 0 && first.deleted == 0,
                "manifest + 2 persons + 1 relationship")

        let second = try store.apply(tree: tree, manifestID: manifestID,
                                     mediaSourceDirectory: dir.appendingPathComponent("media"))
        #expect(second.inserted == 0 && second.updated == 0 && second.deleted == 0)
        #expect(second.unchanged == 4, "identical projection generates zero CloudKit traffic")
    }

    @Test func changedRowUpdatesInPlaceNeverDeleteReinsert() throws {
        let (db, dir) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PublishedStore.open(at: dir.appendingPathComponent("s.publish.sqlite"))
        let (tree, manifestID) = try project(db: db, generation: 1)
        _ = try store.apply(tree: tree, manifestID: manifestID,
                            mediaSourceDirectory: dir.appendingPathComponent("media"))

        // rowids prove update-in-place: DELETE+INSERT would mint new rowids
        // (sqlite-data #418 — the pattern the spec forbids).
        let rowidsBefore = try store.db.read {
            try Row.fetchAll($0, sql: "SELECT id, rowid FROM publishedPersons ORDER BY id")
        }

        _ = try db.editProfile(
            profileID: "@G@",
            changes: [(field: .birthLocation, oldValue: "Belper", newValue: "Duffield")],
            dateChanges: [],
            source: SourceOrigin(identifier: "manual"))
        let (tree2, _) = try project(db: db, generation: 2)
        let stats = try store.apply(tree: tree2, manifestID: manifestID,
                                    mediaSourceDirectory: dir.appendingPathComponent("media"))
        #expect(stats.updated == 2, "changed person + manifest (generation)")
        #expect(stats.inserted == 0 && stats.deleted == 0)

        let rowidsAfter = try store.db.read {
            try Row.fetchAll($0, sql: "SELECT id, rowid FROM publishedPersons ORDER BY id")
        }
        for (before, after) in zip(rowidsBefore, rowidsAfter) {
            #expect(before["rowid"] as Int64? == after["rowid"] as Int64?,
                    "same primary key must keep its rowid — update-in-place")
        }
    }

    @Test func policyFlipToOmitDeletesPersonAndEdges() throws {
        let (db, dir) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PublishedStore.open(at: dir.appendingPathComponent("s.publish.sqlite"))
        let (tree, manifestID) = try project(db: db, generation: 1)
        _ = try store.apply(tree: tree, manifestID: manifestID,
                            mediaSourceDirectory: dir.appendingPathComponent("media"))

        try db.setPublishPolicy(profileID: "@I@", policy: .omit)
        let (tree2, _) = try project(db: db, generation: 2)
        let stats = try store.apply(tree: tree2, manifestID: manifestID,
                                    mediaSourceDirectory: dir.appendingPathComponent("media"))
        #expect(stats.deleted == 2, "Ida's person row + the spouse edge tombstone")

        let personCount = try store.db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM publishedPersons") ?? -1
        }
        #expect(personCount == 1)
    }

    // MARK: - Generation guard

    @Test func generationGuardRules() {
        // First publish: no server manifest.
        #expect(PublishEngine.generationGuardAllows(serverGeneration: nil, localGeneration: 0))
        // Normal republish: server equals local.
        #expect(PublishEngine.generationGuardAllows(serverGeneration: 3, localGeneration: 3))
        // Our own interrupted attempt: server is exactly one ahead.
        #expect(PublishEngine.generationGuardAllows(serverGeneration: 4, localGeneration: 3))
        // Another Mac has published beyond us: refuse.
        #expect(!PublishEngine.generationGuardAllows(serverGeneration: 5, localGeneration: 3))
    }

    @Test func engineAbortsWhenAnotherMacPublished() async throws {
        let (db, dir) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: PublishError.publishedFromAnotherMac(serverGeneration: 7, localGeneration: 0)) {
            _ = try await PublishEngine.publish(
                projectID: UUID(), db: db,
                mediaSourceDirectory: dir.appendingPathComponent("media"),
                seams: self.offlineSeams(serverGeneration: 7))
        }
    }

    @Test func engineAbortsWhenSignedOut() async throws {
        let (db, dir) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seams = PublishCloudSeams(
            accountStatus: { .noAccount },
            serverGeneration: { _ in nil })
        await #expect(throws: PublishError.iCloudUnavailable(rawStatus: CKAccountStatus.noAccount.rawValue)) {
            _ = try await PublishEngine.publish(
                projectID: UUID(), db: db,
                mediaSourceDirectory: dir.appendingPathComponent("media"),
                seams: seams)
        }
        #expect(try db.loadPublishGeneration() == 0, "no work happened — generation untouched")
    }

    // MARK: - Manifest identity

    @Test func manifestIdentityIsSingletonAndStable() throws {
        let (db, dir) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, firstID) = try project(db: db, generation: 1)
        let (_, secondID) = try project(db: db, generation: 2)
        #expect(firstID == secondID, "manifest UUID persists in published_ids across publishes")
    }
}
