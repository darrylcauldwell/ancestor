# Compact Pedigree Layout + Ghost Nodes — Detailed Specification

**Status:** Proposed (v2 — revised after critique)  
**Scope:** TreeLayout.swift, TreeGraphView.swift (drawing), LayoutNode  
**Date:** 2026-04-24  

---

## 1. Problem Statement

The pedigree layout allocates horizontal space as a full binary tree — every person gets a slot width calculated as if they have two parents at every generation up to `maxGenerations`. Real family trees are ragged: some branches go back 6 generations, others stop at 1. The result is excessive horizontal spread, with existing profiles pushed far apart and large empty gaps where ancestors are unknown.

**Measured impact with the current 71-profile tree:**

| Metric | Current state | Problem |
|--------|-------------|---------|
| Width at 4 ancestor levels | `(160 + 12) × 2^4 = 2752pt` | Far exceeds a 1440pt display — requires horizontal panning |
| Visible profiles without panning | ~6-10 | Most of the 15 possible nodes at 4 ancestor levels are off-screen |
| Empty space | ~60-70% of allocated width is unused | Branches that stop early still reserve full binary-tree width |
| Unknown ancestors | Invisible — no visual representation | User can't see where research is needed from the tree view |

**Terminology note:** "4 generations" in this spec means `maxGenerations = 4` — four ancestor levels above the root (parents, grandparents, great-grandparents, great-great-grandparents). Generation 0 is the root, generation 4 is 2^4 = 16 possible slots.

---

## 2. Current State — Binary-Split Layout

### 2.1 Algorithm (TreeLayout.swift:57–176)

The `pedigreeLayout` function works top-down by slot allocation:

1. **Calculate total width:** `outermostSlot × 2^actualDepth` where `outermostSlot = nodeWidth + horizontalSpacing = 172pt`
2. **Place root** at `(0, bottomY)` with the full `totalWidth` as its slot
3. **Recurse:** For each person, split their slot in half. Place father at `x - slotWidth/4`, mother at `x + slotWidth/4`, each inheriting `slotWidth/2`
4. **Result:** Every node's horizontal position is predetermined by the binary tree structure, regardless of whether siblings/cousins exist

### 2.2 Key Properties

- **Slot width halves per generation.** A node at generation N has slot width `totalWidth / 2^N`. At generation 4, each slot is `2752 / 16 = 172pt` — just enough for one node.
- **Positions are fixed.** A father is always at `parent.x - slotWidth/4` regardless of whether the mother exists. A single parent with no spouse still occupies half the width that two parents would.
- **Empty branches waste space.** If Isaac Land has no parents but his wife Hannah Barker has 3 generations of ancestors, Isaac's side still reserves `totalWidth/4` for non-existent people.
- **No ghost nodes.** Unknown ancestors are simply absent — no placeholder, no visual signal.

### 2.3 Data Structures

```swift
struct LayoutNode: Identifiable {
    let id: String
    let profile: Profile          // Real profile data — required, no ghosts possible
    let x: Double
    let y: Double
    let generation: Int
    let completeness: ProfileCompleteness
    let hasMoreAncestors: Bool
    let hasMoreDescendants: Bool
}
```

`LayoutNode` requires a `Profile` — it cannot represent an unknown ancestor.

---

## 3. Target State — Bottom-Up Compact Layout + Ghost Nodes

### 3.1 Algorithm Overview

Replace the top-down slot-splitting approach with a **bottom-up width-accumulation** algorithm. Instead of pre-allocating width and subdividing, start at the leaves, measure how wide each subtree actually is, and position parents centred above their children.

**Two-pass approach:**
1. **Measure pass (bottom-up):** Compute the width each subtree needs. Leaf nodes need `nodeWidth`. Branches need the sum of their children's widths plus spacing. Results are **memoised** by profile ID — each subtree is measured once.
2. **Place pass (top-down):** From the root, assign x-coordinates. The root is at x=0. Each parent pair is centred above their child using the measured widths to determine offsets.

This is a simplified pedigree-specific layout, not a full Reingold-Tilford implementation. It centres each parent pair geometrically above their child. In asymmetric trees (one parent has deep ancestry, the other doesn't), this means the parent with more ancestry will appear offset from centre within their own subtree. This is a **known limitation** — a proper Reingold-Tilford with contour tracking would fix it, but adds significant complexity. The simplified version produces good results for most real family trees and is a major improvement over the current binary-split layout.

### 3.2 Memoised Measurement

```swift
/// Width measurement for a subtree, computed once per profile and cached.
private struct SubtreeWidth {
    let width: Double  // total horizontal space this subtree needs
}
```

The `rootOffset` field from v1 is dropped — it was always `width/2` (geometric centre), which conveys no information. Each parent pair is positioned symmetrically around their child's x-coordinate using the measured widths directly.

**Measurement with cache:**

```swift
/// Measure subtree width bottom-up. Each profile measured exactly once.
/// O(N) where N is the number of profiles in the visible window.
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

    // Return cached result if available
    if let cached = cache[profileID] {
        return cached
    }

    // Leaf: at boundary or no parents
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
        // Two ghosts above
        leftWidth = ghostNodeWidth
        rightWidth = ghostNodeWidth
    case 1:
        // One real parent + one ghost
        let realInfo = measureWidth(
            profileID: parents[0].id, generation: generation + 1,
            maxGenerations: maxGenerations, snapshot: snapshot, cache: &cache
        )
        leftWidth = realInfo.width  // which side depends on role, but width is the same either way
        rightWidth = ghostNodeWidth
    default:
        // Two parents
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
```

**Complexity:** O(N) where N is the number of profiles in the visible generation window. Each profile's subtree width is computed exactly once and cached. `snapshot.parentsOf(id)` filters the relationships array — O(R) per call where R is the relationship count. With 71 profiles and ~70 relationships, the total cost is trivially fast.

### 3.3 Ghost Node Rules

**When to create ghosts:**

Ghost nodes are created for any person within the visible generation window (generations 0 through `maxGenerations - 1`) who has fewer than 2 known parents. Ghosts ARE created at the outermost visible generation — this is deliberate. Every gap in the visible window is a research target, and hiding boundary gaps would mislead the user into thinking the branch is complete.

**Exception for sparse boundary:** No exception. A wall of ghosts at the boundary of a sparsely-researched tree is an honest signal: "you have work to do here." This is preferable to hiding the gaps.

**Ghost placement rules:**

| Parent count | Ghost creation | Side assignment |
|-------------|---------------|-----------------|
| 0 parents | Two ghosts: father (left), mother (right) | Fixed convention |
| 1 parent with role `.father` | One ghost on the right (mother) | Role-based |
| 1 parent with role `.mother` | One ghost on the left (father) | Role-based |
| 1 parent with role `.unspecified` | Infer from gender: male → father (left), female → mother (right). If gender unknown, place real parent left, ghost right. | Gender fallback, then convention |
| 2 parents | No ghosts | — |

**Role detection with fallback:**

```swift
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
    case .female: return .right
    case .unknown, .none: return .left  // convention: unknown → left
    }
}

private enum ParentSide { case left, right }
```

### 3.4 Node Kind — Type-Safe Ghost Representation

Replace the optional `profile: Profile?` with an enum that makes the two states mutually exclusive:

```swift
/// What kind of node this is — real profile or ghost placeholder.
enum NodeKind: Sendable {
    case profile(Profile, ProfileCompleteness)
    case ghost(parentOf: String, role: GhostRole)
}

enum GhostRole: Sendable {
    case father, mother, unknown
}
```

Updated LayoutNode:

```swift
struct LayoutNode: Identifiable {
    let id: String
    let kind: NodeKind
    let x: Double
    let y: Double
    let generation: Int
    let hasMoreAncestors: Bool
    let hasMoreDescendants: Bool

    /// Convenience accessors
    var isGhost: Bool {
        if case .ghost = kind { return true }
        return false
    }

    var profile: Profile? {
        if case .profile(let p, _) = kind { return p }
        return nil
    }

    var completeness: ProfileCompleteness? {
        if case .profile(_, let c) = kind { return c }
        return nil
    }
}
```

**Benefits over `profile: Profile?`:**
- Ghost state and profile state are mutually exclusive at the type level — no nil-checking accidents
- Ghost metadata (role, parentOf) is carried in the enum, not in separate optional fields
- `GhostRole` replaces string-sniffing the ID for "father"/"mother" — no collision risk

**Ghost ID scheme:** Use a prefix that cannot appear in real profile IDs: `"__ghost_father_\(childID)"` and `"__ghost_mother_\(childID)"`. The double-underscore prefix is a safe namespace — WikiTree IDs are `LastName-NNN` format, GEDCOM IDs are `@I123@` format, neither starts with `__`.

### 3.5 Separate Ghost Array (LayoutResult)

To prevent ghost nodes from leaking into selection, search, hit-testing, keyboard navigation, and history:

```swift
struct LayoutResult {
    let nodes: [LayoutNode]           // Real profiles only
    let ghostNodes: [LayoutNode]      // Ghost placeholders only
    let edges: [LayoutEdge]
    let width: Double
    let height: Double
    let rootID: String?

    /// All nodes for rendering (real + ghost)
    var allNodes: [LayoutNode] { nodes + ghostNodes }
}
```

**System integration — what uses which array:**

| System | Array | Rationale |
|--------|-------|-----------|
| Canvas rendering (draw loop) | `allNodes` | Both real and ghost nodes are drawn |
| Edge rendering | `edges` | Edges connect to both real and ghost nodes |
| Hit testing | `nodes` only | Ghosts are not clickable |
| Selection (`selectedProfileID`) | `nodes` only | Can't select a ghost |
| Search (`filteredNodes`) | `nodes` only | Ghosts don't appear in search |
| Popover | `nodes` only | No popover on ghosts |
| ⓘ icon | `nodes` only | No info icon on ghosts |
| Arrow indicators (▲/▼) | `nodes` only | Ghosts don't show expand indicators |
| Hover highlight | `nodes` only | No hover state on ghosts (MVP) |
| Keyboard navigation | `nodes` only | Can't navigate to a ghost |
| Breadcrumb / history | `nodes` only | Ghost IDs never enter history |
| Popover visible-node filter | `nodes` only | Ghost IDs don't count as "visible" for off-canvas relative logic |

This is a complete enumeration. Any new system that processes nodes should default to `nodes` (real only) and opt into `allNodes` explicitly.

### 3.6 Keyboard Navigation at Ghost Parents

When a user selects a profile whose parent(s) are ghosts and presses ↑ or ⇧↑:

- **↑ (father):** If the father is a ghost, play `NSSound.beep()`. No toast — the ghost is visible on screen, the user can see why navigation fails.
- **⇧↑ (mother):** Same — beep if mother is a ghost.
- **Rule:** `snapshot.parentsOf(id)` returns only real profiles, so arrow-key navigation naturally skips ghosts. The beep comes from the existing "no target found" path. No new code needed — the current keyboard handler already beeps when `targetID == nil`.

### 3.7 Complete Place Algorithm

```swift
static func pedigreeLayout(
    rootID: String,
    snapshot: FamilyGraphSnapshot,
    maxGenerations: Int = 5
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
        let children = snapshot.childrenOf(profileID)

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

    // Execute
    place(profileID: rootID, generation: 0, centreX: 0)

    // Add spouses beside their partners (unchanged logic, operates on realNodes)
    for node in Array(realNodes) {
        let spouses = snapshot.spousesOf(node.id)
        for spouse in spouses where !visited.contains(spouse.id) {
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
        width: maxX - minX + horizontalSpacing * 2,
        height: maxY - minY + verticalSpacing * 2,
        rootID: rootID
    )
}
```

---

## 4. Ghost Node Rendering

### 4.1 Canvas Drawing

The Canvas draw loop iterates `layout.allNodes` and branches on `node.kind`:

```swift
for node in treeVM.layout.allNodes {
    let rect: CGRect
    if node.isGhost {
        rect = CGRect(
            x: node.x + offsetX - TreeLayout.ghostNodeWidth / 2,
            y: node.y + offsetY - TreeLayout.ghostNodeHeight / 2,
            width: TreeLayout.ghostNodeWidth,
            height: TreeLayout.ghostNodeHeight
        )
        drawGhostNode(context: &context, node: node, rect: rect)
    } else {
        rect = CGRect(
            x: node.x + offsetX - TreeLayout.nodeWidth / 2,
            y: node.y + offsetY - TreeLayout.nodeHeight / 2,
            width: TreeLayout.nodeWidth,
            height: TreeLayout.nodeHeight
        )
        drawNode(context: &context, node: node, rect: rect,
                isSelected: ..., isRoot: ..., isHovered: ..., dimmed: ...)
    }
}
```

### 4.2 Ghost Node Drawing

```swift
private func drawGhostNode(context: inout GraphicsContext, node: TreeLayout.LayoutNode, rect: CGRect) {
    let cornerRadius: Double = 10
    let path = Path(roundedRect: rect, cornerRadius: cornerRadius)

    // Dashed border, no fill
    context.stroke(path, with: .color(.secondary.opacity(0.2)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

    // "?" label
    let label = Text("?")
        .font(AppTypography.canvasName)
        .foregroundStyle(.secondary.opacity(0.4))
    context.draw(context.resolve(label),
                 at: CGPoint(x: rect.midX, y: rect.midY - 6),
                 anchor: .center)

    // Role subtitle from enum
    let subtitle: String
    if case .ghost(_, let role) = node.kind {
        switch role {
        case .father: subtitle = "Unknown father"
        case .mother: subtitle = "Unknown mother"
        case .unknown: subtitle = "Unknown"
        }
    } else {
        subtitle = "Unknown"
    }
    let subText = Text(subtitle)
        .font(AppTypography.canvasLocation)
        .foregroundStyle(.secondary.opacity(0.3))
    context.draw(context.resolve(subText),
                 at: CGPoint(x: rect.midX, y: rect.midY + 10),
                 anchor: .center)
}
```

### 4.3 Edge Drawing to Ghosts

Edges to ghost nodes use the existing orthogonal connector drawing — no changes needed. The edge's `fromX/fromY` points to the ghost node's position, which is at the ghost's centre. The connector will draw from ghost to child using the same L-shaped path as real parent-child edges, but visually lighter because the ghost node itself is faded.

---

## 5. Measurable Improvement

### 5.1 Width Reduction

| Scenario | Current width | Compact width | Reduction |
|----------|-------------|---------------|-----------|
| 4 gen, full binary tree (all 15 ancestors exist) | 2752pt | ~2752pt (no change) | 0% |
| 4 gen, sparse (5 of 15 ancestors exist) | 2752pt | ~900pt* | **67%** |
| 4 gen, single line (1 ancestor per generation) | 2752pt | ~400pt* | **85%** |
| 6 gen, sparse (20 of 63 ancestors exist) | 11008pt | ~2200pt* | **80%** |

*Estimates — actual numbers depend on tree shape. Will be verified with the 71-profile dataset during testing (step 10).

### 5.2 Visible Profiles

| Scenario (1440pt display) | Current visible | Compact visible | Improvement |
|---------------------------|-----------------|-----------------|-------------|
| 4 gen, sparse tree | 6-10 profiles | 12-15 profiles | **~2× more** |
| 6 gen, sparse tree | 4-8 profiles | 15-25 profiles | **~3× more** |

### 5.3 Ghost Node Coverage

With the current 71-profile tree (33 profiles missing parents per Gaps view):
- Each generates 2 ghost nodes within the visible window
- At 4 generations, approximately **20-30 ghost nodes** will render
- Each ghost is a visible research target — currently invisible

### 5.4 Testable Acceptance Criteria

1. **Width:** With 4 generations and fewer than 8 real ancestors at the outermost generation, the tree fits within 1200pt width
2. **Ghost nodes:** Every person in generations 0 through `maxGenerations - 1` who has fewer than 2 known parents shows ghost placeholder(s)
3. **Ghosts at boundary:** Ghosts DO appear at generation `maxGenerations` when a person at `maxGenerations - 1` has missing parents
4. **No regression:** A full binary tree (all ancestors present) produces similar layout width to the current algorithm
5. **Ghost rendering:** Ghost nodes render as dashed-border cards with "?" and role-based subtitle ("Unknown father"/"Unknown mother")
6. **Ghost isolation:** Ghost nodes do not appear in: search results, selection, hit testing, popovers, ⓘ icons, arrow indicators, hover highlights, keyboard navigation targets, breadcrumb history
7. **Relative positions stable:** Parents are always above their children, fathers left, mothers right. Absolute positions may shift when generation count changes (this is expected — the tree reshapes around new data)
8. **Asymmetric trees:** Parent pairs are centred geometrically above their child. In highly asymmetric trees (one parent with deep ancestry, other with none), this may produce visual offset at upper generations. This is a known limitation, not a bug.

---

## 6. Known Limitations

### 6.1 Asymmetric Subtree Offset

The algorithm centres each parent pair geometrically above their child using measured subtree widths. It does NOT use Reingold-Tilford contour tracking. In asymmetric trees, accumulated offsets can make distant ancestors appear visually off-centre relative to their descendants.

**When it's visible:** A person whose father has 4 generations of known ancestry and whose mother has none. The father's subtree is wide, the mother's is a single ghost. The pair is centred above the child, but the father's own parents are centred above the father (who is offset left), creating a cascade of leftward drift at upper generations.

**Severity:** Minor for typical family trees (most branches have similar depth). Noticeable for extreme asymmetry. Acceptable for MVP — a full Reingold-Tilford implementation is future work.

### 6.2 Pedigree Collapse (Duplicate Ancestors)

When the same ancestor appears in multiple branches (cousin marriages, small populations), the `visited` set prevents infinite recursion but silently skips the duplicate. The branch that reaches the ancestor second will appear truncated — no ancestor nodes rendered above it, and no ghost nodes either (because the person exists, they just have already been placed elsewhere).

This matches the current algorithm's behaviour — it's not a regression. Proper handling (rendering a "see [name]" reference node, or drawing the duplicate with a visual link) is future work.

### 6.3 Ghost Nodes Are Passive (MVP)

Ghost nodes in this spec are non-interactive visual indicators. They mark research gaps but don't provide an action path. Making ghosts clickable (leading to an "add parent" flow, WikiTree search, or research hints panel) is the natural next step and belongs in the research-workflow spec.

---

## 7. File Changes

### 7.1 Modified Files

| File | Changes |
|------|---------|
| **TreeLayout.swift** | Replace `pedigreeLayout` with bottom-up compact algorithm. Add `SubtreeWidth` struct, `measureWidth()` with memoisation, `parentSide()` with role/gender fallback. Add `NodeKind` enum, `GhostRole` enum. Change `LayoutNode.profile` to `LayoutNode.kind: NodeKind` with convenience accessors. Add `ghostNodeWidth`/`ghostNodeHeight` constants. Add `ghostNodes` array to `LayoutResult`. |
| **TreeGraphView.swift** | Canvas draw loop iterates `layout.allNodes` (real + ghost). Branch on `node.isGhost` for drawing and rect sizing. Add `drawGhostNode` method. Update hit-test to iterate `layout.nodes` only (skips ghosts). Update all `node.profile` accesses to `node.profile?` or switch on `node.kind`. Update node rect calculation to use ghost dimensions for ghost nodes. |
| **TreeViewModel.swift** | Update `filteredNodes()` to use `layout.nodes` (already excludes ghosts). Update `hitTest()` to iterate `layout.nodes` only. No changes to selection, keyboard nav, or history — these already operate on real profiles via `snapshot.parentsOf()`. |
| **ProfilePopoverView.swift** | No changes — popover receives a `Profile`, never a ghost. |

### 7.2 No New Files

All changes are within existing files.

---

## 8. Layout Constants

```swift
// TreeLayout.swift — add
static let ghostNodeWidth: Double = 100
static let ghostNodeHeight: Double = 48
```

---

## 9. Implementation Order

| Step | Work | Risk |
|------|------|------|
| 1 | Add `NodeKind`, `GhostRole` enums to TreeLayout.swift | Low — additive |
| 2 | Change `LayoutNode` to use `kind: NodeKind`, add convenience accessors | Medium — breaks all `node.profile` call sites |
| 3 | Add `ghostNodeWidth`, `ghostNodeHeight` constants | Low |
| 4 | Add `ghostNodes` array to `LayoutResult`, add `allNodes` computed property | Low |
| 5 | Update descendant layout to use new `LayoutNode` initialiser (no ghosts in descendant view) | Low |
| 6 | Implement `SubtreeWidth`, `measureWidth()` with cache, `parentSide()` | Medium — core algorithm |
| 7 | Implement new `pedigreeLayout` with compact placement + ghost creation | Medium — core algorithm |
| 8 | Update TreeGraphView: draw loop uses `allNodes`, add `drawGhostNode`, branch on `isGhost` for rect sizing | Medium — rendering changes |
| 9 | Update TreeGraphView: hit-test, hover, selection use `layout.nodes` only | Low |
| 10 | Update TreeViewModel: `filteredNodes` uses `layout.nodes` only | Low |
| 11 | Fix any remaining `node.profile` force-unwraps → use `node.profile?` or `node.kind` switch | Low — compiler will find these |
| 12 | Build, test with 71-profile dataset, measure actual width reduction, verify ghost rendering | Manual |

Steps 1-5 can be done as safe refactoring before the algorithm change. Steps 6-7 are the core work. Steps 8-11 are integration. Step 12 validates.

---

## 10. What This Spec Does NOT Change

- **Descendant layout** — remains as-is (already uses bottom-up width accumulation, no ghosts)
- **Spouse placement** — spouses placed beside their partner after main layout, unchanged
- **Edge drawing** — orthogonal connectors unchanged
- **Interaction model** — all click/keyboard/popover behaviour unchanged
- **Generation zoom** — ⌘+/⌘- still controls `visibleGenerations`
- **Data model** — no changes to Profile, FamilyGraphSnapshot, or persistence
- **Pedigree collapse** — duplicate ancestors silently skipped, matching current behaviour

---

## 11. Future Work

| Feature | Relationship to this spec |
|---------|--------------------------|
| **Reingold-Tilford with contours** | Fixes the asymmetric-subtree offset (§6.1). Significant additional complexity. |
| **Clickable ghost nodes** | Makes ghosts actionable — "add parent", "search WikiTree", research hints. Belongs in research-workflow spec. |
| **Pedigree collapse handling** | Render duplicate ancestors as reference nodes with visual links. |
| **Minimap** | Now feasible — compact layout provides meaningful spatial representation for a whole-tree overview. |
