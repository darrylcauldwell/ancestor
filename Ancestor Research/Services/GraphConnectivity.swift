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

    /// A connected component summarised for the "connect groups" picker: a
    /// representative profile (the most-connected member — the recognisable head
    /// of the group, e.g. the main tree's hub ancestor rather than a leaf in-law)
    /// plus every member ID. Ordered largest component first, so the main tree
    /// leads and the small islands follow.
    struct ComponentSummary: Identifiable {
        let representativeID: String
        let memberIDs: [String]
        var id: String { representativeID }
        var count: Int { memberIDs.count }
    }

    static func componentSummaries(_ snapshot: FamilyGraphSnapshot) -> [ComponentSummary] {
        // Degree = number of edges touching a profile. The most-connected member
        // is the natural "head" of its group; tie-broken by earliest birth (the
        // likely ancestor), then id, for determinism.
        var degree: [String: Int] = [:]
        for rel in snapshot.relationships {
            degree[rel.from, default: 0] += 1
            degree[rel.to, default: 0] += 1
        }
        return connectedComponents(snapshot).map { members in
            let rep = members.max { a, b in
                let da = degree[a] ?? 0, db = degree[b] ?? 0
                if da != db { return da < db }                        // higher degree wins
                let ya = snapshot.profiles[a]?.birthDate?.bestYear ?? Int.max
                let yb = snapshot.profiles[b]?.birthDate?.bestYear ?? Int.max
                if ya != yb { return ya > yb }                        // then earlier birth wins
                return a > b                                          // then smaller id wins
            } ?? members[0]
            return ComponentSummary(representativeID: rep, memberIDs: members)
        }
    }

    /// M16.12, reshaped 2026-07-15 (owner design): the "Connect them?"
    /// flow leads with the ORPHAN — the person the user just added and
    /// lost — not a random member of the main tree. Returns
    /// (orphan, mainTreeMember): the first member of the SMALLEST
    /// component as the suggested anchor, and a largest-component member
    /// for reference. The sheet's anchor is user-changeable regardless.
    static func suggestConnectionAnchors(snapshot: FamilyGraphSnapshot) -> (String, String)? {
        let components = connectedComponents(snapshot)
        guard components.count >= 2,
              let orphan = components.last?.first,
              let mainMember = components[0].first else { return nil }
        return (orphan, mainMember)
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
