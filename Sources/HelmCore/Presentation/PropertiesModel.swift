// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Aggregate Get Info metadata (F-050, B-066); directory sizes are not recursive totals.
/// Negative sizes are unknown. Overflow saturates with an explicit flag rather than trapping.
public struct PropertiesModel: Sendable, Equatable {
    public let itemCount: Int
    public let directoryCount: Int
    public let fileCount: Int
    /// Legacy raw metadata sum, not recursive contents bytes.
    public let totalSize: Int64
    /// F-050/B-066: packages and directories require a recursive contents measurement.
    public let contentsSize: InspectorSizeState
    public let hasUnknownSize: Bool
    public let sizeOverflowed: Bool
    public let commonKind: FileEntryKind?
    public let commonKindDescription: String?
    public let hasMixedKinds: Bool
    public let hasMixedSizes: Bool
    public let hasMixedLocations: Bool
    public let hasMixedCreationDates: Bool
    public let hasMixedModificationDates: Bool
    public let hasMixedReadability: Bool
    public let hasMixedHiddenState: Bool
    public init(entries: [FileEntry]) {
        var seen: Set<ItemID> = []
        let items = entries.filter { seen.insert($0.id).inserted }
        contentsSize = InspectorSizeState.aggregate(items.map { entry in
            InspectorSizeState.metadata(bytes: entry.size,
                isDirectory: entry.kind == .directory || entry.kind == .package)
        })
        itemCount = items.count
        directoryCount = items.filter(\.isDirectoryLike).count
        fileCount = itemCount - directoryCount
        var size: Int64 = 0
        var overflow: Bool = false
        for entry in items where entry.size >= 0 {
            let sum = size.addingReportingOverflow(entry.size)
            if sum.overflow { size = .max; overflow = true } else { size = sum.partialValue }
        }
        totalSize = size; sizeOverflowed = overflow
        hasUnknownSize = items.contains { $0.size < 0 }
        hasMixedKinds = Set(items.map(\.kind)).count > 1
        commonKind = hasMixedKinds ? nil : items.first?.kind
        let descriptions = Set(items.map(\.localizedKindDescription))
        commonKindDescription = descriptions.count == 1 ? items.first?.localizedKindDescription : nil
        hasMixedSizes = Set(items.map(\.size)).count > 1
        hasMixedLocations = Set(items.map { $0.url.deletingLastPathComponent().standardizedFileURL }).count > 1
        hasMixedCreationDates = Set(items.map(\.creationDate)).count > 1
        hasMixedModificationDates = Set(items.map(\.modificationDate)).count > 1
        hasMixedReadability = Set(items.map(\.isReadable)).count > 1
        hasMixedHiddenState = Set(items.map(\.isHidden)).count > 1
    }
}
