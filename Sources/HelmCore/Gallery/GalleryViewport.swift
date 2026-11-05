// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Bounded horizontal demand extends F-035/F-048 without enabling a new ViewMode.
public struct GalleryViewport: Equatable, Sendable {
    public let offset: Double
    public let width: Double
    public let itemExtent: Double
    public let prefetch: Int
    public let requestLimit: Int
    public init(offset: Double = 0, width: Double = 0, itemExtent: Double = 96,
                prefetch: Int = 2, requestLimit: Int = 128) {
        self.offset = offset.isFinite ? max(0, offset) : 0
        self.width = width.isFinite ? max(0, width) : 0
        self.itemExtent = itemExtent.isFinite && itemExtent > 0 ? itemExtent : 96
        self.prefetch = min(max(0, prefetch), 128)
        self.requestLimit = min(max(0, requestLimit), 512)
    }
    /// Visible F-041 page geometry, independent of thumbnail prefetch and budget.
    public func visibleCellCount(count: Int) -> Int {
        guard count > 0, width > 0 else { return 0 }
        let start = floor(offset / itemExtent)
        guard start.isFinite, start < Double(count) else { return 0 }
        let remaining = count - Int(start)
        let cells = ceil((offset.truncatingRemainder(dividingBy: itemExtent) + width) / itemExtent)
        guard cells.isFinite, cells < Double(remaining) else { return remaining }
        return max(0, Int(cells))
    }
    public func indices(count: Int) -> Range<Int> {
        guard count > 0, width > 0, requestLimit > 0 else { return 0..<0 }
        let startValue = floor(offset / itemExtent)
        guard startValue.isFinite, startValue < Double(count) else { return 0..<0 }
        let start = Int(startValue)
        let visibleValue = ceil((offset.truncatingRemainder(dividingBy: itemExtent) + width) / itemExtent)
        let visible = visibleValue.isFinite ? Int(min(Double(requestLimit), visibleValue)) : requestLimit
        // Visible cells take priority when a small request budget cannot fit prefetch.
        let lower = max(0, start - min(prefetch, requestLimit - visible))
        let length = min(requestLimit, visible + (start - lower) + prefetch)
        return lower..<(lower + min(count - lower, length))
    }
}

/// Full content token and unique generation reject F-048 late previews, including ABA (B-009).
public struct GalleryPreviewRequest: Hashable, Sendable {
    public let generation: UUID
    public let key: ThumbnailKey
    public let changeToken: ChangeToken
    public init(generation: UUID, key: ThumbnailKey, changeToken: ChangeToken) {
        self.generation = generation; self.key = key; self.changeToken = changeToken
    }
}

/// Stable F-048 cell demand survives selected-preview generations; content changes still reload.
public struct GalleryFilmstripRequest: Hashable, Sendable {
    public let key: ThumbnailKey
    public let changeToken: ChangeToken
    public init(key: ThumbnailKey, changeToken: ChangeToken) {
        self.key = key; self.changeToken = changeToken
    }
}
