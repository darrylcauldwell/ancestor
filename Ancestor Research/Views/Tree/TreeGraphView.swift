import SwiftUI

/// Focus context — determines which keyboard handlers are active.
private enum TreeFocus: Hashable {
    case canvas
    case search
}

/// Interactive family tree visualisation using Canvas.
/// Shows a window of generations around a focal person.
/// Click to select, click again or Space to inspect, Return to recenter.
struct TreeGraphView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var treeVM = TreeViewModel()
    @FocusState private var focus: TreeFocus?
    @AppStorage("coachMarkShownCount") private var coachMarkShownCount: Int = 0
    @AppStorage("selectionCount") private var selectionCount: Int = 0
    @State private var showCoachMark: Bool = false

    var body: some View {
        HStack(spacing: 0) {
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
                        .onTapGesture(count: 1) { location in
                            handleSingleClick(at: location, canvasSize: canvasSize)
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let result = treeVM.hitTest(at: location, canvasSize: canvasSize)
                                switch result {
                                case .nodeBody(let id), .infoIcon(let id), .arrowIndicator(let id),
                                     .ancestorIndicator(let id), .descendantIndicator(let id):
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

                    // Layer 3: Controls overlay
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
            selectInitialRoot()
            treeVM.rebuildLayout(snapshot: appState.snapshot)
        }
    }

    // MARK: - Initial Root

    private var naturalRootID: String? {
        let withParents = appState.snapshot.profiles.values.filter {
            !appState.snapshot.parentsOf($0.id).isEmpty
        }
        let youngest = withParents.max { a, b in
            (a.birthDate?.bestYear ?? 0) < (b.birthDate?.bestYear ?? 0)
        }
        return youngest?.id ?? appState.snapshot.profiles.keys.first
    }

    private func selectInitialRoot() {
        guard treeVM.rootProfileID == nil, !appState.snapshot.profiles.isEmpty else { return }
        if let rootID = naturalRootID {
            treeVM.rootProfileID = rootID
            treeVM.selectedProfileID = rootID
        }
    }

    // MARK: - Click Handling

    private func handleSingleClick(at location: CGPoint, canvasSize: CGSize) {
        if treeVM.isAnimatingRecenter {
            withAnimation(nil) { treeVM.offset = .zero }
            treeVM.isAnimatingRecenter = false
        }

        switch treeVM.hitTest(at: location, canvasSize: canvasSize) {
        case .infoIcon(let id):
            treeVM.popoverProfileID = id

        case .arrowIndicator(let id):
            treeVM.popoverProfileID = nil
            treeVM.recenter(on: id, snapshot: appState.snapshot, canvasSize: canvasSize)

        case .ancestorIndicator(let id):
            // Tapped "▲ ancestors" — stay in pedigree mode, recenter on this node
            treeVM.popoverProfileID = nil
            treeVM.recenter(on: id, snapshot: appState.snapshot, canvasSize: canvasSize)

        case .descendantIndicator(let id):
            // Tapped "▼ N children" — switch to descendants mode to show them
            treeVM.popoverProfileID = nil
            treeVM.viewMode = .descendants
            treeVM.recenter(on: id, snapshot: appState.snapshot, canvasSize: canvasSize)

        case .nodeBody(let id):
            if id == treeVM.selectedProfileID {
                // Re-click on selected node → open popover
                treeVM.popoverProfileID = id
            } else {
                treeVM.selectedProfileID = id
                treeVM.popoverProfileID = nil
                treeVM.pendingExpandTarget = nil
                // Track selection count for coach mark
                selectionCount += 1
                if selectionCount == 3 && coachMarkShownCount < 3 {
                    showCoachMark = true
                    coachMarkShownCount += 1
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        showCoachMark = false
                    }
                }
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
        treeVM.popoverProfileID = nil

        let snapshot = appState.snapshot
        var targetID: String?

        switch press.key {
        case .upArrow:
            let parents = snapshot.parentsOf(selectedID)
            if press.modifiers.contains(.shift) {
                targetID = parents.count >= 2 ? parents[1].id : parents.first?.id
            } else {
                targetID = parents.first?.id
            }

        case .downArrow:
            targetID = snapshot.childrenOf(selectedID).first?.id

        case .leftArrow:
            let siblings = snapshot.siblingsOf(selectedID)
            if let currentIndex = siblings.firstIndex(where: { $0.id == selectedID }),
               currentIndex > 0 {
                targetID = siblings[currentIndex - 1].id
            }

        case .rightArrow:
            let siblings = snapshot.siblingsOf(selectedID)
            if let currentIndex = siblings.firstIndex(where: { $0.id == selectedID }),
               currentIndex < siblings.count - 1 {
                targetID = siblings[currentIndex + 1].id
            }
            if targetID == nil {
                targetID = snapshot.spousesOf(selectedID).first?.id
            }

        default:
            return .ignored
        }

        if let target = targetID {
            if treeVM.layout.nodes.contains(where: { $0.id == target }) {
                treeVM.selectedProfileID = target
                treeVM.pendingExpandTarget = nil
                return .handled
            } else {
                // Boundary case — confirm before expanding
                let handled = treeVM.handleBoundaryExpand(
                    targetID: target, snapshot: snapshot, canvasSize: canvasSize
                )
                return handled ? .handled : .ignored
            }
        }

        NSSound.beep()
        return .handled
    }

    // MARK: - Canvas

    private func treeCanvas(canvasSize: CGSize) -> some View {
        Canvas { context, size in
            let rootNode = treeVM.layout.nodes.first { $0.id == treeVM.rootProfileID }
            let transform = CanvasTransform(
                canvasSize: size,
                rootX: rootNode?.x ?? 0,
                rootY: rootNode?.y ?? 0,
                offset: treeVM.offset,
                scale: treeVM.scale
            )

            context.translateBy(
                x: size.width / 2 + treeVM.offset.width,
                y: size.height / 2 + treeVM.offset.height
            )
            context.scaleBy(x: treeVM.scale, y: treeVM.scale)

            let offsetX = transform.drawOffsetX
            let offsetY = transform.drawOffsetY

            // Draw edges — group parent edges by parent to avoid overlapping line segments
            var parentChildGroups: [String: (from: CGPoint, children: [CGPoint])] = [:]
            var spouseEdges: [(from: CGPoint, to: CGPoint)] = []

            for edge in treeVM.layout.edges {
                let from = CGPoint(x: edge.fromX + offsetX, y: edge.fromY + offsetY)
                let to = CGPoint(x: edge.toX + offsetX, y: edge.toY + offsetY)

                if edge.type == .spouse {
                    spouseEdges.append((from, to))
                } else {
                    let key = edge.fromID
                    if parentChildGroups[key] == nil {
                        parentChildGroups[key] = (from: from, children: [])
                    }
                    parentChildGroups[key]!.children.append(to)
                }
            }

            // Draw grouped parent-child connectors (one path per parent, no overlap)
            for (_, group) in parentChildGroups {
                drawParentChildGroup(context: &context, from: group.from, children: group.children)
            }

            // Draw spouse connectors
            for edge in spouseEdges {
                drawEdge(context: &context, from: edge.from, to: edge.to, type: .spouse)
            }

            // Draw nodes (real + ghost)
            let highlighted = Set(treeVM.filteredNodes().map(\.id))
            let hasSearch = !treeVM.searchText.isEmpty

            for node in treeVM.layout.allNodes {
                if node.isGhost {
                    let rect = CGRect(
                        x: node.x + offsetX - TreeLayout.ghostNodeWidth / 2,
                        y: node.y + offsetY - TreeLayout.ghostNodeHeight / 2,
                        width: TreeLayout.ghostNodeWidth,
                        height: TreeLayout.ghostNodeHeight
                    )
                    drawGhostNode(context: &context, node: node, rect: rect)
                } else {
                    let rect = CGRect(
                        x: node.x + offsetX - TreeLayout.nodeWidth / 2,
                        y: node.y + offsetY - TreeLayout.nodeHeight / 2,
                        width: TreeLayout.nodeWidth,
                        height: TreeLayout.nodeHeight
                    )
                    let isSelected = node.id == treeVM.selectedProfileID
                    let isRoot = node.id == treeVM.rootProfileID
                    let isHovered = node.id == treeVM.hoveredNodeID
                    let dimmed = hasSearch && !highlighted.contains(node.id)
                    drawNode(context: &context, node: node, rect: rect,
                            isSelected: isSelected, isRoot: isRoot, isHovered: isHovered, dimmed: dimmed)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Drawing

    /// Draw a single parent with all children as one connected path.
    /// Parent → vertical drop → horizontal bar → vertical drops to each child.
    /// No overlapping segments.
    private func drawParentChildGroup(context: inout GraphicsContext, from: CGPoint, children: [CGPoint]) {
        guard !children.isEmpty else { return }

        let fromBottom = CGPoint(x: from.x, y: from.y + TreeLayout.nodeHeight / 2)
        let childTops = children.map { CGPoint(x: $0.x, y: $0.y - TreeLayout.nodeHeight / 2) }
        let midY = (fromBottom.y + childTops[0].y) / 2

        var path = Path()

        // Parent down to midY
        path.move(to: fromBottom)
        path.addLine(to: CGPoint(x: fromBottom.x, y: midY))

        // Horizontal bar spanning all children
        let leftX = min(fromBottom.x, childTops.map(\.x).min()!)
        let rightX = max(fromBottom.x, childTops.map(\.x).max()!)
        path.move(to: CGPoint(x: leftX, y: midY))
        path.addLine(to: CGPoint(x: rightX, y: midY))

        // Vertical drops to each child
        for top in childTops {
            path.move(to: CGPoint(x: top.x, y: midY))
            path.addLine(to: top)
        }

        context.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1.5)
    }

    private func drawEdge(context: inout GraphicsContext, from: CGPoint, to: CGPoint, type: RelationshipType) {
        var path = Path()
        if type == .spouse {
            let fromRight = CGPoint(x: from.x + TreeLayout.nodeWidth / 2, y: from.y)
            let toLeft = CGPoint(x: to.x - TreeLayout.nodeWidth / 2, y: to.y)
            path.move(to: fromRight)
            path.addLine(to: toLeft)
            context.stroke(path, with: .color(.pink.opacity(0.6)), lineWidth: 2)
        } else {
            let fromBottom = CGPoint(x: from.x, y: from.y + TreeLayout.nodeHeight / 2)
            let toTop = CGPoint(x: to.x, y: to.y - TreeLayout.nodeHeight / 2)
            let midY = (fromBottom.y + toTop.y) / 2

            path.move(to: fromBottom)
            path.addLine(to: CGPoint(x: fromBottom.x, y: midY))
            path.addLine(to: CGPoint(x: toTop.x, y: midY))
            path.addLine(to: toTop)
            context.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1.5)
        }
    }

    private func drawNode(
        context: inout GraphicsContext,
        node: TreeLayout.LayoutNode,
        rect: CGRect,
        isSelected: Bool,
        isRoot: Bool,
        isHovered: Bool,
        dimmed: Bool
    ) {
        let cornerRadius: Double = 12
        let path = Path(roundedRect: rect, cornerRadius: cornerRadius)

        // Background — completeness gradient
        guard let profile = node.profile, let comp = node.completeness else { return }
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

        // Border — with hover highlight (instant, no animation)
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
        let name = profile.displayName
        if treeVM.scale > 0.4 {
            let nameText = Text(name)
                .font(AppTypography.canvasName)
                .foregroundStyle(dimmed ? .tertiary : .primary)
            context.draw(
                context.resolve(nameText),
                at: CGPoint(x: rect.midX, y: rect.midY - 12),
                anchor: .center
            )

            // Birth/death years with living-person handling
            var dateStr = ""
            if let by = profile.birthDate?.bestYear {
                dateStr += "b.\(by)"
            }
            if let dy = profile.deathDate?.bestYear {
                dateStr += dateStr.isEmpty ? "d.\(dy)" : " — d.\(dy)"
            } else if comp.potentiallyLiving && profile.birthDate != nil {
                dateStr += dateStr.isEmpty ? "living" : " — living"
            }
            if !dateStr.isEmpty {
                let dateText = Text(dateStr)
                    .font(AppTypography.canvasDates)
                    .foregroundStyle(.secondary)
                context.draw(
                    context.resolve(dateText),
                    at: CGPoint(x: rect.midX, y: rect.midY + 8),
                    anchor: .center
                )
            }

            // Birth location at higher zoom
            if treeVM.scale > 0.7, let loc = profile.birthLocation {
                let shortLoc = loc.components(separatedBy: ",").first ?? loc
                let locText = Text(shortLoc)
                    .font(AppTypography.canvasLocation)
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
                .font(AppTypography.canvasNameSmall)
                .foregroundStyle(dimmed ? .quaternary : .secondary)
            context.draw(
                context.resolve(nameText),
                at: CGPoint(x: rect.midX, y: rect.midY),
                anchor: .center
            )
        }

        // Completeness badge
        let badge = Text("\(comp.score)/\(comp.maximum)")
            .font(AppTypography.canvasBadge)
            .foregroundStyle(ratio >= 1.0 ? .green : .orange)
        context.draw(
            context.resolve(badge),
            at: CGPoint(x: rect.maxX - 18, y: rect.minY + 12),
            anchor: .center
        )

        // ⓘ icon — shown on selected node at ALL zoom levels
        if isSelected {
            let iconSize = TreeLayout.infoIconSize
            let iconX = rect.maxX - iconSize / 2 - 4
            let iconY = rect.maxY - iconSize / 2 - 4
            let icon = Text("ⓘ")
                .font(AppTypography.canvasInfoIcon)
                .foregroundStyle(Color(.controlAccentColor))
            context.draw(
                context.resolve(icon),
                at: CGPoint(x: iconX, y: iconY),
                anchor: .center
            )
        }

        // Arrow indicators — recenter triggers
        if node.hasMoreAncestors {
            let parentCount = appState.snapshot.parentsOf(node.id).count
            let label = Text("▲ \(parentCount) parent\(parentCount == 1 ? "" : "s")")
                .font(AppTypography.canvasArrow)
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
                .font(AppTypography.canvasArrow)
                .foregroundStyle(Color(.controlAccentColor))
            context.draw(
                context.resolve(label),
                at: CGPoint(x: rect.midX, y: rect.maxY + 12),
                anchor: .center
            )
        }
    }

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

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
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

    // MARK: - Popover Overlay

    @ViewBuilder
    private func popoverOverlay(canvasSize: CGSize) -> some View {
        if let popoverID = treeVM.popoverProfileID,
           let profile = appState.snapshot.profiles[popoverID] {
            let transform = treeVM.currentTransform(canvasSize: canvasSize)
            let node = treeVM.layout.nodes.first { $0.id == popoverID }
            let screenPos = node.map { transform.toScreen(x: $0.x, y: $0.y) }
                ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

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
                },
                onResearch: {
                    treeVM.popoverProfileID = nil
                    appState.researchProfileID = popoverID
                }
            )
            .frame(width: 320)
            .frame(maxHeight: 480)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: 12))
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .position(x: screenPos.x, y: anchorY)
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: anchor)))
            .animation(.easeOut(duration: 0.15), value: popoverID)
        }
    }

    // MARK: - Controls Overlay

    @ViewBuilder
    private func controlsOverlay(canvasSize: CGSize) -> some View {
        VStack {
            // Breadcrumb trail
            HStack {
                breadcrumbTrail
                Spacer()
            }
            .padding()

            // Coach mark
            if showCoachMark {
                Text("Tip: ↑↓ navigate relatives · Space to inspect · Return to focus")
                    .font(AppTypography.toast)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
            }

            Spacer()

            HStack {
                Spacer()
                // Zoom controls
                VStack(spacing: 4) {
                    Button {
                        if let rootID = naturalRootID {
                            treeVM.viewMode = .pedigree
                            treeVM.recenter(on: rootID, snapshot: appState.snapshot,
                                           canvasSize: canvasSize)
                        }
                    } label: {
                        Image(systemName: "house")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .padding()
            }

            // Toast
            if let toast = treeVM.showToast {
                Text(toast)
                    .font(AppTypography.toast)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Breadcrumb

    private var breadcrumbTrail: some View {
        HStack(spacing: 4) {
            ForEach(treeVM.breadcrumbEntries(snapshot: appState.snapshot)) { entry in
                if entry.isEllipsis {
                    Button("…") {
                        treeVM.expandBreadcrumb = true
                    }
                    .font(AppTypography.breadcrumb)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                } else {
                    Button(entry.name) {
                        treeVM.jumpToHistory(
                            index: entry.historyIndex,
                            snapshot: appState.snapshot
                        )
                    }
                    .font(AppTypography.breadcrumb)
                    .buttonStyle(.plain)
                    .foregroundStyle(entry.isCurrent ? .primary : .secondary)
                }

                if !entry.isLast {
                    Image(systemName: "chevron.right")
                        .font(AppTypography.badge)
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("View", selection: Binding(
                get: { treeVM.viewMode },
                set: { newMode in
                    treeVM.viewMode = newMode
                    treeVM.rebuildLayout(snapshot: appState.snapshot)
                }
            )) {
                ForEach(TreeViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // Generation zoom: − N gen +
            HStack(spacing: 4) {
                Button {
                    treeVM.decreaseGenerations(snapshot: appState.snapshot)
                } label: {
                    Text("−").font(AppTypography.controlLabel.monospaced()).frame(width: 20)
                }
                .help("Show fewer generations (⌘-)")

                Text("\(treeVM.visibleGenerations) gen")
                    .font(AppTypography.controlLabel)
                    .monospacedDigit()
                    .frame(width: 40)

                Button {
                    treeVM.increaseGenerations(snapshot: appState.snapshot)
                } label: {
                    Text("+").font(AppTypography.controlLabel.monospaced()).frame(width: 20)
                }
                .help("Show more generations (⌘+)")
            }

            // Inspector sidebar toggle
            Button {
                treeVM.showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle inspector (⌘⌥I)")

            TreeSearchField(
                searchText: $treeVM.searchText,
                allProfiles: Array(appState.snapshot.profiles.values),
                snapshot: appState.snapshot,
                currentViewMode: treeVM.viewMode,
                onSelect: { profileID in
                    treeVM.recenter(on: profileID, snapshot: appState.snapshot,
                                   canvasSize: treeVM.lastCanvasSize)
                    focus = .canvas
                }
            )
            .focused($focus, equals: .search)
        }
    }
}
