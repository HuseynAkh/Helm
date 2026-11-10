// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// What a row's menu offers for the row itself: a bookmark is removed, anything else is hidden (F-028, P-197).
public enum SidebarContextAction: String, CaseIterable, Sendable {
    case removeBookmark, hide
    public var title: String {
        switch self {
        case .removeBookmark: return "Remove Bookmark"
        case .hide: return "Hide from Sidebar"
        }
    }
}

/// A stable, ordered section of places preserves F-026–F-031.
public struct SidebarSection: Identifiable, Sendable {
    public let id: String
    public let title: String?
    public let rows: [Place]
    public init(id: String, title: String?, rows: [Place]) {
        self.id = id; self.title = title; self.rows = rows
    }
}

/// Pure projection of shared Places; highlight follows committed navigation (F-027, B-029).
/// Starred file activation must be resolved by the caller, not treated as folder navigation.
public struct SidebarModel: Sendable {
    /// One line of the sidebar: a place, or the thin line between two groups.
    public enum Row: Equatable, Sendable { case place(Place), line }
    /// The groups with something on show, in their fixed order: Favorites, Bookmarks, Starred, Locations.
    public let sections: [SidebarSection]
    public let rows: [Row]
    public let selectedPlaceID: String?
    public init(places: PlacesModel, committedDestination: PlaceDestination) {
        sections = SidebarGroup.allCases.compactMap { group in
            let rows = places.shown(group)
            return rows.isEmpty ? nil : SidebarSection(id: group.rawValue, title: group.title, rows: rows)
        }
        var rows: [Row] = []
        for section in sections {
            if !rows.isEmpty { rows.append(.line) }
            rows += section.rows.map(Row.place)
        }
        self.rows = rows
        let candidate = places.selectedPlaceID(for: committedDestination)
        selectedPlaceID = sections.contains { $0.rows.contains { $0.id == candidate } } ? candidate : nil
    }
    public func place(for id: String) -> Place? {
        sections.lazy.flatMap(\.rows).first { $0.id == id }
    }
    public static func contextActions(for place: Place) -> [SidebarContextAction] {
        place.kind == .bookmark ? [.removeBookmark] : [.hide]
    }

    // MARK: Drops, counted in rows with the lines between groups included

    /// Where a row dragged within the sidebar lands: the insertion line stays inside the row's own group,
    /// however far the pointer goes. A negative index means the end of the group. Gives the row index for the
    /// line and the row it goes before, nil at the group's end. Nil when the dragged row isn't on show.
    public func reorderTarget(moving id: String, proposedIndex: Int) -> (index: Int, before: String?)? {
        guard let place = place(for: id), let span = span(of: place.group) else { return nil }
        return target(in: span, proposedIndex: proposedIndex)
    }

    /// Where folders dropped between rows are bookmarked: among the bookmarks, or right under Favorites
    /// when there are none on show, which is where the new bookmark appears.
    public func bookmarkTarget(proposedIndex: Int) -> (index: Int, before: String?) {
        if let span = span(of: .bookmarks) { return target(in: span, proposedIndex: proposedIndex) }
        return (span(of: .favorites).map { $0.upperBound + 1 } ?? 0, nil)
    }

    private func target(in span: ClosedRange<Int>, proposedIndex: Int) -> (index: Int, before: String?) {
        let index = proposedIndex < 0 ? span.upperBound + 1 : min(max(proposedIndex, span.lowerBound), span.upperBound + 1)
        guard index <= span.upperBound, case .place(let place) = rows[index] else { return (index, nil) }
        return (index, place.id)
    }

    /// The rows a group covers, if any of them are on show.
    private func span(of group: SidebarGroup) -> ClosedRange<Int>? {
        let indices = rows.indices.filter { if case .place(let place) = rows[$0] { return place.group == group }; return false }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }
}

/// A move within one group, as Settings › Sidebar makes them: the row goes just before `anchor`,
/// or to the end of the group when `anchor` is nil.
public struct SidebarMove: Equatable, Sendable {
    public let id: String
    public let anchor: String?
    public init(id: String, anchor: String?) { self.id = id; self.anchor = anchor }

    /// Dragging `id` over `target`: the dragged row takes the target's place, so it goes after a row below
    /// it and before a row above it. `ids` is the group's rows in order. Nil when nothing would move.
    public static func onto(_ target: String, moving id: String, in ids: [String]) -> SidebarMove? {
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else { return nil }
        if from < to { return SidebarMove(id: id, anchor: to + 1 < ids.count ? ids[to + 1] : nil) }
        return SidebarMove(id: id, anchor: ids[to])
    }

    /// One step up (negative) or down (positive), as Move Up and Move Down do. Nil at either end.
    public static func step(_ id: String, by delta: Int, in ids: [String]) -> SidebarMove? {
        guard let from = ids.firstIndex(of: id), delta != 0, ids.indices.contains(from + delta) else { return nil }
        return onto(ids[from + delta], moving: id, in: ids)
    }

    /// The dragged row put at position `index` in its group, the row under the pointer: it takes that place and the
    /// others close up around it, so it stays under the pointer as they make room. Nil when it's already there.
    public static func placing(_ id: String, at index: Int, in ids: [String]) -> SidebarMove? {
        guard let from = ids.firstIndex(of: id) else { return nil }
        let others = ids.filter { $0 != id }
        let to = min(max(index, 0), others.count)
        guard to != from else { return nil }
        return SidebarMove(id: id, anchor: to < others.count ? others[to] : nil)
    }

    /// The group's rows with this move made, as the pane shows them while a row is dragged.
    public func applied(to ids: [String]) -> [String] {
        guard ids.contains(id), anchor != id else { return ids }
        var next = ids.filter { $0 != id }
        next.insert(id, at: anchor.flatMap { next.firstIndex(of: $0) } ?? next.count)
        return next
    }

    /// A row let go of with the line just above `anchor`, or at the end of its group when `anchor` is nil, among the
    /// rows in `listed`: the rows on show in the sidebar, or every row in Settings. `ids` is the group's whole order,
    /// including rows that weren't listed there, such as hidden rows and drives that aren't connected. The row moves
    /// past as few of those as it can, so they keep their places beside the rows they were next to, and a row let
    /// go of where it already was changes nothing. Gives the row to go just before in `ids`, or nil when nothing moves.
    public static func dropped(_ id: String, before anchor: String?, in ids: [String], listed: Set<String>) -> SidebarMove? {
        let rows = ids.filter(listed.contains)
        guard let from = rows.firstIndex(of: id) else { return nil }
        let to: Int
        if let anchor {
            guard let index = rows.firstIndex(of: anchor) else { return nil }
            to = index
        } else {
            to = rows.count
        }
        // The line just above the row or just below it leaves the row where it is.
        guard to != from, to != from + 1 else { return nil }
        // Up: just before the row the line is above. Rows out of sight that were before that row stay before it.
        if to < from { return SidebarMove(id: id, anchor: rows[to]) }
        // Down: just after the row the line is below. Rows out of sight that were after that row stay after it.
        let others = ids.filter { $0 != id }
        guard let after = others.firstIndex(of: rows[to - 1]) else { return nil }
        return SidebarMove(id: id, anchor: after + 1 < others.count ? others[after + 1] : nil)
    }
}

/// What letting go of a row dragged out of the sidebar does (P-188, P-306).
public enum SidebarDragEnd: Equatable, Sendable {
    /// Nothing happens to the row: something took the drop, such as another window's sidebar, it was let go of
    /// back in the sidebar, or the drag was cancelled with Escape.
    case keep
    /// Taken out of the sidebar with the poof: a bookmark is removed, any other row is hidden, as in Finder.
    case takeOut

    public init(accepted: Bool, insideSidebar: Bool, cancelled: Bool) {
        self = accepted || insideSidebar || cancelled ? .keep : .takeOut
    }

    /// Whether the dragged image slides back to its row when the drag ends without a drop at this point. Outside the
    /// sidebar it doesn't, since letting go there takes the row out with the poof.
    public static func slidesBack(insideSidebar: Bool) -> Bool { insideSidebar }
}
