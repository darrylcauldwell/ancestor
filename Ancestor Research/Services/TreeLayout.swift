import Foundation

/// Assigns 2D positions to profiles for tree rendering.
/// Uses progressive disclosure — shows a window of generations around the
/// focal person, never all profiles at once.
/// Based on patterns from Ancestry, FamilySearch, WikiTree, MacFamilyTree.
nonisolated struct TreeLayout {

    /// A positioned node for rendering.
    struct LayoutNode: Identifiable {
        let id: String
        let profile: Profile
        let x: Double
        let y: Double
        let generation: Int
        let completeness: ProfileCompleteness
        let hasMoreAncestors: Bool  // Show expand indicator
        let hasMoreDescendants: Bool
    }

    /// A visual edge between two positioned nodes.
    struct LayoutEdge: Identifiable {
        let id: String
        let fromID: String
        let toID: String
        let fromX: Double
        let fromY: Double
        let toX: Double
        let toY: Double
        let type: RelationshipType
    }

    struct LayoutResult {
        let nodes: [LayoutNode]
        let edges: [LayoutEdge]
        let width: Double
        let height: Double
        let rootID: String?
    }

    // MARK: - Configuration

    static let nodeWidth: Double = 200
    static let nodeHeight: Double = 80
    static let horizontalSpacing: Double = 40
    static let verticalSpacing: Double = 100
    static let spouseSpacing: Double = 24

    // MARK: - Focussed Pedigree Layout

    /// Show 5 generations of ancestors from a focal person.
    /// Root at bottom centre, parents above, grandparents above that.
    /// Max ~31 nodes visible — readable and navigable.
    static func pedigreeLayout(
        rootID: String,
        snapshot: FamilyGraphSnapshot,
        maxGenerations: Int = 5
    ) -> LayoutResult {
        var nodes: [LayoutNode] = []
        var edges: [LayoutEdge] = []
        var visited: Set<String> = []

        // Calculate how many generations actually exist
        let actualDepth = min(maxGenerations, countAncestorGenerations(rootID, snapshot: snapshot, max: maxGenerations))
        let totalRows = actualDepth + 1  // +1 for the root

        // Place root at bottom centre
        let rootX = 0.0
        let rootY = Double(actualDepth) * (nodeHeight + verticalSpacing)

        func place(profileID: String, generation: Int, x: Double, slotWidth: Double) {
            guard generation <= maxGenerations,
                  !visited.contains(profileID),
                  let profile = snapshot.profiles[profileID] else { return }

            visited.insert(profileID)

            let y = Double(actualDepth - generation) * (nodeHeight + verticalSpacing)
            let completeness = snapshot.completeness(for: profileID)
            let parents = snapshot.parentsOf(profileID)
            let children = snapshot.childrenOf(profileID)

            // Check if there are more beyond our window
            let hasMoreAncestors = generation == maxGenerations && !parents.isEmpty
            let hasMoreDescendants = generation == 0 && !children.isEmpty && profileID != rootID

            nodes.append(LayoutNode(
                id: profileID, profile: profile,
                x: x, y: y, generation: generation,
                completeness: completeness,
                hasMoreAncestors: hasMoreAncestors,
                hasMoreDescendants: hasMoreDescendants
            ))

            // Place parents above
            if generation < maxGenerations && !parents.isEmpty {
                let halfSlot = slotWidth / 4

                if parents.count >= 1 {
                    let parentX = x - halfSlot
                    let parentY = Double(actualDepth - generation - 1) * (nodeHeight + verticalSpacing)
                    place(profileID: parents[0].id, generation: generation + 1,
                          x: parentX, slotWidth: slotWidth / 2)
                    edges.append(LayoutEdge(
                        id: "\(parents[0].id)->\(profileID)",
                        fromID: parents[0].id, toID: profileID,
                        fromX: parentX, fromY: parentY,
                        toX: x, toY: y, type: .parent
                    ))
                }

                if parents.count >= 2 {
                    let parentX = x + halfSlot
                    let parentY = Double(actualDepth - generation - 1) * (nodeHeight + verticalSpacing)
                    place(profileID: parents[1].id, generation: generation + 1,
                          x: parentX, slotWidth: slotWidth / 2)
                    edges.append(LayoutEdge(
                        id: "\(parents[1].id)->\(profileID)",
                        fromID: parents[1].id, toID: profileID,
                        fromX: parentX, fromY: parentY,
                        toX: x, toY: y, type: .parent
                    ))
                }
            }
        }

        // Calculate initial slot width based on generations
        let totalWidth = pow(2.0, Double(actualDepth)) * (nodeWidth + horizontalSpacing)
        place(profileID: rootID, generation: 0, x: 0, slotWidth: totalWidth)

        // Add spouses beside their partners
        for node in Array(nodes) {
            let spouses = snapshot.spousesOf(node.id)
            for spouse in spouses where !visited.contains(spouse.id) {
                visited.insert(spouse.id)
                let completeness = snapshot.completeness(for: spouse.id)
                let spouseX = node.x + nodeWidth + spouseSpacing
                nodes.append(LayoutNode(
                    id: spouse.id, profile: spouse,
                    x: spouseX, y: node.y, generation: node.generation,
                    completeness: completeness,
                    hasMoreAncestors: false, hasMoreDescendants: false
                ))
                edges.append(LayoutEdge(
                    id: "\(node.id)=\(spouse.id)",
                    fromID: node.id, toID: spouse.id,
                    fromX: node.x, fromY: node.y,
                    toX: spouseX, toY: node.y,
                    type: .spouse
                ))
            }
        }

        // Calculate bounds
        let allX = nodes.map(\.x)
        let allY = nodes.map(\.y)
        let minX = (allX.min() ?? 0) - nodeWidth / 2
        let maxX = (allX.max() ?? 0) + nodeWidth / 2 + nodeWidth // Extra for spouse
        let minY = (allY.min() ?? 0) - nodeHeight / 2
        let maxY = (allY.max() ?? 0) + nodeHeight / 2

        return LayoutResult(
            nodes: nodes, edges: edges,
            width: maxX - minX + horizontalSpacing * 2,
            height: maxY - minY + verticalSpacing * 2,
            rootID: rootID
        )
    }

    // MARK: - Descendant Layout

    /// Show descendants of a focal person, expanding downward.
    /// Limited to 4 generations to keep it readable.
    static func descendantLayout(
        rootID: String,
        snapshot: FamilyGraphSnapshot,
        maxGenerations: Int = 4
    ) -> LayoutResult {
        var nodes: [LayoutNode] = []
        var edges: [LayoutEdge] = []
        var visited: Set<String> = []
        var nextX: Double = 0

        func place(profileID: String, generation: Int) -> Double {
            guard generation <= maxGenerations,
                  !visited.contains(profileID),
                  let profile = snapshot.profiles[profileID] else { return nextX }

            visited.insert(profileID)

            let children = snapshot.childrenOf(profileID)
            let y = Double(generation) * (nodeHeight + verticalSpacing)

            if children.isEmpty || generation == maxGenerations {
                // Leaf node or max depth
                let x = nextX
                let completeness = snapshot.completeness(for: profileID)
                let hasMore = generation == maxGenerations && !children.isEmpty
                nodes.append(LayoutNode(
                    id: profileID, profile: profile,
                    x: x, y: y, generation: generation,
                    completeness: completeness,
                    hasMoreAncestors: false,
                    hasMoreDescendants: hasMore
                ))
                nextX += nodeWidth + horizontalSpacing
                return x
            } else {
                // Place children first, then centre parent
                var childXs: [Double] = []
                for child in children {
                    let childX = place(profileID: child.id, generation: generation + 1)
                    childXs.append(childX)
                }

                let x = childXs.isEmpty ? nextX : (childXs.first! + childXs.last!) / 2
                let completeness = snapshot.completeness(for: profileID)
                nodes.append(LayoutNode(
                    id: profileID, profile: profile,
                    x: x, y: y, generation: generation,
                    completeness: completeness,
                    hasMoreAncestors: false, hasMoreDescendants: false
                ))

                // Add edges to children
                for (i, child) in children.enumerated() where i < childXs.count {
                    edges.append(LayoutEdge(
                        id: "\(profileID)->\(child.id)",
                        fromID: profileID, toID: child.id,
                        fromX: x, fromY: y,
                        toX: childXs[i],
                        toY: Double(generation + 1) * (nodeHeight + verticalSpacing),
                        type: .parent
                    ))
                }

                return x
            }
        }

        _ = place(profileID: rootID, generation: 0)

        // Add spouses beside their partners
        for node in Array(nodes) {
            let spouses = snapshot.spousesOf(node.id)
            for spouse in spouses where !visited.contains(spouse.id) {
                visited.insert(spouse.id)
                let completeness = snapshot.completeness(for: spouse.id)
                let spouseX = node.x + nodeWidth + spouseSpacing
                nodes.append(LayoutNode(
                    id: spouse.id, profile: spouse,
                    x: spouseX, y: node.y, generation: node.generation,
                    completeness: completeness,
                    hasMoreAncestors: false, hasMoreDescendants: false
                ))
                edges.append(LayoutEdge(
                    id: "\(node.id)=\(spouse.id)",
                    fromID: node.id, toID: spouse.id,
                    fromX: node.x, fromY: node.y,
                    toX: spouseX, toY: node.y,
                    type: .spouse
                ))
            }
        }

        let width = (nodes.map(\.x).max() ?? 0) + nodeWidth * 2
        let height = (nodes.map(\.y).max() ?? 0) + nodeHeight * 2

        return LayoutResult(nodes: nodes, edges: edges,
                           width: width, height: height, rootID: rootID)
    }

    // MARK: - Overview Layout (all profiles as small dots)

    /// Grid of all profiles — for orientation, not detailed reading.
    /// Nodes are small, colour-coded by completeness.
    static func overviewLayout(snapshot: FamilyGraphSnapshot) -> LayoutResult {
        let sorted = snapshot.profiles.values.sorted { a, b in
            let ca = snapshot.completeness(for: a.id)
            let cb = snapshot.completeness(for: b.id)
            if ca.score != cb.score { return ca.score > cb.score }
            return a.displayName < b.displayName
        }

        let columns = max(1, Int(sqrt(Double(sorted.count))))
        var nodes: [LayoutNode] = []

        for (i, profile) in sorted.enumerated() {
            let col = i % columns
            let row = i / columns
            let x = Double(col) * (nodeWidth + horizontalSpacing)
            let y = Double(row) * (nodeHeight + horizontalSpacing / 2)
            let completeness = snapshot.completeness(for: profile.id)
            nodes.append(LayoutNode(
                id: profile.id, profile: profile,
                x: x, y: y, generation: 0,
                completeness: completeness,
                hasMoreAncestors: false, hasMoreDescendants: false
            ))
        }

        let width = Double(columns) * (nodeWidth + horizontalSpacing)
        let height = (nodes.map(\.y).max() ?? 0) + nodeHeight

        return LayoutResult(nodes: nodes, edges: [],
                           width: width, height: height, rootID: nil)
    }

    // MARK: - Helpers

    private static func countAncestorGenerations(_ id: String, snapshot: FamilyGraphSnapshot, max: Int) -> Int {
        guard max > 0 else { return 0 }
        let parents = snapshot.parentsOf(id)
        if parents.isEmpty { return 0 }
        let depths = parents.map { countAncestorGenerations($0.id, snapshot: snapshot, max: max - 1) }
        return 1 + (depths.max() ?? 0)
    }
}
