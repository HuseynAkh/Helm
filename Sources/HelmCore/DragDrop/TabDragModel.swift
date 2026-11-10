// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Tab-strip intent preserves F-010 identity while adding P-003/P-005 window transfers.
public enum TabDropIntent: Hashable, Sendable {
    case reorder(from: Int, to: Int), transfer(insertionIndex: Int), detach, none
}
/// Pure geometry uses strip-local coordinates; controllers retain tab state/identity (F-010).
public enum TabDragModel {
    /// Slots are in the original array; exact midpoints insert after that tab.
    public static func insertionIndex(x: Double, widths: [Double]) -> Int? {
        guard x.isFinite, widths.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        var edge: Double = 0
        for (index, width) in widths.enumerated() {
            guard (edge + width).isFinite else { return nil }
            if x < edge + width / 2 { return index }
            edge += width
        }
        return widths.count
    }
    /// Converts a pre-removal insertion slot to the final index; adjacent slots are no-ops.
    public static func reorderIndex(sourceIndex: Int, insertionIndex: Int, count: Int) -> Int? {
        guard count > 0, sourceIndex >= 0, sourceIndex < count,
              insertionIndex >= 0, insertionIndex <= count else { return nil }
        let result = insertionIndex > sourceIndex ? insertionIndex - 1 : insertionIndex
        return result == sourceIndex ? nil : result
    }
    /// Destination-strip hit testing wins over tear-off. Distance is from the source strip boundary.
    public static func intent(sourceIndex: Int, sourceCount: Int, destinationWidths: [Double]?,
                              destinationX: Double, sameWindow: Bool, distanceOutsideStrip: Double,
                              detachThreshold: Double = 40) -> TabDropIntent {
        guard sourceIndex >= 0, sourceIndex < sourceCount else { return .none }
        if let widths = destinationWidths {
            guard let slot = insertionIndex(x: destinationX, widths: widths) else { return .none }
            if !sameWindow { return .transfer(insertionIndex: slot) }
            guard widths.count == sourceCount,
                  let target = reorderIndex(sourceIndex: sourceIndex, insertionIndex: slot, count: sourceCount) else { return .none }
            return .reorder(from: sourceIndex, to: target)
        }
        guard distanceOutsideStrip.isFinite, detachThreshold.isFinite, detachThreshold >= 0,
              distanceOutsideStrip > 0, distanceOutsideStrip >= detachThreshold,
              sourceCount > 1 else { return .none }
        return .detach
    }
}
