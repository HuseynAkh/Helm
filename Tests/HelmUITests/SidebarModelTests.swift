// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmUI

final class SidebarModelTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")

    func testSectionOrderAndEmptySections() {
        let empty = SidebarModel(places: PlacesModel(home: home), committedDestination: .recent)
        XCTAssertEqual(empty.sections.map(\.id), ["recent", "favorites", "trash"])
        XCTAssertEqual(empty.selectedPlaceID, "recent-root")
        let places = PlacesModel(home: home, bookmarks: [home.appendingPathComponent("Unavailable")],
                                 starred: [home.appendingPathComponent("file.txt")],
                                 volumes: [VolumeInfo(url: URL(fileURLWithPath: "/Volumes/USB"), name: "USB")])
        let model = SidebarModel(places: places, committedDestination: .trash)
        XCTAssertEqual(model.sections.map(\.id), ["recent", "favorites", "bookmarks", "starred", "devices", "trash"])
        XCTAssertEqual(model.sections.compactMap(\.title), ["Favorites", "Bookmarks", "Starred", "Devices"])
        XCTAssertEqual(model.selectedPlaceID, "trash")
        XCTAssertEqual(model.place(for: places.bookmarks[0].id)?.url, home.appendingPathComponent("Unavailable"))
        XCTAssertNil(model.place(for: "missing"))
    }

    func testDeepestAncestorUsesPathBoundariesAndIgnoresStarredRows() {
        let documents = home.appendingPathComponent("Documents")
        let project = documents.appendingPathComponent("Project")
        let places = PlacesModel(home: home, bookmarks: [project], starred: [project.appendingPathComponent("Child")])
        let nested = SidebarModel(places: places, committedDestination: .directory(project.appendingPathComponent("Child/file")))
        XCTAssertEqual(nested.selectedPlaceID, places.bookmarks[0].id)
        let sibling = SidebarModel(places: places, committedDestination: .directory(documents.appendingPathComponent("ProjectOther")))
        XCTAssertEqual(sibling.selectedPlaceID, "documents")
        let exact = SidebarModel(places: places, committedDestination: .directory(project))
        XCTAssertEqual(exact.selectedPlaceID, places.bookmarks[0].id)
        let unrelated = SidebarModel(places: places, committedDestination: .directory(URL(fileURLWithPath: "/elsewhere")))
        XCTAssertNil(unrelated.selectedPlaceID)
    }

    func testTrashDescendantAndAbsentVirtualStarredRow() {
        let places = PlacesModel(home: home)
        let trash = SidebarModel(places: places, committedDestination: .directory(home.appendingPathComponent(".Trash/item")))
        XCTAssertEqual(trash.selectedPlaceID, "trash")
        XCTAssertNil(SidebarModel(places: places, committedDestination: .starred).selectedPlaceID)
    }

    func testOnlyBookmarksExposeRemoveIntent() {
        let places = PlacesModel(home: home, bookmarks: [home.appendingPathComponent("Bookmark")])
        for place in places.allPlaces {
            XCTAssertEqual(SidebarModel.contextActions(for: place), place.kind == .bookmark ? [.removeBookmark] : [])
        }
        XCTAssertEqual(SidebarContextAction.removeBookmark.title, "Remove Bookmark")
    }

    func testHighlightOnlyChangesWhenHostSuppliesCommittedDestination() {
        let places = PlacesModel(home: home)
        let before = SidebarModel(places: places, committedDestination: .recent)
        let after = SidebarModel(places: places, committedDestination: .directory(home))
        XCTAssertEqual(before.selectedPlaceID, "recent-root")
        XCTAssertEqual(after.selectedPlaceID, "home")
    }
}
