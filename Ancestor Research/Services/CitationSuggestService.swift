import Foundation

/// Auto-suggest values for the structured citation fields, drawn from
/// citations the user has already entered elsewhere in the project.
///
/// Mirrors `AutoSuggestService` style: pure functions, no I/O. The view
/// passes the snapshot in; this service walks every profile's field
/// sources, collects non-empty repository / collection strings, and
/// returns the top 5 by frequency. Picking from previous entries keeps
/// citations consistent — "The National Archives" instead of three
/// separate spellings.
nonisolated enum CitationSuggestService {

    /// Repositories ranked by usage frequency across the tree.
    /// Empty / nil values are skipped.
    static func repositories(snapshot: FamilyGraphSnapshot) -> [String] {
        topByFrequency(snapshot: snapshot, keyPath: \.repository)
    }

    /// Collections ranked by usage frequency across the tree.
    static func collections(snapshot: FamilyGraphSnapshot) -> [String] {
        topByFrequency(snapshot: snapshot, keyPath: \.collection)
    }

    // MARK: - Private

    private static func topByFrequency(
        snapshot: FamilyGraphSnapshot,
        keyPath: KeyPath<Citation, String?>
    ) -> [String] {
        var counts: [String: Int] = [:]
        for profile in snapshot.profiles.values {
            for sources in profile.sources.values {
                for source in sources {
                    guard let citation = source.citation else { continue }
                    if let value = citation[keyPath: keyPath], !value.isEmpty {
                        counts[value, default: 0] += 1
                    }
                }
            }
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)
    }
}
