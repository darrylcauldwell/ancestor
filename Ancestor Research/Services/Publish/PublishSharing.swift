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
        db: ProjectDatabase,
        storeURL: URL? = nil,
        defaultZone: CKRecordZone? = nil
    ) async throws -> (share: CKShare, container: CKContainer) {
        let identityKey = PublishedIdentity.key(
            kind: PublishEngine.manifestIdentityKind,
            canonicalID: PublishEngine.manifestIdentityCanonical)
        let resolvedStoreURL = storeURL ?? PublishedStore.sharedURL
        guard let manifestUUID = try db.loadPublishedIdentityMap()[identityKey],
              FileManager.default.fileExists(atPath: resolvedStoreURL.path)
        else { throw PublishSharingError.notPublished }

        let store = try PublishedStore.open(at: resolvedStoreURL)
        let engine = try SyncEngine(
            for: store.db,
            tables: StoreManifest.self, StorePerson.self, StoreRelationship.self,
                    StoreLifeEvent.self, StoreMedia.self,
            containerIdentifier: PublishEngine.containerID,
            defaultZone: defaultZone ?? CKRecordZone(zoneID: PublishEngine.zoneID),
            startImmediately: false)
        defer { engine.stop() }
        try await engine.start()

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

    /// Unpublish: tombstone every record in this project's manifest
    /// lineage (participants lose the shared hierarchy; server records
    /// are deleted — the GDPR-erasure path). The store and zone are
    /// shared across projects, so unpublish deletes ROWS, never files or
    /// zones. Idempotent: no rows means nothing to do.
    static func unpublish(
        projectID: UUID,
        db: ProjectDatabase,
        storeURL: URL? = nil,
        defaultZone: CKRecordZone? = nil
    ) async throws {
        let identityKey = PublishedIdentity.key(
            kind: PublishEngine.manifestIdentityKind,
            canonicalID: PublishEngine.manifestIdentityCanonical)
        guard let manifestUUID = try db.loadPublishedIdentityMap()[identityKey] else {
            return   // never published — nothing to erase
        }
        let store = try storeURL.map { try PublishedStore.open(at: $0) }
            ?? PublishedStore.openShared()
        let engine = try SyncEngine(
            for: store.db,
            tables: StoreManifest.self, StorePerson.self, StoreRelationship.self,
                    StoreLifeEvent.self, StoreMedia.self,
            containerIdentifier: PublishEngine.containerID,
            defaultZone: defaultZone ?? CKRecordZone(zoneID: PublishEngine.zoneID),
            startImmediately: false)
        defer { engine.stop() }
        try await engine.start()

        // Tombstone the rows. CloudKit deletes the CKShare automatically
        // when its root record (the manifest) is deleted, which evicts all
        // participants — no explicit unshare needed (and engine.unshare's
        // metadata lookup misses shares created in other engine sessions,
        // spuriously reporting an issue).
        _ = try store.deleteProject(manifestID: manifestUUID)
        try await engine.sendChanges()

        // Drain the tombstones with a bounded wait.
        let deadline = ContinuousClock.now + .seconds(60)
        while try store.pendingChangeCount() > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// Whether this project has published rows in the shared store —
    /// drives menu enablement and delete-flow prompts.
    static func hasPublishedStore(projectID: UUID, db: ProjectDatabase) -> Bool {
        let identityKey = PublishedIdentity.key(
            kind: PublishEngine.manifestIdentityKind,
            canonicalID: PublishEngine.manifestIdentityCanonical)
        guard let manifestUUID = try? db.loadPublishedIdentityMap()[identityKey],
              FileManager.default.fileExists(atPath: PublishedStore.sharedURL.path),
              let store = try? PublishedStore.openShared(),
              let count = try? store.db.read({ db in
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM publishedManifests WHERE id = ?",
                                   arguments: [manifestUUID]) ?? 0
              })
        else { return false }
        return count > 0
    }
}
