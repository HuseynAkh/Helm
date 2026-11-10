// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Portable widget feedback guard preserves visible stable-ID selection (F-038/F-039, B-009/B-011).
@MainActor public final class StoreSelectionBinder {
    public private(set) var isApplying: Bool = false
    public private(set) var selection: Set<ItemID> = []
    private var snapshot: PresentationSnapshot?
    private var expanded: Set<ItemID> = []
    public init() {}

    /// Widget reload and selection application belong inside the guarded closure.
    public func apply(_ tab: TabState, to widget: (PresentationSnapshot, Set<ItemID>) -> Void) {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        snapshot = tab.snapshot; expanded = tab.expandedIDs
        selection = valid(tab.selection)
        widget(tab.snapshot, selection)
    }

    /// Returns nil for delegate feedback during reload. Grid command paths call this explicitly.
    public func userSelection(_ ids: Set<ItemID>) -> Set<ItemID>? {
        guard !isApplying, snapshot != nil else { return nil }
        selection = valid(ids); return selection
    }

    private func valid(_ ids: Set<ItemID>) -> Set<ItemID> {
        guard let snapshot = snapshot else { return [] }
        if snapshot.children.isEmpty {
            return Set(ids.filter { snapshot.index(of: $0).map { $0 < snapshot.rootCount } ?? false })
        }
        return ids.intersection(Set(snapshot.visibleIDs(expanding: expanded)))
    }
}
