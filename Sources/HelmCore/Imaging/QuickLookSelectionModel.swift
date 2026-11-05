// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-049 panel commands are values; adapters retain panel ownership and source-frame lookup.
public enum QuickLookEffect: Equatable, Sendable {
    case show(items: [ItemID], index: Int)
    case reload(items: [ItemID], index: Int)
    case select(index: Int)
    case close
}

/// F-049 preview follows display-ordered selection, including expanded children (B-060).
public struct QuickLookSelectionModel: Equatable, Sendable {
    public private(set) var items: [ItemID] = []
    public private(set) var currentIndex: Int? = nil
    public private(set) var isOpen: Bool = false
    public init() {}

    public mutating func selectionChanged(_ selectionInDisplayOrder: [ItemID]) -> [QuickLookEffect] {
        var seen: Set<ItemID> = []
        let selection = selectionInDisplayOrder.filter { seen.insert($0).inserted }
        guard selection != items else { return [] }
        let previous = currentIndex.flatMap { items.indices.contains($0) ? items[$0] : nil }
        items = selection
        currentIndex = previous.flatMap { items.firstIndex(of: $0) } ?? (items.isEmpty ? nil : 0)
        guard isOpen else { return [] }
        guard let currentIndex else { isOpen = false; return [.close] }
        return [.reload(items: items, index: currentIndex)]
    }
    public mutating func space(paneIsFirstResponder: Bool = true, hasModifiers: Bool = false) -> [QuickLookEffect] {
        guard paneIsFirstResponder, !hasModifiers else { return [] }
        if isOpen { return close() }
        guard let currentIndex else { return [] }
        isOpen = true
        return [.show(items: items, index: currentIndex)]
    }
    /// Arrows clamp at selection bounds; platform pane navigation can feed selectionChanged instead.
    public mutating func move(forward: Bool) -> [QuickLookEffect] {
        guard isOpen, let index = currentIndex else { return [] }
        let next = forward ? min(items.count - 1, index + 1) : max(0, index - 1)
        guard next != index else { return [] }
        currentIndex = next
        return [.select(index: next)]
    }
    public mutating func close() -> [QuickLookEffect] {
        guard isOpen else { return [] }
        isOpen = false
        return [.close]
    }
}
