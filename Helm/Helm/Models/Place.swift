import Foundation
import AppKit

struct Place: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let iconName: String
    let kind: PlaceKind

    enum PlaceKind: String, Codable {
        case recentRoot
        case favorite
        case bookmark
        case starred
        case recent
        case device
        case network
        case trash
    }

    var icon: NSImage {
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: name) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func defaultFavorites() -> [Place] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        return [
            Place(
                id: "home",
                name: "Home",
                url: home,
                iconName: "house",
                kind: .favorite
            ),
            Place(
                id: "desktop",
                name: "Desktop",
                url: home.appending(path: "Desktop"),
                iconName: "menubar.dock.rectangle",
                kind: .favorite
            ),
            Place(
                id: "documents",
                name: "Documents",
                url: home.appending(path: "Documents"),
                iconName: "doc",
                kind: .favorite
            ),
            Place(
                id: "downloads",
                name: "Downloads",
                url: home.appending(path: "Downloads"),
                iconName: "arrow.down.circle",
                kind: .favorite
            ),
            Place(
                id: "applications",
                name: "Applications",
                url: URL(fileURLWithPath: "/Applications"),
                iconName: "square.grid.2x2",
                kind: .favorite
            )
        ]
    }

    static func recentsRoot() -> Place {
        Place(
            id: "recent-root",
            name: "Recent",
            url: .helmRecentsURL,
            iconName: "clock.arrow.circlepath",
            kind: .recentRoot
        )
    }

    static func trash() -> Place {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".Trash")
        return Place(
            id: "trash",
            name: "Trash",
            url: trashURL,
            iconName: "trash",
            kind: .trash
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Place, rhs: Place) -> Bool {
        lhs.id == rhs.id
    }
}
