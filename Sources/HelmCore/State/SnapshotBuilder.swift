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
        for parent in children.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let sorted: [FileEntry] = sort.sorted(children[parent] ?? [], rankByID: rankByID ?? [:])
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
}
