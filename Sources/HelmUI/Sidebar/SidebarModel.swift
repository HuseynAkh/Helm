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
        let candidate = places.selectedPlaceID(for: committedDestination)
        selectedPlaceID = result.flatMap(\.rows).contains { $0.id == candidate } ? candidate : nil
    }
    public func place(for id: String) -> Place? {
        sections.lazy.flatMap(\.rows).first { $0.id == id }
    }
    public static func contextActions(for place: Place) -> [SidebarContextAction] {
        place.kind == .bookmark ? [.removeBookmark] : []
    }
}
