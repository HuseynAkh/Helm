// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import HelmCore

/// B-009/B-014: accepted snapshot identity is distinct from the request generation.
/// The tab reducer supplies its per-tab counter; this helper neither allocates IDs nor accepts loads.
public struct SnapshotStamp: Hashable, Sendable {
    public let id: Generation
    public let loadGeneration: Generation

    public init(id: Generation, loadGeneration: Generation) {
        self.id = id
        self.loadGeneration = loadGeneration
    }

    /// Wraps an already-sorted loader result without losing its request identity (B-009/B-014).
    /// The reducer rejects stale generations and allocates its own accepted presentation ID.
    public func loadAction(location: Location, sortedEntries: [FileEntry], sort: ItemSort = .defaultSort,
                           finished: Bool = true) -> TabAction {
        let snapshot = PresentationSnapshot(id: id, location: location,
            phase: finished ? .ready : .loading(loadedCount: sortedEntries.count),
            sort: sort, sortedEntries: sortedEntries)
        return finished ? .loadFinished(loadGeneration, snapshot) : .loadProgress(loadGeneration, snapshot)
    }
}
