import Foundation

/// Portable load preferences preserve hidden-file filtering (F-042). Batch size is clamped to one.
public struct LoadOptions: Sendable, Equatable {
    public let showHidden: Bool
    public let sort: ItemSort
    public let useCache: Bool
    public let batchSize: Int
    public init(showHidden: Bool = false, sort: ItemSort = .defaultSort, useCache: Bool = true, batchSize: Int = Limits.enumerationBatchSize) {
        self.showHidden = showHidden; self.sort = sort; self.useCache = useCache; self.batchSize = max(1, batchSize)
    }
}
/// Portable monitor failures describe unavailable watching without exposing platform errors (B-015).
public enum MonitorFailure: Error, Hashable, Sendable { case permissionDenied, unavailable, timedOut, other(String) }
/// Root changes request revalidation, not an invented new path (B-073, B-104).
public enum MonitorEvent: Hashable, Sendable {
    case changed(paths: Set<String>), rescan, rootChanged, volumeUnmounted, unavailable(MonitorFailure)
}
/// Shared validation failures preserve safe filename handling (F-054, B-039); colon is permitted.
public enum FileNameError: Error, Hashable, Sendable { case empty, separator, nul, dot, tooLong }
