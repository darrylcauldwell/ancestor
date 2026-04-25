import Foundation

/// Single source of truth for converting between layout coordinates and screen coordinates.
/// Created per-frame from current view state. Used by Canvas draw, hit testing, and popover positioning.
nonisolated struct CanvasTransform: Sendable {
    let canvasSize: CGSize
    let rootX: Double
    let rootY: Double
    let offset: CGSize
    let scale: Double

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

    /// Screen position → layout position.
    func toLayout(screenX: Double, screenY: Double) -> CGPoint {
        CGPoint(
            x: (screenX - canvasSize.width / 2 - offset.width) / scale - drawOffsetX,
            y: (screenY - canvasSize.height / 2 - offset.height) / scale - drawOffsetY
        )
    }
}
