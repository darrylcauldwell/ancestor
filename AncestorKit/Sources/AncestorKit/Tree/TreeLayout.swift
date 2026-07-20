import Foundation

/// Assigns 2D positions to profiles for tree rendering.
/// Uses progressive disclosure — shows a window of generations around the
/// focal person, never all profiles at once.
public nonisolated struct TreeLayout {

    // MARK: - Node Kind (type-safe ghost representation)

    /// What kind of node this is — real profile or ghost placeholder.
    /// GhostRole is defined in Models/GhostRole.swift (shared with Research pipeline).
    public enum NodeKind: Sendable {
        case profile(Profile, ProfileCompleteness)
        case ghost(parentOf: String, role: GhostRole)
    }

    /// A positioned node for rendering.
    public struct LayoutNode: Identifiable {
        public let id: String
        public let kind: NodeKind
        public let x: Double
        public let y: Double
        public let generation: Int
        public let hasMoreAncestors: Bool
        public let hasMoreDescendants: Bool

        public var isGhost: Bool {
            if case .ghost = kind { return true }
            return false
        }

        public var profile: Profile? {
            if case .profile(let p, _) = kind { return p }
            return nil
        }

        public var completeness: ProfileCompleteness? {
            if case .profile(_, let c) = kind { return c }
            return nil
        }
    }

    /// A visual edge between two positioned nodes.
    public struct LayoutEdge: Identifiable {
        public let id: String
        public let fromID: String
        public let toID: String
        public let fromX: Double
        public let fromY: Double
        public let toX: Double
        public let toY: Double
        public let type: RelationshipType
    }

    public struct LayoutResult {
        public let nodes: [LayoutNode]          // Real profiles only
        public let ghostNodes: [LayoutNode]     // Ghost placeholders only
        public let edges: [LayoutEdge]
        public let contentWidth: Double
        public let contentHeight: Double
        public let rootID: String?

        public init(nodes: [LayoutNode], ghostNodes: [LayoutNode], edges: [LayoutEdge],
                    contentWidth: Double, contentHeight: Double, rootID: String?) {
            self.nodes = nodes
            self.ghostNodes = ghostNodes
            self.edges = edges
            self.contentWidth = contentWidth
            self.contentHeight = contentHeight
            self.rootID = rootID
        }

        /// All nodes for rendering (real + ghost).
        public var allNodes: [LayoutNode] { nodes + ghostNodes }
    }

    // MARK: - Configuration

    public static let nodeWidth: Double = 160
    public static let nodeHeight: Double = 64
    public static let horizontalSpacing: Double = 12
    public static let verticalSpacing: Double = 44
    public static let spouseSpacing: Double = 10
    public static let arrowHitWidth: Double = 80
    public static let arrowHitHeight: Double = 20
    public static let infoIconSize: Double = 24
    public static let spouseChipSize: Double = 18
    public static let spouseChipGap: Double = 4

    /// Layout-space CENTRES of the marriage-switch chips for a person with
    /// `count` marriages — a small row centred below the couple (between the
    /// person and the shown spouse), clear of the person-centred "▼ children"
    /// affordance. Draw AND hit-test both derive chip positions from this, so
    /// they stay perfectly in sync. Empty for < 2 marriages.
    public static func spouseChipCentres(nodeX: Double, nodeY: Double, count: Int) -> [(x: Double, y: Double)] {
        guard count >= 2 else { return [] }
        let midX = nodeX + (nodeWidth + spouseSpacing) / 2
        let rowWidth = Double(count) * spouseChipSize + Double(count - 1) * spouseChipGap
        let firstCentreX = midX - rowWidth / 2 + spouseChipSize / 2
        let y = nodeY + nodeHeight / 2 + spouseChipSize / 2 + 6
        return (0..<count).map { i in
            (x: firstCentreX + Double(i) * (spouseChipSize + spouseChipGap), y: y)
        }
    }
    public static let ghostNodeWidth: Double = 100
    public static let ghostNodeHeight: Double = 48

    // MARK: - Compact Pedigree Layout

    /// Width measurement for a subtree, computed once per profile and cached.
    private struct SubtreeWidth {
        let width: Double
    }

    private enum ParentSide { case left, right }

    /// Determine which side a single parent goes on (father=left, mother=right).
    private static func parentSide(
        realParent: Profile,
        childID: String,
        snapshot: FamilyGraphSnapshot
    ) -> ParentSide {
        // Check relationship role first
        if let rel = snapshot.relationships.first(where: {
            $0.type == .parent && $0.from == realParent.id && $0.to == childID
        }) {
            switch rel.role {
            case .father: return .left
            case .mother: return .right
            case .unspecified, .none: break
            }
        }
        // Fallback: infer from gender
        switch realParent.gender {
        case .male: return .left
        case .female, .other: return .right
        case .unknown, .none: return .left
        }
    }

    /// Measure subtree width bottom-up. Each profile measured exactly once via cache.
    private static func measureWidth(
        profileID: String?,
        generation: Int,
        maxGenerations: Int,
        snapshot: FamilyGraphSnapshot,
        cache: inout [String: SubtreeWidth]
    ) -> SubtreeWidth {
        // Ghost nodes are leaf-sized
        guard let profileID else {
            return SubtreeWidth(width: ghostNodeWidth)
        }

        // Return cached result
        if let cached = cache[profileID] {
            return cached
        }

        // At boundary — leaf-sized
        guard generation < maxGenerations else {
            let result = SubtreeWidth(width: nodeWidth)
            cache[profileID] = result
            return result
        }

        let parents = snapshot.parentsOf(profileID)

        let leftWidth: Double
        let rightWidth: Double

        switch parents.count {
        case 0:
            leftWidth = ghostNodeWidth
            rightWidth = ghostNodeWidth
        case 1:
            let realInfo = measureWidth(
                profileID: parents[0].id, generation: generation + 1,
                maxGenerations: maxGenerations, snapshot: snapshot, cache: &cache
            )
            // Width is the same regardless of side
            leftWidth = realInfo.width
            rightWidth = ghostNodeWidth
        default:
            let left = measureWidth(
                profileID: parents[0].id, generation: generation + 1,
                maxGenerations: maxGenerations, snapshot: snapshot, cache: &cache
            )
            let right = measureWidth(
                profileID: parents[1].id, generation: generation + 1,
                maxGenerations: maxGenerations, snapshot: snapshot, cache: &cache
            )
            leftWidth = left.width
            rightWidth = right.width
        }

        let totalWidth = leftWidth + horizontalSpacing + rightWidth
        let result = SubtreeWidth(width: max(totalWidth, nodeWidth))
        cache[profileID] = result
        return result
    }

    /// Compact pedigree layout — bottom-up width accumulation with ghost nodes.
    /// Root at bottom centre, parents above. Ghost placeholders for missing ancestors.
    public static func pedigreeLayout(
        rootID: String,
        snapshot: FamilyGraphSnapshot,
        maxGenerations: Int = 5,
        activeSpouse: [String: String] = [:]
    ) -> LayoutResult {
        var realNodes: [LayoutNode] = []
        var ghostNodes: [LayoutNode] = []
        var edges: [LayoutEdge] = []
        var visited: Set<String> = []
        var measureCache: [String: SubtreeWidth] = [:]

        let actualDepth = min(maxGenerations,
            countAncestorGenerations(rootID, snapshot: snapshot, max: maxGenerations))

        func place(profileID: String, generation: Int, centreX: Double) {
            guard !visited.contains(profileID),
                  let profile = snapshot.profiles[profileID] else { return }

            visited.insert(profileID)

            let y = Double(actualDepth - generation) * (nodeHeight + verticalSpacing)
            let completeness = snapshot.completeness(for: profileID)
            let parents = snapshot.parentsOf(profileID)
            // Only the ACTIVE marriage's children count toward the "▼ N
            // children" affordance, so the count matches the spouse shown.
            let children = snapshot.displayedChildren(of: profileID, activeSpouse: activeSpouse)

            let hasMoreAncestors = generation == maxGenerations && !parents.isEmpty
            let hasMoreDescendants = generation == 0 && !children.isEmpty

            realNodes.append(LayoutNode(
                id: profileID,
                kind: .profile(profile, completeness),
                x: centreX, y: y, generation: generation,
                hasMoreAncestors: hasMoreAncestors,
                hasMoreDescendants: hasMoreDescendants
            ))

            guard generation < maxGenerations else { return }

            let parentY = Double(actualDepth - generation - 1) * (nodeHeight + verticalSpacing)

            switch parents.count {
            case 0:
                // Two ghost nodes
                let spacing = ghostNodeWidth + horizontalSpacing
                let leftX = centreX - spacing / 2
                let rightX = centreX + spacing / 2
                let fatherID = "__ghost_father_\(profileID)"
                let motherID = "__ghost_mother_\(profileID)"

                ghostNodes.append(LayoutNode(
                    id: fatherID, kind: .ghost(parentOf: profileID, role: .father),
                    x: leftX, y: parentY, generation: generation + 1,
                    hasMoreAncestors: false, hasMoreDescendants: false
                ))
                ghostNodes.append(LayoutNode(
                    id: motherID, kind: .ghost(parentOf: profileID, role: .mother),
                    x: rightX, y: parentY, generation: generation + 1,
                    hasMoreAncestors: false, hasMoreDescendants: false
                ))
                edges.append(LayoutEdge(id: "\(fatherID)->\(profileID)",
                    fromID: fatherID, toID: profileID,
                    fromX: leftX, fromY: parentY, toX: centreX, toY: y, type: .parent))
                edges.append(LayoutEdge(id: "\(motherID)->\(profileID)",
                    fromID: motherID, toID: profileID,
                    fromX: rightX, fromY: parentY, toX: centreX, toY: y, type: .parent))

            case 1:
                // One real parent + one ghost
                let realParent = parents[0]
                let side = parentSide(realParent: realParent, childID: profileID, snapshot: snapshot)
                let realInfo = measureWidth(
                    profileID: realParent.id, generation: generation + 1,
                    maxGenerations: maxGenerations, snapshot: snapshot, cache: &measureCache
                )
                let totalWidth = max(realInfo.width + horizontalSpacing + ghostNodeWidth, nodeWidth)
                let halfTotal = totalWidth / 2

                let realX: Double
                let ghostX: Double
                let ghostID: String
                let ghostRole: GhostRole

                switch side {
                case .left:
                    realX = centreX - halfTotal + realInfo.width / 2
                    ghostX = centreX + halfTotal - ghostNodeWidth / 2
                    ghostID = "__ghost_mother_\(profileID)"
                    ghostRole = .mother
                case .right:
                    ghostX = centreX - halfTotal + ghostNodeWidth / 2
                    realX = centreX + halfTotal - realInfo.width / 2
                    ghostID = "__ghost_father_\(profileID)"
                    ghostRole = .father
                }

                place(profileID: realParent.id, generation: generation + 1, centreX: realX)

                ghostNodes.append(LayoutNode(
                    id: ghostID, kind: .ghost(parentOf: profileID, role: ghostRole),
                    x: ghostX, y: parentY, generation: generation + 1,
                    hasMoreAncestors: false, hasMoreDescendants: false
                ))
                edges.append(LayoutEdge(id: "\(realParent.id)->\(profileID)",
                    fromID: realParent.id, toID: profileID,
                    fromX: realX, fromY: parentY, toX: centreX, toY: y, type: .parent))
                edges.append(LayoutEdge(id: "\(ghostID)->\(profileID)",
                    fromID: ghostID, toID: profileID,
                    fromX: ghostX, fromY: parentY, toX: centreX, toY: y, type: .parent))

            default:
                // Two parents
                let leftInfo = measureWidth(
                    profileID: parents[0].id, generation: generation + 1,
                    maxGenerations: maxGenerations, snapshot: snapshot, cache: &measureCache
                )
                let rightInfo = measureWidth(
                    profileID: parents[1].id, generation: generation + 1,
                    maxGenerations: maxGenerations, snapshot: snapshot, cache: &measureCache
                )
                let totalWidth = max(leftInfo.width + horizontalSpacing + rightInfo.width, nodeWidth)
                let halfTotal = totalWidth / 2

                let leftX = centreX - halfTotal + leftInfo.width / 2
                let rightX = centreX + halfTotal - rightInfo.width / 2

                place(profileID: parents[0].id, generation: generation + 1, centreX: leftX)
                place(profileID: parents[1].id, generation: generation + 1, centreX: rightX)

                edges.append(LayoutEdge(id: "\(parents[0].id)->\(profileID)",
                    fromID: parents[0].id, toID: profileID,
                    fromX: leftX, fromY: parentY, toX: centreX, toY: y, type: .parent))
                edges.append(LayoutEdge(id: "\(parents[1].id)->\(profileID)",
                    fromID: parents[1].id, toID: profileID,
                    fromX: rightX, fromY: parentY, toX: centreX, toY: y, type: .parent))
            }
        }

        // Execute layout
        place(profileID: rootID, generation: 0, centreX: 0)

        // Add the DISPLAYED spouse beside each partner. Under the marriage
        // switcher, a person with multiple spouses (remarriage / widowhood —
        // e.g. David Rose married Margaret, then Jean after Margaret died)
        // shows ONE marriage at a time (the selected one, else the earliest),
        // so at most one spouse card renders here and the generation row stays
        // neat. Previously all spouses shared one x and overwrote each other.
        for node in Array(realNodes) {
            guard node.profile != nil,
                  let spouse = snapshot.displayedSpouse(of: node.id, activeSpouse: activeSpouse),
                  !visited.contains(spouse.id)
            else { continue }
            visited.insert(spouse.id)
            let completeness = snapshot.completeness(for: spouse.id)
            let spouseX = node.x + nodeWidth + spouseSpacing
            realNodes.append(LayoutNode(
                id: spouse.id,
                kind: .profile(spouse, completeness),
                x: spouseX, y: node.y, generation: node.generation,
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

        // Render the focal subject's siblings at generation 0 alongside
        // them. The user's mental model is "focus on a person, see the
        // family group" — pedigree mode previously showed only the
        // ancestor chain going up, hiding siblings even when they
        // existed as full profiles in the tree. We place siblings to
        // the right of the subject's row (after any spouse) sorted by
        // birth year so the family group reads in birth order. Each
        // sibling gets parent-edges to the subject's real parents so
        // the lineage is visually obvious.
        let rootY = realNodes.first(where: { $0.id == rootID })?.y ?? 0
        // Determine where the rightmost existing generation-0 node sits
        // so siblings start beyond it.
        var rightEdge = (realNodes.filter { $0.generation == 0 }.map(\.x).max() ?? 0)
        let siblings = snapshot.siblingsOf(rootID).filter { !visited.contains($0.id) }
        let sortedSiblings = siblings.sorted { lhs, rhs in
            let a = lhs.birthDate?.earliest ?? Int.max
            let b = rhs.birthDate?.earliest ?? Int.max
            if a != b { return a < b }
            return lhs.displayName < rhs.displayName
        }
        // Cache real-parent positions for edge wiring (one parent may
        // be a ghost — those don't generate edges, which is intentional:
        // a placeholder parent shouldn't be shown anchoring siblings).
        let rootParents = snapshot.parentsOf(rootID)
        let parentPositions: [(id: String, x: Double, y: Double)] = rootParents.compactMap { p in
            guard let n = realNodes.first(where: { $0.id == p.id }) else { return nil }
            return (p.id, n.x, n.y)
        }
        for sibling in sortedSiblings {
            visited.insert(sibling.id)
            let completeness = snapshot.completeness(for: sibling.id)
            let siblingX = rightEdge + nodeWidth + horizontalSpacing
            realNodes.append(LayoutNode(
                id: sibling.id,
                kind: .profile(sibling, completeness),
                x: siblingX, y: rootY, generation: 0,
                hasMoreAncestors: false, hasMoreDescendants: false
            ))
            for parent in parentPositions {
                edges.append(LayoutEdge(
                    id: "\(parent.id)->\(sibling.id)",
                    fromID: parent.id, toID: sibling.id,
                    fromX: parent.x, fromY: parent.y,
                    toX: siblingX, toY: rootY,
                    type: .parent
                ))
            }
            rightEdge = siblingX
        }

        // Calculate bounds from all nodes (real + ghost)
        let allNodes = realNodes + ghostNodes
        let allX = allNodes.map(\.x)
        let allY = allNodes.map(\.y)
        let minX = (allX.min() ?? 0) - nodeWidth / 2
        let maxX = (allX.max() ?? 0) + nodeWidth / 2 + nodeWidth
        let minY = (allY.min() ?? 0) - nodeHeight / 2
        let maxY = (allY.max() ?? 0) + nodeHeight / 2

        return LayoutResult(
            nodes: realNodes,
            ghostNodes: ghostNodes,
            edges: edges,
            contentWidth: maxX - minX + horizontalSpacing * 2,
            contentHeight: maxY - minY + verticalSpacing * 2,
            rootID: rootID
        )
    }

    // MARK: - Descendant Layout

    /// Show descendants of a focal person, expanding downward.
    /// Spouses are placed inline during layout (not post-processed)
    /// to ensure correct horizontal spacing at every level.
    public static func descendantLayout(
        rootID: String,
        snapshot: FamilyGraphSnapshot,
        maxGenerations: Int = 4,
        activeSpouse: [String: String] = [:]
    ) -> LayoutResult {
        var nodes: [LayoutNode] = []
        var edges: [LayoutEdge] = []
        var visited: Set<String> = []
        var nextX: Double = 0

        /// Place a person and their spouse(s), returning the person's x position.
        /// Advances nextX past the entire family unit (person + spouses).
        func place(profileID: String, generation: Int) -> Double {
            guard generation <= maxGenerations,
                  !visited.contains(profileID),
                  let profile = snapshot.profiles[profileID] else { return nextX }

            visited.insert(profileID)

            // Only the active marriage's children under the switcher.
            let children = snapshot.displayedChildren(of: profileID, activeSpouse: activeSpouse)
            let y = Double(generation) * (nodeHeight + verticalSpacing)
            let completeness = snapshot.completeness(for: profileID)

            if children.isEmpty || generation == maxGenerations {
                // Leaf node — place person, then spouse(s) to the right
                let x = nextX
                let hasMore = generation == maxGenerations && !children.isEmpty
                nodes.append(LayoutNode(
                    id: profileID,
                    kind: .profile(profile, completeness),
                    x: x, y: y, generation: generation,
                    hasMoreAncestors: false,
                    hasMoreDescendants: hasMore
                ))
                nextX += nodeWidth + spouseSpacing

                // Place spouses inline
                placeSpouses(of: profileID, personX: x, atY: y, generation: generation)

                // Ensure gap before next sibling
                nextX += horizontalSpacing - spouseSpacing
                return x
            } else {
                // Branch node — place children first, then centre parent over them
                var childXs: [Double] = []
                for child in children {
                    let childX = place(profileID: child.id, generation: generation + 1)
                    childXs.append(childX)
                }

                let x = childXs.isEmpty ? nextX : (childXs.first! + childXs.last!) / 2

                // Ensure the parent (+ spouse) doesn't overlap with already-placed nodes
                let minX = nextX  // never go left of what's already placed

                // But also don't go left of centre-over-children position
                let finalX = max(x, minX)

                nodes.append(LayoutNode(
                    id: profileID,
                    kind: .profile(profile, completeness),
                    x: finalX, y: y, generation: generation,
                    hasMoreAncestors: false, hasMoreDescendants: false
                ))

                // Place spouses inline, starting right of the person
                let savedNextX = nextX
                nextX = finalX + nodeWidth + spouseSpacing
                placeSpouses(of: profileID, personX: finalX, atY: y, generation: generation)
                nextX = max(nextX, savedNextX) // don't go backwards

                // Parent-child edges
                for (i, child) in children.enumerated() where i < childXs.count {
                    edges.append(LayoutEdge(
                        id: "\(profileID)->\(child.id)",
                        fromID: profileID, toID: child.id,
                        fromX: finalX, fromY: y,
                        toX: childXs[i],
                        toY: Double(generation + 1) * (nodeHeight + verticalSpacing),
                        type: .parent
                    ))
                }

                return finalX
            }
        }

        /// Place the DISPLAYED spouse of a person to the right, advancing nextX.
        /// Under the switcher a multi-spouse person shows one marriage at a time.
        func placeSpouses(of profileID: String, personX: Double, atY y: Double, generation: Int) {
            let spouses = [snapshot.displayedSpouse(of: profileID, activeSpouse: activeSpouse)]
                .compactMap { $0 }
                .filter { !visited.contains($0.id) }
            for spouse in spouses {
                visited.insert(spouse.id)
                let spouseX = nextX
                let completeness = snapshot.completeness(for: spouse.id)
                nodes.append(LayoutNode(
                    id: spouse.id,
                    kind: .profile(spouse, completeness),
                    x: spouseX, y: y, generation: generation,
                    hasMoreAncestors: false, hasMoreDescendants: false
                ))
                edges.append(LayoutEdge(
                    id: "\(profileID)=\(spouse.id)",
                    fromID: profileID, toID: spouse.id,
                    fromX: personX, fromY: y,
                    toX: spouseX, toY: y,
                    type: .spouse
                ))
                nextX += nodeWidth + spouseSpacing
            }
        }

        _ = place(profileID: rootID, generation: 0)

        let width = (nodes.map(\.x).max() ?? 0) + nodeWidth * 2
        let height = (nodes.map(\.y).max() ?? 0) + nodeHeight * 2

        return LayoutResult(nodes: nodes, ghostNodes: [],
                           edges: edges, contentWidth: width, contentHeight: height, rootID: rootID)
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
