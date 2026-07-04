import Foundation
import CloudKit
import GRDB
import SQLiteData

// PUBLISHER_SPEC Change 4 — the publish orchestrator.
//
// publish() = pre-flight → generation guard → projection → store apply
// (checksum diff, update-in-place) → explicit sendChanges() → ack wait →
// publish_meta bump. Every failure THROWS — no `try?` anywhere in this
// path (review-doc debt class; spec Change 4 requirement). The CloudKit
// seams (account status, server-manifest fetch) are injectable so the
// orchestration logic tests offline.

nonisolated enum PublishError: Error, LocalizedError, Equatable {
    case iCloudUnavailable(rawStatus: Int)
    case publishedFromAnotherMac(serverGeneration: Int, localGeneration: Int)
    case quotaExceeded
    case syncTimeout(acked: Int, total: Int)

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud is not available. Sign into iCloud in System Settings, then try again."
        case .publishedFromAnotherMac(let server, let local):
            return "This tree was last published from another Mac (server generation \(server), this Mac \(local)). A full republish from this Mac is required — use Unpublish first if you want this Mac to take over."
        case .quotaExceeded:
            return "Your iCloud storage is full. Free up space or reduce published media, then try again."
        case .syncTimeout(let acked, let total):
            return "Publishing stalled: \(acked) of \(total) records were confirmed by iCloud. The remaining records will finish syncing automatically; you can also try publishing again."
        }
    }
}

nonisolated struct PublishSummary: Sendable {
    let generation: Int
    let stats: PublishedStore.ApplyStats
    let ackedRecords: Int
    let totalRecords: Int
}

/// Injectable CloudKit seams (offline tests replace these).
nonisolated struct PublishCloudSeams {
    var accountStatus: @Sendable () async throws -> CKAccountStatus
    var serverGeneration: @Sendable (_ manifestRecordID: CKRecord.ID) async throws -> Int?

    static func live(containerID: String) -> PublishCloudSeams {
        PublishCloudSeams(
            accountStatus: {
                try await CKContainer(identifier: containerID).accountStatus()
            },
            serverGeneration: { recordID in
                let database = CKContainer(identifier: containerID).privateCloudDatabase
                do {
                    let record = try await database.record(for: recordID)
                    return record["CD_generation"] as? Int ?? record["generation"] as? Int
                } catch let error as CKError where
                    error.code == .unknownItem || error.code == .zoneNotFound {
                    return nil   // first publish — nothing on the server yet
                }
            }
        )
    }
}

nonisolated enum PublishEngine {

    static let containerID = "iCloud.dev.dreamfold.Ancestor-Research"

    /// The §4.1 manifest identity is a singleton per project.
    static let manifestIdentityKind = "manifest"
    static let manifestIdentityCanonical = "singleton"

    /// Second-Mac guard rule (spec §2): abort when the server is AHEAD of
    /// what this Mac believes it last published — allowing exactly +1 so
    /// our own interrupted attempt (rows pushed, publish_meta not yet
    /// bumped) can resume rather than lock itself out.
    static func generationGuardAllows(serverGeneration: Int?, localGeneration: Int) -> Bool {
        guard let serverGeneration else { return true }   // first publish
        return serverGeneration <= localGeneration + 1
    }

    /// Full publish of one project. Runs off the main actor; the caller
    /// surfaces progress/errors through the app's report conventions.
    static func publish(
        projectID: UUID,
        db: ProjectDatabase,
        mediaSourceDirectory: URL,
        seams: PublishCloudSeams? = nil,
        now: Date = Date(),
        ackTimeout: Duration = .seconds(120),
        progress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> PublishSummary {
        let seams = seams ?? .live(containerID: containerID)

        // 1. Pre-flight — fail before any work if iCloud can't take it.
        await progress?("Checking iCloud account…")
        let status = try await seams.accountStatus()
        guard status == .available else {
            throw PublishError.iCloudUnavailable(rawStatus: status.rawValue)
        }

        // 2. Projection at generation + 1 (this engine owns the bump).
        let localGeneration = try db.loadPublishGeneration()
        let candidateGeneration = localGeneration + 1
        await progress?("Building redacted projection…")
        var (inputs, identity) = try PublishInputs.load(
            db: db, now: now, generation: candidateGeneration)
        let tree = PublishedTree.project(inputs, identity: &identity)
        let manifestID = identity.uuid(
            kind: manifestIdentityKind, canonicalID: manifestIdentityCanonical)
        try db.savePublishedIDs(identity.minted)

        // 3. Second-Mac generation guard.
        await progress?("Checking for publishes from other Macs…")
        let zoneID = CKRecordZone.ID(zoneName: projectID.uuidString)
        let manifestRecordID = CKRecord.ID(
            recordName: "\(manifestID):publishedManifests", zoneID: zoneID)
        let serverGeneration = try await seams.serverGeneration(manifestRecordID)
        guard generationGuardAllows(
            serverGeneration: serverGeneration, localGeneration: localGeneration) else {
            throw PublishError.publishedFromAnotherMac(
                serverGeneration: serverGeneration ?? 0, localGeneration: localGeneration)
        }

        // 4. Reconcile the published store (checksum diff, update-in-place).
        await progress?("Writing published store…")
        let store = try PublishedStore.open(projectID: projectID)
        let stats = try store.apply(
            tree: tree, manifestID: manifestID, mediaSourceDirectory: mediaSourceDirectory)

        // 5. Sync — engine per publish; explicit sendChanges() is BINDING
        // (Change 3 finding: the scheduler defers indefinitely otherwise).
        await progress?("Uploading to iCloud…")
        let engine = try SyncEngine(
            for: store.db,
            tables: StoreManifest.self, StorePerson.self, StoreRelationship.self,
                    StoreLifeEvent.self, StoreMedia.self,
            containerIdentifier: containerID,
            defaultZone: CKRecordZone(zoneName: projectID.uuidString),
            startImmediately: true)
        defer { engine.stop() }
        do {
            try await engine.sendChanges()
        } catch let error as CKError where error.code == .quotaExceeded {
            throw PublishError.quotaExceeded
        }

        // 6. Wait for server acks.
        let total = try store.totalRows()
        var acked = try store.ackedRows()
        let deadline = ContinuousClock.now + ackTimeout
        while acked < total, ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(2))
            acked = try store.ackedRows()
            await progress?("Confirmed \(acked) of \(total) records…")
        }
        guard acked >= total else {
            throw PublishError.syncTimeout(acked: acked, total: total)
        }

        // 7. Commit the bump — only after the server has everything.
        try db.setPublishGeneration(candidateGeneration, publishedAt: now)
        await progress?("Published generation \(candidateGeneration).")
        return PublishSummary(
            generation: candidateGeneration, stats: stats,
            ackedRecords: acked, totalRecords: total)
    }
}
