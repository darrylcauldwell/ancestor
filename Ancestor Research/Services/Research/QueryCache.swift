import Foundation

/// Per-pipeline-run cache preventing duplicate queries to the same source.
/// Keyed by searchKey (source + record type + normalised params).
/// Discarded at pipeline end — not a persistent cache.
actor QueryCache {
    private var cache: [String: [SourceRecord]] = [:]

    func get(_ key: String) -> [SourceRecord]? {
        cache[key]
    }

    func set(_ key: String, results: [SourceRecord]) {
        cache[key] = results
    }

    func contains(_ key: String) -> Bool {
        cache[key] != nil
    }

    func clear() {
        cache.removeAll()
    }
}
