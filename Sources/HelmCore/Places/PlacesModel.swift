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
    public init(home: URL, bookmarks: [URL] = [], starred: [URL] = [],
                volumes: [VolumeInfo] = [], showAllVolumes: Bool = false) {
        self.home = home.standardizedFileURL
        self.favorites = Place.defaultFavorites(home: home)
        self.recentsRoot = Place(id: "recent-root", name: "Recent", destination: .recent, iconName: "clock.arrow.circlepath", kind: .recentRoot)
        self.starredRoot = Place(id: "starred-root", name: "Starred", destination: .starred, iconName: "star.fill", kind: .starred)
        self.trash = Place(id: "trash", name: "Trash", destination: .trash, iconName: "trash", kind: .trash)
        self.bookmarks = Self.places(bookmarks, kind: .bookmark, home: home)
        self.starred = Self.places(starred, kind: .starred, home: home)
        self.devices = VolumeFilter.filtered(volumes, showAll: showAllVolumes).map {
            Place(id: "volume-\($0.url.path)", name: $0.name, destination: .directory($0.url),
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
    public func selectedPlaceID(for destination: PlaceDestination) -> String? {
        switch destination {
        case .recent: return recentsRoot.id
        case .starred: return starredRoot.id
        case .trash: return trash.id
        case .directory(let url):
            guard url.isFileURL else { return nil }
            let path = url.standardizedFileURL.path
            let trashFolder = home.appendingPathComponent(".Trash")
            let candidates: [(Place, String)] = (favorites + bookmarks + devices).compactMap {
                guard let url = $0.url else { return nil }; return ($0, url.standardizedFileURL.path)
            } + [(trash, trashFolder.path)] + starred.compactMap {
                guard let url = $0.url else { return nil }; return ($0, url.standardizedFileURL.path)
            }
            if let exact = candidates.first(where: { $0.1 == path }) { return exact.0.id }
            return candidates.filter { path.hasPrefix($0.1.hasSuffix("/") ? $0.1 : $0.1 + "/") }
                .max { $0.1.count < $1.1.count }?.0.id
        }
    }
    private static func places(_ urls: [URL], kind: Place.PlaceKind, home: URL) -> [Place] {
        let unique = Set(urls.filter(\.isFileURL).map(\.standardizedFileURL))
        return unique.map { url in
            Place(id: "\(kind.rawValue)-\(url.path)",
                  name: url.path == home.standardizedFileURL.path ? "Home" : (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent),
                  destination: .directory(url), iconName: kind == .bookmark ? "bookmark.fill" : "star.fill", kind: kind)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
