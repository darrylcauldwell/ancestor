import Testing
import Dependencies
import Foundation
import CloudKit
import GRDB
import AncestorKit
@testable import Ancestor_Research

// PUBLISHER_SPEC Change 4 acceptance — LIVE end-to-end against the
// CloudKit development environment, using a FIXTURE tree (never a real
// project). Env-gated like the Change 3 spike:
//   env TEST_RUNNER_RUN_PUBLISH_E2E=1 xcodebuild test ... -parallel-testing-enabled NO
// Each run uses a fresh project UUID = fresh zone, so runs never collide;
// dev-environment zones are disposable (reset-schema wipes them).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_PUBLISH_E2E"] == "1"))
struct PublishEngineE2ETests {

    @Test func publishThenDeltaRepublish() async throws {
        // CRITICAL: swift-dependencies detects the TEST context and
        // sqlite-data then substitutes MockCloudContainer/MockSyncEngine —
        // instant fake acks, nothing touches Apple's servers. These suites
        // exist precisely to hit the real development environment, so
        // force live context before any engine is created.
        prepareDependencies { $0.context = .live }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ProjectDatabase(path: dir.appendingPathComponent("p.sqlite").path)
        let projectID = UUID()

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

        // Publish 1 — everything new.
        let first = try await PublishEngine.publish(
            projectID: projectID, db: db,
            mediaSourceDirectory: dir.appendingPathComponent("media"),
            progress: { print("E2E publish 1: \($0)") })
        #expect(first.generation == 1)
        #expect(first.stats.inserted == 4 && first.ackedRecords == first.totalRecords)
        print("E2E PASS 1 — generation 1, \(first.ackedRecords)/\(first.totalRecords) acked")

        // Publish 2 — one field changed; only the person + manifest move.
        _ = try db.editProfile(
            profileID: "@G@",
            changes: [(field: .birthLocation, oldValue: "Belper", newValue: "Duffield")],
            dateChanges: [],
            source: SourceOrigin(identifier: "manual"))
        let second = try await PublishEngine.publish(
            projectID: projectID, db: db,
            mediaSourceDirectory: dir.appendingPathComponent("media"),
            progress: { print("E2E publish 2: \($0)") })
        #expect(second.generation == 2, "generation strictly monotonic")
        #expect(second.stats.updated == 2 && second.stats.inserted == 0 && second.stats.deleted == 0,
                "delta republish touches only the changed person + manifest")
        #expect(second.stats.unchanged == 2)
        print("E2E PASS 2 — generation 2, delta of \(second.stats.updated) updates only")

        // Publish 3 — no changes at all: nothing moves but the manifest
        // (its publishedAtISO/generation), proving no-op cheapness.
        let third = try await PublishEngine.publish(
            projectID: projectID, db: db,
            mediaSourceDirectory: dir.appendingPathComponent("media"),
            progress: { _ in })
        #expect(third.generation == 3)
        #expect(third.stats.updated == 1 && third.stats.unchanged == 3,
                "idle republish moves only the manifest row")
        print("E2E PASS 3 — idle republish is manifest-only traffic")

        // Change 5 — share lifecycle. share() is idempotent (same share on
        // repeat call); unpublish deletes the zone; a republish after
        // unpublish keeps every record UUID (§4.1 permanence) and continues
        // the generation sequence (monotonic through unpublish).
        // DIAGNOSTIC — exact CK coordinates the sync engine recorded.
        let store = try PublishedStore.open(projectID: projectID)
        let metaRows = try await store.db.read { database in
            try Row.fetchAll(database, sql: """
                SELECT recordName, zoneName, ownerName,
                       lastKnownServerRecord IS NOT NULL AS acked
                FROM sqlitedata_icloud_metadata
                """)
        }
        for row in metaRows {
            print("E2E META: name=\(row["recordName"] as String? ?? "?") zone=\(row["zoneName"] as String? ?? "?") owner=\(row["ownerName"] as String? ?? "?") acked=\(row["acked"] as Bool? ?? false)")
        }
        let zones = try await CKContainer(identifier: PublishEngine.containerID)
            .privateCloudDatabase.allRecordZones()
        for zone in zones {
            print("E2E ZONE ON SERVER: \(zone.zoneID.zoneName) owner=\(zone.zoneID.ownerName)")
        }

        if let manifestMeta = metaRows.first(where: { (($0["recordName"] as String?) ?? "").contains("anifest") }) {
            let name: String = manifestMeta["recordName"]
            let zone: String = manifestMeta["zoneName"]
            let owner: String = manifestMeta["ownerName"]
            let directID = CKRecord.ID(recordName: name,
                                       zoneID: CKRecordZone.ID(zoneName: zone, ownerName: owner))
            do {
                let fetched = try await CKContainer(identifier: PublishEngine.containerID)
                    .privateCloudDatabase.record(for: directID)
                print("E2E DIRECT FETCH OK: type=\(fetched.recordType) name=\(fetched.recordID.recordName)")
            } catch {
                print("E2E DIRECT FETCH FAIL: \((error as NSError).code) for \(name) @ \(zone)/\(owner)")
            }
        }

        let share1: CKShare
        do {
            (share1, _) = try await PublishSharing.share(
                projectID: projectID, projectName: "E2E Fixture", db: db)
        } catch {
            let ns = error as NSError
            print("E2E SHARE FAIL detail: \(ns.domain) \(ns.code) userInfo=\(ns.userInfo)")
            throw error
        }
        let (share2, _) = try await PublishSharing.share(
            projectID: projectID, projectName: "E2E Fixture", db: db)
        #expect(share1.recordID == share2.recordID, "share() must reuse the existing share")
        print("E2E PASS 4 — share created and idempotent: \(share1.recordID.recordName)")

        let identityBefore = try db.loadPublishedIdentityMap()
        try await PublishSharing.unpublish(projectID: projectID)
        #expect(!PublishSharing.hasPublishedStore(projectID: projectID))
        // Idempotent unpublish.
        try await PublishSharing.unpublish(projectID: projectID)
        print("E2E PASS 5 — unpublish removed zone + local store, idempotently")

        // CloudKit zone deletion is eventually consistent — brief pause
        // before recreating the same zone name.
        try await Task.sleep(for: .seconds(5))
        let fourth = try await PublishEngine.publish(
            projectID: projectID, db: db,
            mediaSourceDirectory: dir.appendingPathComponent("media"),
            progress: { _ in })
        #expect(fourth.generation == 4, "generation continues through unpublish")
        #expect(fourth.stats.inserted == 4, "fresh store repopulates fully")
        let identityAfter = try db.loadPublishedIdentityMap()
        #expect(identityBefore == identityAfter, "record UUIDs survive unpublish — §4.1")
        print("E2E PASS 6 — republish after unpublish: generation 4, identical identities")
    }
}
