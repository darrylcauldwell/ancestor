import SwiftUI

/// What the user tapped on the canvas.
nonisolated enum HitTestResult: Sendable {
    case infoIcon(String)
    case arrowIndicator(String)
    case ancestorIndicator(String)
    case descendantIndicator(String)
    case nodeBody(String)
    case empty
}

nonisolated enum TreeViewMode: String, CaseIterable {
    case pedigree = "Pedigree"
    case descendants = "Descendants"
}

/// View model for the interactive tree graph.
@MainActor @Observable
final class TreeViewModel {
    var layout: TreeLayout.LayoutResult = .init(nodes: [], ghostNodes: [], edges: [], width: 0, height: 0, rootID: nil)
    var selectedProfileID: String?
    var rootProfileID: String?
    var viewMode: TreeViewMode = .pedigree
    var scale: Double = 1.0
    var offset: CGSize = .zero
    var dragStartOffset: CGSize = .zero
    var searchText: String = ""
    var visibleGenerations: Int = 4

    // Navigation history
    private var history: [String] = []
    private var historyIndex: Int = -1

    // New state for v5 redesign
    var popoverProfileID: String?
    var showInspector: Bool = false
    var isAnimatingRecenter: Bool = false
    var expandBreadcrumb: Bool = false
    var showToast: String?
    var hoveredNodeID: String?
    var pendingExpandTarget: String?
    var lastCanvasSize: CGSize = .zero
    private var toastGeneration: Int = 0

    var canGoBack: Bool { historyIndex > 0 }

    // MARK: - Layout

    func rebuildLayout(snapshot: FamilyGraphSnapshot) {
        if let rootID = rootProfileID {
            // Auto-switch mode if the current mode produces an empty tree
            var mode = viewMode
            if mode == .descendants && snapshot.childrenOf(rootID).isEmpty && !snapshot.parentsOf(rootID).isEmpty {
                mode = .pedigree
                viewMode = .pedigree
                setToast("Switched to Pedigree — no descendants")
            } else if mode == .pedigree && snapshot.parentsOf(rootID).isEmpty && !snapshot.childrenOf(rootID).isEmpty {
                mode = .descendants
                viewMode = .descendants
                setToast("Switched to Descendants — no ancestors")
            }

            switch mode {
            case .pedigree:
                layout = TreeLayout.pedigreeLayout(rootID: rootID, snapshot: snapshot, maxGenerations: visibleGenerations)
            case .descendants:
                layout = TreeLayout.descendantLayout(rootID: rootID, snapshot: snapshot, maxGenerations: visibleGenerations)
            }
        } else {
            layout = .init(nodes: [], ghostNodes: [], edges: [], width: 0, height: 0, rootID: nil)
        }
        scale = 1.0
        offset = .zero
        dragStartOffset = .zero
    }

    /// Rebuild layout without resetting offset/scale — used during animated recenter.
    private func rebuildLayoutOnly(snapshot: FamilyGraphSnapshot) {
        guard let rootID = rootProfileID else { return }
        switch viewMode {
        case .pedigree:
            layout = TreeLayout.pedigreeLayout(rootID: rootID, snapshot: snapshot, maxGenerations: visibleGenerations)
        case .descendants:
            layout = TreeLayout.descendantLayout(rootID: rootID, snapshot: snapshot, maxGenerations: visibleGenerations)
        }
    }

    // MARK: - Recenter (animated)

    func recenter(on profileID: String, snapshot: FamilyGraphSnapshot, canvasSize: CGSize) {
        guard let oldRootID = rootProfileID else {
            // First root — no animation
            rootProfileID = profileID
            selectedProfileID = profileID
            rebuildLayoutOnly(snapshot: snapshot)
            scale = 1.0
            offset = .zero
            dragStartOffset = .zero
            if history.isEmpty {
                history.append(profileID)
                historyIndex = 0
            }
            return
        }

        // 1. Capture old root's screen position before rebuild
        let transform = currentTransform(canvasSize: canvasSize)
        let oldRootNode = layout.nodes.first { $0.id == oldRootID }
        let oldScreenPos = oldRootNode.map { transform.toScreen(x: $0.x, y: $0.y) }

        // 2. Update history
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(profileID)
        historyIndex = history.count - 1

        // 3. Rebuild with new root
        rootProfileID = profileID
        selectedProfileID = profileID
        popoverProfileID = nil
        scale = 1.0
        rebuildLayoutOnly(snapshot: snapshot)

        // 4. Where does old root appear in the new layout at offset=.zero?
        let newTransform = CanvasTransform(
            canvasSize: canvasSize,
            rootX: rootNodePosition().x,
            rootY: rootNodePosition().y,
            offset: .zero,
            scale: scale
        )
        let newOldRootNode = layout.nodes.first { $0.id == oldRootID }
        let newScreenPos = newOldRootNode.map { newTransform.toScreen(x: $0.x, y: $0.y) }

        // 5. Animate from displaced offset to zero
        if let before = oldScreenPos, let after = newScreenPos {
            let initialOffset = CGSize(
                width: before.x - after.x,
                height: before.y - after.y
            )
            isAnimatingRecenter = true
            offset = initialOffset
            dragStartOffset = .zero

            withAnimation(.easeInOut(duration: 0.35)) {
                offset = .zero
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.35))
                isAnimatingRecenter = false
            }
        } else {
            offset = .zero
            dragStartOffset = .zero
        }
    }

    /// Recenter that may auto-switch view mode for off-canvas relatives.
    func recenterOnRelative(
        _ relativeID: String, from currentProfileID: String,
        snapshot: FamilyGraphSnapshot, canvasSize: CGSize
    ) {
        let isAncestor = snapshot.parentsOf(currentProfileID).contains { $0.id == relativeID }
        let isChild = snapshot.childrenOf(currentProfileID).contains { $0.id == relativeID }

        if isAncestor && viewMode == .descendants {
            viewMode = .pedigree
        } else if isChild && viewMode == .pedigree {
            viewMode = .descendants
        }

        recenter(on: relativeID, snapshot: snapshot, canvasSize: canvasSize)
    }

    // MARK: - History Navigation

    func goBack(snapshot: FamilyGraphSnapshot) {
        guard canGoBack else { return }
        historyIndex -= 1
        rootProfileID = history[historyIndex]
        selectedProfileID = rootProfileID
        popoverProfileID = nil
        rebuildLayout(snapshot: snapshot)
    }

    func jumpToHistory(index targetIndex: Int, snapshot: FamilyGraphSnapshot) {
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
        // Entire history invalid — caller should set a new root
    }

    // MARK: - Generation Zoom

    func increaseGenerations(snapshot: FamilyGraphSnapshot) {
        visibleGenerations = min(visibleGenerations + 1, 10)
        rebuildLayout(snapshot: snapshot)
    }

    func decreaseGenerations(snapshot: FamilyGraphSnapshot) {
        visibleGenerations = max(visibleGenerations - 1, 2)
        rebuildLayout(snapshot: snapshot)
    }

    // MARK: - Keyboard Boundary Expand

    func handleBoundaryExpand(
        targetID: String,
        snapshot: FamilyGraphSnapshot,
        canvasSize: CGSize
    ) -> Bool {
        guard visibleGenerations < 10 else {
            NSSound.beep()
            return true
        }

        if pendingExpandTarget == targetID {
            // Second press — expand and select
            pendingExpandTarget = nil
            visibleGenerations = min(visibleGenerations + 1, 10)
            rebuildLayoutOnly(snapshot: snapshot)
            selectedProfileID = targetID
            showToast = nil
            return true
        } else {
            // First press — show hint
            pendingExpandTarget = targetID
            setToast("Press again to show more generations")
            let capturedTarget = targetID
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if pendingExpandTarget == capturedTarget {
                    pendingExpandTarget = nil
                    showToast = nil
                }
            }
            return true
        }
    }

    // MARK: - Hit Testing

    func hitTest(at screenPoint: CGPoint, canvasSize: CGSize) -> HitTestResult {
        let transform = currentTransform(canvasSize: canvasSize)
        let layoutPoint = transform.toLayout(screenX: screenPoint.x, screenY: screenPoint.y)

        // Phase 1: ⓘ icon on the selected node
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

        // Phase 2: arrow indicators
        for node in layout.nodes {
            if node.hasMoreAncestors {
                let arrowRect = CGRect(
                    x: node.x - TreeLayout.arrowHitWidth / 2,
                    y: node.y - TreeLayout.nodeHeight / 2 - TreeLayout.arrowHitHeight - 4,
                    width: TreeLayout.arrowHitWidth,
                    height: TreeLayout.arrowHitHeight
                )
                if arrowRect.contains(layoutPoint) {
                    return .ancestorIndicator(node.id)
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
                    return .descendantIndicator(node.id)
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

    // MARK: - Search

    func filteredNodes() -> [TreeLayout.LayoutNode] {
        guard !searchText.isEmpty else { return layout.nodes }
        let query = searchText.lowercased()
        return layout.nodes.filter {
            $0.profile?.displayName.lowercased().contains(query) ?? false
        }
    }

    // MARK: - Toast

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

    // MARK: - Breadcrumb

    struct BreadcrumbEntry: Identifiable {
        let id = UUID()
        let historyIndex: Int
        let name: String
        let isCurrent: Bool
        let isLast: Bool
        let isEllipsis: Bool
    }

    func breadcrumbEntries(snapshot: FamilyGraphSnapshot) -> [BreadcrumbEntry] {
        guard !history.isEmpty, historyIndex >= 0 else { return [] }
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

    // MARK: - Data Change Validation

    func validateState(snapshot: FamilyGraphSnapshot) {
        if let selected = selectedProfileID, snapshot.profiles[selected] == nil {
            selectedProfileID = nil
            popoverProfileID = nil
        }
        if let root = rootProfileID, snapshot.profiles[root] == nil {
            rootProfileID = nil
        }
    }

    // MARK: - Transform Helpers

    func currentTransform(canvasSize: CGSize) -> CanvasTransform {
        let pos = rootNodePosition()
        return CanvasTransform(
            canvasSize: canvasSize,
            rootX: pos.x,
            rootY: pos.y,
            offset: offset,
            scale: scale
        )
    }

    func rootNodePosition() -> CGPoint {
        let rootNode = layout.nodes.first { $0.id == rootProfileID }
        return CGPoint(x: rootNode?.x ?? 0, y: rootNode?.y ?? 0)
    }
}
