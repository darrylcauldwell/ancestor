import Foundation

/// Assigns 2D positions to profiles for tree rendering.
/// Supports pedigree (ancestors upward) and descendant (children downward) views.
struct TreeLayout {

    /// A positioned node for rendering.
    struct LayoutNode: Identifiable {
        let id: String
        let profile: Profile
        let x: Double
        let y: Double
        let generation: Int
        let completeness: ProfileCompleteness
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
    }

    // MARK: - Configuration

    static let nodeWidth: Double = 160
    static let nodeHeight: Double = 60
    static let horizontalSpacing: Double = 30
    static let verticalSpacing: Double = 80
    static let spouseSpacing: Double = 20

    // MARK: - Pedigree Layout (ancestors upward)

    /// Layout ancestors of a root person. Root at bottom, parents above,
    /// grandparents above that, etc.
    static func pedigreeLayout(
        rootID: String,
        snapshot: FamilyGraphSnapshot,
        maxGenerations: Int = 8
    ) -> LayoutResult {
        var nodes: [LayoutNode] = []
        var edges: [LayoutEdge] = []
        var visited: Set<String> = []

        // Assign positions using recursive pedigree algorithm
        // Each ancestor generation doubles the available slots
        func place(profileID: String, generation: Int, slot: Double, totalSlots: Double) {
            guard generation <= maxGenerations,
                  !visited.contains(profileID),
                  let profile = snapshot.profiles[profileID] else { return }

            visited.insert(profileID)

            let x = slot * (nodeWidth + horizontalSpacing)
            let y = Double(generation) * (nodeHeight + verticalSpacing)
            let completeness = snapshot.completeness(for: profileID)

            nodes.append(LayoutNode(
                id: profileID, profile: profile,
                x: x, y: y, generation: generation,
                completeness: completeness
            ))

            // Place parents in the generation above
            let parents = snapshot.parentsOf(profileID)
            if parents.count >= 1 {
                let leftSlot = slot - totalSlots / 4
                let rightSlot = slot + totalSlots / 4
                let nextTotalSlots = totalSlots / 2

                place(profileID: parents[0].id, generation: generation - 1,
                      slot: leftSlot, totalSlots: nextTotalSlots)
                edges.append(LayoutEdge(
                    id: "\(parents[0].id)->\(profileID)",
                    fromID: parents[0].id, toID: profileID,
                    fromX: leftSlot * (nodeWidth + horizontalSpacing),
                    fromY: Double(generation - 1) * (nodeHeight + verticalSpacing),
                    toX: x, toY: y, type: .parent
                ))

                if parents.count >= 2 {
                    place(profileID: parents[1].id, generation: generation - 1,
                          slot: rightSlot, totalSlots: nextTotalSlots)
                    edges.append(LayoutEdge(
                        id: "\(parents[1].id)->\(profileID)",
                        fromID: parents[1].id, toID: profileID,
                        fromX: rightSlot * (nodeWidth + horizontalSpacing),
                        fromY: Double(generation - 1) * (nodeHeight + verticalSpacing),
                        toX: x, toY: y, type: .parent
                    ))
                }
            }
        }

        // Count generations to determine initial slot range
        let genCount = countAncestorGenerations(rootID, snapshot: snapshot, max: maxGenerations)
        let totalSlots = pow(2.0, Double(genCount))
        let centerSlot = totalSlots / 2

        place(profileID: rootID, generation: genCount, slot: centerSlot, totalSlots: totalSlots)

        // Normalise coordinates so minimum x,y is 0
        let minX = nodes.map(\.x).min() ?? 0
        let minY = nodes.map(\.y).min() ?? 0
        let adjustedNodes = nodes.map { node in
            LayoutNode(id: node.id, profile: node.profile,
                       x: node.x - minX + nodeWidth / 2,
                       y: node.y - minY + nodeHeight / 2,
                       generation: node.generation,
                       completeness: node.completeness)
        }
        let adjustedEdges = edges.map { edge in
            LayoutEdge(id: edge.id, fromID: edge.fromID, toID: edge.toID,
                       fromX: edge.fromX - minX + nodeWidth / 2,
                       fromY: edge.fromY - minY + nodeHeight / 2,
                       toX: edge.toX - minX + nodeWidth / 2,
                       toY: edge.toY - minY + nodeHeight / 2,
                       type: edge.type)
        }

        let width = (adjustedNodes.map(\.x).max() ?? 0) + nodeWidth
        let height = (adjustedNodes.map(\.y).max() ?? 0) + nodeHeight

        return LayoutResult(nodes: adjustedNodes, edges: adjustedEdges,
                           width: width, height: height)
    }

    // MARK: - Descendant Layout (children downward)

    /// Layout descendants of a root person. Root at top, children below.
    static func descendantLayout(
        rootID: String,
        snapshot: FamilyGraphSnapshot,
        maxGenerations: Int = 6
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

            if children.isEmpty {
                // Leaf node — place at next available x
                let x = nextX
                let completeness = snapshot.completeness(for: profileID)
                nodes.append(LayoutNode(
                    id: profileID, profile: profile,
                    x: x, y: y, generation: generation,
                    completeness: completeness
                ))
                nextX += nodeWidth + horizontalSpacing
                return x
            } else {
                // Internal node — place children first, then center parent above them
                var childXs: [Double] = []
                for child in children {
                    let childX = place(profileID: child.id, generation: generation + 1)
                    edges.append(LayoutEdge(
                        id: "\(profileID)->\(child.id)",
                        fromID: profileID, toID: child.id,
                        fromX: 0, fromY: 0, // Will be adjusted
                        toX: childX, toY: Double(generation + 1) * (nodeHeight + verticalSpacing),
                        type: .parent
                    ))
                    childXs.append(childX)
                }

                let x = childXs.isEmpty ? nextX : (childXs.first! + childXs.last!) / 2
                let completeness = snapshot.completeness(for: profileID)
                nodes.append(LayoutNode(
                    id: profileID, profile: profile,
                    x: x, y: y, generation: generation,
                    completeness: completeness
                ))

                // Fix edge start positions
                for i in edges.indices where edges[i].fromID == profileID {
                    edges[i] = LayoutEdge(
                        id: edges[i].id, fromID: edges[i].fromID, toID: edges[i].toID,
                        fromX: x, fromY: y,
                        toX: edges[i].toX, toY: edges[i].toY,
                        type: edges[i].type
                    )
                }

                return x
            }
        }

        _ = place(profileID: rootID, generation: 0)

        // Add spouse nodes beside their partners
        for node in Array(nodes) {
            let spouses = snapshot.spousesOf(node.id)
            for spouse in spouses where !visited.contains(spouse.id) {
                visited.insert(spouse.id)
                let completeness = snapshot.completeness(for: spouse.id)
                nodes.append(LayoutNode(
                    id: spouse.id, profile: spouse,
                    x: node.x + nodeWidth + spouseSpacing,
                    y: node.y, generation: node.generation,
                    completeness: completeness
                ))
                edges.append(LayoutEdge(
                    id: "\(node.id)=\(spouse.id)",
                    fromID: node.id, toID: spouse.id,
                    fromX: node.x, fromY: node.y,
                    toX: node.x + nodeWidth + spouseSpacing, toY: node.y,
                    type: .spouse
                ))
            }
        }

        let width = (nodes.map(\.x).max() ?? 0) + nodeWidth + horizontalSpacing
        let height = (nodes.map(\.y).max() ?? 0) + nodeHeight + verticalSpacing

        return LayoutResult(nodes: nodes, edges: edges, width: width, height: height)
    }

    // MARK: - Overview Layout (all profiles)

    /// Simple grid layout showing all profiles sorted by completeness.
    /// Used when no root is selected.
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
                completeness: completeness
            ))
        }

        let width = Double(columns) * (nodeWidth + horizontalSpacing)
        let height = (nodes.map(\.y).max() ?? 0) + nodeHeight

        return LayoutResult(nodes: nodes, edges: [], width: width, height: height)
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
