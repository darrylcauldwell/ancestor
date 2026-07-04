import Foundation
import CloudKit
import GRDB
import SQLiteData

// PUBLISHER_SPEC Change 5 — share lifecycle + unpublish.
//
// The share is a hierarchy CKShare rooted at the manifest row (Change 3);
// SQLiteData's share() is idempotent (reuses the existing share from sync
// metadata), so "Invite Family…" and "Manage Sharing…" are the same call.
// Unpublish deletes the project's zone server-side — that evicts every
// participant, kills the share, and removes all published records — then
// clears the local store. `published_ids` and `publish_meta.generation`
// survive (spec §4.1: identity and monotonicity persist through unpublish,
// proven by the republish-after-unpublish E2E).

nonisolated enum PublishSharingError: Error, LocalizedError, Equatable {
    case notPublished

    var errorDescription: String? {
        switch self {
        case .notPublished:
            return "This tree hasn’t been published yet. Use “Publish Tree to iCloud…” first, then invite your family."
        }
    }
}

nonisolated enum PublishSharing {

    /// Fetch-or-create the CKShare for a published project.
    /// Requires a prior successful publish (the manifest must be synced —
    /// SQLiteData refuses to share an unsynced record).
    static func share(
        projectID: UUID,
        projectName: String,
        db: ProjectDatabase
    ) async throws -> (share: CKShare, container: CKContainer) {
        let identityKey = PublishedIdentity.key(
            kind: PublishEngine.manifestIdentityKind,
            canonicalID: PublishEngine.manifestIdentityCanonical)
        guard let manifestUUID = try db.loadPublishedIdentityMap()[identityKey],
              FileManager.default.fileExists(atPath: PublishedStore.url(for: projectID).path)
        else { throw PublishSharingError.notPublished }

        let store = try PublishedStore.open(projectID: projectID)
        let engine = try SyncEngine(
            for: store.db,
            tables: StoreManifest.self, StorePerson.self, StoreRelationship.self,
                    StoreLifeEvent.self, StoreMedia.self,
            containerIdentifier: PublishEngine.containerID,
            defaultZone: CKRecordZone(zoneName: projectID.uuidString),
            startImmediately: true)
        defer { engine.stop() }

        let manifest = try await store.db.read { database in
            try StoreManifest.find(manifestUUID).fetchOne(database)
        }
        guard let manifest else { throw PublishSharingError.notPublished }

        // Settle the fresh engine session before sharing: sendChanges()
        // awaits engine start and flushes any pending state (a cold
        // engine straight into share() can see zoneNotFound).
        try await engine.sendChanges()

        // share() re-fetches the root record from the server; right after
        // a publish that read can race CloudKit's replication (unknownItem
        // on a record that was acked moments ago). Bounded retry — also the
        // correct behaviour for "Invite Family…" clicked straight after a
        // publish in production.
        var lastError: Error = PublishSharingError.notPublished
        for attempt in 1...5 {
            do {
                let shared = try await engine.share(record: manifest) { share in
                    share[CKShare.SystemFieldKey.title] =
                        "\(projectName) Family Tree" as CKRecordValue
                    // Invite-only. NEVER touch publicPermission after
                    // participants exist — reverting evicts everyone (§Change 5).
                }
                return (shared.share, CKContainer(identifier: PublishEngine.containerID))
            } catch let error as CKError where error.code == .unknownItem && attempt < 5 {
                lastError = error
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw lastError
    }

    /// Unpublish: server-side zone deletion (share dies with the zone;
    /// all participants lose access; every published record is removed —
    /// the GDPR-erasure path), then local store cleanup. Idempotent:
    /// unpublishing an already-unpublished project succeeds silently.
    static func unpublish(projectID: UUID) async throws {
        let container = CKContainer(identifier: PublishEngine.containerID)
        let zoneID = CKRecordZone.ID(zoneName: projectID.uuidString)
        do {
            _ = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [], deleting: [zoneID])
        } catch let error as CKError where
            error.code == .zoneNotFound || error.code == .userDeletedZone {
            // Already gone server-side — proceed to local cleanup.
        }
        try removeLocalStore(projectID: projectID)
    }

    /// Remove the published store and its SQLiteData metadatabase
    /// (`.{name}.metadata-{container}.sqlite` hidden sibling) plus WAL/SHM
    /// journals. `published_ids` and `publish_meta` live in the CANONICAL
    /// database and are deliberately untouched.
    static func removeLocalStore(projectID: UUID) throws {
        let fm = FileManager.default
        let storeURL = PublishedStore.url(for: projectID)
        let directory = storeURL.deletingLastPathComponent()
        let storeName = storeURL.deletingPathExtension().lastPathComponent
        let candidates = [
            storeURL.lastPathComponent,
            storeURL.lastPathComponent + "-wal",
            storeURL.lastPathComponent + "-shm",
            ".\(storeName).metadata-\(PublishEngine.containerID).sqlite",
            ".\(storeName).metadata-\(PublishEngine.containerID).sqlite-wal",
            ".\(storeName).metadata-\(PublishEngine.containerID).sqlite-shm",
        ]
        for name in candidates {
            let url = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
    }

    /// Whether this project currently has a published store on disk —
    /// drives the "unpublish first?" prompt in the delete flow and menu
    /// enablement.
    static func hasPublishedStore(projectID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: PublishedStore.url(for: projectID).path)
    }
}
