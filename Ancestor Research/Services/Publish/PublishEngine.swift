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
    case storeInconsistent

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud is not available. Sign into iCloud in System Settings, then try again."
        case .publishedFromAnotherMac(let server, let local):
            return "This tree was last published from another Mac (server generation \(server), this Mac \(local)). A full republish from this Mac is required — use Unpublish first if you want this Mac to take over."
        case .quotaExceeded:
            return "Your iCloud storage is full. Free up space or reduce published media, then try again."
        case .syncTimeout(let acked, let total):
            return "Publishing stalled: \(acked) of \(total) records were confirmed by iCloud. Publish again to resume — already-confirmed records are never re-uploaded."
        case .storeInconsistent:
            return "The published store ended up empty mid-publish. Nothing was published; please try again."
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

    /// sqlite-data's default zone — all published records live here; the
    /// per-project zone design died with the cross-contamination finding
    /// (engine syncs database-wide) and was already obsolete for sharing
    /// (shares are manifest-rooted hierarchies since Change 3).
    static let zoneID = CKRecordZone.ID(zoneName: "co.pointfree.SQLiteData.defaultZone")

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
        storeURL: URL? = nil,
        defaultZone: CKRecordZone? = nil,
        now: Date = Date(),
        ackTimeout: Duration = .seconds(600),
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
        let manifestRecordID = CKRecord.ID(
            recordName: "\(manifestID):publishedManifests",
            zoneID: defaultZone?.zoneID ?? Self.zoneID)
        let serverGeneration = try await seams.serverGeneration(manifestRecordID)
        guard generationGuardAllows(
            serverGeneration: serverGeneration, localGeneration: localGeneration) else {
            throw PublishError.publishedFromAnotherMac(
                serverGeneration: serverGeneration ?? 0, localGeneration: localGeneration)
        }

        // 4. Engine BEFORE writes — sqlite-data's change triggers exist only
        // while an engine is attached ("all edits made after stopping the
        // sync engine will not be synchronized"), and awaiting start()
        // completes the initial server reconciliation BEFORE our rows exist.
        // This closes the first-real-publish wipe: a fetch reporting the
        // zone deleted (e.g. after Unpublish) purges local rows for that
        // zone, and with apply-before-start it raced our upload — 967 rows
        // lost on a real tree while small fixtures won the race.
        await progress?("Preparing iCloud sync…")
        let store = try storeURL.map { try PublishedStore.open(at: $0) }
            ?? PublishedStore.openShared()
        let engine = try SyncEngine(
            for: store.db,
            tables: StoreManifest.self, StorePerson.self, StoreRelationship.self,
                    StoreLifeEvent.self, StoreMedia.self,
            containerIdentifier: containerID,
            defaultZone: defaultZone ?? CKRecordZone(zoneID: Self.zoneID),
            startImmediately: false)
        defer { engine.stop() }
        try await engine.start()

        // 5. Reconcile the published store (checksum diff, update-in-place)
        // — every change now recorded as pending via live triggers.
        await progress?("Writing published store…")
        let stats = try store.apply(
            tree: tree, manifestID: manifestID, mediaSourceDirectory: mediaSourceDirectory)

        // 6. Push and drain — PACED. CloudKit rate-limits burst uploads
        // (both real-tree first publishes died at batch 3, ~record 500):
        // the engine's own scheduler would honor retry-after, but manual
        // sendChanges() surfaces the throttle as an error. So: re-invoke
        // sendChanges with the server's retry-after (or backoff), and keep
        // going as long as records keep landing. Completion = every row
        // server-acked AND the pending queue drained.
        await progress?("Uploading to iCloud…")
        let total = try store.totalRows()
        guard total > 0 else {
            // The manifest row alone makes total ≥ 1; zero means the store
            // was emptied under us — never report success on nothing.
            throw PublishError.storeInconsistent
        }
        let deadline = ContinuousClock.now + ackTimeout
        var attempt = 0
        var lastAcked = -1
        while true {
            do {
                try await engine.sendChanges()
            } catch let error as CKError where error.code == .quotaExceeded {
                throw PublishError.quotaExceeded
            } catch {
                let acked = try store.ackedRows()
                let progressMade = acked > lastAcked
                lastAcked = acked
                attempt += 1
                guard ContinuousClock.now < deadline, progressMade || attempt <= 5 else {
                    throw error
                }
                let delay = (error as? CKError)?.retryAfterSeconds
                    ?? Double(min(1 << min(attempt, 5), 30))
                await progress?(
                    "iCloud is pacing the upload — resuming in \(Int(delay))s (\(acked) of \(total) confirmed)")
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            let pending = try store.pendingChangeCount()
            let acked = try store.ackedRows()
            await progress?("Confirmed \(acked) of \(total) records…")
            if pending == 0 && acked >= total { break }
            guard ContinuousClock.now < deadline else {
                throw PublishError.syncTimeout(acked: acked, total: total)
            }
            try await Task.sleep(for: .seconds(2))
        }

        let acked = try store.ackedRows()

        // 7. Commit the bump — only after the server has everything.
        try db.setPublishGeneration(candidateGeneration, publishedAt: now)
        await progress?("Published generation \(candidateGeneration).")
        return PublishSummary(
            generation: candidateGeneration, stats: stats,
            ackedRecords: acked, totalRecords: total)
    }
}
