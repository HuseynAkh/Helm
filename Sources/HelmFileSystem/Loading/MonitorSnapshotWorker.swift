// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Serial, off-main snapshot indexing preserves F-035/F-040 without repeating sorting (B-010).
/// The awaiting reload owns cancellation; there is no detached task or independent worker lifetime.
actor MonitorSnapshotWorker {
    private let beforeBuild: @Sendable () -> Void
    init(beforeBuild: @escaping @Sendable () -> Void = {}) { self.beforeBuild = beforeBuild }

    func build(location: Location, sortedEntries: [FileEntry], sort: ItemSort) throws -> PresentationSnapshot {
        try Task.checkCancellation()
        beforeBuild()
        try Task.checkCancellation()
        // DirectoryLoader.snapshot already applied the requested order. The initializer
        // derives indexes and deduplicates identities without sorting a second time.
        let snapshot = PresentationSnapshot(location: location, sort: sort, sortedEntries: sortedEntries)
        try Task.checkCancellation()
        return snapshot
    }
}
