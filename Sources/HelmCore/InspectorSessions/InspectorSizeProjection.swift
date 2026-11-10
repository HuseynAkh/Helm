// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-050/B-066 raw directory/package metadata is never a computed contents total.
/// Computed values must already be admitted by session identity; unknown IDs are ignored.
public struct InspectorSizeProjection: Equatable, Sendable {
    public let rawMetadata: InspectorSizeState
    public let contents: InspectorSizeState
    public init(entries: [FileEntry], computed: [ItemID: InspectorSizeState] = [:]) {
        var seen: Set<ItemID> = []
        let unique = entries.filter { seen.insert($0.id).inserted }
        rawMetadata = InspectorSizeState.aggregate(unique.map {
            InspectorSizeState.metadata(bytes: $0.size, isDirectory: false)
        })
        contents = InspectorSizeState.aggregate(unique.map { entry in
            computed[entry.id] ?? InspectorSizeState.metadata(bytes: entry.size,
                isDirectory: entry.kind == .directory || entry.kind == .package)
        })
    }
}
