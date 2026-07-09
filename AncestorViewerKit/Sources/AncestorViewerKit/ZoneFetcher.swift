import Foundation
import CloudKit

// The only CloudKit surface in the viewer. Read-only by construction: it
// wraps zone-change FETCH operations exclusively — there is no code path
// that could issue a modify. One fetcher serves both shells via the scope
// parameter: `.privateDatabase` for same-account devices (the owner's own
// zone), `.sharedDatabase` for participants after share acceptance.

public nonisolated enum ViewerDatabaseScope: String, Sendable {
    case privateDatabase
    case sharedDatabase
}

public actor ZoneFetcher {

    /// SQLiteData's fixed zone name — the publisher writes here
    /// (PublishEngine.zoneID) and never anywhere else.
    public static let zoneName = "co.pointfree.SQLiteData.defaultZone"
    public static let defaultContainerIdentifier = "iCloud.dev.dreamfold.Ancestor-Research"

    private let database: CKDatabase
    private let scope: ViewerDatabaseScope
    private let assetDirectory: URL

    /// - Parameter assetDirectory: where CKAsset files are copied as they
    ///   arrive (a Caches subdirectory — disposable like the row cache).
    public init(
        containerIdentifier: String = ZoneFetcher.defaultContainerIdentifier,
        scope: ViewerDatabaseScope,
        assetDirectory: URL
    ) {
        let container = CKContainer(identifier: containerIdentifier)
        self.database = scope == .privateDatabase
            ? container.privateCloudDatabase
            : container.sharedCloudDatabase
        self.scope = scope
        self.assetDirectory = assetDirectory
    }

    public struct FetchResult: Sendable {
        public let records: [MappedRecord]
        public let deletedRecordNames: [String]
        public let changeTokenData: Data?
        /// True when the server invalidated our token (or this was a
        /// first fetch after one) and everything was re-fetched from
        /// scratch — the caller must wipe the cache before applying.
        public let isFullRefetch: Bool
    }

    /// Incremental change fetch. Handles pagination (`moreComing`) and
    /// recovers from `changeTokenExpired` by restarting from scratch
    /// (§4.3) — the caller sees that as `isFullRefetch`.
    public func fetchChanges(since tokenData: Data?) async throws -> FetchResult {
        let zoneID = try await resolveZoneID()
        var token = tokenData.flatMap(Self.unarchiveToken)
        var isFullRefetch = token == nil && tokenData != nil // stored token failed to decode
        var records: [MappedRecord] = []
        var deletions: [String] = []
        var moreComing = true

        while moreComing {
            do {
                let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (_, result) in page.modificationResultsByID {
                    guard case .success(let modification) = result else { continue }
                    if let mapped = RecordMapper.map(modification.record, materialiseAsset: materialiseAsset) {
                        records.append(mapped)
                    }
                }
                deletions.append(contentsOf: page.deletions.map { $0.recordID.recordName })
                token = page.changeToken
                moreComing = page.moreComing
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                records = []
                deletions = []
                isFullRefetch = true
                moreComing = true
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                throw ViewerError.treeNotFound
            }
        }

        return FetchResult(
            records: records,
            deletedRecordNames: deletions,
            changeTokenData: token.flatMap(Self.archiveToken),
            isFullRefetch: isFullRefetch || tokenData == nil)
    }

    // MARK: - Zone resolution

    private func resolveZoneID() async throws -> CKRecordZone.ID {
        switch scope {
        case .privateDatabase:
            return CKRecordZone.ID(zoneName: Self.zoneName)
        case .sharedDatabase:
            // A participant's copy of the zone carries the OWNER's name in
            // its zone ID — discover it rather than assuming.
            let zones = try await database.allRecordZones()
            guard let zone = zones.first(where: { $0.zoneID.zoneName == Self.zoneName }) else {
                throw ViewerError.treeNotFound
            }
            return zone.zoneID
        }
    }

    // MARK: - Assets

    private nonisolated func materialiseAsset(temporaryURL: URL, recordID: String) -> String? {
        let destination = assetDirectory.appendingPathComponent(recordID)
        do {
            try FileManager.default.createDirectory(
                at: assetDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            return destination.path
        } catch {
            return nil // missing media never fails a fetch; the row keeps localAssetPath nil
        }
    }

    // MARK: - Token archiving

    static func archiveToken(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func unarchiveToken(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}
