// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Menu intents preserve the bookmark-only context action (F-028).
public enum SidebarContextAction: String, CaseIterable, Sendable {
    case removeBookmark
    public var title: String { "Remove Bookmark" }
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
    public let sections: [SidebarSection]
    public let selectedPlaceID: String?
    public init(places: PlacesModel, committedDestination: PlaceDestination) {
        var result: [SidebarSection] = [
            SidebarSection(id: "recent", title: nil, rows: [places.recentsRoot]),
            SidebarSection(id: "favorites", title: "Favorites", rows: places.favorites)
        ]
        if !places.bookmarks.isEmpty {
            result.append(SidebarSection(id: "bookmarks", title: "Bookmarks", rows: places.bookmarks))
        }
        if !places.starred.isEmpty {
            result.append(SidebarSection(id: "starred", title: "Starred", rows: places.starred))
        }
        if !places.devices.isEmpty {
            result.append(SidebarSection(id: "devices", title: "Devices", rows: places.devices))
        }
        result.append(SidebarSection(id: "trash", title: nil, rows: [places.trash]))
        sections = result
        var candidate = places.selectedPlaceID(for: committedDestination)
        // Core includes starred destinations; this leaf preserves F-027's bookmark/
        // favorite highlight policy until a shared policy is agreed by integration.
        if places.starred.contains(where: { $0.id == candidate }),
           case .directory(let url) = committedDestination {
            let path = url.standardizedFileURL.path
            let eligible = (places.favorites + places.bookmarks + places.devices).compactMap { place -> (String, String)? in
                guard let url = place.url else { return nil }
                return (place.id, url.standardizedFileURL.path)
            } + [(places.trash.id, places.home.appendingPathComponent(".Trash").path)]
            candidate = eligible.first { $0.1 == path }?.0 ?? eligible.filter {
                path.hasPrefix($0.1.hasSuffix("/") ? $0.1 : $0.1 + "/")
            }.max { $0.1.count < $1.1.count }?.0
        }
        selectedPlaceID = result.flatMap(\.rows).contains { $0.id == candidate } ? candidate : nil
    }
    public func place(for id: String) -> Place? {
        sections.lazy.flatMap(\.rows).first { $0.id == id }
    }
    public static func contextActions(for place: Place) -> [SidebarContextAction] {
        place.kind == .bookmark ? [.removeBookmark] : []
    }
}
