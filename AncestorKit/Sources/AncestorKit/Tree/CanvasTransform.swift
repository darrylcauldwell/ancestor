import Foundation

/// Single source of truth for converting between layout coordinates and screen coordinates.
/// Created per-frame from current view state. Used by Canvas draw, hit testing, and popover positioning.
public nonisolated struct CanvasTransform: Sendable {
    public let canvasSize: CGSize
    public let rootX: Double
    public let rootY: Double
    public let offset: CGSize
    public let scale: Double

    public init(canvasSize: CGSize, rootX: Double, rootY: Double, offset: CGSize, scale: Double) {
        self.canvasSize = canvasSize
        self.rootX = rootX
        self.rootY = rootY
        self.offset = offset
        self.scale = scale
    }

    /// Offset applied in Canvas to centre the root node near the bottom of the viewport.
    public var drawOffsetX: Double { -rootX }
    public var drawOffsetY: Double { -rootY + (canvasSize.height / scale / 2) - TreeLayout.nodeHeight }

    /// Layout position → screen position.
    public func toScreen(x: Double, y: Double) -> CGPoint {
        CGPoint(
            x: (x + drawOffsetX) * scale + canvasSize.width / 2 + offset.width,
            y: (y + drawOffsetY) * scale + canvasSize.height / 2 + offset.height
        )
    }

    /// Screen position → layout position.
    public func toLayout(screenX: Double, screenY: Double) -> CGPoint {
        CGPoint(
            x: (screenX - canvasSize.width / 2 - offset.width) / scale - drawOffsetX,
            y: (screenY - canvasSize.height / 2 - offset.height) / scale - drawOffsetY
        )
    }
}
