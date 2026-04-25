# Pedigree Navigation & Interaction — Detailed Specification

**Status:** Proposed (v5 — revised after fourth critique)  
**Scope:** TreeGraphView, TreeViewModel, TreeLayout, ProfileDetailView  
**Milestone:** M3 (Tree Visualisation)  
**Date:** 2026-04-24  

---

## 1. Scope and Framing

This spec is a **navigation-and-inspection redesign**. It solves two problems completely and lays groundwork for two others:

| # | Problem | This spec | Future spec |
|---|---------|-----------|-------------|
| 1 | **Inspection** — can't inspect without losing position | Three-tier interaction model (§5) | — |
| 2 | **Finding** — can't jump to a named person | Search-to-recenter (§4) | — |
| 3 | **Orientation** — where am I in the whole tree? | Breadcrumb trail (§3) | Minimap (requires whole-tree layout algorithm — not ready for M3) |
| 4 | **Research tracking** — what have I looked at? | — | Visited state, audit queue, investigated flags |

The minimap and visited-node tracking are deferred. A minimap that uses the current grid overview layout (sorted by completeness, no tree structure) would mislead users about spatial position. A proper minimap requires a compact whole-tree layout algorithm (Reingold-Tilford or radial) which is significant work — it belongs in its own spec. Visited dots (3pt, bottom-left) are too subtle to be useful; research tracking deserves a proper design pass, not a gesture.

---

## 2. Current State (Annotated)

### 2.1 TreeGraphView.swift (384 lines)

| Aspect | Current Implementation | File:Line |
|--------|----------------------|-----------|
| **Layout** | HSplitView: canvas (left) + ProfileDetailView (right, 300px) | TreeGraphView.swift:11–63 |
| **Click handling** | Single `onTapGesture(count: 1)` → hit-tests → `recenter()` | TreeGraphView.swift:156–161 |
| **Selection** | `recenter()` sets both `rootProfileID` and `selectedProfileID` simultaneously | TreeViewModel.swift:44–53 |
| **Expand indicators** | `▲`/`▼` drawn as Canvas text at ±8pt from node edge | TreeGraphView.swift:291–311 |
| **Inspector** | Permanent 300px sidebar, shown whenever `selectedProfileID != nil` | TreeGraphView.swift:52–63 |
| **Pan** | DragGesture updates `offset` | TreeGraphView.swift:344–355 |
| **Pinch zoom** | MagnifyGesture sets `scale` (0.1–4.0) | TreeGraphView.swift:357–362 |
| **Button zoom** | `zoomIn`/`zoomOut` change `visibleGenerations` (2–10) and call `rebuildLayout` | TreeViewModel.swift:74–85 |
| **Recenter reset** | `rebuildLayout` always sets `scale=1.0, offset=.zero` | TreeViewModel.swift:37–40 |
| **Semantic zoom** | scale > 0.4 → full detail; scale ≤ 0.4 → name only | TreeGraphView.swift:226–278 |
| **History** | Array-based back/forward, `goBack()` rebuilds layout | TreeViewModel.swift:17–62 |
| **Breadcrumb** | Shows root person name + back chevron (top-left overlay) | TreeGraphView.swift:21–41 |
| **Home button** | Recenters on `naturalRootID` (youngest profile with parents) | TreeGraphView.swift:366–372 |

### 2.2 TreeLayout.swift (319 lines)

| Aspect | Current Implementation | File:Line |
|--------|----------------------|-----------|
| **Node size** | 180×70pt, 20pt horizontal spacing, 50pt vertical spacing | TreeLayout.swift:43–47 |
| **Pedigree** | Root at bottom-centre, parents above, recursive binary split. Slot width doubles per generation. | TreeLayout.swift:54–168 |
| **Spouses** | Placed at `node.x + nodeWidth + spouseSpacing` (16pt gap) | TreeLayout.swift:132–152 |
| **LayoutNode flags** | `hasMoreAncestors` (true when at max generation and parents exist), `hasMoreDescendants` | TreeLayout.swift:84–85 |
| **Overview** | Grid of all profiles sorted by completeness. No edges. | TreeLayout.swift:277–307 |

### 2.3 TreeViewModel.swift (102 lines)

| Aspect | Current Implementation |
|--------|----------------------|
| **View modes** | `.pedigree`, `.descendants`, `.overview` |
| **Default generations** | 4 |
| **Generation range** | 2–10 |
| **History** | `[String]` with `historyIndex`, truncates forward history on new recenter |
| **Search** | Case-insensitive substring match on `displayName`, non-matching nodes dimmed |

### 2.4 ProfileDetailView.swift (152 lines)

| Content | Detail |
|---------|--------|
| Header | displayName, WikiTree ID, completeness score + living indicator |
| Fields | Birth date/location, death date/location, gender — each with source badges |
| Relationships | Parents, spouses, children, siblings — name + birth year |
| Disputes | Field name, reason, competing sources |
| Actions | "Show as Root" button |

---

## 3. Orientation: Breadcrumb Trail

### 3.1 Current Problem

The breadcrumb shows only `< John Smith` — the current root and one back step. After three recenters the user has no idea how they got here or how to get back to a specific earlier point.

### 3.2 Target

Full path from the home person to the current root:

```
Home › William Smith › John Smith › Thomas Smith
```

Each name is clickable (recenters on that person). If the trail exceeds available width, collapse middle entries to `…` with click to expand.

### 3.3 Implementation

The history array already tracks the path. Render as an `HStack` of buttons in the top overlay:

```swift
HStack(spacing: 4) {
    ForEach(breadcrumbEntries, id: \.id) { entry in
        if entry.isEllipsis {
            Button("…") {
                treeVM.expandBreadcrumb = true
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        } else {
            Button(entry.name) {
                treeVM.jumpToHistory(index: entry.historyIndex, snapshot: appState.snapshot)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(entry.isCurrent ? .primary : .secondary)

            if !entry.isLast {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
    }
}
.padding(.horizontal, 12)
.padding(.vertical, 6)
.glassEffect(.regular, in: .capsule)
```

**Collapsing rule:** If more than 4 entries and `expandBreadcrumb` is false, show first entry, `…`, last two. Clicking `…` sets `expandBreadcrumb = true` to show all.

**`jumpToHistory`:** Sets `historyIndex` to the target index, updates `rootProfileID`, and rebuilds with animation. Does not truncate forward history — the user can still go forward after jumping back.

---

## 4. Finding: Search with Recenter

### 4.1 Current Problem

Search dims non-matching nodes but:
- Matches outside the generation window are invisible
- Visible matches off-screen have no scroll-to behaviour
- No way to cycle between multiple matches

### 4.2 Target Behaviour

Search becomes a "jump to person" tool:

1. User types in the search field
2. A dropdown appears showing matching profiles from the **entire snapshot** (not just visible nodes) — name + birth year + completeness score
3. Clicking a result or pressing Return recenters the tree on that person
4. ↑/↓ navigate the dropdown list
5. Escape or clearing the field dismisses the dropdown
6. Canvas still dims non-matching visible nodes while search is active

### 4.3 Focus Management

**Return key ownership:** Return is claimed by two contexts — the search field and the canvas. These must never conflict.

- When the search field has focus (`@FocusState` is `.search`), Return submits the search (selects highlighted result and recenters). ↑/↓ navigate the dropdown, not tree relatives.
- When the canvas has focus (`@FocusState` is `.canvas`), Return recenters on the selected node. ↑/↓ navigate tree relatives.
- Clicking the search field sets focus to `.search`. Clicking the canvas or pressing Escape from the search field sets focus to `.canvas`.
- The canvas is `.focusable()` and requests focus on appear.

```swift
enum TreeFocus: Hashable {
    case canvas
    case search
}

@FocusState private var focus: TreeFocus?

// In toolbar:
TreeSearchField(searchText: $treeVM.searchText, ...)
    .focused($focus, equals: .search)

// Canvas area:
treeCanvas
    .focusable()
    .focused($focus, equals: .canvas)
    .onAppear { focus = .canvas }
```

This ensures Return and ↑/↓ never fire in the wrong context.

### 4.4 Implementation

Replace the plain `TextField` with a custom search component:

```swift
struct TreeSearchField: View {
    @Binding var searchText: String
    let allProfiles: [Profile]
    let snapshot: FamilyGraphSnapshot
    var onSelect: (String) -> Void  // profileID

    @State private var highlightedIndex: Int = 0

    private var matches: [(profile: Profile, completeness: ProfileCompleteness)] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        let results = allProfiles
            .filter { $0.displayName.lowercased().contains(query) }
            .sorted { a, b in a.displayName < b.displayName }
        return results.map { ($0, snapshot.completeness(for: $0.id)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search people…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit {
                    if let match = matches[safe: highlightedIndex] {
                        onSelect(match.profile.id)
                        searchText = ""
                    }
                }

            if !matches.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let displayed = matches.prefix(20)
                        ForEach(Array(displayed.enumerated()), id: \.element.profile.id) { index, match in
                            Button {
                                onSelect(match.profile.id)
                                searchText = ""
                            } label: {
                                HStack {
                                    Text(match.profile.displayName)
                                        .font(.callout)
                                    Spacer()
                                    if let year = match.profile.birthDate?.bestYear {
                                        Text("b. \(year)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text("\(match.completeness.score)/\(match.completeness.maximum)")
                                        .font(.caption2)
                                        .foregroundStyle(match.completeness.score == match.completeness.maximum ? .green : .orange)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(index == highlightedIndex ? Color.accentColor.opacity(0.1) : .clear)
                            }
                            .buttonStyle(.plain)
                        }
                        if matches.count > 20 {
                            Text("Showing 20 of \(matches.count) matches — refine search")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
            }
        }
    }
}
```

### 4.5 Search and View Mode

If the user selects a search result while in descendants mode and the result has no children, the tree would render an empty single-node view. Handle this: auto-switch to the viable view mode silently.

**Pre-click signalling in search results:** Search result rows that would trigger a mode switch show a ↻ badge, same as the popover's off-canvas relatives (§5.1). This keeps mode-switch signalling consistent across the app — the user always sees ↻ *before* clicking, rather than learning about it via a toast *after*.

```swift
// In TreeSearchField, each result row:
HStack {
    if wouldSwitchMode(for: match.profile) {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.caption2)
            .foregroundStyle(.orange)
    }
    Text(match.profile.displayName)
    // ...
}

private func wouldSwitchMode(for profile: Profile) -> Bool {
    let snapshot = snapshot
    switch currentViewMode {
    case .pedigree:
        return snapshot.parentsOf(profile.id).isEmpty && !snapshot.childrenOf(profile.id).isEmpty
    case .descendants:
        return snapshot.childrenOf(profile.id).isEmpty && !snapshot.parentsOf(profile.id).isEmpty
    }
}
```

The mode switch itself is silent — the badge was the informed consent.

---

## 5. Inspection: Interaction Model Redesign

### 5.1 Three Tiers

#### Tier 1: Canvas Node (always visible)

```
┌────────────────────────┐
│  John William Smith     │  ← displayName (13pt medium)
│  b.1845 — d.1902       │  ← birth/death years (11pt)
│  Kent, England          │  ← birthLocation (9pt, scale > 0.7)
│                    5/7  │  ← completeness badge (top-right)
└────────────────────────┘
  ▲ 2 parents              ← recenter indicator (edge-generation nodes only)

    background colour = completeness gradient (unchanged)
    border: 1pt secondary (default), 2pt blue (root), 2.5pt accent (selected)
    hover: border brightens to secondary.opacity(0.6) over 100ms
```

**Living people:** For profiles where `completeness.potentiallyLiving` is true, the date line shows `b. 1970 — living` instead of omitting the death date. This avoids the ambiguity of a blank death field (could mean living or unknown).

**Hover state:** On mouse hover over any node, the border colour brightens slightly (secondary → secondary at 0.6 opacity) with a 100ms animation. This signals clickability without requiring the user to know the interaction model. Implemented via `hoveredNodeID: String?` tracked through the Canvas overlay or `.onContinuousHover`.

#### Tier 2: Popover (explicit trigger)

**Trigger — two paths, both explicit:**

1. **Click the `ⓘ` icon** on the selected node (mouse path)
2. **Press Space** with a node selected (keyboard path — matches macOS Quick Look)
3. **Click a selected node again** — if a node is already selected and the user clicks the same node body a second time, open the popover. This provides a natural two-phase mouse gesture: first click selects, second click on the same node inspects. No aiming at a sub-element required.

The `ⓘ` icon is drawn on the selected node at all zoom levels (not gated by scale > 0.7). Even when other detail is hidden at low zoom, the selected node shows the icon so the user always has a visible path to the popover.

**Rationale:**
- Path 1 (ⓘ) is discoverable — the icon is visible on the selected node
- Path 2 (Space) is efficient — keyboard users don't need the mouse
- Path 3 (re-click) is natural — lowest-friction mouse path for scanning multiple nodes. Click node A (selects). Click node B (selects B, deselects A). Click node B again (inspects B). Or: click node A (selects), click A again (inspects A) — two clicks, same location.

**Content — scoped relationships:** Only show relatives NOT currently visible on the canvas. If all parents, spouses, and children are rendered as nodes, the relationships section is omitted. Only off-canvas relatives (beyond the generation window, or siblings not in the layout) appear as clickable links.

```swift
private var offCanvasRelatives: (parents: [Profile], spouses: [Profile],
                                  children: [Profile], siblings: [Profile]) {
    let visibleIDs = Set(visibleNodeIDs)
    return (
        snapshot.parentsOf(profile.id).filter { !visibleIDs.contains($0.id) },
        snapshot.spousesOf(profile.id).filter { !visibleIDs.contains($0.id) },
        snapshot.childrenOf(profile.id).filter { !visibleIDs.contains($0.id) },
        snapshot.siblingsOf(profile.id).filter { !visibleIDs.contains($0.id) }
    )
}
```

**Off-canvas relative rows — mode-switch badge:** If tapping a relative would require switching view mode (e.g., a parent while in descendants view), the row shows a small `↻` icon next to the name. The user can see before clicking that this action will reorganise the view. No surprise, no toast needed for this case — the badge provides informed consent.

```swift
// In popover relative row:
HStack {
    Text(relative.displayName).font(.callout)
    if wouldSwitchMode(to: relative.id) {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.caption2)
            .foregroundStyle(.orange)
            .help("Will switch to \(targetMode.rawValue) view")
    }
    Spacer()
    // ...
}
```

**Popover layout:**

```
┌─────────────────────────────────┐
│ John William Smith              │  ← title3, bold
│ Smith-12345 (WikiTree)          │  ← caption, secondary
│ ████░░░ 5/7                     │  ← progress bar
│                                 │
│ Born:  12 Mar 1845              │
│        Maidstone, Kent, England │
│        [GEDCOM] [WIKITREE]      │  ← source badges
│                                 │
│ Died:  3 Nov 1902               │
│        Lambeth, London, England │
│        [GEDCOM]                 │
│                                 │
│ ─── Off-canvas relatives ────── │  ← only if any exist
│ Sibling: James Smith (b.1847) → │  ← clickable, recenters
│ ↻ Father: William Smith (b.1820)│  ← ↻ = will switch view mode
│                                 │
│ All relatives visible on canvas │  ← OR this, if none off-canvas
│                                 │
│ Missing: death location,        │
│   mother's maiden name          │
│                                 │
│ ⚠ 1 disputed field             │  ← orange, only if disputes exist
│                                 │
│ [Focus Here]       [Full Detail]│
└─────────────────────────────────┘
```

**Popover width:** 320pt fixed  
**Popover max height:** 480pt (scrollable)

**Action buttons:**
- **Focus Here** — recenters tree on this person. Disabled when this person is already the root.
- **Full Detail** — opens the inspector sidebar (Tier 3), dismisses popover.

#### Tier 3: Inspector Sidebar (on demand)

The existing ProfileDetailView. No longer permanently visible.

**How to open:**
- "Full Detail" button in popover
- ⌘⌥I keyboard shortcut
- Toolbar toggle button (sidebar icon, `sidebar.right`) — always visible in toolbar, shows current state

**How to close:**
- ⌘⌥I toggle
- Toolbar toggle button
- Escape (when no popover is open)

**Changes from current:**
- Hidden by default
- Adds ProfileHistoryView as a disclosure group at the bottom
- Width remains 300pt

### 5.2 Click / Gesture Model

| Gesture | Target | Action |
|---------|--------|--------|
| **Single click on unselected node** | Node body | Select node. Dismiss popover. |
| **Single click on already-selected node** | Node body | Open popover (Tier 2) |
| **Single click on `ⓘ` icon** | Hit zone: 24×24pt, bottom-right of selected node | Open popover (Tier 2) |
| **Single click on `▲` indicator** | Hit zone: 80×20pt above node | Recenter on this person |
| **Single click on empty canvas** | No node hit | Deselect, dismiss popover |
| **Drag on canvas** | Any area (after 8pt movement threshold) | Pan. Dismiss popover on first qualifying movement. |
| **Trackpad pinch** | Canvas | Geometric zoom (0.5–2.0×). See §5.5. |
| **⌘+ / ⌘-** | Window (canvas focused) | Increase/decrease `visibleGenerations` |
| **⌘0** | Window (canvas focused) | Reset to 4 generations, scale 1.0 |
| **⌘⌥I** | Window | Toggle inspector sidebar |
| **⌘Z** | Window (canvas focused) | Undo last recenter (go back in history) |
| **Escape** | Window | Dismiss popover → close inspector → deselect (cascade) |
| **Space** | Canvas focused, node selected | Open popover (Quick Look convention) |
| **Return** | Canvas focused, node selected | Recenter on selected node |
| **Return** | Search focused | Submit search (select highlighted result) |
| **Arrow keys** | Canvas focused, node selected | Navigate to relative (see §5.6) |
| **Arrow keys** | Search focused, dropdown open | Navigate dropdown list |

**No double-click gesture.** v3 used `onTapGesture(count: 2)` for recenter, but this creates a timing conflict with "click already-selected node to inspect." SwiftUI's tap-count recognition means a rapid two-click on the same node would: (1) select on first tap, (2) fire the double-click handler which recenters — the user never gets the popover. Worse, SwiftUI delays the single-click handler (~300ms) to distinguish from double-click, making all single clicks feel sluggish.

Recenter is accessible via: Return key, `▲ N parents` indicator, popover "Focus Here" button. These paths are sufficient — double-click is not needed and its removal makes the click model clean: single-click always fires immediately, no ambiguity.

**Drag threshold:** `DragGesture(minimumDistance: 8)` — prevents accidental drags from dismissing the popover during trackpad clicks. 8pt is the standard macOS threshold for distinguishing click from drag.

**Hover state:** Nodes show a subtle border highlight on hover (border brightens from `secondary.opacity(0.2)` to `secondary.opacity(0.5)`). The highlight is **instant** — no animation. Animated hover transitions cause visual noise when the mouse crosses multiple nodes quickly. Hover state tracked via `hoveredNodeID: String?` updated by `.onContinuousHover`.

**Note on focus gating:** All keyboard shortcuts in the "canvas focused" column require `focus == .canvas` (see §4.3). When the search field has focus, these keys are handled by the search field instead. This prevents Return from ambiguously recentering vs submitting search.

**Known limitation:** SwiftUI's `onTapGesture` does not read the system double-click interval accessibility setting. Users with slow-click accessibility needs should use Return for recenter and Space for inspect. Document in accessibility notes.

### 5.3 Arrow Indicators as Recenter Triggers

The `▲`/`▼` indicators on edge-generation nodes are **recenter triggers**.

**Why recenter, not expand:** Per-node affordances should do per-node things. If expansion is global, the control should be global (⌘+/- toolbar). Clicking `▲` on a specific person navigates to that person's branch.

**Visual design — text link with parent count:**

```swift
if node.hasMoreAncestors {
    let parentCount = snapshot.parentsOf(node.id).count
    let label = Text("▲ \(parentCount) parent\(parentCount == 1 ? "" : "s")")
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(Color(.controlAccentColor))
    context.draw(
        context.resolve(label),
        at: CGPoint(x: rect.midX, y: rect.minY - 12),
        anchor: .center
    )
}
```

**Label text:** `"▲ 2 parents"` (not "ancestors"). "Parents" is accurate — it's the immediate parents beyond the boundary. "Ancestors" implies the full line, which could mislead users about depth.

For `▼`: `"▼ 3 children"` — count of immediate children.

**Hit zone:** 80pt wide × 20pt tall, centred at the indicator's draw position. Tested BEFORE node body in `hitTest()`.

**Colour:** `Color(.controlAccentColor)` — respects system accent colour preference and provides adequate contrast on all backgrounds.

### 5.4 Generation Zoom (Toolbar Only)

Generation zoom is controlled exclusively from the toolbar.

**Toolbar controls:**

```swift
HStack(spacing: 4) {
    Button {
        treeVM.decreaseGenerations(snapshot: appState.snapshot)
    } label: {
        Text("−")
            .font(.body.monospaced())
            .frame(width: 20)
    }
    .help("Show fewer generations (⌘-)")

    Text("\(treeVM.visibleGenerations) gen")
        .font(.caption)
        .monospacedDigit()
        .frame(width: 40)

    Button {
        treeVM.increaseGenerations(snapshot: appState.snapshot)
    } label: {
        Text("+")
            .font(.body.monospaced())
            .frame(width: 20)
    }
    .help("Show more generations (⌘+)")
}
```

**Icons:** Text `−` / `+` labels with "N gen" count between them. No SF Symbols — the previous suggestions (`rectangle.expand.vertical`, magnifying glasses) all carry wrong connotations. Plain text is unambiguous and matches common stepper patterns.

### 5.5 Two Zoom Models (Complementary)

| Zoom type | Control | What changes | Range | Use case |
|-----------|---------|-------------|-------|----------|
| **Geometric** | Trackpad pinch | `scale` | 0.5–2.0 | Read small text, fit tree in viewport |
| **Generation** | ⌘+/⌘-, toolbar ±buttons | `visibleGenerations` | 2–10 | See more/fewer generations |

**Geometric zoom range:** 0.5–2.0 (narrower than current 0.1–4.0). Below 0.5 nodes are unreadable. Above 2.0 the inspector is more useful.

**Semantic zoom thresholds:**
- scale > 0.7: full detail (name + dates + location)
- scale 0.5–0.7: name + dates only
- scale = 0.5 (minimum): name only
- `ⓘ` icon on selected node: visible at ALL scales (not gated by semantic zoom)

### 5.6 Keyboard Navigation

**Mapping — one action per key, no double-duty:**

| Key | Action | Rationale |
|-----|--------|-----------|
| **↑** | Select father (first parent) | Up = ancestors |
| **⇧↑** | Select mother (second parent) | Shift = alternate |
| **↓** | Select first child | Down = descendants |
| **←** | Previous sibling | Left/right = same generation |
| **→** | Next sibling or spouse | Same generation |
| **Space** | Open popover on selected node | Quick Look (macOS convention) |
| **Return** | Recenter on selected node | Open/commit (macOS convention) |

**All keyboard navigation requires `focus == .canvas`.** When the search field has focus, these keys belong to the search component.

**Boundary behaviour — confirm before expanding:**

This rule applies to **any arrow-key navigation that crosses a generation boundary**: ↑ (father), ⇧↑ (mother), and ↓ (first child). All three can hit the boundary of the visible generation window.

When the target relative exists in the data but isn't rendered in the current layout:

1. First press: a hint appears — `"Press again to show more generations"` — rendered as transient text (2 seconds, then cleared). Selection does not change. The view model sets `pendingExpandTarget = targetID`.
2. Second press of the **same key** (within 3 seconds): expands (`visibleGenerations += 1`), rebuilds layout, selects the target. `pendingExpandTarget` resets. New nodes fade in over 0.3s.
3. If the user presses a **different** key, clicks, or 3 seconds elapse, `pendingExpandTarget` resets and the hint clears.

**Asymmetric boundaries:** In a pedigree layout, the father may be visible (within the generation window) but the mother may not (if only one parent was placed due to layout constraints). In this case, ↑ works immediately but ⇧↑ hits the boundary. This is correct — the confirm-before-expand rule applies per-target, not per-direction.

**Why confirm:** Global expansion adds nodes to every branch (tree width can double). A single keypress shouldn't silently double the tree complexity. The two-press pattern makes expansion deliberate while staying fast for users who know what they're doing.

**Generation cap:** At `visibleGenerations == 10`, boundary-crossing keypresses play `NSSound.beep()` and do nothing. No hint, no second press — there's nothing to expand to.

**Off-canvas lateral navigation (← / →):** If the target sibling isn't in the layout, play `NSSound.beep()`. Siblings aren't rendered in pedigree layout. The user can find siblings via the popover's off-canvas relatives section.

**Discoverability:** On the third node selection in the app's lifetime (not the first — the user needs to commit to exploring before a hint is useful), show a transient coach mark (3 seconds, fades out) in the breadcrumb area:

```
Tip: ↑↓ navigate relatives · Space to inspect · Return to focus
```

Stored as `selectionCount: Int` in UserDefaults. Coach mark shows when count reaches 3, and at most 3 times across sessions (tracked by `coachMarkShownCount: Int`).

### 5.7 Shared World-to-Screen Transform

Extract transform logic into a single struct used by Canvas drawing, hit testing, and popover positioning.

```swift
/// Converts between layout coordinates and screen coordinates.
struct CanvasTransform {
    let canvasSize: CGSize
    let rootPosition: CGPoint   // root node's layout (x, y)
    let offset: CGSize          // pan offset
    let scale: Double           // geometric zoom

    /// Draw offset that centres the root at the bottom of the viewport.
    var drawOffset: CGPoint {
        CGPoint(
            x: -rootPosition.x,
            y: -rootPosition.y + (canvasSize.height / scale / 2) - TreeLayout.nodeHeight
        )
    }

    /// Layout coordinates → screen coordinates.
    func toScreen(_ layoutPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (layoutPoint.x + drawOffset.x) * scale + canvasSize.width / 2 + offset.width,
            y: (layoutPoint.y + drawOffset.y) * scale + canvasSize.height / 2 + offset.height
        )
    }

    /// Screen coordinates → layout coordinates.
    func toLayout(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (screenPoint.x - canvasSize.width / 2 - offset.width) / scale - drawOffset.x,
            y: (screenPoint.y - canvasSize.height / 2 - offset.height) / scale - drawOffset.y
        )
    }
}
```

Used by: Canvas draw, hit testing, popover positioning. Recomputed per frame (value type, depends on mutable state).

### 5.8 Animated Transitions

**Goal:** When recentering, the old root stays visually stationary while the tree slides to centre the new root.

**Algorithm:**

```swift
func recenter(on profileID: String, snapshot: FamilyGraphSnapshot, canvasSize: CGSize) {
    guard let oldRootID = rootProfileID else {
        // First root — no animation needed
        rootProfileID = profileID
        selectedProfileID = profileID
        rebuildLayoutOnly(snapshot: snapshot)
        scale = 1.0
        offset = .zero
        dragStartOffset = .zero
        return
    }

    // 1. Compute old root's screen position BEFORE rebuild
    let transform = currentTransform(canvasSize: canvasSize)
    let oldRootNode = layout.nodes.first { $0.id == oldRootID }
    let oldScreenPos = oldRootNode.map {
        transform.toScreen(CGPoint(x: $0.x, y: $0.y))
    }

    // 2. Update history
    if historyIndex < history.count - 1 {
        history.removeSubrange((historyIndex + 1)...)
    }
    history.append(profileID)
    historyIndex = history.count - 1

    // 3. Rebuild layout with new root, reset scale, zero offset as target
    rootProfileID = profileID
    selectedProfileID = profileID
    popoverProfileID = nil
    scale = 1.0
    rebuildLayoutOnly(snapshot: snapshot)

    // 4. Compute where the old root appears in the new layout at offset=.zero
    let newTransform = CanvasTransform(
        canvasSize: canvasSize,
        rootPosition: rootNodePosition(),
        offset: .zero,
        scale: scale
    )
    let newOldRootNode = layout.nodes.first { $0.id == oldRootID }
    let newScreenPos = newOldRootNode.map {
        newTransform.toScreen(CGPoint(x: $0.x, y: $0.y))
    }

    // 5. Set initial offset so old root appears at its pre-rebuild position,
    //    then animate to zero (new root centred)
    if let before = oldScreenPos, let after = newScreenPos {
        let initialOffset = CGSize(
            width: before.x - after.x,
            height: before.y - after.y
        )
        isAnimatingRecenter = true
        offset = initialOffset
        dragStartOffset = .zero

        if accessibilityReduceMotion {
            offset = .zero
            isAnimatingRecenter = false
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                offset = .zero
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.isAnimatingRecenter = false
            }
        }
    } else {
        // Old root not in new layout — hard cut
        offset = .zero
        dragStartOffset = .zero
    }
}

private func rootNodePosition() -> CGPoint {
    let rootNode = layout.nodes.first { $0.id == rootProfileID }
    return CGPoint(x: rootNode?.x ?? 0, y: rootNode?.y ?? 0)
}

private func currentTransform(canvasSize: CGSize) -> CanvasTransform {
    CanvasTransform(
        canvasSize: canvasSize,
        rootPosition: rootNodePosition(),
        offset: offset,
        scale: scale
    )
}

/// Rebuild layout without resetting offset/scale.
private func rebuildLayoutOnly(snapshot: FamilyGraphSnapshot) {
    guard let rootID = rootProfileID else { return }
    switch viewMode {
    case .pedigree:
        layout = TreeLayout.pedigreeLayout(rootID: rootID, snapshot: snapshot, maxGenerations: visibleGenerations)
    case .descendants:
        layout = TreeLayout.descendantLayout(rootID: rootID, snapshot: snapshot, maxGenerations: visibleGenerations)
    }
}
```

**`isAnimatingRecenter` usage:** This flag has exactly ONE purpose: if the user clicks a node during an active recenter animation, cancel the animation first (`withAnimation(nil) { offset = .zero }; isAnimatingRecenter = false`), then process the click. It does NOT gate popover dismissal or any other state change.

---

## 6. State and Transitions

### 6.1 New ViewModel State

```swift
@MainActor @Observable
final class TreeViewModel {
    // Existing (unchanged)
    var layout: TreeLayout.LayoutResult = .init(nodes: [], edges: [], width: 0, height: 0, rootID: nil)
    var rootProfileID: String?
    var viewMode: TreeViewMode = .pedigree   // .pedigree or .descendants (overview removed)
    var scale: Double = 1.0
    var offset: CGSize = .zero
    var dragStartOffset: CGSize = .zero
    var searchText: String = ""
    var visibleGenerations: Int = 4
    private var history: [String] = []
    private var historyIndex: Int = -1

    // Revised — decoupled from rootProfileID
    var selectedProfileID: String?

    // New
    var popoverProfileID: String?           // nil = no popover
    var showInspector: Bool = false          // sidebar toggle
    var isAnimatingRecenter: Bool = false    // animation cancellation flag (see §5.8)
    var expandBreadcrumb: Bool = false       // show full breadcrumb trail vs collapsed
    var showToast: String?                   // transient message, auto-clears (see §6.4)
    var accessibilityReduceMotion: Bool = false  // set from @Environment on appear
    var hoveredNodeID: String?              // for hover border highlight
    var pendingExpandTarget: String?        // keyboard boundary expand confirmation target (see §5.6)
    private var toastGeneration: Int = 0    // race-safe toast clearing (see §6.4)
}
```

### 6.2 Transition Table

| User action | selectedProfileID | popoverProfileID | rootProfileID | showInspector | offset |
|-------------|-------------------|------------------|---------------|---------------|--------|
| Click unselected node | Set to node | nil (dismiss) | Unchanged | Unchanged | Unchanged |
| Click already-selected node | Unchanged | **Set to node** | Unchanged | Unchanged | Unchanged |
| Click `ⓘ` icon | Unchanged | **Set to node** | Unchanged | Unchanged | Unchanged |
| Click `▲ N parents` indicator | Set to node | nil | **Set to node** | Unchanged | **Animated slide** |
| Click empty canvas | nil | nil | Unchanged | Unchanged | Unchanged |
| Drag (after 8pt threshold) | Unchanged | nil (dismiss) | Unchanged | Unchanged | Updating |
| Popover "Focus Here" | Unchanged | nil | **Set to node** | Unchanged | **Animated slide** |
| Popover off-canvas relative tap | Set to relative | nil | **Set to relative** | Unchanged | **Animated slide** |
| Popover "Full Detail" | Unchanged | nil | Unchanged | **true** | Unchanged |
| Toolbar inspector toggle | Unchanged | Unchanged | Unchanged | **Toggle** | Unchanged |
| ⌘⌥I | Unchanged | Unchanged | Unchanged | **Toggle** | Unchanged |
| ⌘Z (canvas focused) | Set to prev root | nil | **Set to prev** | Unchanged | **Animated slide** |
| ⌘+ / ⌘- (canvas focused) | Unchanged | Unchanged | Unchanged | Unchanged | Unchanged (layout rebuilt) |
| Escape (popover open) | Unchanged | nil | Unchanged | Unchanged | Unchanged |
| Escape (no popover, inspector open) | Unchanged | Unchanged | Unchanged | **false** | Unchanged |
| Escape (nothing open, node selected) | nil | Unchanged | Unchanged | Unchanged | Unchanged |
| Space (canvas focused, no popover) | Unchanged | **Set to selected** | Unchanged | Unchanged | Unchanged |
| Space (canvas focused, popover open) | Unchanged | Unchanged (no-op) | Unchanged | Unchanged | Unchanged |
| Return (canvas focused, node selected) | Unchanged | nil | **Set to selected** | Unchanged | **Animated slide** |
| Return (search focused) | Per search logic | nil | Per search logic | Unchanged | Per search logic |
| ↑/⇧↑/↓ within window (canvas) | **Set to relative** | nil (dismiss) | Unchanged | Unchanged | Unchanged |
| ↑/⇧↑/↓ at boundary, first press (canvas) | Unchanged | nil | Unchanged | Unchanged | Unchanged (hint shown) |
| Same key at boundary, second press (canvas) | **Set to target** | nil | Unchanged | Unchanged | Unchanged (expand) |
| ←/→ sibling in layout (canvas) | **Set to sibling** | nil (dismiss) | Unchanged | Unchanged | Unchanged |
| ←/→ sibling not in layout (canvas) | Unchanged | Unchanged | Unchanged | Unchanged | Unchanged (beep) |
| Search result selected | Set to result | nil | **Set to result** | Unchanged | **Animated slide** |

### 6.3 Popover Dismissal

The popover is dismissed by explicit actions only. The triggers are:

1. **Click on any unselected node** (selecting a different node)
2. **Drag gesture past 8pt threshold**
3. **Escape key**
4. **Any action that changes `rootProfileID`** (recenter, search select, ⌘Z, double-click, arrow indicator click)
5. **"Full Detail" button** (transitions to sidebar)

NOT dismissed by: offset changes during animation, geometric zoom, generation zoom, hovering.

### 6.4 Toast Behaviour

`showToast` is a transient message string displayed as an overlay near the bottom of the canvas.

```swift
// In TreeGraphView, overlay:
if let toast = treeVM.showToast {
    Text(toast)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .transition(.opacity)
}
```

**Auto-clear with generation counter:** A naive `Task.sleep` + clear pattern is racy — if two toasts fire in quick succession, the first timer can clear the second toast early. Use a generation counter:

```swift
private var toastGeneration: Int = 0

func setToast(_ message: String) {
    showToast = message
    toastGeneration += 1
    let myGeneration = toastGeneration
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        if toastGeneration == myGeneration {
            showToast = nil
        }
    }
}
```

Each new toast increments the generation. The clear-Task only clears if no newer toast has been set. This handles rapid-fire correctly — the second toast's timer is the only one that clears.

### 6.5 Data Change Handling

When the snapshot changes (profiles added/removed — e.g., WikiTree refresh, GEDCOM import):

1. **Layout rebuilds automatically** — existing `onChange(of: appState.snapshot.profiles.count)` triggers `rebuildLayout`
2. **Selected node may vanish** — if `selectedProfileID` is no longer in the snapshot, set to `nil`, dismiss popover
3. **Root node may vanish** — if `rootProfileID` is no longer in the snapshot, fall back to `naturalRootID` and rebuild
4. **History entries may be invalid** — `jumpToHistory` walks backward from the target index until it finds a profile that still exists. If the entire history is invalid (snapshot completely replaced), fall back to `naturalRootID`

```swift
func jumpToHistory(index targetIndex: Int, snapshot: FamilyGraphSnapshot) {
    // Search outward from target: check target, then target-1, target+1, target-2, ...
    // This finds the nearest valid entry regardless of direction.
    let maxDist = max(targetIndex, history.count - 1 - targetIndex)
    for dist in 0...maxDist {
        for candidate in [targetIndex - dist, targetIndex + dist] {
            guard candidate >= 0, candidate < history.count else { continue }
            let profileID = history[candidate]
            if snapshot.profiles[profileID] != nil {
                historyIndex = candidate
                recenter(on: profileID, snapshot: snapshot, canvasSize: lastCanvasSize)
                return
            }
        }
    }
    // Entire history invalid — fall back to natural root
    if let rootID = naturalRootID(snapshot: snapshot) {
        history = [rootID]
        historyIndex = 0
        recenter(on: rootID, snapshot: snapshot, canvasSize: lastCanvasSize)
    }
}
```

---

## 7. Edge Cases

### 7.1 Popover Positioning Near Canvas Edge

If the node is near the top of the canvas, flip the popover below:

```swift
let nodeScreenPos = transform.toScreen(CGPoint(x: node.x, y: node.y))
let popoverHeight: CGFloat = 400
let roomAbove = nodeScreenPos.y - TreeLayout.nodeHeight / 2

let placeBelow = roomAbove < popoverHeight + 20
let popoverY = placeBelow
    ? nodeScreenPos.y + TreeLayout.nodeHeight / 2 + 10
    : nodeScreenPos.y - TreeLayout.nodeHeight / 2 - 10
```

### 7.2 Popover During Recenter Animation

If the user clicks a node while a recenter animation is in progress:
1. Cancel the animation: `withAnimation(nil) { offset = .zero }`
2. Set `isAnimatingRecenter = false`
3. Process the click normally (select or inspect depending on whether node was already selected)

### 7.3 Spouse Node Indicators

Spouses don't show `▲`/`▼` indicators. To navigate a spouse's ancestors: select spouse → inspect (click again or Space) → parents shown in off-canvas relatives → click parent to recenter.

### 7.4 Empty Tree / Single Profile

Empty: show `TreePlaceholderView`. Single profile: centred node, click selects, second click or Space inspects, "Full Detail" opens sidebar.

### 7.5 Rapid Clicks on Arrow Indicator

If the user clicks an `▲ N parents` indicator twice quickly, the first click recenters (animated slide). The second click arrives during or after the animation — it will hit-test against the new layout. The node that was under the arrow may no longer be there. This is harmless: the second click either hits the new layout's node (selects it) or hits empty canvas (deselects). No special handling needed.

### 7.6 Generation Cap

At `visibleGenerations == 10`, ⌘+ and the toolbar "+" button are disabled (greyed out). Keyboard auto-expand at the boundary stops (first ↑ beeps). Nodes at generation 10 still show `▲ N parents` — clicking recenters, which shows the next 10 generations from that person.

### 7.7 Search and Empty View Mode

If the user selects a search result in descendants mode and the result has no children, auto-switch to pedigree with a toast ("Switched to Pedigree — no descendants"). Vice versa for pedigree mode with no parents. See §4.5.

---

## 8. Completeness Memoisation

`snapshot.completeness(for:)` is called for every visible node every frame. `FamilyGraphSnapshot` has a `completenessCache` dictionary populated on snapshot creation. Verify during implementation:
1. Cache is populated eagerly (on snapshot init), not lazily per-call
2. All callers (`drawNode`, popover, sidebar) read from the cache
3. Dictionary lookup is O(1)

If not cached: add `computedCompleteness: [String: ProfileCompleteness]` to `LayoutResult`, populated once during layout computation.

---

## 9. File Changes Summary

### 9.1 Modified Files

| File | Changes |
|------|---------|
| **TreeGraphView.swift** | Replace `onTapGesture` with differentiated hit-test dispatch (ⓘ → arrow → node body, with selected-node re-click logic). No double-click handler (see §5.2). Add popover overlay in ZStack. Add `FocusState` for canvas/search focus management. Add keyboard handlers gated on `.canvas` focus. Remove overview from view mode picker. Add `GeometryReader` for canvas size. Keep `MagnifyGesture` (clamp 0.5–2.0). Set `DragGesture(minimumDistance: 8)`. Replace breadcrumb with full trail. Add toolbar toggle for inspector sidebar (`sidebar.right` icon). Draw `ⓘ` icon (SF Symbol `info.circle.fill`) on selected node at all zoom levels. Instant hover highlight via `onContinuousHover`. Change generation-zoom toolbar to text `− N gen +`. Add coach mark. Add toast overlay. |
| **TreeViewModel.swift** | Add `popoverProfileID`, `showInspector`, `isAnimatingRecenter`, `expandBreadcrumb`, `showToast`, `accessibilityReduceMotion`, `hoveredNodeID`, `pendingExpand`. Add `HitTestResult` enum. Modify `recenter(on:snapshot:canvasSize:)` with animation. Add `rebuildLayoutOnly()`, `currentTransform()`, `rootNodePosition()`, `recenterOnRelative()`. Add `increaseGenerations()` / `decreaseGenerations()`. Add `jumpToHistory()` with invalid-entry fallback. Decouple `selectedProfileID` from `rootProfileID`. Add data-change validation. Add `lastCanvasSize` cache for use in non-gesture recenter calls. |
| **TreeLayout.swift** | Add arrow hit-zone constants. Increase `verticalSpacing` to 60. Remove `overviewLayout()`. |
| **ProfileDetailView.swift** | Add ProfileHistoryView as disclosure group at bottom. |

### 9.2 New Files

| File | Purpose |
|------|---------|
| **ProfilePopoverView.swift** | Tier 2 popover. Off-canvas-only relatives with mode-switch badge (↻). Focus Here + Full Detail buttons. |
| **CanvasTransform.swift** | Value type for world↔screen coordinate conversion. |
| **TreeSearchField.swift** | Search with dropdown, keyboard nav, result count, recenter-on-select. |

### 9.3 Removed

| What | Why |
|------|-----|
| `TreeLayout.overviewLayout()` | Minimap deferred; overview mode removed |
| `TreeViewMode.overview` | Picker becomes Pedigree / Descendants |

---

## 10. Layout Constants Update

```swift
// TreeLayout.swift — add/modify
static let arrowHitWidth: Double = 80      // hit zone for arrow indicator text
static let arrowHitHeight: Double = 20     // hit zone for arrow indicator text
static let infoIconSize: Double = 24       // ⓘ icon hit zone and draw size
static let verticalSpacing: Double = 60    // was 50; accommodates arrow text + padding
```

---

## 11. Implementation Order

| Step | Work | Files | Depends on |
|------|------|-------|------------|
| 1 | Extract `CanvasTransform` struct, use in Canvas draw + hitTest | New: CanvasTransform.swift. Modify: TreeGraphView | — |
| 2 | Decouple `selectedProfileID` from `rootProfileID` — single click selects only | TreeViewModel, TreeGraphView | — |
| 3 | Add `FocusState` for canvas/search, gate keyboard handlers on focus | TreeGraphView | — |
| 4 | Add `HitTestResult` enum + multi-phase hit testing (ⓘ → arrow → node → empty) | TreeGraphView, TreeViewModel | 1 |
| 5 | Draw `ⓘ` icon on selected node (all zoom levels) + handle click to open popover | TreeGraphView | 2, 4 |
| 6 | Add "click already-selected node" → open popover logic in hit-test dispatch | TreeGraphView | 2, 4 |
| 7 | Create `ProfilePopoverView` with off-canvas-only relatives + mode-switch badge | New: ProfilePopoverView.swift | 2 |
| 8 | Add popover overlay in ZStack, wired to ⓘ/re-click/Space | TreeGraphView | 5, 6, 7 |
| 9 | Add animated recenter transition (via `CanvasTransform`) | TreeViewModel | 1, 2 |
| 10 | Restyle `▲`/`▼` indicators as "▲ N parents" text links → recenter on click | TreeGraphView | 4, 9 |
| 11 | Replace permanent sidebar with toggle-able inspector + toolbar button | TreeGraphView | 2 |
| 12 | Set `DragGesture(minimumDistance: 8)`, dismiss popover on qualifying drag | TreeGraphView | 8 |
| 13 | Create `TreeSearchField` with dropdown, ↻ mode-switch badge, recenter-on-select | New: TreeSearchField.swift, TreeGraphView toolbar | 3, 9 |
| 14 | Extend breadcrumb to full trail with collapsing | TreeGraphView, TreeViewModel | — |
| 15 | Add keyboard navigation (↑↓←→, Space, Return) gated on canvas focus | TreeGraphView, TreeViewModel | 2, 3, 8, 9 |
| 16 | Add keyboard boundary expand with confirm-before-expand | TreeViewModel | 15 |
| 17 | Add hover state for nodes (instant border highlight via `onContinuousHover`) | TreeGraphView | — |
| 18 | Add coach mark (3rd selection, up to 3 times) | TreeGraphView | 15 |
| 19 | Add toast overlay + auto-clear | TreeGraphView, TreeViewModel | — |
| 20 | Change generation-zoom toolbar to `− N gen +` text | TreeGraphView | — |
| 21 | Add data-change handling (selected/root/history validation) | TreeViewModel | 2 |
| 22 | Remove overview mode from picker and layout | TreeGraphView, TreeViewModel, TreeLayout | — |
| 23 | Increase `verticalSpacing`, add hit-zone constants | TreeLayout | 10 |
| 24 | Add living-person display ("b. 1970 — living") in node rendering | TreeGraphView | — |
| 25 | Test with 450-profile dataset | Manual | All |

Steps 1, 2, 3, 14, 17, 19, 20, 22, 24 have no dependencies and can start in parallel.

---

## 12. What This Spec Does NOT Change

- **Layout algorithm** — Pedigree and descendant layouts remain as-is (recursive binary split, children-centred). Reingold-Tilford/Sugiyama upgrades are separate work.
- **Completeness colouring** — Node background colour logic unchanged.
- **Edge rendering** — Orthogonal connectors and spouse lines unchanged.
- **Data model** — No changes to Profile, FamilyGraphSnapshot, or any persistence layer.
- **Home button** — Recenters on youngest profile, unchanged.

---

## 13. Deferred to Future Specs

| Feature | Why deferred | Prerequisite |
|---------|-------------|-------------|
| **Right-click context menus** | Requires invisible overlay geometry synced with Canvas + CanvasTransform — a class of sync bugs. All context menu actions (Focus Here, Inspect, Show in Sidebar) are reachable via other means (double-click, Space/ⓘ, ⌘⌥I). Revisit if users report discoverability issues. | Decision on Canvas vs SwiftUI-view node rendering |
| **Minimap** | Requires whole-tree layout algorithm. Grid overview has no spatial meaning. | Compact tree layout algorithm |
| **Visited-node tracking** | Too subtle as a dot. Research tracking needs persistent state + proper design. | Research-workflow spec, schema change |
| **Audit queue / "next incomplete"** | First-class research-workflow feature. | Research-workflow spec |
| **Per-branch selective expansion** | Global ⌘+/- is honest and sufficient for MVP. | User feedback |
| **Bookmarks / saved positions** | Requires new data model. | Schema design |
| **Side-by-side branch comparison** | Major layout change. | Research-workflow spec |
| **Fan chart** | Alternative visualisation. | Layout algorithm work |
| **Deep linking** | Saved view state. | Bookmarks |

---

## Appendix A: Implementation Code

Working code for the key navigation features. Each snippet is grounded in the actual codebase — model types (`Profile`, `FamilyGraphSnapshot`, `ProfileCompleteness`, `TreeLayout.LayoutNode`, `TreeLayout.LayoutEdge`), the existing Canvas draw approach, and the `@Observable` view model pattern.

### A.1 CanvasTransform — Single Source of Truth for Coordinates

This replaces the duplicated transform logic currently in both the Canvas draw block (TreeGraphView.swift:112–127) and the hit-test function (TreeGraphView.swift:315–339).

```swift
// CanvasTransform.swift

import Foundation

/// Value type converting between layout coordinates and screen coordinates.
/// Created per-frame from current view state. Used by Canvas draw, hit testing,
/// popover positioning, and animation offset calculation.
nonisolated struct CanvasTransform: Sendable {
    let canvasSize: CGSize
    let rootX: Double       // root node's layout x
    let rootY: Double       // root node's layout y
    let offset: CGSize      // user pan offset
    let scale: Double       // geometric zoom (0.5–2.0)

    /// Offset applied in Canvas to centre the root node near the bottom of the viewport.
    var drawOffsetX: Double { -rootX }
    var drawOffsetY: Double { -rootY + (canvasSize.height / scale / 2) - TreeLayout.nodeHeight }

    /// Layout position → screen position.
    func toScreen(x: Double, y: Double) -> CGPoint {
        CGPoint(
            x: (x + drawOffsetX) * scale + canvasSize.width / 2 + offset.width,
            y: (y + drawOffsetY) * scale + canvasSize.height / 2 + offset.height
        )
    }

    /// Screen position → layout position (inverse of toScreen).
    func toLayout(screenX: Double, screenY: Double) -> CGPoint {
        CGPoint(
            x: (screenX - canvasSize.width / 2 - offset.width) / scale - drawOffsetX,
            y: (screenY - canvasSize.height / 2 - offset.height) / scale - drawOffsetY
        )
    }
}
```

**Usage in Canvas draw block** — replaces lines 112–127 of TreeGraphView:

```swift
Canvas { context, size in
    let rootNode = treeVM.layout.nodes.first { $0.id == treeVM.rootProfileID }
    let transform = CanvasTransform(
        canvasSize: size,
        rootX: rootNode?.x ?? 0,
        rootY: rootNode?.y ?? 0,
        offset: treeVM.offset,
        scale: treeVM.scale
    )

    // Apply transform to context
    context.translateBy(
        x: size.width / 2 + treeVM.offset.width,
        y: size.height / 2 + treeVM.offset.height
    )
    context.scaleBy(x: treeVM.scale, y: treeVM.scale)

    // All node/edge positions use drawOffset
    for edge in treeVM.layout.edges {
        let from = CGPoint(x: edge.fromX + transform.drawOffsetX, y: edge.fromY + transform.drawOffsetY)
        let to = CGPoint(x: edge.toX + transform.drawOffsetX, y: edge.toY + transform.drawOffsetY)
        drawEdge(context: &context, from: from, to: to, type: edge.type)
    }
    // ... nodes drawn the same way
}
```

### A.2 HitTestResult + Multi-Phase Hit Testing

Replaces the current `hitTest(at:) -> String?` (TreeGraphView.swift:315–339) with a typed result and priority ordering.

```swift
// In TreeViewModel.swift

/// What the user tapped on the canvas.
enum HitTestResult {
    case infoIcon(String)           // ⓘ on the selected node
    case arrowIndicator(String)     // ▲/▼ text link on an edge-generation node
    case nodeBody(String)           // the node card itself
    case empty                      // background canvas
}

extension TreeViewModel {
    /// Multi-phase hit test. Priority: ⓘ icon → arrow indicators → node bodies → empty.
    func hitTest(at screenPoint: CGPoint, canvasSize: CGSize) -> HitTestResult {
        let transform = currentTransform(canvasSize: canvasSize)
        let layoutPoint = transform.toLayout(screenX: screenPoint.x, screenY: screenPoint.y)

        // Phase 1: ⓘ icon on the selected node (highest priority, smallest target)
        if let selectedID = selectedProfileID,
           let node = layout.nodes.first(where: { $0.id == selectedID }) {
            let iconRect = CGRect(
                x: node.x + TreeLayout.nodeWidth / 2 - TreeLayout.infoIconSize - 4,
                y: node.y + TreeLayout.nodeHeight / 2 - TreeLayout.infoIconSize - 4,
                width: TreeLayout.infoIconSize,
                height: TreeLayout.infoIconSize
            )
            if iconRect.contains(layoutPoint) {
                return .infoIcon(selectedID)
            }
        }

        // Phase 2: arrow indicators on edge-generation nodes
        for node in layout.nodes {
            if node.hasMoreAncestors {
                let arrowRect = CGRect(
                    x: node.x - TreeLayout.arrowHitWidth / 2,
                    y: node.y - TreeLayout.nodeHeight / 2 - TreeLayout.arrowHitHeight - 4,
                    width: TreeLayout.arrowHitWidth,
                    height: TreeLayout.arrowHitHeight
                )
                if arrowRect.contains(layoutPoint) {
                    return .arrowIndicator(node.id)
                }
            }
            if node.hasMoreDescendants {
                let arrowRect = CGRect(
                    x: node.x - TreeLayout.arrowHitWidth / 2,
                    y: node.y + TreeLayout.nodeHeight / 2 + 4,
                    width: TreeLayout.arrowHitWidth,
                    height: TreeLayout.arrowHitHeight
                )
                if arrowRect.contains(layoutPoint) {
                    return .arrowIndicator(node.id)
                }
            }
        }

        // Phase 3: node bodies
        for node in layout.nodes {
            let nodeRect = CGRect(
                x: node.x - TreeLayout.nodeWidth / 2,
                y: node.y - TreeLayout.nodeHeight / 2,
                width: TreeLayout.nodeWidth,
                height: TreeLayout.nodeHeight
            )
            if nodeRect.contains(layoutPoint) {
                return .nodeBody(node.id)
            }
        }

        return .empty
    }
}
```

### A.3 Gesture Dispatch — TreeGraphView Body

This replaces the current `treeCanvas` view with its single `onTapGesture` (TreeGraphView.swift:111–163). Shows the full ZStack structure with popover overlay, focus management, and gesture wiring.

```swift
// In TreeGraphView.swift — replaces the current body's ZStack + HSplitView

enum TreeFocus: Hashable {
    case canvas
    case search
}

struct TreeGraphView: View {
    @Environment(AppState.self) private var appState
    @State private var treeVM = TreeViewModel()
    @FocusState private var focus: TreeFocus?

    var body: some View {
        HStack(spacing: 0) {
            // Main tree area
            GeometryReader { geo in
                let canvasSize = geo.size

                ZStack {
                    // Layer 1: Canvas
                    treeCanvas(canvasSize: canvasSize)
                        .gesture(panGesture)
                        .gesture(magnifyGesture)
                        .focusable()
                        .focused($focus, equals: .canvas)
                        .onKeyPress(.space) {
                            guard focus == .canvas else { return .ignored }
                            return handleSpace()
                        }
                        .onKeyPress(.return) {
                            guard focus == .canvas else { return .ignored }
                            return handleReturn(canvasSize: canvasSize)
                        }
                        .onKeyPress(.escape) {
                            return handleEscape()
                        }
                        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                            guard focus == .canvas else { return .ignored }
                            return handleArrowKey(press, canvasSize: canvasSize)
                        }
                        // Single click — dispatch through hit test
                        .onTapGesture(count: 1) { location in
                            handleSingleClick(at: location, canvasSize: canvasSize)
                        }
                        // No double-click gesture — see §5.2 for rationale
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                // Instant hover update — no animation (see §5.2)
                                let result = treeVM.hitTest(at: location, canvasSize: canvasSize)
                                switch result {
                                case .nodeBody(let id), .infoIcon(let id), .arrowIndicator(let id):
                                    treeVM.hoveredNodeID = id
                                case .empty:
                                    treeVM.hoveredNodeID = nil
                                }
                            case .ended:
                                treeVM.hoveredNodeID = nil
                            }
                        }

                    // Layer 2: Popover overlay
                    popoverOverlay(canvasSize: canvasSize)

                    // Layer 3: Controls overlay (breadcrumb, zoom, toast)
                    controlsOverlay(canvasSize: canvasSize)
                }
                .onAppear {
                    focus = .canvas
                    treeVM.lastCanvasSize = canvasSize
                }
                .onChange(of: canvasSize) { _, newSize in
                    treeVM.lastCanvasSize = newSize
                }
            }
            .frame(minWidth: 400)

            // Inspector sidebar (on demand)
            if treeVM.showInspector,
               let selectedID = treeVM.selectedProfileID,
               let profile = appState.snapshot.profiles[selectedID] {
                ProfileDetailView(
                    profile: profile,
                    snapshot: appState.snapshot,
                    onSetRoot: {
                        treeVM.recenter(on: selectedID, snapshot: appState.snapshot,
                                       canvasSize: treeVM.lastCanvasSize)
                    }
                )
                .frame(width: 300)
            }
        }
        .toolbar { toolbarContent }
        .onAppear {
            selectInitialRoot()
            treeVM.rebuildLayout(snapshot: appState.snapshot)
        }
        .onChange(of: appState.snapshot.profiles.count) {
            treeVM.validateState(snapshot: appState.snapshot)
            treeVM.rebuildLayout(snapshot: appState.snapshot)
        }
    }

    // MARK: - Click Handling

    private func handleSingleClick(at location: CGPoint, canvasSize: CGSize) {
        // Cancel in-progress animation if needed
        if treeVM.isAnimatingRecenter {
            withAnimation(nil) { treeVM.offset = .zero }
            treeVM.isAnimatingRecenter = false
        }

        switch treeVM.hitTest(at: location, canvasSize: canvasSize) {
        case .infoIcon(let id):
            // ⓘ tapped — open popover
            treeVM.popoverProfileID = id

        case .arrowIndicator(let id):
            // ▲/▼ tapped — recenter on this person
            treeVM.popoverProfileID = nil
            treeVM.recenter(on: id, snapshot: appState.snapshot, canvasSize: canvasSize)

        case .nodeBody(let id):
            if id == treeVM.selectedProfileID {
                // Re-click on already-selected node → open popover
                treeVM.popoverProfileID = id
            } else {
                // Click on unselected node → select, dismiss popover
                treeVM.selectedProfileID = id
                treeVM.popoverProfileID = nil
                treeVM.pendingExpandTarget = nil
            }

        case .empty:
            treeVM.selectedProfileID = nil
            treeVM.popoverProfileID = nil
            treeVM.pendingExpandTarget = nil
        }

        focus = .canvas
    }

    // MARK: - Keyboard Handling

    private func handleSpace() -> KeyPress.Result {
        guard let selectedID = treeVM.selectedProfileID else { return .ignored }
        if treeVM.popoverProfileID == nil {
            treeVM.popoverProfileID = selectedID
        }
        // If popover already open, no-op (per spec §6.2)
        return .handled
    }

    private func handleReturn(canvasSize: CGSize) -> KeyPress.Result {
        guard let selectedID = treeVM.selectedProfileID else { return .ignored }
        treeVM.popoverProfileID = nil
        treeVM.recenter(on: selectedID, snapshot: appState.snapshot, canvasSize: canvasSize)
        return .handled
    }

    private func handleEscape() -> KeyPress.Result {
        if treeVM.popoverProfileID != nil {
            treeVM.popoverProfileID = nil
            return .handled
        }
        if treeVM.showInspector {
            treeVM.showInspector = false
            return .handled
        }
        if treeVM.selectedProfileID != nil {
            treeVM.selectedProfileID = nil
            return .handled
        }
        return .ignored
    }

    private func handleArrowKey(_ press: KeyPress, canvasSize: CGSize) -> KeyPress.Result {
        guard let selectedID = treeVM.selectedProfileID else { return .ignored }
        treeVM.popoverProfileID = nil  // dismiss on any navigation

        let snapshot = appState.snapshot
        var targetID: String?

        switch press.key {
        case .upArrow:
            let parents = snapshot.parentsOf(selectedID)
            if press.modifiers.contains(.shift) {
                // ⇧↑ = mother (second parent)
                targetID = parents.count >= 2 ? parents[1].id : parents.first?.id
            } else {
                // ↑ = father (first parent)
                targetID = parents.first?.id
            }

        case .downArrow:
            targetID = snapshot.childrenOf(selectedID).first?.id

        case .leftArrow:
            let siblings = snapshot.siblingsOf(selectedID)
            if let currentIndex = siblings.firstIndex(where: { $0.id == selectedID }) {
                if currentIndex > 0 {
                    targetID = siblings[currentIndex - 1].id
                }
            }

        case .rightArrow:
            let siblings = snapshot.siblingsOf(selectedID)
            if let currentIndex = siblings.firstIndex(where: { $0.id == selectedID }) {
                if currentIndex < siblings.count - 1 {
                    targetID = siblings[currentIndex + 1].id
                }
            }
            // Also check spouses if no sibling navigation
            if targetID == nil {
                targetID = snapshot.spousesOf(selectedID).first?.id
            }

        default:
            return .ignored
        }

        // Is the target in the current layout?
        if let target = targetID {
            if treeVM.layout.nodes.contains(where: { $0.id == target }) {
                treeVM.selectedProfileID = target
                treeVM.pendingExpandTarget = nil
                return .handled
            } else {
                // Target exists in data but not in layout — boundary case
                // Applies to ↑, ⇧↑, and ↓ uniformly (see §5.6)
                return treeVM.handleBoundaryExpand(
                    targetID: target, pressedKey: press.key,
                    snapshot: snapshot, canvasSize: canvasSize
                )
            }
        }

        NSSound.beep()
        return .handled
    }
}
```

### A.4 Confirm-Before-Expand at Generation Boundary

Generalised for ↑, ⇧↑, and ↓ — any direction that crosses the generation window.

```swift
// In TreeViewModel.swift

/// Handle arrow-key navigation that crosses the visible generation boundary.
/// First press shows a hint; second press of the same key within 3 seconds expands.
func handleBoundaryExpand(
    targetID: String,
    pressedKey: KeyEquivalent,
    snapshot: FamilyGraphSnapshot,
    canvasSize: CGSize
) -> KeyPress.Result {
    guard visibleGenerations < 10 else {
        NSSound.beep()
        return .handled
    }

    if pendingExpandTarget == targetID {
        // Second press for the same target — expand and select
        pendingExpandTarget = nil
        visibleGenerations = min(visibleGenerations + 1, 10)
        rebuildLayoutOnly(snapshot: snapshot)
        selectedProfileID = targetID
        // Clear the hint toast
        showToast = nil
        return .handled
    } else {
        // First press — show hint, start 3-second window
        pendingExpandTarget = targetID
        setToast("Press again to show more generations")
        let capturedTarget = targetID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if pendingExpandTarget == capturedTarget {
                pendingExpandTarget = nil
                showToast = nil  // clear hint if still showing
            }
        }
        return .handled
    }
}
```

### A.5 Node Drawing — ⓘ Icon, Hover Highlight, Arrow Indicators, Living Display

This replaces `drawNode` in TreeGraphView.swift (lines 190–311). Shows the key additions; unchanged parts are marked with comments.

```swift
private func drawNode(
    context: inout GraphicsContext,
    node: TreeLayout.LayoutNode,
    rect: CGRect,
    isSelected: Bool,
    isRoot: Bool,
    isHovered: Bool,
    dimmed: Bool,
    colorScheme: ColorScheme
) {
    let cornerRadius: Double = 12
    let path = Path(roundedRect: rect, cornerRadius: cornerRadius)

    // Background — completeness gradient (unchanged from current)
    let comp = node.completeness
    let ratio = comp.maximum > 0 ? Double(comp.score) / Double(comp.maximum) : 0
    let fillColor: Color = if isSelected {
        .accentColor.opacity(0.3)
    } else if isRoot {
        .blue.opacity(0.15)
    } else if dimmed {
        .gray.opacity(0.1)
    } else {
        Color(
            red: 1.0 - ratio * 0.7,
            green: 0.3 + ratio * 0.7,
            blue: 0.3
        ).opacity(0.15)
    }
    context.fill(path, with: .color(fillColor))

    // Border — with hover highlight
    let borderColor: Color
    let borderWidth: Double
    if isSelected {
        borderColor = .accentColor
        borderWidth = 2.5
    } else if isRoot {
        borderColor = .blue.opacity(0.5)
        borderWidth = 2
    } else if isHovered {
        borderColor = .secondary.opacity(0.5)
        borderWidth = 1.5
    } else {
        borderColor = .secondary.opacity(0.2)
        borderWidth = 1
    }
    context.stroke(path, with: .color(borderColor), lineWidth: borderWidth)

    // Name
    let name = node.profile.displayName
    if treeVM.scale > 0.4 {
        let nameText = Text(name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(dimmed ? .tertiary : .primary)
        context.draw(
            context.resolve(nameText),
            at: CGPoint(x: rect.midX, y: rect.midY - 12),
            anchor: .center
        )

        // Birth/death years — with living-person handling
        var dateStr = ""
        if let by = node.profile.birthDate?.bestYear {
            dateStr += "b.\(by)"
        }
        if let dy = node.profile.deathDate?.bestYear {
            dateStr += dateStr.isEmpty ? "d.\(dy)" : " — d.\(dy)"
        } else if comp.potentiallyLiving && node.profile.birthDate != nil {
            dateStr += dateStr.isEmpty ? "living" : " — living"
        }
        if !dateStr.isEmpty {
            let dateText = Text(dateStr)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            context.draw(
                context.resolve(dateText),
                at: CGPoint(x: rect.midX, y: rect.midY + 8),
                anchor: .center
            )
        }

        // Birth location (only at higher zoom)
        if treeVM.scale > 0.7, let loc = node.profile.birthLocation {
            let shortLoc = loc.components(separatedBy: ",").first ?? loc
            let locText = Text(shortLoc)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            context.draw(
                context.resolve(locText),
                at: CGPoint(x: rect.midX, y: rect.midY + 24),
                anchor: .center
            )
        }
    } else {
        // Low zoom: name only
        let nameText = Text(name)
            .font(.system(size: 10))
            .foregroundStyle(dimmed ? .quaternary : .secondary)
        context.draw(
            context.resolve(nameText),
            at: CGPoint(x: rect.midX, y: rect.midY),
            anchor: .center
        )
    }

    // Completeness badge (unchanged)
    let badge = Text("\(comp.score)/\(comp.maximum)")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(ratio >= 1.0 ? .green : .orange)
    context.draw(
        context.resolve(badge),
        at: CGPoint(x: rect.maxX - 18, y: rect.minY + 12),
        anchor: .center
    )

    // ⓘ icon — shown on selected node at ALL zoom levels (not gated by semantic zoom)
    // Uses SF Symbol for consistent rendering across fonts and system styles
    if isSelected {
        let iconSize = TreeLayout.infoIconSize
        let iconX = rect.maxX - iconSize / 2 - 4
        let iconY = rect.maxY - iconSize / 2 - 4
        let icon = context.resolve(Image(systemName: "info.circle.fill")
            .foregroundStyle(Color(.controlAccentColor)))
        context.draw(icon, in: CGRect(
            x: iconX - iconSize / 2, y: iconY - iconSize / 2,
            width: iconSize, height: iconSize
        ))
    }

    // Arrow indicators — recenter triggers
    if node.hasMoreAncestors {
        let parentCount = appState.snapshot.parentsOf(node.id).count
        let label = Text("▲ \(parentCount) parent\(parentCount == 1 ? "" : "s")")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color(.controlAccentColor))
        context.draw(
            context.resolve(label),
            at: CGPoint(x: rect.midX, y: rect.minY - 12),
            anchor: .center
        )
    }
    if node.hasMoreDescendants {
        let childCount = appState.snapshot.childrenOf(node.id).count
        let label = Text("▼ \(childCount) child\(childCount == 1 ? "" : "ren")")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color(.controlAccentColor))
        context.draw(
            context.resolve(label),
            at: CGPoint(x: rect.midX, y: rect.maxY + 12),
            anchor: .center
        )
    }
}
```

### A.6 Popover Overlay

The popover is a SwiftUI view positioned over the Canvas using screen coordinates from `CanvasTransform`.

```swift
// In TreeGraphView.swift

@ViewBuilder
private func popoverOverlay(canvasSize: CGSize) -> some View {
    if let popoverID = treeVM.popoverProfileID,
       let profile = appState.snapshot.profiles[popoverID] {
        let transform = treeVM.currentTransform(canvasSize: canvasSize)
        let node = treeVM.layout.nodes.first { $0.id == popoverID }
        let screenPos = node.map { transform.toScreen(x: $0.x, y: $0.y) }
            ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

        // Flip below if not enough room above
        let popoverHeight: CGFloat = 400
        let placeBelow = screenPos.y - TreeLayout.nodeHeight / 2 < popoverHeight + 20
        let anchorY = placeBelow
            ? screenPos.y + TreeLayout.nodeHeight / 2 * treeVM.scale + 10
            : screenPos.y - TreeLayout.nodeHeight / 2 * treeVM.scale - 10
        let anchor: UnitPoint = placeBelow ? .top : .bottom

        ProfilePopoverView(
            profile: profile,
            snapshot: appState.snapshot,
            completeness: appState.snapshot.completeness(for: popoverID),
            visibleNodeIDs: Set(treeVM.layout.nodes.map(\.id)),
            isRoot: popoverID == treeVM.rootProfileID,
            currentViewMode: treeVM.viewMode,
            onRecenter: { relativeID in
                treeVM.popoverProfileID = nil
                treeVM.recenterOnRelative(
                    relativeID, from: popoverID,
                    snapshot: appState.snapshot, canvasSize: canvasSize
                )
            },
            onFocusHere: {
                treeVM.popoverProfileID = nil
                treeVM.recenter(on: popoverID, snapshot: appState.snapshot,
                               canvasSize: canvasSize)
            },
            onShowDetail: {
                treeVM.popoverProfileID = nil
                treeVM.showInspector = true
            }
        )
        .frame(width: 320)
        .frame(maxHeight: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .position(x: screenPos.x, y: anchorY)
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: anchor)))
        .animation(.easeOut(duration: 0.15), value: popoverID)
    }
}
```

### A.7 ProfilePopoverView — Off-Canvas Relatives with Mode-Switch Badge

```swift
// ProfilePopoverView.swift

import SwiftUI

struct ProfilePopoverView: View {
    let profile: Profile
    let snapshot: FamilyGraphSnapshot
    let completeness: ProfileCompleteness
    let visibleNodeIDs: Set<String>
    let isRoot: Bool
    let currentViewMode: TreeViewMode

    var onRecenter: (String) -> Void        // relative ID → recenter on them
    var onFocusHere: () -> Void             // recenter on this profile
    var onShowDetail: () -> Void            // open inspector sidebar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                vitalEvents
                offCanvasRelativesSection
                missingFields
                disputeIndicator
                Divider()
                actionButtons
            }
            .padding(16)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.displayName)
                .font(.title3)
                .fontWeight(.bold)
            if let wikiTreeID = profile.wikiTreeID {
                Text(wikiTreeID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Completeness progress bar
            HStack(spacing: 6) {
                ProgressView(value: Double(completeness.score), total: Double(completeness.maximum))
                    .tint(completeness.score == completeness.maximum ? .green : .orange)
                    .frame(width: 60)
                Text("\(completeness.score)/\(completeness.maximum)")
                    .font(.caption)
                    .foregroundStyle(completeness.score == completeness.maximum ? .green : .orange)
            }
        }
    }

    // MARK: - Vital Events

    private var vitalEvents: some View {
        VStack(alignment: .leading, spacing: 8) {
            if profile.birthDate != nil || profile.birthLocation != nil {
                fieldRow("Born", date: profile.birthDate?.original, location: profile.birthLocation, field: .birthDate)
            }
            if profile.deathDate != nil || profile.deathLocation != nil {
                fieldRow("Died", date: profile.deathDate?.original, location: profile.deathLocation, field: .deathDate)
            } else if completeness.potentiallyLiving {
                Text("Living")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let gender = profile.gender {
                HStack {
                    Text("Gender").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(gender.rawValue.capitalized).font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ label: String, date: String?, location: String?, field: ProfileField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                sourceBadges(for: field)
            }
            if let d = date { Text(d).font(.callout) }
            if let l = location { Text(l).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private func sourceBadges(for field: ProfileField) -> some View {
        let sources = profile.sources[field] ?? []
        HStack(spacing: 2) {
            ForEach(sources, id: \.raw) { source in
                Text(source.origin.identifier.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
            }
        }
    }

    // MARK: - Off-Canvas Relatives

    private var offCanvas: (parents: [Profile], spouses: [Profile],
                            children: [Profile], siblings: [Profile]) {
        (
            snapshot.parentsOf(profile.id).filter { !visibleNodeIDs.contains($0.id) },
            snapshot.spousesOf(profile.id).filter { !visibleNodeIDs.contains($0.id) },
            snapshot.childrenOf(profile.id).filter { !visibleNodeIDs.contains($0.id) },
            snapshot.siblingsOf(profile.id).filter { !visibleNodeIDs.contains($0.id) }
        )
    }

    private var hasOffCanvas: Bool {
        !offCanvas.parents.isEmpty || !offCanvas.spouses.isEmpty ||
        !offCanvas.children.isEmpty || !offCanvas.siblings.isEmpty
    }

    @ViewBuilder
    private var offCanvasRelativesSection: some View {
        if hasOffCanvas {
            VStack(alignment: .leading, spacing: 4) {
                Text("Off-canvas relatives")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                relativeGroup("Parent", relatives: offCanvas.parents, isAncestor: true)
                relativeGroup("Spouse", relatives: offCanvas.spouses, isAncestor: false)
                relativeGroup("Child", relatives: offCanvas.children, isAncestor: false)
                relativeGroup("Sibling", relatives: offCanvas.siblings, isAncestor: false)
            }
        } else {
            Text("All relatives visible on canvas")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .italic()
        }
    }

    @ViewBuilder
    private func relativeGroup(_ label: String, relatives: [Profile], isAncestor: Bool) -> some View {
        if !relatives.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                // Group header — shown once
                Text(relatives.count == 1 ? label : "\(label)s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                // Indented rows
                ForEach(relatives) { relative in
                    Button {
                        onRecenter(relative.id)
                    } label: {
                        HStack(spacing: 4) {
                            // Mode-switch badge
                            if wouldSwitchMode(relative: relative, isAncestor: isAncestor) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help("Will switch to \(targetMode(isAncestor: isAncestor).rawValue) view")
                            }
                            Text(relative.displayName)
                                .font(.callout)
                            if let year = relative.birthDate?.bestYear {
                                Text("b. \(year)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                }
            }
        }
    }

    private func wouldSwitchMode(relative: Profile, isAncestor: Bool) -> Bool {
        (isAncestor && currentViewMode == .descendants) ||
        (!isAncestor && currentViewMode == .pedigree &&
         snapshot.childrenOf(profile.id).contains { $0.id == relative.id })
    }

    private func targetMode(isAncestor: Bool) -> TreeViewMode {
        isAncestor ? .pedigree : .descendants
    }

    // MARK: - Missing Fields & Disputes

    @ViewBuilder
    private var missingFields: some View {
        if !completeness.missing.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Missing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(completeness.missing, id: \.self) { check in
                    switch check {
                    case .field(let field):
                        Text("• \(field.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    case .hasParents:
                        Text("• parents")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var disputeIndicator: some View {
        if !profile.disputes.isEmpty {
            let count = profile.disputes.count
            Text("⚠ \(count) disputed field\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack {
            Button("Focus Here") { onFocusHere() }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(isRoot)
            Spacer()
            Button("Full Detail") { onShowDetail() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }
}
```

### A.8 Breadcrumb Trail

```swift
// In TreeGraphView.swift — replaces the current breadcrumb overlay (lines 21–41)

private var breadcrumbTrail: some View {
    HStack(spacing: 4) {
        ForEach(treeVM.breadcrumbEntries(snapshot: appState.snapshot), id: \.historyIndex) { entry in
            if entry.isEllipsis {
                Button("…") {
                    treeVM.expandBreadcrumb = true
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            } else {
                Button(entry.name) {
                    treeVM.jumpToHistory(
                        index: entry.historyIndex,
                        snapshot: appState.snapshot
                    )
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(entry.isCurrent ? .primary : .secondary)
            }

            if !entry.isLast {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .glassEffect(.regular, in: .capsule)
}
```

```swift
// In TreeViewModel.swift

struct BreadcrumbEntry: Identifiable {
    let id = UUID()
    let historyIndex: Int
    let name: String
    let isCurrent: Bool
    let isLast: Bool
    let isEllipsis: Bool
}

/// Build breadcrumb entries from history.
/// Uses snapshot.profiles for name lookup — NOT layout.nodes, because
/// historical entries may reference profiles no longer in the visible layout.
func breadcrumbEntries(snapshot: FamilyGraphSnapshot) -> [BreadcrumbEntry] {
    guard !history.isEmpty else { return [] }
    let validEntries = history.prefix(through: historyIndex).enumerated().map { index, profileID in
        (index: index, name: snapshot.profiles[profileID]?.displayName ?? "?")
    }

    let count = validEntries.count
    if count <= 4 || expandBreadcrumb {
        return validEntries.enumerated().map { i, entry in
            BreadcrumbEntry(
                historyIndex: entry.index,
                name: i == 0 ? "Home" : entry.name,
                isCurrent: entry.index == historyIndex,
                isLast: i == count - 1,
                isEllipsis: false
            )
        }
    } else {
        // Collapse: first, …, last two
        var result: [BreadcrumbEntry] = []
        let first = validEntries[0]
        result.append(BreadcrumbEntry(
            historyIndex: first.index, name: "Home",
            isCurrent: false, isLast: false, isEllipsis: false
        ))
        result.append(BreadcrumbEntry(
            historyIndex: -1, name: "",
            isCurrent: false, isLast: false, isEllipsis: true
        ))
        for i in (count - 2)..<count {
            let entry = validEntries[i]
            result.append(BreadcrumbEntry(
                historyIndex: entry.index, name: entry.name,
                isCurrent: entry.index == historyIndex,
                isLast: i == count - 1, isEllipsis: false
            ))
        }
        return result
    }
}
```

### A.9 Pan Gesture with 8pt Threshold + Popover Dismissal

```swift
// In TreeGraphView.swift — replaces panGesture (lines 344–355)

private var panGesture: some Gesture {
    DragGesture(minimumDistance: 8)
        .onChanged { value in
            // Dismiss popover on first qualifying drag movement
            treeVM.popoverProfileID = nil
            treeVM.pendingExpandTarget = nil

            treeVM.offset = CGSize(
                width: treeVM.dragStartOffset.width + value.translation.width,
                height: treeVM.dragStartOffset.height + value.translation.height
            )
        }
        .onEnded { _ in
            treeVM.dragStartOffset = treeVM.offset
        }
}

private var magnifyGesture: some Gesture {
    MagnifyGesture()
        .onChanged { value in
            treeVM.scale = max(0.5, min(2.0, value.magnification))
        }
}
```

### A.10 View-Mode-Aware Recenter for Off-Canvas Relatives

```swift
// In TreeViewModel.swift

func recenterOnRelative(
    _ relativeID: String,
    from currentProfileID: String,
    snapshot: FamilyGraphSnapshot,
    canvasSize: CGSize
) {
    let isAncestor = snapshot.parentsOf(currentProfileID).contains { $0.id == relativeID }
    let isChild = snapshot.childrenOf(currentProfileID).contains { $0.id == relativeID }

    // Auto-switch mode if the relative isn't reachable in the current mode
    if isAncestor && viewMode == .descendants {
        viewMode = .pedigree
    } else if isChild && viewMode == .pedigree {
        viewMode = .descendants
    }

    recenter(on: relativeID, snapshot: snapshot, canvasSize: canvasSize)
}

/// Validate state after snapshot change — ensure selected/root still exist.
func validateState(snapshot: FamilyGraphSnapshot) {
    if let selected = selectedProfileID, snapshot.profiles[selected] == nil {
        selectedProfileID = nil
        popoverProfileID = nil
    }
    if let root = rootProfileID, snapshot.profiles[root] == nil {
        rootProfileID = nil  // will be re-set by selectInitialRoot
    }
}
```
