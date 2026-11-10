// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Pure sidebar sections, drops and deepest-ancestor highlighting (F-027–F-031, B-029).
public struct PlacesModel: Sendable {
    public let home: URL
    public let favorites: [Place]
    public private(set) var bookmarks: [Place]
    public let starred: [Place]
    public let devices: [Place]
    public let recentsRoot: Place
    public let starredRoot: Place
    public let trash: Place
    /// Your order and hidden rows. The catalogs above stay complete; `shown(_:)` applies it.
    public let layout: SidebarLayout
    public init(home: URL, bookmarks: [URL] = [], starred: [URL] = [],
                volumes: [VolumeInfo] = [], showAllVolumes: Bool = false, layout: SidebarLayout = SidebarLayout()) {
        self.home = home.standardizedFileURL
        self.layout = layout
        self.favorites = Place.defaultFavorites(home: home)
        self.recentsRoot = Place(id: "recent-root", name: "Recent", destination: .recent, iconName: "clock.arrow.circlepath", kind: .recentRoot)
        self.starredRoot = Place(id: "starred-root", name: "Starred", destination: .starred, iconName: "star.fill", kind: .starred)
        self.trash = Place(id: "trash", name: "Trash", destination: .trash, iconName: "trash", kind: .trash)
        self.bookmarks = Self.places(bookmarks, kind: .bookmark, home: home)
        self.starred = Self.places(starred, kind: .starred, home: home)
        self.devices = VolumeFilter.filtered(volumes, showAll: showAllVolumes).map {
            Place(id: Place.id(.device, path: $0.url.path), name: $0.name, destination: .directory($0.url),
                  iconName: $0.isCloud ? "cloud" : ($0.isRemovable ? "externaldrive" : "internaldrive"), kind: .device)
        }
    }
    public var allPlaces: [Place] {
        var result: [Place] = [recentsRoot]
        result.append(contentsOf: favorites)
        result.append(contentsOf: bookmarks)
        result.append(starredRoot)
        result.append(contentsOf: starred)
        result.append(contentsOf: devices)
        result.append(trash)
        return result
    }
    public func place(for id: String) -> Place? { allPlaces.first { $0.id == id } }
    /// Provider acceptance is separate from directory validation: a file drop is accepted but adds nothing.
    @discardableResult public mutating func handleBookmarkDrop(_ urls: [URL], isDirectory: (URL) -> Bool) -> Bool {
        let files = urls.filter(\.isFileURL)
        let additions = files.map(\.standardizedFileURL).filter(isDirectory)
        bookmarks = Self.places(bookmarks.compactMap(\.url) + additions, kind: .bookmark, home: home)
        return !files.isEmpty
    }
    public mutating func removeBookmark(id: String) { bookmarks.removeAll { $0.id == id } }
    /// A group's rows in their natural order, before your layout: Favorites runs from Recent to Trash.
    public func natural(_ group: SidebarGroup) -> [Place] {
        switch group {
        case .favorites: return [recentsRoot] + favorites + [trash]
        case .bookmarks: return bookmarks
        case .starred: return starred
        case .locations: return devices
        }
    }
    /// A group's rows in your order, hidden ones included, as Settings › Sidebar lists them.
    public func arranged(_ group: SidebarGroup) -> [Place] { layout.arranged(natural(group), in: group) }
    /// A group's rows as the sidebar shows them.
    public func shown(_ group: SidebarGroup) -> [Place] { layout.shown(natural(group), in: group) }
    /// A group's whole order as the layout keeps it: every row here, plus drives that aren't connected right now,
    /// which keep their places for when they're back. Bookmarks are in their own order and are always all here.
    public func fullOrder(_ group: SidebarGroup) -> [String] {
        SidebarLayout.merged(saved: layout.order(of: group), natural: natural(group).map(\.id))
    }
    /// Whether Restore Defaults would change anything: a row here is hidden or out of its natural order, or a drive
    /// that isn't connected has a place or is hidden, which applies again when it's back. A starred item or bookmark
    /// that's gone doesn't count, so hiding a starred item and then unstarring it leaves nothing to restore.
    public var isCustomized: Bool {
        let present = Set(SidebarGroup.allCases.flatMap { natural($0) }.map(\.id))
        if layout.hidden.contains(where: present.contains) { return true }
        if SidebarGroup.allCases.contains(where: { arranged($0).map(\.id) != natural($0).map(\.id) }) { return true }
        let drive = Place.id(.device, path: "")
        return (layout.locations + layout.hidden.filter { $0.hasPrefix(drive) }).contains { !present.contains($0) }
    }
    /// Only rows on show can be highlighted, so inside a hidden Documents the highlight falls to Home.
    public func selectedPlaceID(for destination: PlaceDestination) -> String? {
        let visible = Set(SidebarGroup.allCases.flatMap { shown($0) }.map(\.id))
        switch destination {
        case .recent: return visible.contains(recentsRoot.id) ? recentsRoot.id : nil
        case .starred: return starredRoot.id
        case .trash: return visible.contains(trash.id) ? trash.id : nil
        case .directory(let url):
            guard url.isFileURL else { return nil }
            let path = url.standardizedFileURL.path
            let trashFolder = home.appendingPathComponent(".Trash")
            let all: [(Place, String)] = (favorites + bookmarks + devices).compactMap {
                guard let url = $0.url else { return nil }; return ($0, url.standardizedFileURL.path)
            } + [(trash, trashFolder.path)] + starred.compactMap {
                guard let url = $0.url else { return nil }; return ($0, url.standardizedFileURL.path)
            }
            let candidates = all.filter { visible.contains($0.0.id) }
            if let exact = candidates.first(where: { $0.1 == path }) { return exact.0.id }
            return candidates.filter { path.hasPrefix($0.1.hasSuffix("/") ? $0.1 : $0.1 + "/") }
                .max { $0.1.count < $1.1.count }?.0.id
        }
    }
    private static func places(_ urls: [URL], kind: Place.PlaceKind, home: URL) -> [Place] {
        var seen = Set<URL>()
        let unique = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        let places = unique.map { url in
            Place(id: Place.id(kind, path: url.path),
                  name: url.path == home.standardizedFileURL.path ? "Home" : (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent),
                  destination: .directory(url), iconName: kind == .bookmark ? "bookmark.fill" : "star.fill", kind: kind)
        }
        // Bookmarks stay in the order you put them (P-188). Starred items are listed by name.
        if kind == .bookmark { return places }
        return places.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
