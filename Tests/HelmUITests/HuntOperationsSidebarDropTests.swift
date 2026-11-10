#if os(macOS)
import AppKit
import XCTest
import HelmCore
@testable import HelmUI

/// Records where the sidebar sends a drop.
@MainActor private final class HuntOperationsSidebarDouble: SidebarDelegate {
    var offered: NSDragOperation = .move
    var performed: [String] = []
    var bookmarked: [[URL]] = []
    var moved: [String] = []
    func sidebarActivate(_ place: Place, newTab: Bool) {}
    func sidebarRemoveBookmark(_ place: Place) {}
    func sidebarEject(_ place: Place) {}
    func sidebarInsertBookmarks(_ urls: [URL], before anchor: Place?) { bookmarked.append(urls) }
    func sidebarMove(_ place: Place, before anchor: Place?) { moved.append(place.name) }
    func sidebarHide(_ place: Place) {}
    func sidebarShowSettings() {}
    func sidebarDropOperation(_ info: NSDraggingInfo, onto place: Place) -> NSDragOperation { offered }
    func sidebarPerformDrop(_ info: NSDraggingInfo, onto place: Place) -> Bool { performed.append(place.name); return true }
    func sidebarDragEnded() {}
    func sidebarEmptyTrash() {}
}

/// Rows can now be dragged to new places, which must not change what a file dropped on a row does:
/// on a folder it moves or copies in, on Trash it goes to the Trash, and only between rows is it bookmarked.
@MainActor final class HuntOperationsSidebarDropTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/hunt", isDirectory: true)

    private func sidebar() -> (SidebarController, HuntOperationsSidebarDouble, NSWindow) {
        let controller = SidebarController()
        let delegate = HuntOperationsSidebarDouble()
        controller.delegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.render(SidebarModel(places: PlacesModel(home: home, bookmarks: [home.appendingPathComponent("Projects")]),
                                       committedDestination: .directory(home)))
        window.layoutIfNeeded()
        return (controller, delegate, window)
    }
    private func file() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(home.appendingPathComponent("Desktop/notes.txt").absoluteString, forType: .fileURL)
        return item
    }
    private func row(_ controller: SidebarController, _ name: String) -> Int? {
        controller.currentModel?.sections.lazy.flatMap(\.rows).first { $0.name == name }.flatMap { controller.listIndexForTesting(of: $0.id) }
    }

    func testAFileDroppedOnAFolderRowGoesIntoTheFolder() throws {
        let (controller, delegate, window) = sidebar()
        defer { window.orderOut(nil) }
        for (name, lowerHalf) in [("Documents", false), ("Documents", true), ("Projects", false), ("Trash", true)] {
            let index = try XCTUnwrap(row(controller, name), "no row \(name)")
            let result = controller.scriptedDropForTesting(file(), overRow: index, lowerHalf: lowerHalf)
            XCTAssertEqual(result.offered, .move, "\(name)")
            XCTAssertTrue(result.taken, "\(name)")
            XCTAssertEqual(delegate.performed.last, name, "a file let go over \(name) goes into it")
        }
        XCTAssertTrue(delegate.bookmarked.isEmpty, "nothing was bookmarked")
        XCTAssertTrue(delegate.moved.isEmpty, "no row moved")
    }

    func testARowThatTakesNothingBookmarksInstead() throws {
        let (controller, delegate, window) = sidebar()
        defer { window.orderOut(nil) }
        delegate.offered = []
        let index = try XCTUnwrap(row(controller, "Recent"))
        let result = controller.scriptedDropForTesting(file(), overRow: index, lowerHalf: true)
        XCTAssertEqual(result.offered, .link)
        XCTAssertTrue(delegate.performed.isEmpty)
        XCTAssertEqual(delegate.bookmarked.count, 1)
    }
}
#endif
