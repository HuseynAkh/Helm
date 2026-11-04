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
}
