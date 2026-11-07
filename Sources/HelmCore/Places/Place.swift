// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Sidebar destinations distinguish Helm-owned collections from writable folders (F-027–F-030).
public enum PlaceDestination: Hashable, Sendable, Codable {
    case directory(URL), recent, starred, trash
    /// Lossless routing seam until Location can represent the Starred collection.
    public var resolved: ResolvedPlace {
        switch self {
        case .directory(let url): return .directory(url)
        case .recent: return .recentCollection
        case .starred: return .starredCollection
        case .trash: return .trashCollection
        }
    }

    /// Compatibility projection; use resolved when routing virtual collections.
    public var location: Location? {
        switch self {
        case .directory(let url): return .directory(url)
        case .recent: return .recent
        case .trash: return .trash
        case .starred: return nil // K1 Location has no Starred case yet.
        }
    }
}

/// Stable sidebar identity and presentation without AppKit (F-027).
public struct Place: Identifiable, Hashable, Sendable, Codable {
    public enum PlaceKind: String, Sendable, Codable {
        case recentRoot, favorite, bookmark, starred, recent, device, network, trash
    }
    public let id: String
    public let name: String
    public let destination: PlaceDestination
    public let iconName: String
    public let kind: PlaceKind
    public init(id: String, name: String, destination: PlaceDestination, iconName: String, kind: PlaceKind) {
        self.id = id; self.name = name; self.destination = destination; self.iconName = iconName; self.kind = kind
    }
    public var url: URL? {
        if case .directory(let url) = destination { return url }; return nil
    }
    public static func == (lhs: Place, rhs: Place) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func defaultFavorites(home: URL) -> [Place] {
        let rows: [(String, String, URL, String)] = [
            ("home", "Home", home, "house"),
            ("desktop", "Desktop", home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            ("documents", "Documents", home.appendingPathComponent("Documents"), "doc"),
            ("downloads", "Downloads", home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            ("pictures", "Pictures", home.appendingPathComponent("Pictures"), "photo"),
            ("music", "Music", home.appendingPathComponent("Music"), "music.note"),
            ("movies", "Movies", home.appendingPathComponent("Movies"), "film"),
            ("applications", "Applications", URL(fileURLWithPath: "/Applications"), "square.grid.2x2")
        ]
        return rows.map { Place(id: $0.0, name: $0.1, destination: .directory($0.2), iconName: $0.3, kind: .favorite) }
    }
}
