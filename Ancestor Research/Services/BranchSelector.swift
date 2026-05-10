import Foundation

/// Direction of a branch walk relative to a root profile.
nonisolated enum BranchDirection: Sendable {
    case ancestors
    case descendants
}

/// Pure helper that selects the IDs of every profile reachable from a root
/// in a given direction (parents-only or children-only). Used by the tree's
/// "Remove person and ancestors / descendants" affordance (DESIGN.md §7.5.6)
/// so the confirmation alert can show an accurate count and the actual
/// soft-delete is a single transaction.
///
/// Always includes the root itself in the returned set. Cycle-safe: if the
/// graph contains a cycle (it shouldn't, genealogically) the walk terminates
/// because each profile is visited at most once.
nonisolated enum BranchSelector {

    /// All ancestors of `profileID` plus the profile itself.
    /// Walks parent edges only — never descends into children.
    static func ancestorsOf(
        _ profileID: String,
        in snapshot: FamilyGraphSnapshot
    ) -> Set<String> {
        branch(rootedAt: profileID, direction: .ancestors, in: snapshot)
    }

    /// All descendants of `profileID` plus the profile itself.
    /// Walks child edges only — never ascends to parents.
    static func descendantsOf(
        _ profileID: String,
        in snapshot: FamilyGraphSnapshot
    ) -> Set<String> {
        branch(rootedAt: profileID, direction: .descendants, in: snapshot)
    }

    /// Generic branch walker. Returns the root and every profile reachable
    /// in the given direction. Iterative breadth-first traversal with a
    /// visited set to defend against cyclic input.
    static func branch(
        rootedAt id: String,
        direction: BranchDirection,
        in snapshot: FamilyGraphSnapshot
    ) -> Set<String> {
        // Bail out cleanly if the root doesn't exist — empty set rather than
        // a phantom containing only an unknown id.
        guard snapshot.profiles[id] != nil else { return [] }

        var visited: Set<String> = [id]
        var queue: [String] = [id]

        while let current = queue.first {
            queue.removeFirst()
            let neighbours: [Profile]
            switch direction {
            case .ancestors:
                neighbours = snapshot.parentsOf(current)
            case .descendants:
                neighbours = snapshot.childrenOf(current)
            }
            for next in neighbours where !visited.contains(next.id) {
                visited.insert(next.id)
                queue.append(next.id)
            }
        }
        return visited
    }
}

// MARK: - Snapshot extension

nonisolated extension FamilyGraphSnapshot {
    /// Number of distinct parent edges pointing at `profileID`.
    /// Drives the third-parent disambiguation prompt (DESIGN.md §7.5.7) —
    /// when adding a relationship would push the count to 3+, the UI surfaces
    /// a "What's the relationship?" picker rather than silently defaulting.
    func parentCount(for profileID: String) -> Int {
        relationships.reduce(0) { count, rel in
            (rel.type == .parent && rel.to == profileID) ? count + 1 : count
        }
    }
}
