import SwiftUI
import AncestorKit
import AncestorKitUI
import AncestorViewerKit

/// Touch tree per PHASE4_VIEWER_SPEC §6: full pan/zoom canvas — drag to
/// pan, pinch to zoom, tap a person for their sheet, "focus" from the
/// sheet re-roots the layout on them. CanvasTransform stays the single
/// source of truth for draw and hit-testing, exactly as on macOS.
struct TreeScreen: View {
    let tree: ViewerTree
    @Environment(ViewerModel.self) private var model

    @State private var focalID: String?
    @State private var selectedPerson: SelectedPerson?

    @State private var committedOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero
    @State private var committedScale = 1.0
    @GestureState private var pinchScale = 1.0

    private let maxGenerations = 4

    struct SelectedPerson: Identifiable {
        let id: String
    }

    private var scale: Double {
        min(max(committedScale * pinchScale, 0.35), 2.5)
    }

    private var offset: CGSize {
        CGSize(width: committedOffset.width + dragOffset.width,
               height: committedOffset.height + dragOffset.height)
    }

    private var resolvedFocalID: String? {
        if let focalID, tree.snapshot.profiles[focalID] != nil { return focalID }
        if let root = tree.manifest.rootPerson, tree.snapshot.profiles[root] != nil { return root }
        return tree.snapshot.profiles.keys.sorted().first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let focal = resolvedFocalID {
                    let layout = TreeLayout.pedigreeLayout(
                        rootID: focal, snapshot: tree.snapshot, maxGenerations: maxGenerations)
                    GeometryReader { geometry in
                        canvas(layout: layout, focalID: focal, size: geometry.size)
                            .contentShape(Rectangle())
                            .gesture(tapGesture(layout: layout, size: geometry.size, focalID: focal))
                            .simultaneousGesture(dragGesture)
                            .simultaneousGesture(pinchGesture)
                            .task(id: focal) {
                                // Fit-to-width whenever the focal person
                                // changes — a pedigree is wide, phones are
                                // narrow; start framed, pinch from there.
                                // Vertically: the transform pins the root
                                // near the bottom edge; recentre the whole
                                // content block on tall screens.
                                let fit = geometry.size.width / max(layout.contentWidth, 1)
                                let s = min(max(fit, 0.35), 1.0)
                                committedScale = s
                                let verticalShift = (layout.contentHeight * s - geometry.size.height) / 2
                                    + TreeLayout.nodeHeight * s
                                committedOffset = CGSize(width: 0, height: min(verticalShift, 0))
                            }
                    }
                } else {
                    StatusScreen(
                        systemImage: "tree",
                        title: "Tree is empty",
                        message: "The published tree has no people yet.")
                }
            }
            .navigationTitle(tree.snapshot.profiles[resolvedFocalID ?? ""]?.displayName ?? "Family Tree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { try? await model.refresh() }
                    } label: {
                        if model.isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .accessibilityLabel("Refresh from iCloud")
                }
            }
            .sheet(item: $selectedPerson) { person in
                PersonSheet(personID: person.id, tree: tree) { newFocal in
                    focalID = newFocal
                    committedOffset = .zero
                    committedScale = 1.0
                }
            }
            .overlay(alignment: .bottom) {
                if tree.schemaExceedsSupported {
                    Text("Published with a newer version — update the app to see the latest.")
                        .font(AppTypography.toast)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: - Canvas

    private func canvas(layout: TreeLayout.LayoutResult, focalID: String, size: CGSize) -> some View {
        let transform = self.transform(layout: layout, focalID: focalID, size: size)
        // The macOS pattern, copied faithfully: scale the GraphicsContext
        // and draw in LAYOUT coordinates — fixed theme fonts then scale
        // with the zoom instead of overflowing shrunken nodes.
        return Canvas { context, canvasSize in
            context.translateBy(
                x: canvasSize.width / 2 + offset.width,
                y: canvasSize.height / 2 + offset.height)
            context.scaleBy(x: scale, y: scale)
            let ox = transform.drawOffsetX
            let oy = transform.drawOffsetY

            for edge in layout.edges {
                let from = CGPoint(x: edge.fromX + ox, y: edge.fromY + oy)
                let to = CGPoint(x: edge.toX + ox, y: edge.toY + oy)
                TreeCanvasRenderer.drawEdge(context: &context, from: from, to: to, type: edge.type)
            }
            for node in layout.ghostNodes {
                TreeCanvasRenderer.drawGhostNode(
                    context: &context, node: node,
                    rect: layoutRect(node, ox: ox, oy: oy,
                                     width: TreeLayout.ghostNodeWidth, height: TreeLayout.ghostNodeHeight),
                    theme: AppTypography.treeCanvasTheme)
            }
            for node in layout.nodes {
                TreeCanvasRenderer.drawNode(
                    context: &context,
                    node: node,
                    rect: layoutRect(node, ox: ox, oy: oy,
                                     width: TreeLayout.nodeWidth, height: TreeLayout.nodeHeight),
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

    private func transform(layout: TreeLayout.LayoutResult, focalID: String, size: CGSize) -> CanvasTransform {
        let rootNode = layout.nodes.first { $0.id == focalID }
        return CanvasTransform(
            canvasSize: size,
            rootX: rootNode?.x ?? 0,
            rootY: rootNode?.y ?? 0,
            offset: offset,
            scale: scale)
    }

    private func layoutRect(_ node: TreeLayout.LayoutNode, ox: Double, oy: Double,
                            width: Double, height: Double) -> CGRect {
        CGRect(x: node.x + ox - width / 2, y: node.y + oy - height / 2,
               width: width, height: height)
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                committedOffset.width += value.translation.width
                committedOffset.height += value.translation.height
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                committedScale = min(max(committedScale * value.magnification, 0.35), 2.5)
            }
    }

    private func tapGesture(layout: TreeLayout.LayoutResult, size: CGSize, focalID: String) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let transform = self.transform(layout: layout, focalID: focalID, size: size)
                let point = transform.toLayout(screenX: value.location.x, screenY: value.location.y)
                if let hit = layout.nodes.first(where: { node in
                    abs(point.x - node.x) <= TreeLayout.nodeWidth / 2
                        && abs(point.y - node.y) <= TreeLayout.nodeHeight / 2
                }) {
                    selectedPerson = SelectedPerson(id: hit.id)
                }
            }
    }
}
