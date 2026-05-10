import Foundation

/// Identifies the connected components of a family graph — groups of
/// profiles linked by parent or spouse edges. Used by the disconnected
/// banner and by the import-merge flow to decide whether a manual tree
/// has multiple unconnected islands.
nonisolated enum GraphConnectivity {

    /// Returns one array of profile IDs per connected component.
    /// A profile with no edges forms a singleton component.
    /// Sorted: largest component first; tie-broken by lexicographic order
    /// of the smallest ID in each component, so output is deterministic.
    static func connectedComponents(_ snapshot: FamilyGraphSnapshot) -> [[String]] {
        var parent: [String: String] = [:]
        let allIDs = Array(snapshot.profiles.keys)
        for id in allIDs { parent[id] = id }

        for rel in snapshot.relationships {
            // Only consider edges between profiles that actually exist.
            guard parent[rel.from] != nil, parent[rel.to] != nil else { continue }
            union(rel.from, rel.to, parent: &parent)
        }

        var groups: [String: [String]] = [:]
        for id in allIDs {
            let root = find(id, parent: &parent)
            groups[root, default: []].append(id)
        }

        return groups.values
            .map { $0.sorted() }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return (lhs.first ?? "") < (rhs.first ?? "")
            }
    }

    /// `true` iff the snapshot has 2 or more connected components.
    static func isDisconnected(_ snapshot: FamilyGraphSnapshot) -> Bool {
        connectedComponents(snapshot).count > 1
    }

    /// M16.12 — pick representative profile IDs from the two largest
    /// connected components. The DisconnectedBanner's "Connect them?" button
    /// uses these as the suggested anchor pair when launching
    /// `AddRelationshipView`. Returns `nil` for trees with a single
    /// component (or none).
    ///
    /// `connectedComponents()` already returns components in descending
    /// size order with deterministic tie-breaking, so picking
    /// `.first` of each component yields a stable, reproducible suggestion.
    static func suggestConnectionAnchors(snapshot: FamilyGraphSnapshot) -> (String, String)? {
        let components = connectedComponents(snapshot)
        guard components.count >= 2,
              let primary = components[0].first,
              let secondary = components[1].first else { return nil }
        return (primary, secondary)
    }

    // MARK: - Union-find helpers

    private static func find(_ id: String, parent: inout [String: String]) -> String {
        var current = id
        while let p = parent[current], p != current {
            parent[current] = parent[p] ?? p   // path compression
            current = parent[current]!
        }
        return current
    }

    private static func union(_ a: String, _ b: String, parent: inout [String: String]) {
        let rootA = find(a, parent: &parent)
        let rootB = find(b, parent: &parent)
        if rootA != rootB {
            parent[rootA] = rootB
        }
    }
}
