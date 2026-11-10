// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Pane navigation for F-038/F-041 and P-068; list callers use one column.
public enum ContentMovement: Sendable { case up, down, left, right, home, end, pageUp, pageDown }

/// Stable visible selection for F-038/F-039, P-069/P-080; prevents B-009/B-011/B-101.
/// Supply already sorted, visible IDs (including expanded children); never sorts internally.
public struct SelectionModel: Sendable {
    public private(set) var order: [ItemID]
    public private(set) var selected: Set<ItemID>
    public private(set) var anchor: ItemID?
    public private(set) var focus: ItemID?
    private var indices: [ItemID: Int]

    public init(order: [ItemID] = [], selected: Set<ItemID> = [], anchor: ItemID? = nil, focus: ItemID? = nil) {
        var indices: [ItemID: Int] = [:]
        var unique: [ItemID] = []
        for id in order where indices[id] == nil { indices[id] = unique.count; unique.append(id) }
        self.order = unique; self.indices = indices
        self.selected = selected.intersection(Set(unique))
        self.anchor = anchor.flatMap { indices[$0] == nil ? nil : $0 }
        self.focus = focus.flatMap { indices[$0] == nil ? nil : $0 }
    }

    public init(snapshot: PresentationSnapshot) { self.init(order: snapshot.sortedIDs) }

    public mutating func click(_ id: ItemID, command: Bool = false, shift: Bool = false) {
        guard let end = indices[id] else { return }
        if shift {
            let start: Int = anchor.flatMap { indices[$0] } ?? focus.flatMap { indices[$0] } ?? end
            let range: Set<ItemID> = Set(order[min(start, end)...max(start, end)])
            selected = command ? selected.union(range) : range
            anchor = order[start]
        } else if command {
            if !selected.insert(id).inserted { selected.remove(id) }
            anchor = id
        } else { selected = [id]; anchor = id }
        focus = id
    }

    /// Right click keeps an existing group, selects a new target, or clears the background (P-083).
    public mutating func contextClick(_ id: ItemID?) {
        guard let id else { clear(); return }
        guard indices[id] != nil else { return }
        if !selected.contains(id) { click(id) }
    }

    public mutating func clear() { selected = []; anchor = nil; focus = nil }
    public mutating func selectAll() {
        selected = Set(order); anchor = anchor ?? order.first; focus = focus ?? order.first
    }
    public mutating func invert() {
        selected = Set(order).subtracting(selected)
        focus = order.first(where: { selected.contains($0) }); anchor = focus
    }

    /// Horizontal grid movement never wraps rows. Down clamps to the final cell of a short row.
    /// Page size is supplied in items by the viewport; Home/End move selection as well as focus.
    public mutating func move(_ direction: ContentMovement, columns: Int = 1,
                              pageSize: Int = 1, extending: Bool = false) {
        guard !order.isEmpty else { return }
        let last: Int = order.count - 1
        guard let current = focus.flatMap({ indices[$0] }) else {
            click(order[direction == .end || direction == .pageUp || direction == .up ? last : 0]); return
        }
        let width: Int = min(max(columns, 1), order.count)
        let page: Int = min(max(pageSize, 1), order.count)
        var target: Int = current
        switch direction {
        case .home: target = 0
        case .end: target = last
        case .up: target = current >= width ? current - width : current
        case .down: target = current / width < last / width ? current + min(width, last - current) : current
        case .left: if width > 1 && current % width > 0 { target -= 1 }
        case .right: if width > 1 && current % width < width - 1 { target += min(1, last - current) }
        case .pageUp: target = max(0, current - page)
        case .pageDown: target = current + min(page, last - current)
        }
        click(order[target], shift: extending)
    }

    /// Uses the existing timed prefix policy (F-041/P-067); entries are resolved in visible order.
    @discardableResult
    public mutating func typeSelect(_ text: String, matcher: inout TypeSelect,
                                    snapshot: PresentationSnapshot) -> ItemID? {
        let entries: [FileEntry] = order.compactMap { snapshot.entry($0) }
        guard let index = matcher.select(typing: text, names: entries.map(\.name)) else { return nil }
        let id: ItemID = entries[index].id
        click(id)
        return id
    }

    /// Known operation rename mappings are accepted; external renames must not be guessed (P-080).
    /// A vanished anchor/focus uses the nearest surviving old neighbour, ties favouring the next.
    public mutating func reconcile(order newOrder: [ItemID], renamed: [ItemID: ItemID] = [:]) {
        let oldOrder: [ItemID] = order
        let oldIndices: [ItemID: Int] = indices
        let replacement: SelectionModel = SelectionModel(order: newOrder)
        func mapped(_ id: ItemID) -> ItemID { renamed[id] ?? id }
        func nearest(_ id: ItemID?) -> ItemID? {
            guard let id else { return nil }
            if replacement.indices[mapped(id)] != nil { return mapped(id) }
            guard let position = oldIndices[id] else { return replacement.order.first }
            var best: (distance: Int, index: Int, id: ItemID)?
            for (index, candidate) in oldOrder.enumerated() where replacement.indices[mapped(candidate)] != nil {
                let distance: Int = abs(index - position)
                if best == nil || distance < (best?.distance ?? Int.max) ||
                    (distance == best?.distance && index > (best?.index ?? -1)) {
                    best = (distance, index, mapped(candidate))
                }
            }
            return best?.id ?? (replacement.order.isEmpty ? nil : replacement.order[min(position, replacement.order.count - 1)])
        }
        let newAnchor: ItemID? = nearest(anchor)
        let newFocus: ItemID? = nearest(focus)
        selected = Set(selected.map(mapped)).intersection(Set(replacement.order))
        anchor = newAnchor; focus = newFocus; order = replacement.order; indices = replacement.indices
    }
}

extension SelectionModel {
    /// The item that takes the selection once these leave, such as for the Trash: the next one in `order` (the items
    /// on show, top to bottom), or the previous one at the end. What's inside a leaving folder leaves with it, so it's
    /// passed over too.
    public static func successor(afterRemoving removed: Set<ItemID>, in order: [ItemID]) -> ItemID? {
        guard let last = order.lastIndex(where: removed.contains) else { return nil }
        let paths = Set(removed.map(\.rawValue))
        func leaves(_ id: ItemID) -> Bool {
            var path = Substring(id.rawValue)
            while true {
                if paths.contains(String(path)) { return true }
                guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return false }
                path = path[..<slash]
            }
        }
        if let after = order[(last + 1)...].first(where: { !leaves($0) }) { return after }
        return order[..<last].last(where: { !leaves($0) })
    }
}
