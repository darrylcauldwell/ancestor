import Foundation

/// Pure-logic kinship calculator. Given two profile IDs and a snapshot,
/// returns a human-readable relationship label ("first cousin once removed",
/// "great-grandfather", "self", "spouse", "no known relationship") plus the
/// path of profile IDs through the lowest common ancestor.
///
/// The algorithm is BFS over `parentsOf` from each profile, collecting
/// (ancestor → distance) maps. The intersection of those maps gives candidate
/// common ancestors; we pick the one that minimises `d1 + d2` (ties broken by
/// preferring the deeper ancestor, i.e. larger `min(d1, d2)`, which yields the
/// closest LCA — "lowest" in genealogical terms means closest to the subjects).
nonisolated enum RelationshipCalculator {

    /// Compute a kinship description from `subjectID` to `targetID`.
    /// Returns nil only if either ID is missing from the snapshot.
    static func describe(
        from subjectID: String,
        to targetID: String,
        snapshot: FamilyGraphSnapshot
    ) -> Description? {
        guard snapshot.profiles[subjectID] != nil,
              let target = snapshot.profiles[targetID] else {
            return nil
        }

        // Self
        if subjectID == targetID {
            return Description(label: "self", path: [])
        }

        // Spouse — gendered when possible
        let spouseIDs = snapshot.spousesOf(subjectID).map(\.id)
        if spouseIDs.contains(targetID) {
            let label: String
            switch target.gender {
            case .male: label = "husband"
            case .female: label = "wife"
            default: label = "spouse"
            }
            return Description(label: label, path: [])
        }

        // BFS ancestor distances from each profile
        let subjectAncestors = ancestorDistances(of: subjectID, snapshot: snapshot)
        let targetAncestors = ancestorDistances(of: targetID, snapshot: snapshot)

        // Direct ancestry: target IS an ancestor of subject
        if let depth = subjectAncestors[targetID] {
            let path = ancestorPath(from: subjectID, to: targetID, snapshot: snapshot) ?? []
            return Description(
                label: ancestorLabel(depth: depth, gender: target.gender),
                path: path
            )
        }

        // Direct descendancy: subject IS an ancestor of target
        if let depth = targetAncestors[subjectID] {
            let path = (ancestorPath(from: targetID, to: subjectID, snapshot: snapshot) ?? []).reversed()
            return Description(
                label: descendantLabel(depth: depth, gender: target.gender),
                path: Array(path)
            )
        }

        // Find lowest common ancestor (smallest d1+d2; tie → deepest, i.e. closest)
        var best: (ancestor: String, d1: Int, d2: Int)?
        for (ancestor, d1) in subjectAncestors {
            guard let d2 = targetAncestors[ancestor] else { continue }
            if let cur = best {
                let curSum = cur.d1 + cur.d2
                let newSum = d1 + d2
                if newSum < curSum
                    || (newSum == curSum && min(d1, d2) > min(cur.d1, cur.d2)) {
                    best = (ancestor, d1, d2)
                }
            } else {
                best = (ancestor, d1, d2)
            }
        }

        guard let lca = best else {
            return Description(label: "no known relationship", path: [])
        }

        // Build path: subject → LCA → target
        let upPath = ancestorPath(from: subjectID, to: lca.ancestor, snapshot: snapshot) ?? []
        let downReversed = ancestorPath(from: targetID, to: lca.ancestor, snapshot: snapshot) ?? []
        let downPath = Array(downReversed.reversed())
        // upPath already includes both subject and LCA; downPath also includes LCA and target.
        // Concatenate while skipping the duplicated LCA.
        var fullPath = upPath
        if let lcaIndex = downPath.firstIndex(of: lca.ancestor) {
            fullPath.append(contentsOf: downPath[(lcaIndex + 1)...])
        }

        let label = lateralLabel(d1: lca.d1, d2: lca.d2, targetGender: target.gender)
        return Description(label: label, path: fullPath)
    }

    // MARK: - BFS helpers

    /// BFS from `id` up the parent chain. Returns map of ancestor ID →
    /// distance (1 = parent, 2 = grandparent, …). Does not include `id` itself.
    private static func ancestorDistances(
        of id: String,
        snapshot: FamilyGraphSnapshot
    ) -> [String: Int] {
        var distances: [String: Int] = [:]
        var queue: [(String, Int)] = [(id, 0)]
        var seen: Set<String> = [id]
        while let (current, depth) = queue.first {
            queue.removeFirst()
            for parent in snapshot.parentsOf(current) {
                if seen.contains(parent.id) { continue }
                seen.insert(parent.id)
                let newDepth = depth + 1
                // Smallest distance wins (BFS guarantees first-seen is shortest)
                if distances[parent.id] == nil {
                    distances[parent.id] = newDepth
                }
                queue.append((parent.id, newDepth))
            }
        }
        return distances
    }

    /// Returns a path of IDs from `from` up to `to` inclusive (assuming `to` is
    /// an ancestor of `from`). Picks the shortest path via BFS predecessors.
    /// Returns nil if `to` is not reachable.
    private static func ancestorPath(
        from: String,
        to: String,
        snapshot: FamilyGraphSnapshot
    ) -> [String]? {
        if from == to { return [from] }
        var predecessor: [String: String] = [:]
        var queue: [String] = [from]
        var seen: Set<String> = [from]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for parent in snapshot.parentsOf(current) {
                if seen.contains(parent.id) { continue }
                seen.insert(parent.id)
                predecessor[parent.id] = current
                if parent.id == to {
                    // Reconstruct path
                    var path: [String] = [to]
                    var node = to
                    while let prev = predecessor[node] {
                        path.append(prev)
                        node = prev
                    }
                    return path.reversed()
                }
                queue.append(parent.id)
            }
        }
        return nil
    }

    // MARK: - Label decision tree

    /// Direct ancestor of subject at depth `d`: 1 = parent, 2 = grandparent, …
    private static func ancestorLabel(depth: Int, gender: Gender?) -> String {
        switch depth {
        case 1:
            switch gender {
            case .male: return "father"
            case .female: return "mother"
            default: return "parent"
            }
        case 2:
            switch gender {
            case .male: return "grandfather"
            case .female: return "grandmother"
            default: return "grandparent"
            }
        default:
            // depth >= 3: great-(N)-grandparent
            // depth 3 = great-grandparent, depth 4 = great-great-grandparent, …
            let greats = String(repeating: "great-", count: depth - 2)
            switch gender {
            case .male: return "\(greats)grandfather"
            case .female: return "\(greats)grandmother"
            default: return "\(greats)grandparent"
            }
        }
    }

    /// Direct descendant of subject at depth `d`: 1 = child, 2 = grandchild, …
    /// Per spec: gendered terms only at depth 1 (son/daughter) and depth 2
    /// (grandson/granddaughter). Beyond that, gender-neutral great-(N)-grandchild.
    private static func descendantLabel(depth: Int, gender: Gender?) -> String {
        switch depth {
        case 1:
            switch gender {
            case .male: return "son"
            case .female: return "daughter"
            default: return "child"
            }
        case 2:
            switch gender {
            case .male: return "grandson"
            case .female: return "granddaughter"
            default: return "grandchild"
            }
        default:
            let greats = String(repeating: "great-", count: depth - 2)
            return "\(greats)grandchild"
        }
    }

    /// Lateral relationship via a common ancestor.
    /// - `d1` = subject's distance up to the LCA
    /// - `d2` = target's distance up to the LCA
    private static func lateralLabel(d1: Int, d2: Int, targetGender: Gender?) -> String {
        // Sibling: LCA is the immediate parent of both (d1 == 1 && d2 == 1).
        if d1 == 1 && d2 == 1 {
            switch targetGender {
            case .male: return "brother"
            case .female: return "sister"
            default: return "sibling"
            }
        }

        // Aunt/uncle territory: target's parent (d2 == 1) is the LCA; subject is at
        // d1 >= 2 from that LCA. So target is a sibling of one of subject's ancestors.
        // Examples:
        //   d1 = 2, d2 = 1 → LCA is target's parent and subject's grandparent →
        //                    target is sibling of subject's parent → aunt/uncle
        //   d1 = 3, d2 = 1 → great-aunt/great-uncle
        //   d1 = 4, d2 = 1 → great-great-aunt/great-great-uncle
        if d2 == 1 && d1 >= 2 {
            let greats = d1 >= 3 ? String(repeating: "great-", count: d1 - 2) : ""
            switch targetGender {
            case .male: return "\(greats)uncle"
            case .female: return "\(greats)aunt"
            default: return "\(greats)aunt/uncle"
            }
        }

        // Nephew/niece territory: subject's parent (d1 == 1) is the LCA; target is at
        // d2 >= 2 from that LCA. So target is a descendant of subject's sibling.
        if d1 == 1 && d2 >= 2 {
            let greats = d2 >= 3 ? String(repeating: "great-", count: d2 - 2) : ""
            switch targetGender {
            case .male: return "\(greats)nephew"
            case .female: return "\(greats)niece"
            default: return "\(greats)nephew/niece"
            }
        }

        // Cousin territory: both d1 >= 2 and d2 >= 2.
        // cousinDegree = min(d1, d2) - 1 → 2/2 = 1st cousin, 3/3 = 2nd cousin, …
        // removed = |d1 - d2| → 0 = same generation, 1 = once removed, …
        let cousinDegree = min(d1, d2) - 1
        let removed = abs(d1 - d2)
        let degreeLabel = ordinal(cousinDegree)
        let base = "\(degreeLabel) cousin"
        switch removed {
        case 0: return base
        case 1: return "\(base) once removed"
        case 2: return "\(base) twice removed"
        default: return "\(base) \(removed) times removed"
        }
    }

    private static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "first"
        case 2: return "second"
        case 3: return "third"
        case 4: return "fourth"
        case 5: return "fifth"
        case 6: return "sixth"
        case 7: return "seventh"
        case 8: return "eighth"
        case 9: return "ninth"
        case 10: return "tenth"
        default:
            // Fallback for very distant cousins
            let suffix: String
            switch n % 10 {
            case 1 where n % 100 != 11: suffix = "st"
            case 2 where n % 100 != 12: suffix = "nd"
            case 3 where n % 100 != 13: suffix = "rd"
            default: suffix = "th"
            }
            return "\(n)\(suffix)"
        }
    }
}

/// Result of a kinship calculation.
nonisolated struct Description: Sendable, Hashable {
    /// Human-readable label like "first cousin once removed" or "self".
    let label: String
    /// Path of profile IDs from subject up to the lowest common ancestor
    /// then back down to target. Empty for `.self` / `.spouse` cases.
    let path: [String]
}
