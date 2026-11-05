// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Point dimensions and backing scale stay separate to fix F-048/B-056's quadruple sizing.
public struct ImageDimensions: Hashable, Sendable {
    public let widthPoints: Double
    public let heightPoints: Double
    public let backingScale: Double
    public init(widthPoints: Double, heightPoints: Double, backingScale: Double) {
        self.widthPoints = Self.valid(widthPoints)
        self.heightPoints = Self.valid(heightPoints)
        self.backingScale = Self.valid(backingScale)
    }
    private static func valid(_ value: Double) -> Double { value.isFinite && value > 0 ? value : 1 }
    public var pixelWidth: Double { (widthPoints * backingScale).rounded(.up) }
    public var pixelHeight: Double { (heightPoints * backingScale).rounded(.up) }
}

/// F-048 cache identity includes content changes and display scale (B-056).
public struct ThumbnailKey: Hashable, Sendable {
    public let itemID: ItemID
    public let modificationDate: Date
    public let fileSize: Int64
    public let dimensions: ImageDimensions
    public init(itemID: ItemID, modificationDate: Date, fileSize: Int64, dimensions: ImageDimensions) {
        self.itemID = itemID; self.modificationDate = modificationDate
        self.fileSize = fileSize; self.dimensions = dimensions
    }
    public init(entry: FileEntry, dimensions: ImageDimensions) {
        self.init(itemID: entry.id, modificationDate: entry.modificationDate, fileSize: entry.size, dimensions: dimensions)
    }
}

/// Unique per-cell subscription identity preserves F-048 reuse guards, including same-file reuse.
public struct ThumbnailRequestToken: Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Encoded bytes or another safe Sendable payload crosses the F-048 platform boundary; never NSImage.
public struct ThumbnailImage<Image: Sendable>: Sendable {
    public let image: Image
    public let costBytes: Int
    public init(image: Image, costBytes: Int) { self.image = image; self.costBytes = max(1, costBytes) }
}

/// F-048 failures are values so cache expiry and cancellation have distinct behavior.
public enum ThumbnailFailure: Error, Equatable, Sendable { case unavailable, cancelled }

/// F-048 delivery must be compared with the cell's current token on its UI actor before assignment.
public struct ThumbnailDelivery<Image: Sendable>: Sendable {
    public let token: ThumbnailRequestToken
    public let result: Result<ThumbnailImage<Image>, ThumbnailFailure>
    public init(token: ThumbnailRequestToken, result: Result<ThumbnailImage<Image>, ThumbnailFailure>) {
        self.token = token; self.result = result
    }
    public func image(ifCurrent current: ThumbnailRequestToken?) -> Image? {
        guard current == token, case .success(let value) = result else { return nil }
        return value.image
    }
}

/// One single-consumer stream per subscriber fixes dropped F-048 subscribers (B-055).
public struct ThumbnailSubscription<Image: Sendable>: Sendable {
    public let token: ThumbnailRequestToken
    public let deliveries: AsyncStream<ThumbnailDelivery<Image>>
    public init(token: ThumbnailRequestToken, deliveries: AsyncStream<ThumbnailDelivery<Image>>) {
        self.token = token; self.deliveries = deliveries
    }
}
