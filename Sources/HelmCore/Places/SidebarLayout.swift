import Foundation

/// The sidebar's groups, always drawn in this order with a thin line between them and no headings (P-187).
/// A row moves only within its own group.
public enum SidebarGroup: String, CaseIterable, Codable, Sendable {
    case favorites, bookmarks, starred, locations
    /// What Settings › Sidebar calls each group. Drives and cloud folders are Finder's "Locations".
    public var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .bookmarks: return "Bookmarks"
        case .starred: return "Starred"
        case .locations: return "Locations"
        }
    }
}

public extension Place {
    /// The group this row belongs to and moves within: Recent, the standard folders and Trash are Favorites.
    var group: SidebarGroup {
        switch kind {
        case .recentRoot, .recent, .favorite, .trash: return .favorites
        case .bookmark: return .bookmarks
        case .starred: return .starred
        case .device, .network: return .locations
        }
    }
    /// A user row's stable ID: "bookmark-" or "starred-" and the path, or "volume-" and the path for a drive.
    /// Built in one place, so the layout's saved IDs always match the rows they name.
    static func id(_ kind: PlaceKind, path: String) -> String {
        kind == .device ? "volume-\(path)" : "\(kind.rawValue)-\(path)"
    }
}

/// How you've arranged the sidebar: rows you've hidden, and the order of Favorites, Starred and Locations,
/// by Place ID. Bookmarks keep their own order in bookmarks.json, so they have none here (P-188, P-306).
///
/// IDs of rows that aren't there right now, such as an unplugged drive, are kept, so the drive comes back
/// to its old place. A starred item or bookmark that goes is forgotten instead, so no path you've let go of stays.
/// A row that's new to a group lands right after the row it follows naturally.
public struct SidebarLayout: Codable, Equatable, Sendable {
    /// The most IDs any one list keeps, so drives that never come back can't grow the file for ever.
    public static let limit = 400
    /// Hidden rows, sorted.
    public private(set) var hidden: [String]
    public private(set) var favorites: [String]
    public private(set) var starred: [String]
    public private(set) var locations: [String]

    public init(hidden: [String] = [], favorites: [String] = [], starred: [String] = [], locations: [String] = []) {
        self.hidden = Self.cleaned(hidden).sorted()
        self.favorites = Self.cleaned(favorites)
        self.starred = Self.cleaned(starred)
        self.locations = Self.cleaned(locations)
    }

    /// A damaged or older file still loads: missing lists are empty, and repeated or empty IDs are dropped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func list(_ key: CodingKeys) throws -> [String] { try container.decodeIfPresent([String].self, forKey: key) ?? [] }
        self.init(hidden: try list(.hidden), favorites: try list(.favorites), starred: try list(.starred), locations: try list(.locations))
    }

    /// Nothing hidden and every group in its natural order.
    public var isDefault: Bool { self == SidebarLayout() }

    public func isHidden(_ id: String) -> Bool { hidden.contains(id) }

    /// A group's saved order, which may name rows that aren't there now. Empty means the natural order.
    public func order(of group: SidebarGroup) -> [String] {
        switch group {
        case .favorites: return favorites
        case .bookmarks: return []
        case .starred: return starred
        case .locations: return locations
        }
    }

    /// A group's rows in your order, hidden ones included. Bookmarks are already in theirs.
    public func arranged(_ natural: [Place], in group: SidebarGroup) -> [Place] {
        guard group != .bookmarks, !order(of: group).isEmpty else { return natural }
        let byID = Dictionary(natural.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Self.merged(saved: order(of: group), natural: natural.map(\.id)).compactMap { byID[$0] }
    }

    /// A group's rows as the sidebar shows them: in your order, without the hidden ones.
    public func shown(_ natural: [Place], in group: SidebarGroup) -> [Place] {
        arranged(natural, in: group).filter { !isHidden($0.id) }
    }

    /// The same layout once items have moved or been renamed: a hidden bookmark or starred item stays hidden, and a
    /// starred item keeps its place, under the ID its new path gives it.
    public func relocated(_ moves: PathMoves) -> SidebarLayout {
        func follow(_ id: String) -> String {
            for kind in [Place.PlaceKind.bookmark, .starred] {
                let prefix = Place.id(kind, path: "")
                // Path IDs only: "starred-root" is the Starred heading's own row.
                guard id.hasPrefix(prefix + "/") else { continue }
                return moves.relocated(String(id.dropFirst(prefix.count))).map { Place.id(kind, path: $0) } ?? id
            }
            return id
        }
        return SidebarLayout(hidden: hidden.map(follow), favorites: favorites, starred: starred.map(follow), locations: locations)
    }

    /// Drops these rows from every list: where you'd put them and whether you'd hidden them. A starred item or bookmark
    /// that goes is forgotten this way, so starring or bookmarking it again shows a new row in its natural place.
    public mutating func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        hidden.removeAll(where: ids.contains)
        favorites.removeAll(where: ids.contains)
        starred.removeAll(where: ids.contains)
        locations.removeAll(where: ids.contains)
    }

    /// The rows of starred items and bookmarks it names, hidden or in an order. Drives and the standard rows aren't
    /// among them, and nor is the Starred heading's own row.
    public var starAndBookmarkIDs: Set<String> {
        let prefixes = [Place.PlaceKind.bookmark, .starred].map { Place.id($0, path: "/") }
        return Set((hidden + favorites + starred + locations).filter { id in prefixes.contains { id.hasPrefix($0) } })
    }

    public mutating func setHidden(_ id: String, _ isHidden: Bool) {
        guard !id.isEmpty else { return }
        if isHidden {
            guard !hidden.contains(id) else { return }
            hidden.append(id); hidden.sort()
        } else {
            hidden.removeAll { $0 == id }
        }
    }

    /// Moves a row to just before `anchor`, or to the end of its group when `anchor` is nil.
    /// Positions count hidden rows too, so a hidden row can't throw a move off. `natural` is the group's
    /// rows as they are now, in their natural order. Bookmarks are moved in their own store instead.
    public mutating func move(_ id: String, before anchor: String?, in group: SidebarGroup, natural: [String]) {
        guard group != .bookmarks, id != anchor, natural.contains(id) else { return }
        let current = Self.merged(saved: order(of: group), natural: natural)
        var next = current
        next.removeAll { $0 == id }
        if let anchor {
            // An anchor from another group, or one that's gone, isn't a place to move to.
            guard let index = next.firstIndex(of: anchor) else { return }
            next.insert(id, at: index)
        } else {
            next.append(id)
        }
        guard next != current else { return }
        setOrder(next == natural ? [] : Self.capped(next, keeping: Set(natural)), of: group)
    }

    /// Your saved order with any new rows slotted in: each new row goes right after the row it naturally
    /// follows, or first if it naturally comes first. Saved IDs that aren't present now keep their place.
    public static func merged(saved: [String], natural: [String]) -> [String] {
        var result = cleaned(saved)
        var placed = Set(result)
        for (index, id) in natural.enumerated() where !placed.contains(id) {
            if index > 0, let after = result.firstIndex(of: natural[index - 1]) {
                result.insert(id, at: after + 1)
            } else {
                result.insert(id, at: 0)
            }
            placed.insert(id)
        }
        return result
    }

    private mutating func setOrder(_ order: [String], of group: SidebarGroup) {
        switch group {
        case .favorites: favorites = order
        case .bookmarks: break
        case .starred: starred = order
        case .locations: locations = order
        }
    }

    /// Unique, non-empty IDs in their first order, at most `limit` of them.
    private static func cleaned(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return Array(ids.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(limit))
    }

    /// Keeps every row that's there now. When the list is too long, rows that aren't there are dropped first.
    private static func capped(_ ids: [String], keeping present: Set<String>) -> [String] {
        var spare = limit - ids.filter(present.contains).count
        return ids.filter { id in
            if present.contains(id) { return true }
            spare -= 1
            return spare >= 0
        }
    }
}
