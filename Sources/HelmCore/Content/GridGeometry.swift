// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Uniform grid preserves F-035 metrics and supports P-027/P-028/P-052 without scanning all items.
/// Coordinates have a top-left origin. Empty space and spacing do not hit cells.
public struct GridGeometry: Sendable {
    public let itemCount: Int
    public let columns: Int
    public let itemSize: CGSize
    public let horizontalSpacing: CGFloat
    public let verticalSpacing: CGFloat
    public let horizontalInset: CGFloat
    public let verticalInset: CGFloat
    public let availableWidth: CGFloat
    public var rows: Int { itemCount / columns + (itemCount % columns == 0 ? 0 : 1) }
    public var contentHeight: CGFloat {
        rows == 0 ? 2 * verticalInset : 2 * verticalInset + CGFloat(rows) * pitchY - verticalSpacing
    }
    private var pitchX: CGFloat { itemSize.width + horizontalSpacing }
    private var pitchY: CGFloat { itemSize.height + verticalSpacing }

    public init(itemCount: Int, availableWidth: CGFloat, itemSize: CGSize = CGSize(width: 140, height: 140),
                horizontalSpacing: CGFloat = 10, verticalSpacing: CGFloat = 14,
                horizontalInset: CGFloat = 16, verticalInset: CGFloat = 12) {
        func clean(_ value: CGFloat, fallback: CGFloat, minimum: CGFloat = 0) -> CGFloat {
            value.isFinite ? min(1_000_000_000, max(minimum, value)) : fallback
        }
        self.itemCount = max(0, itemCount)
        self.availableWidth = clean(availableWidth, fallback: 0)
        self.itemSize = CGSize(width: clean(itemSize.width, fallback: 140, minimum: 1),
                               height: clean(itemSize.height, fallback: 140, minimum: 1))
        self.horizontalSpacing = clean(horizontalSpacing, fallback: 10)
        self.verticalSpacing = clean(verticalSpacing, fallback: 14)
        self.horizontalInset = clean(horizontalInset, fallback: 16)
        self.verticalInset = clean(verticalInset, fallback: 12)
        self.columns = max(1, Int(floor((max(0, self.availableWidth - 2 * self.horizontalInset) +
                                        self.horizontalSpacing) / (self.itemSize.width + self.horizontalSpacing))))
    }

    public func rect(at index: Int) -> CGRect? {
        guard index >= 0, index < itemCount else { return nil }
        return CGRect(x: horizontalInset + CGFloat(index % columns) * pitchX,
                      y: verticalInset + CGFloat(index / columns) * pitchY,
                      width: itemSize.width, height: itemSize.height)
    }

    public func index(at point: CGPoint) -> Int? {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= horizontalInset, point.y >= verticalInset else { return nil }
        let colValue: CGFloat = floor((point.x - horizontalInset) / pitchX)
        let rowValue: CGFloat = floor((point.y - verticalInset) / pitchY)
        guard colValue < CGFloat(columns), rowValue < CGFloat(rows) else { return nil }
        let row: Int = Int(rowValue), column: Int = Int(colValue)
        guard row <= (Int.max - column) / columns else { return nil }
        let index: Int = row * columns + column
        guard let rect = rect(at: index), point.x < rect.maxX, point.y < rect.maxY else { return nil }
        return index
    }

    /// A contiguous candidate range for vertically visible rows; excludes rows wholly in a gap.
    public func visibleRange(scrollOffset: CGFloat, viewportHeight: CGFloat) -> Range<Int> {
        guard scrollOffset.isFinite, viewportHeight.isFinite, viewportHeight > 0,
              (scrollOffset + viewportHeight).isFinite else { return 0..<0 }
        let rowRange: Range<Int> = axisRange(minimum: scrollOffset, maximum: scrollOffset + viewportHeight,
                                            inset: verticalInset, size: itemSize.height, pitch: pitchY, count: rows)
        guard !rowRange.isEmpty else { return 0..<0 }
        let lower: Int = rowRange.lowerBound * columns
        let upper: Int = rowRange.upperBound == rows ? itemCount : rowRange.upperBound * columns
        return lower..<upper
    }

    /// Positive-area intersection only; work is proportional to intersecting rows and columns.
    public func indices(intersecting rect: CGRect) -> Set<Int> {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return [] }
        let rect: CGRect = rect.standardized
        guard rect.width > 0, rect.height > 0, rect.maxX.isFinite, rect.maxY.isFinite else { return [] }
        let rowRange: Range<Int> = axisRange(minimum: rect.minY, maximum: rect.maxY, inset: verticalInset,
                                            size: itemSize.height, pitch: pitchY, count: rows)
        let cols: Range<Int> = axisRange(minimum: rect.minX, maximum: rect.maxX, inset: horizontalInset,
                                        size: itemSize.width, pitch: pitchX, count: columns)
        guard !rowRange.isEmpty, !cols.isEmpty else { return [] }
        var result: Set<Int> = []
        for row in rowRange {
            let base: Int = row * columns
            for column in cols where column < itemCount - base { result.insert(base + column) }
        }
        return result
    }

    private func axisRange(minimum: CGFloat, maximum: CGFloat, inset: CGFloat,
                           size: CGFloat, pitch: CGFloat, count: Int) -> Range<Int> {
        func bounded(_ value: CGFloat) -> Int {
            if value <= 0 { return 0 }
            if value >= CGFloat(count) { return count }
            return Int(value)
        }
        let lower: Int = bounded(floor((minimum - inset - size) / pitch) + 1)
        let upper: Int = bounded(ceil((maximum - inset) / pitch))
        return lower..<max(lower, upper)
    }
}
