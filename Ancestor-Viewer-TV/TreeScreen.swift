import SwiftUI
import AncestorKit
import AncestorKitUI
import AncestorViewerKit

/// The living-room tree. Focus-driven per PHASE4_VIEWER_SPEC §5: remote
/// swipes move the focal person (up = parent, down = child, left/right =
/// spouse/siblings), the layout re-centres on every move, and the glass
/// info panel narrates whoever is focal. Select opens the full person
/// screen. Fixed comfortable scale — no pinch-zoom on a Siri Remote.
struct TreeScreen: View {
    let tree: ViewerTree
    @Environment(ViewerModel.self) private var model

    @State private var focalID: String?
    @State private var personSheet: FocusedPerson?
    @State private var showingSearch = false
    @FocusState private var canvasFocused: Bool

    private let scale = 1.5
    private let maxGenerations = 3

    /// Identifiable wrapper — .sheet(item:) per the project's
    /// sheet-isPresented-race convention.
    struct FocusedPerson: Identifiable {
        let id: String
    }

    private var resolvedFocalID: String? {
        if let focalID, tree.snapshot.profiles[focalID] != nil { return focalID }
        return tree.suggestedRootID
    }

    var body: some View {
        GeometryReader { geometry in
            if let focal = resolvedFocalID {
                let layout = TreeLayout.pedigreeLayout(
                    rootID: focal, snapshot: tree.snapshot, maxGenerations: maxGenerations)
                ZStack(alignment: .topLeading) {
                    canvas(layout: layout, focalID: focal, size: geometry.size)
                        .focusable()
                        .focused($canvasFocused)
                        .onMoveCommand { direction in move(direction, from: focal) }
                        .onTapGesture { personSheet = FocusedPerson(id: focal) }
                        .onLongPressGesture { showingSearch = true }
                        .onPlayPauseCommand { Task { try? await model.refresh() } }

                    FocusInfoPanel(
                        personID: focal,
                        tree: tree,
                        refreshing: model.isRefreshing)
                        .padding(48)
                }
                .onAppear { canvasFocused = true }
            } else {
                StatusScreen(
                    systemImage: "tree",
                    title: "Tree is empty",
                    message: "The published tree has no people yet.")
            }
        }
        .ignoresSafeArea()
        .fullScreenCover(item: $personSheet) { person in
            PersonScreen(personID: person.id, tree: tree)
        }
        .fullScreenCover(isPresented: $showingSearch) {
            PersonSearchScreen(tree: tree) { personID in
                focalID = personID
            }
        }
        .overlay(alignment: .bottom) {
            if tree.schemaExceedsSupported {
                Text("This tree was published with a newer version — update the app to see the latest.")
                    .font(AppTypography.toast)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
            }
        }
    }

    private func canvas(layout: TreeLayout.LayoutResult, focalID: String, size: CGSize) -> some View {
        let rootNode = layout.nodes.first { $0.id == focalID }
        // The macOS pattern, copied faithfully: scale the GraphicsContext
        // and draw in LAYOUT coordinates — fixed theme fonts then scale
        // with the canvas instead of drifting out of their nodes.
        return Canvas { context, canvasSize in
            let transform = CanvasTransform(
                canvasSize: canvasSize,
                rootX: rootNode?.x ?? 0,
                rootY: rootNode?.y ?? 0,
                offset: .zero,
                scale: scale)
            context.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            context.scaleBy(x: scale, y: scale)
            let ox = transform.drawOffsetX
            let oy = transform.drawOffsetY

            for edge in layout.edges {
                let from = CGPoint(x: edge.fromX + ox, y: edge.fromY + oy)
                let to = CGPoint(x: edge.toX + ox, y: edge.toY + oy)
                TreeCanvasRenderer.drawEdge(context: &context, from: from, to: to, type: edge.type)
            }

            for node in layout.ghostNodes {
                let rect = CGRect(
                    x: node.x + ox - TreeLayout.ghostNodeWidth / 2,
                    y: node.y + oy - TreeLayout.ghostNodeHeight / 2,
                    width: TreeLayout.ghostNodeWidth,
                    height: TreeLayout.ghostNodeHeight)
                TreeCanvasRenderer.drawGhostNode(
                    context: &context, node: node, rect: rect,
                    theme: AppTypography.treeCanvasTheme)
            }

            for node in layout.nodes {
                let rect = CGRect(
                    x: node.x + ox - TreeLayout.nodeWidth / 2,
                    y: node.y + oy - TreeLayout.nodeHeight / 2,
                    width: TreeLayout.nodeWidth,
                    height: TreeLayout.nodeHeight)
                TreeCanvasRenderer.drawNode(
                    context: &context,
                    node: node,
                    rect: rect,
                    scale: scale,
                    snapshot: tree.snapshot,
                    theme: AppTypography.treeCanvasTheme,
                    isSelected: node.id == focalID,
                    isRoot: node.id == tree.manifest.rootPerson,
                    isHovered: false,
                    dimmed: false,
                    showsCompletenessBadge: false)
            }
        }
    }

    /// Remote-swipe focal movement: up = first parent, down = first
    /// child, right/left = cycle through spouses then siblings (birth
    /// order). Every move re-roots the layout on the new focal person.
    private func move(_ direction: MoveCommandDirection, from focal: String) {
        let snapshot = tree.snapshot
        switch direction {
        case .up:
            if let parent = snapshot.parentsOf(focal).first { focalID = parent.id }
        case .down:
            if let child = snapshot.childrenOf(focal).first { focalID = child.id }
        case .left, .right:
            let row = lateralRow(around: focal)
            guard let index = row.firstIndex(of: focal), row.count > 1 else { return }
            let next = direction == .right
                ? row[(index + 1) % row.count]
                : row[(index - 1 + row.count) % row.count]
            focalID = next
        @unknown default:
            break
        }
    }

    /// The focal person's lateral family group: self + spouses + siblings
    /// in birth order, deduplicated, stable.
    private func lateralRow(around focal: String) -> [String] {
        let snapshot = tree.snapshot
        var row = [focal]
        row += snapshot.spousesOf(focal).map(\.id)
        let siblings = snapshot.siblingsOf(focal).sorted {
            ($0.birthDate?.earliest ?? Int.max, $0.displayName)
                < ($1.birthDate?.earliest ?? Int.max, $1.displayName)
        }
        row += siblings.map(\.id)
        var seen = Set<String>()
        return row.filter { seen.insert($0).inserted }
    }
}
