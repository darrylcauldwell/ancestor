import Foundation

// Orchestration: fetch → cache → snapshot. This is the type a viewer
// shell holds; everything below it is mechanism.

public actor ViewerStore {
    private let fetcher: ZoneFetcher
    private let cache: ViewerCache

    public init(fetcher: ZoneFetcher, cache: ViewerCache) {
        self.fetcher = fetcher
        self.cache = cache
    }

    /// Pull changes from CloudKit into the cache. Returns the manifests
    /// now cached. A full refetch (first run, expired token, purged
    /// cache) wipes before applying so tombstoned rows can't linger.
    @discardableResult
    public func refresh() async throws -> [ManifestRow] {
        let token = try cache.changeToken()
        let result = try await fetcher.fetchChanges(since: token)
        if result.isFullRefetch {
            try cache.wipe()
        }
        try cache.apply(records: result.records, deletedRecordNames: result.deletedRecordNames)
        try cache.setChangeToken(result.changeTokenData)
        return try cache.manifests()
    }

    /// Manifests already in the cache — render-before-refresh path.
    public func cachedManifests() throws -> [ManifestRow] {
        try cache.manifests()
    }

    /// Build the renderable tree for one manifest lineage from cache.
    public func tree(manifestID: String) throws -> ViewerTree {
        let lineage = try cache.lineage(manifestID: manifestID)
        return SnapshotBuilder.build(
            manifest: lineage.manifest,
            persons: lineage.persons,
            relationships: lineage.relationships,
            events: lineage.events,
            media: lineage.media)
    }
}
