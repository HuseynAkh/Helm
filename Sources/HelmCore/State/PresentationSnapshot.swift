// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Portable listing failures preserve the attempted location without corrupting history (B-069).
public enum LoadError: Error, Hashable, Sendable {
    case notFound, permissionDenied, volumeUnmounted, notIndexed, cancelled, timedOut, other(String)
}
/// Loading and failure presentation is separate from accepted navigation (F-008, B-069).
public enum SnapshotPhase: Hashable, Sendable {
    case loading(loadedCount: Int), ready, failed(LoadError, attempted: Location)
}
/// The sole expanded-folder topology, with stable identities (F-037, B-032).
public struct TreeChildren: Hashable, Sendable {
    public let phase: SnapshotPhase
    public let sortedIDs: [ItemID]
    public init(phase: SnapshotPhase = .ready, sortedIDs: [ItemID]) {
        self.phase = phase; self.sortedIDs = sortedIDs
    }
}
/// Immutable display order and constant-time identity lookup retire B-009/B-010/B-101.
/// IDs are per-tab presentation counters, independent of asynchronous request generations.
public struct PresentationSnapshot: Sendable, Equatable {
    public let id: Generation
    public var revision: UInt64 { id.rawValue }
    public let location: Location
    public let phase: SnapshotPhase
    public let sort: ItemSort
    public let sortedEntries: [FileEntry]
    public let rootCount: Int
    public let indexByID: [ItemID: Int]
    public let children: [ItemID: TreeChildren]
    public let rankByID: [ItemID: Int]?
    public let freeCapacityBytes: Int64?
    public let selectionSource: SelectionSource
    public var sortedIDs: [ItemID] { sortedEntries.map(\.id) }

    /// Input order is already sorted by the producer. Duplicate IDs retain their first entry.
    /// The index is derived here, never trusted from an external datasource.
    public init(id: Generation = Generation(), location: Location, phase: SnapshotPhase = .ready,
                sort: ItemSort = .defaultSort, sortedEntries: [FileEntry] = [], rootCount: Int? = nil,
                children: [ItemID: TreeChildren] = [:], rankByID: [ItemID: Int]? = nil,
                freeCapacityBytes: Int64? = nil, selectionSource: SelectionSource = .widget) {
        var entries: [FileEntry] = []
        var index: [ItemID: Int] = [:]
        var roots: Int = 0
        let prefixCount: Int = min(max(rootCount ?? sortedEntries.count, 0), sortedEntries.count)
        for (offset, entry) in sortedEntries.enumerated() where index[entry.id] == nil {
            index[entry.id] = entries.count; entries.append(entry)
            if offset < prefixCount { roots += 1 }
        }
        self.id = id; self.location = location; self.phase = phase; self.sort = sort
        self.sortedEntries = entries; self.rootCount = roots; self.indexByID = index
        self.children = children; self.rankByID = rankByID
        self.freeCapacityBytes = freeCapacityBytes; self.selectionSource = selectionSource
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func entry(_ id: ItemID) -> FileEntry? { indexByID[id].map { sortedEntries[$0] } }
    public func index(of id: ItemID) -> Int? { indexByID[id] }

    /// Iterative traversal tolerates malformed cycles and deep folder trees without recursion.
    public func visibleIDs(expanding expanded: Set<ItemID>) -> [ItemID] {
        var pending: [ItemID] = Array(sortedEntries.prefix(rootCount).map(\.id).reversed())
        var visited: Set<ItemID> = []
        var result: [ItemID] = []
        while let id = pending.popLast() {
            guard indexByID[id] != nil, visited.insert(id).inserted else { continue }
            result.append(id)
            if expanded.contains(id), let child = children[id] {
                pending.append(contentsOf: child.sortedIDs.reversed())
            }
        }
        return result
    }

    /// Metadata-only stamp uses copy-on-write storage; no sorting or index rebuild at publication.
    func stamped(_ id: Generation, phase: SnapshotPhase? = nil,
                 source: SelectionSource? = nil) -> Self {
        Self(id: id, original: self, phase: phase ?? self.phase, source: source ?? selectionSource)
    }
    private init(id: Generation, original: Self, phase: SnapshotPhase, source: SelectionSource) {
        self.id = id; self.location = original.location; self.phase = phase; self.sort = original.sort
        self.sortedEntries = original.sortedEntries; self.rootCount = original.rootCount
        self.indexByID = original.indexByID; self.children = original.children
        self.rankByID = original.rankByID; self.freeCapacityBytes = original.freeCapacityBytes
        self.selectionSource = source
    }
}
