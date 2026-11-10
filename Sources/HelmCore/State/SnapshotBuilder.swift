// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Build once off the UI actor; datasource reads never sort (F-040, B-010/B-101).
public enum SnapshotBuilder {
    public static func build(location: Location, entries: [FileEntry], sort: ItemSort = .defaultSort,
                             phase: SnapshotPhase = .ready, rankByID: [ItemID: Int]? = nil,
                             children: [ItemID: [FileEntry]] = [:]) -> PresentationSnapshot {
        let roots: [FileEntry] = sort.sorted(entries, rankByID: rankByID ?? [:])
        var all: [FileEntry] = roots
        var topology: [ItemID: TreeChildren] = [:]
        // Each item has one row. Recent can list a folder and something inside it, so a folder opened there leaves
        // out what's already listed at the top rather than show it twice.
        let listed: Set<ItemID> = children.isEmpty ? [] : Set(roots.map(\.id))
        for parent in children.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let sorted: [FileEntry] = sort.sorted((children[parent] ?? []).filter { !listed.contains($0.id) }, rankByID: rankByID ?? [:])
            topology[parent] = TreeChildren(sortedIDs: sorted.map(\.id))
            all.append(contentsOf: sorted)
        }
        return PresentationSnapshot(location: location, phase: phase, sort: sort, sortedEntries: all,
                                    rootCount: roots.count, children: topology, rankByID: rankByID)
    }
    public static func resort(_ snapshot: PresentationSnapshot, sort: ItemSort) -> PresentationSnapshot {
        let ranks: [ItemID: Int] = snapshot.rankByID ?? [:]
        let roots: [FileEntry] = sort.sorted(Array(snapshot.sortedEntries.prefix(snapshot.rootCount)), rankByID: ranks)
        var entries: [FileEntry] = roots
        var topology: [ItemID: TreeChildren] = [:]
        for parent in snapshot.children.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let child = snapshot.children[parent] else { continue }
            let sorted: [FileEntry] = sort.sorted(child.sortedIDs.compactMap { snapshot.entry($0) }, rankByID: ranks)
            entries.append(contentsOf: sorted)
            topology[parent] = TreeChildren(phase: child.phase, sortedIDs: sorted.map(\.id))
        }
        return PresentationSnapshot(location: snapshot.location, phase: snapshot.phase, sort: sort,
                                    sortedEntries: entries, rootCount: roots.count, children: topology,
                                    rankByID: snapshot.rankByID, freeCapacityBytes: snapshot.freeCapacityBytes,
                                    selectionSource: snapshot.selectionSource)
    }
}
/// Selection restoration resolves identities in O(k); widgets apply these IDs after reload (B-011).
public enum SnapshotDiff {
    public static func selection(_ ids: Set<ItemID>, in snapshot: PresentationSnapshot) -> Set<ItemID> {
        Set(ids.filter { snapshot.index(of: $0) != nil })
    }
    public static func anchor(_ id: ItemID?, in snapshot: PresentationSnapshot) -> ItemID? {
        id.flatMap { snapshot.index(of: $0) == nil ? nil : $0 }
    }
    /// The rows that leave and arrive when one folder's listing becomes another, so a list can move only those.
    /// Nil when rows that stay have changed order (a re-sort, say), which the caller shows by reloading that folder.
    public static func childChange(from old: [ItemID], to new: [ItemID]) -> ChildChange? {
        let oldSet = Set(old), newSet = Set(new)
        // A listing with the same item twice can't be told apart row by row.
        guard oldSet.count == old.count, newSet.count == new.count,
              old.filter(newSet.contains) == new.filter(oldSet.contains) else { return nil }
        var removed = IndexSet(), inserted = IndexSet()
        for (index, id) in old.enumerated() where !newSet.contains(id) { removed.insert(index) }
        for (index, id) in new.enumerated() where !oldSet.contains(id) { inserted.insert(index) }
        return ChildChange(removed: removed, inserted: inserted)
    }
}
/// Rows to take out (indexes in the old listing), then rows to put in (indexes in the new one),
/// in the order an outline view applies them inside one batch of updates.
public struct ChildChange: Equatable, Sendable {
    public let removed: IndexSet
    public let inserted: IndexSet
    public init(removed: IndexSet, inserted: IndexSet) { self.removed = removed; self.inserted = inserted }
    public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty }
}
