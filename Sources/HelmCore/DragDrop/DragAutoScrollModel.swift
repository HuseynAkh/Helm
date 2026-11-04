// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Linear edge acceleration preserves native F-067 auto-scroll behaviour (P-279).
public struct DragAutoScrollModel: Hashable, Sendable {
    public let edgeExtent: Double
    public let maximumSpeed: Double
    public init(edgeExtent: Double = 32, maximumSpeed: Double = 600) {
        self.edgeExtent = edgeExtent.isFinite ? max(0, edgeExtent) : 0
        self.maximumSpeed = maximumSpeed.isFinite ? max(0, maximumSpeed) : 0
    }
    /// Signed points/second on either axis. Call only while the pointer is inside the viewport.
    public func velocity(position: Double, viewportExtent: Double) -> Double {
        guard position.isFinite, viewportExtent.isFinite, viewportExtent > 0,
              position >= 0, position <= viewportExtent, edgeExtent > 0 else { return 0 }
        let edge = min(edgeExtent, viewportExtent / 2)
        if position < edge { return -maximumSpeed * (1 - position / edge) }
        if position > viewportExtent - edge { return maximumSpeed * (1 - (viewportExtent - position) / edge) }
        return 0
    }
}
