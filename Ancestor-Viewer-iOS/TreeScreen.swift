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
    @State private var showingSearch = false

    // nil = "not touched yet" — the fit-to-screen default is computed
    // per-render from live geometry (a one-shot write raced initial
    // layout on iPad); the first gesture takes over.
    @State private var userOffset: CGSize?
    @GestureState private var dragOffset: CGSize = .zero
    @State private var userScale: Double?
    @GestureState private var pinchScale = 1.0

    private let maxGenerations = 4

    struct SelectedPerson: Identifiable {
        let id: String
    }

    private func fitScale(layout: TreeLayout.LayoutResult, size: CGSize) -> Double {
        let fit = size.width / max(layout.contentWidth, 1)
        return min(max(fit, 0.35), 1.0)
    }

    /// The transform pins the root near the bottom edge; recentre the
    /// whole content block vertically on tall screens.
    private func fitOffset(layout: TreeLayout.LayoutResult, size: CGSize, scale: Double) -> CGSize {
        let shift = (layout.contentHeight * scale - size.height) / 2
            + TreeLayout.nodeHeight * scale
        return CGSize(width: 0, height: min(shift, 0))
    }

    private func effectiveScale(layout: TreeLayout.LayoutResult, size: CGSize) -> Double {
        min(max((userScale ?? fitScale(layout: layout, size: size)) * pinchScale, 0.35), 2.5)
    }

    private func effectiveOffset(layout: TreeLayout.LayoutResult, size: CGSize, scale: Double) -> CGSize {
        let base = userOffset ?? fitOffset(layout: layout, size: size, scale: scale)
        return CGSize(width: base.width + dragOffset.width,
                      height: base.height + dragOffset.height)
    }

    private var resolvedFocalID: String? {
        if let focalID, tree.snapshot.profiles[focalID] != nil { return focalID }
        return tree.suggestedRootID
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
                            .simultaneousGesture(dragGesture(layout: layout, size: geometry.size))
                            .simultaneousGesture(pinchGesture(layout: layout, size: geometry.size))
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
                        showingSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Find a person")
                }
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
            .sheet(isPresented: $showingSearch) {
                PersonSearchSheet(tree: tree) { personID in
                    focalID = personID
                    userOffset = nil
                    userScale = nil
                }
            }
            .sheet(item: $selectedPerson) { person in
                PersonSheet(personID: person.id, tree: tree) { newFocal in
                    focalID = newFocal
                    userOffset = nil   // back to fit-to-screen for the new root
                    userScale = nil
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
        let scale = effectiveScale(layout: layout, size: size)
        let offset = effectiveOffset(layout: layout, size: size, scale: scale)
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
        let scale = effectiveScale(layout: layout, size: size)
        return CanvasTransform(
            canvasSize: size,
            rootX: rootNode?.x ?? 0,
            rootY: rootNode?.y ?? 0,
            offset: effectiveOffset(layout: layout, size: size, scale: scale),
            scale: scale)
    }

    private func layoutRect(_ node: TreeLayout.LayoutNode, ox: Double, oy: Double,
                            width: Double, height: Double) -> CGRect {
        CGRect(x: node.x + ox - width / 2, y: node.y + oy - height / 2,
               width: width, height: height)
    }

    // MARK: - Gestures

    private func dragGesture(layout: TreeLayout.LayoutResult, size: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let scale = effectiveScale(layout: layout, size: size)
                let base = userOffset ?? fitOffset(layout: layout, size: size, scale: scale)
                userOffset = CGSize(width: base.width + value.translation.width,
                                    height: base.height + value.translation.height)
            }
    }

    private func pinchGesture(layout: TreeLayout.LayoutResult, size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinchScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                let base = userScale ?? fitScale(layout: layout, size: size)
                userScale = min(max(base * value.magnification, 0.35), 2.5)
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
