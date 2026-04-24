import SwiftUI

/// Interactive family tree visualisation using Canvas.
/// Shows a window of generations around a focal person — never all profiles at once.
/// Click any node to select. Double-click to recenter the view on that person.
struct TreeGraphView: View {
    @Environment(AppState.self) private var appState
    @State private var treeVM = TreeViewModel()
    @State private var dragStart: CGSize = .zero

    var body: some View {
        HSplitView {
            // Tree canvas
            ZStack {
                treeCanvas
                    .gesture(panGesture)
                    .gesture(magnifyGesture)

                // Controls overlay
                VStack {
                    // Navigation breadcrumb
                    if let rootID = treeVM.rootProfileID,
                       let root = appState.snapshot.profiles[rootID] {
                        HStack {
                            if treeVM.canGoBack {
                                Button {
                                    treeVM.goBack(snapshot: appState.snapshot)
                                } label: {
                                    Image(systemName: "chevron.left")
                                }
                                .buttonStyle(.glass)
                            }
                            Text(root.displayName)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .glassEffect(.regular, in: .capsule)
                            Spacer()
                        }
                        .padding()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        zoomControls
                            .padding()
                    }
                }
            }
            .frame(minWidth: 400)

            // Inspector panel
            if let selectedID = treeVM.selectedProfileID,
               let profile = appState.snapshot.profiles[selectedID] {
                ProfileDetailView(
                    profile: profile,
                    snapshot: appState.snapshot,
                    onSetRoot: {
                        treeVM.recenter(on: selectedID, snapshot: appState.snapshot)
                    }
                )
                .frame(width: 300)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("View", selection: $treeVM.viewMode) {
                    ForEach(TreeViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: treeVM.viewMode) {
                    treeVM.rebuildLayout(snapshot: appState.snapshot)
                }

                TextField("Search...", text: $treeVM.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }
        }
        .onAppear {
            selectInitialRoot()
            treeVM.rebuildLayout(snapshot: appState.snapshot)
        }
        .onChange(of: appState.snapshot.profiles.count) {
            selectInitialRoot()
            treeVM.rebuildLayout(snapshot: appState.snapshot)
        }
    }

    /// Pick the youngest profile with parents as the initial root.
    private func selectInitialRoot() {
        guard treeVM.rootProfileID == nil, !appState.snapshot.profiles.isEmpty else { return }

        let withParents = appState.snapshot.profiles.values.filter {
            !appState.snapshot.parentsOf($0.id).isEmpty
        }
        let youngest = withParents.max { a, b in
            (a.birthDate?.bestYear ?? 0) < (b.birthDate?.bestYear ?? 0)
        }
        if let rootID = youngest?.id ?? appState.snapshot.profiles.keys.first {
            treeVM.rootProfileID = rootID
        }
    }

    // MARK: - Canvas

    private var treeCanvas: some View {
        Canvas { context, size in
            let centerX = size.width / 2
            let centerY = size.height / 2

            context.translateBy(
                x: centerX + treeVM.offset.width,
                y: centerY + treeVM.offset.height
            )
            context.scaleBy(x: treeVM.scale, y: treeVM.scale)

            let offsetX = -treeVM.layout.width / 2
            let offsetY = -treeVM.layout.height / 2

            // Draw edges
            for edge in treeVM.layout.edges {
                let from = CGPoint(x: edge.fromX + offsetX, y: edge.fromY + offsetY)
                let to = CGPoint(x: edge.toX + offsetX, y: edge.toY + offsetY)
                drawEdge(context: &context, from: from, to: to, type: edge.type)
            }

            // Draw nodes
            let highlighted = Set(treeVM.filteredNodes().map(\.id))
            let hasSearch = !treeVM.searchText.isEmpty

            for node in treeVM.layout.nodes {
                let origin = CGPoint(
                    x: node.x + offsetX - TreeLayout.nodeWidth / 2,
                    y: node.y + offsetY - TreeLayout.nodeHeight / 2
                )
                let rect = CGRect(
                    origin: origin,
                    size: CGSize(width: TreeLayout.nodeWidth, height: TreeLayout.nodeHeight)
                )
                let isSelected = node.id == treeVM.selectedProfileID
                let isRoot = node.id == treeVM.rootProfileID
                let dimmed = hasSearch && !highlighted.contains(node.id)
                drawNode(context: &context, node: node, rect: rect,
                        isSelected: isSelected, isRoot: isRoot, dimmed: dimmed)
            }
        }
        .onTapGesture(count: 1) { location in
            // Single click to select AND recenter
            if let nodeID = hitTest(at: location) {
                treeVM.recenter(on: nodeID, snapshot: appState.snapshot)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Drawing

    private func drawEdge(context: inout GraphicsContext, from: CGPoint, to: CGPoint, type: RelationshipType) {
        var path = Path()
        if type == .spouse {
            // Horizontal double-line for spouse
            let fromRight = CGPoint(x: from.x + TreeLayout.nodeWidth / 2, y: from.y)
            let toLeft = CGPoint(x: to.x - TreeLayout.nodeWidth / 2, y: to.y)
            path.move(to: fromRight)
            path.addLine(to: toLeft)
            context.stroke(path, with: .color(.pink.opacity(0.6)), lineWidth: 2)
        } else {
            // Orthogonal connector for parent-child
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
        dimmed: Bool
    ) {
        let cornerRadius: Double = 12
        let path = Path(roundedRect: rect, cornerRadius: cornerRadius)

        // Background colour based on completeness
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

        // Border
        let borderColor: Color = isSelected ? .accentColor : (isRoot ? .blue.opacity(0.5) : .secondary.opacity(0.2))
        context.stroke(path, with: .color(borderColor), lineWidth: isSelected ? 2.5 : (isRoot ? 2 : 1))

        // Semantic zoom — detail level based on scale
        let name = node.profile.displayName
        if treeVM.scale > 0.4 {
            // Full detail: name + dates
            let nameText = Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(dimmed ? .tertiary : .primary)
            context.draw(
                context.resolve(nameText),
                at: CGPoint(x: rect.midX, y: rect.midY - 12),
                anchor: .center
            )

            // Birth/death years
            var dateStr = ""
            if let by = node.profile.birthDate?.bestYear {
                dateStr += "b.\(by)"
            }
            if let dy = node.profile.deathDate?.bestYear {
                dateStr += dateStr.isEmpty ? "d.\(dy)" : " — d.\(dy)"
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

            // Birth location (if space)
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
            // Medium/far zoom: name only
            let nameText = Text(name)
                .font(.system(size: 10))
                .foregroundStyle(dimmed ? .quaternary : .secondary)
            context.draw(
                context.resolve(nameText),
                at: CGPoint(x: rect.midX, y: rect.midY),
                anchor: .center
            )
        }

        // Completeness badge
        let badge = Text("\(comp.score)/\(comp.maximum)")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(ratio >= 1.0 ? .green : .orange)
        context.draw(
            context.resolve(badge),
            at: CGPoint(x: rect.maxX - 18, y: rect.minY + 12),
            anchor: .center
        )

        // Expand indicators
        if node.hasMoreAncestors {
            let indicator = Text("▲")
                .font(.system(size: 10))
                .foregroundStyle(.blue)
            context.draw(
                context.resolve(indicator),
                at: CGPoint(x: rect.midX, y: rect.minY - 8),
                anchor: .center
            )
        }
        if node.hasMoreDescendants {
            let indicator = Text("▼")
                .font(.system(size: 10))
                .foregroundStyle(.blue)
            context.draw(
                context.resolve(indicator),
                at: CGPoint(x: rect.midX, y: rect.maxY + 8),
                anchor: .center
            )
        }
    }

    // MARK: - Hit Testing

    private func hitTest(at location: CGPoint) -> String? {
        guard let canvasSize = NSApp?.keyWindow?.contentView?.bounds.size else { return nil }
        let centerX = canvasSize.width / 2
        let centerY = canvasSize.height / 2

        let canvasX = (location.x - centerX - treeVM.offset.width) / treeVM.scale + treeVM.layout.width / 2
        let canvasY = (location.y - centerY - treeVM.offset.height) / treeVM.scale + treeVM.layout.height / 2

        return treeVM.layout.nodes.first { node in
            let nodeRect = CGRect(
                x: node.x - TreeLayout.nodeWidth / 2,
                y: node.y - TreeLayout.nodeHeight / 2,
                width: TreeLayout.nodeWidth,
                height: TreeLayout.nodeHeight
            )
            return nodeRect.contains(CGPoint(x: canvasX, y: canvasY))
        }?.id
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                treeVM.offset = CGSize(
                    width: dragStart.width + value.translation.width,
                    height: dragStart.height + value.translation.height
                )
            }
            .onEnded { _ in
                dragStart = treeVM.offset
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                treeVM.scale = max(0.1, min(4.0, value.magnification))
            }
    }

    private var zoomControls: some View {
        VStack(spacing: 4) {
            Button { treeVM.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            Button { treeVM.zoomToFit() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            Button { treeVM.zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
            }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }
}
