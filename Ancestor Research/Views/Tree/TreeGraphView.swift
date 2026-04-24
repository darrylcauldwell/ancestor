import SwiftUI

/// Interactive family tree visualisation using Canvas.
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

                // Zoom controls overlay
                VStack {
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
                    onSetRoot: { treeVM.setRoot(selectedID, snapshot: appState.snapshot) }
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
            treeVM.rebuildLayout(snapshot: appState.snapshot)
        }
        .onChange(of: appState.snapshot.profiles.count) {
            treeVM.rebuildLayout(snapshot: appState.snapshot)
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
                let dimmed = hasSearch && !highlighted.contains(node.id)
                drawNode(context: &context, node: node, rect: rect,
                        isSelected: isSelected, dimmed: dimmed)
            }
        }
        .onTapGesture { location in
            handleTap(at: location)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Drawing

    private func drawEdge(context: inout GraphicsContext, from: CGPoint, to: CGPoint, type: RelationshipType) {
        var path = Path()
        if type == .spouse {
            // Horizontal line for spouse connections
            path.move(to: CGPoint(x: from.x + TreeLayout.nodeWidth / 2, y: from.y))
            path.addLine(to: CGPoint(x: to.x - TreeLayout.nodeWidth / 2, y: to.y))
            context.stroke(path, with: .color(.pink.opacity(0.6)), lineWidth: 2)
        } else {
            // Curved line for parent-child
            let midY = (from.y + to.y) / 2
            path.move(to: CGPoint(x: from.x, y: from.y + TreeLayout.nodeHeight / 2))
            path.addCurve(
                to: CGPoint(x: to.x, y: to.y - TreeLayout.nodeHeight / 2),
                control1: CGPoint(x: from.x, y: midY),
                control2: CGPoint(x: to.x, y: midY)
            )
            context.stroke(path, with: .color(.secondary.opacity(0.5)), lineWidth: 1.5)
        }
    }

    private func drawNode(
        context: inout GraphicsContext,
        node: TreeLayout.LayoutNode,
        rect: CGRect,
        isSelected: Bool,
        dimmed: Bool
    ) {
        let cornerRadius: Double = 10
        let path = Path(roundedRect: rect, cornerRadius: cornerRadius)

        // Background colour based on completeness
        let comp = node.completeness
        let ratio = comp.maximum > 0 ? Double(comp.score) / Double(comp.maximum) : 0
        let fillColor: Color = if isSelected {
            .accentColor.opacity(0.3)
        } else if dimmed {
            .gray.opacity(0.1)
        } else {
            Color(
                red: 1.0 - ratio * 0.7,
                green: 0.3 + ratio * 0.7,
                blue: 0.3
            ).opacity(0.2)
        }

        context.fill(path, with: .color(fillColor))

        // Border
        let borderColor: Color = isSelected ? .accentColor : .secondary.opacity(0.3)
        context.stroke(path, with: .color(borderColor), lineWidth: isSelected ? 2 : 1)

        // Name text
        let name = node.profile.displayName
        let nameText = Text(name).font(.caption).foregroundStyle(dimmed ? .tertiary : .primary)
        context.draw(
            context.resolve(nameText),
            at: CGPoint(x: rect.midX, y: rect.midY - 8),
            anchor: .center
        )

        // Birth year text
        if let year = node.profile.birthDate?.bestYear {
            let yearText = Text("b. \(year)").font(.caption2).foregroundStyle(.secondary)
            context.draw(
                context.resolve(yearText),
                at: CGPoint(x: rect.midX, y: rect.midY + 10),
                anchor: .center
            )
        }

        // Completeness badge
        let badge = Text("\(comp.score)/\(comp.maximum)")
            .font(.system(size: 9))
            .foregroundStyle(ratio >= 1.0 ? .green : .orange)
        context.draw(
            context.resolve(badge),
            at: CGPoint(x: rect.maxX - 16, y: rect.minY + 10),
            anchor: .center
        )

        // Dispute indicator
        if !node.profile.disputes.isEmpty {
            let disputeBadge = Text("⚠").font(.system(size: 10))
            context.draw(
                context.resolve(disputeBadge),
                at: CGPoint(x: rect.minX + 10, y: rect.minY + 10),
                anchor: .center
            )
        }
    }

    // MARK: - Interaction

    private func handleTap(at location: CGPoint) {
        // Transform screen coordinates back to canvas coordinates
        // This is approximate — works for basic selection
        guard let canvasSize = NSApp?.keyWindow?.contentView?.bounds.size else { return }
        let centerX = canvasSize.width / 2
        let centerY = canvasSize.height / 2

        let canvasX = (location.x - centerX - treeVM.offset.width) / treeVM.scale + treeVM.layout.width / 2
        let canvasY = (location.y - centerY - treeVM.offset.height) / treeVM.scale + treeVM.layout.height / 2

        // Find the node under the tap
        let hitNode = treeVM.layout.nodes.first { node in
            let nodeRect = CGRect(
                x: node.x - TreeLayout.nodeWidth / 2,
                y: node.y - TreeLayout.nodeHeight / 2,
                width: TreeLayout.nodeWidth,
                height: TreeLayout.nodeHeight
            )
            return nodeRect.contains(CGPoint(x: canvasX, y: canvasY))
        }

        treeVM.selectedProfileID = hitNode?.id
    }

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
