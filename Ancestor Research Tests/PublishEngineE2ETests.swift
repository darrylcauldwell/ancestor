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
        let storeURL = dir.appendingPathComponent("fixture.publish.sqlite")
        // Dedicated test zone: E2E must NEVER share the production zone —
        // hygiene purges here would otherwise tombstone real published
        // trees. Zone-deleting e2e-fixtures at start is always safe.
        let testZone = CKRecordZone(zoneName: "e2e-fixtures")

        // Hygiene: purge UUID-named zones left by the per-project-zone era
        // (their records bleed into every run via database-wide fetch).
        let privateDB = CKContainer(identifier: PublishEngine.containerID).privateCloudDatabase
        let staleZones = try await privateDB.allRecordZones()
            .map(\.zoneID)
            .filter { UUID(uuidString: $0.zoneName) != nil }
            // NEVER zone-delete e2e-fixtures here: recreating a just-deleted
            // zone name makes the server answer uploads with zone-deleted,
            // and the engine purges local rows — the exact first-real-publish
            // wipe, reproduced in miniature. Stray fixture rows from failed
            // runs are inert (all assertions are lineage-scoped) and each
            // successful run tombstones its own.
        if !staleZones.isEmpty {
            _ = try await privateDB.modifyRecordZones(saving: [], deleting: staleZones)
            print("E2E HYGIENE — purged \(staleZones.count) stale per-project zones")
        }

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

        // Life event + opted-in media: exercises the CKAsset upload path
        // live AND ensures the dev environment JIT-creates ALL FIVE record
        // types — production promote must never freeze a partial schema.
        _ = try db.addLifeEvent(LifeEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
            profileID: "@G@", type: .census,
            date: GenealogicalDate(parsing: "1911"), location: "Belper",
            details: .census(CensusDetails(
                household: [HouseholdMember(name: "Ida Brooks", relationship: "Wife")]))))
        try Data("e2e-portrait-bytes".utf8).write(
            to: dir.appendingPathComponent("media/portrait.jpg"))
        let attachment = AncestorKit.Attachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            filename: "portrait.jpg", mediaType: .photo, caption: "George, 1920",
            relativePath: "portrait.jpg", attachedTo: .profile(id: "@G@"),
            addedAt: Date(timeIntervalSince1970: 0))
        _ = try db.addAttachment(attachment)
        try db.setPublishMediaOptIn(attachmentID: attachment.id, optedIn: true)

        // Publish 1 — everything new.
        let first = try await PublishEngine.publish(
            projectID: projectID, db: db,
            mediaSourceDirectory: dir.appendingPathComponent("media"),
            storeURL: storeURL, defaultZone: testZone,
            progress: { print("E2E publish 1: \($0)") })
        #expect(first.generation == 1)
        #expect(first.stats.inserted == 6, "manifest + 2 persons + edge + event + media")
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
            storeURL: storeURL, defaultZone: testZone,
            progress: { print("E2E publish 2: \($0)") })
        #expect(second.generation == 2, "generation strictly monotonic")
        #expect(second.stats.updated == 2 && second.stats.inserted == 0 && second.stats.deleted == 0,
                "delta republish touches only the changed person + manifest")
        #expect(second.stats.unchanged == 4)
        print("E2E PASS 2 — generation 2, delta of \(second.stats.updated) updates only")

        // SERVER-TRUTH check (added after the 967-record real-tree wipe):
        // local bookkeeping said "delta pushed" while the server had
        // nothing — so fetch George's record from CloudKit and assert the
        // changed field REALLY changed. Bounded retry for dev-env
        // read-after-write lag.
        let georgeUUID = try #require(
            db.loadPublishedIdentityMap()[PublishedIdentity.key(kind: "person", canonicalID: "@G@")])
        let georgeRecordID = CKRecord.ID(
            recordName: "\(georgeUUID):publishedPersons",
            zoneID: testZone.zoneID)
        var serverBirthPlace: String?
        for _ in 1...5 {
            if let record = try? await CKContainer(identifier: PublishEngine.containerID)
                .privateCloudDatabase.record(for: georgeRecordID) {
                serverBirthPlace = record.encryptedValues["birthPlace"] as? String
                if serverBirthPlace == "Duffield" { break }
            }
            try await Task.sleep(for: .seconds(2))
        }
        #expect(serverBirthPlace == "Duffield",
                "the delta must be on the SERVER, not just in local bookkeeping (got \(serverBirthPlace ?? "nil"))")
        print("E2E PASS 2b — server copy verified: birthPlace = \(serverBirthPlace ?? "nil")")

        // Publish 3 — no changes at all: nothing moves but the manifest
        // (its publishedAtISO/generation), proving no-op cheapness.
        let third = try await PublishEngine.publish(
            projectID: projectID, db: db,
            mediaSourceDirectory: dir.appendingPathComponent("media"),
            storeURL: storeURL, defaultZone: testZone,
            progress: { _ in })
        #expect(third.generation == 3)
        #expect(third.stats.updated == 1 && third.stats.unchanged == 5,
                "idle republish moves only the manifest row")
        print("E2E PASS 3 — idle republish is manifest-only traffic")

        // Change 5 — share lifecycle. share() is idempotent (same share on
        // repeat call); unpublish deletes the zone; a republish after
        // unpublish keeps every record UUID (§4.1 permanence) and continues
        // the generation sequence (monotonic through unpublish).
        // DIAGNOSTIC — exact CK coordinates the sync engine recorded.
        let store = try PublishedStore.open(at: storeURL)
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
                projectID: projectID, projectName: "E2E Fixture", db: db, storeURL: storeURL, defaultZone: testZone)
        } catch {
            let ns = error as NSError
            print("E2E SHARE FAIL detail: \(ns.domain) \(ns.code) userInfo=\(ns.userInfo)")
            throw error
        }
        print("E2E share1 ok: \(share1.recordID.recordName)")
        let (share2, _) = try await PublishSharing.share(
            projectID: projectID, projectName: "E2E Fixture", db: db,
            storeURL: storeURL, defaultZone: testZone)
        #expect(share1.recordID == share2.recordID, "share() must reuse the existing share")
        print("E2E PASS 4 — share created and idempotent: \(share1.recordID.recordName)")

        let identityBefore = try db.loadPublishedIdentityMap()
        try await PublishSharing.unpublish(
            projectID: projectID, db: db, storeURL: storeURL, defaultZone: testZone)
        // Idempotent unpublish.
        try await PublishSharing.unpublish(
            projectID: projectID, db: db, storeURL: storeURL, defaultZone: testZone)
        // Erasure is server-truth: George's record must be GONE.
        var georgeGone = false
        for _ in 1...5 {
            do {
                _ = try await privateDB.record(for: georgeRecordID)
            } catch let error as CKError where error.code == .unknownItem {
                georgeGone = true; break
            }
            try await Task.sleep(for: .seconds(2))
        }
        #expect(georgeGone, "unpublish must erase records server-side (GDPR path)")
        print("E2E PASS 5 — unpublish tombstoned the project server-side, idempotently")

        try await Task.sleep(for: .seconds(2))
        let fourth = try await PublishEngine.publish(
            projectID: projectID, db: db,
            mediaSourceDirectory: dir.appendingPathComponent("media"),
            storeURL: storeURL, defaultZone: testZone,
            progress: { _ in })
        #expect(fourth.generation == 4, "generation continues through unpublish")
        #expect(fourth.stats.inserted == 6, "project rows repopulate fully")
        let identityAfter = try db.loadPublishedIdentityMap()
        #expect(identityBefore == identityAfter, "record UUIDs survive unpublish — §4.1")

        // §418 hazard check: republish-after-unpublish re-inserts the SAME
        // primary keys that were just tombstoned — sqlite-data's known
        // delete-then-reinsert pattern. Server truth decides whether the
        // records genuinely came back.
        var georgeBack: String?
        for _ in 1...5 {
            if let record = try? await privateDB.record(for: georgeRecordID) {
                georgeBack = record.encryptedValues["birthPlace"] as? String
                break
            }
            try await Task.sleep(for: .seconds(2))
        }
        #expect(georgeBack == "Duffield",
                "republished record must exist server-side with current data (got \(georgeBack ?? "nil")) — if nil, sqlite-data #418 bites and unpublish must clear published_ids instead")
        print("E2E PASS 6 — republish after unpublish: generation 4, identical identities, server-verified")

        // Leave nothing behind: project rows tombstoned server-side, temp
        // files die with the defer.
        try await PublishSharing.unpublish(
            projectID: projectID, db: db, storeURL: storeURL, defaultZone: testZone)
        print("E2E CLEANUP — fixture records tombstoned")
    }
}
