// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmUI

final class SidebarModelTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")

    func testSectionOrderAndEmptySections() {
        let empty = SidebarModel(places: PlacesModel(home: home), committedDestination: .recent)
        XCTAssertEqual(empty.sections.map(\.id), ["favorites"])
        XCTAssertEqual(empty.sections[0].rows.first?.id, "recent-root")
        XCTAssertEqual(empty.sections[0].rows.last?.id, "trash")
        XCTAssertEqual(empty.selectedPlaceID, "recent-root")
        let places = PlacesModel(home: home, bookmarks: [home.appendingPathComponent("Unavailable")],
                                 starred: [home.appendingPathComponent("file.txt")],
                                 volumes: [VolumeInfo(url: URL(fileURLWithPath: "/Volumes/USB"), name: "USB")])
        let model = SidebarModel(places: places, committedDestination: .trash)
        XCTAssertEqual(model.sections.map(\.id), ["favorites", "bookmarks", "starred", "locations"])
        XCTAssertEqual(model.sections.compactMap(\.title), ["Favorites", "Bookmarks", "Starred", "Locations"])
        XCTAssertEqual(model.selectedPlaceID, "trash")
        XCTAssertEqual(model.place(for: places.bookmarks[0].id)?.url, home.appendingPathComponent("Unavailable"))
        XCTAssertNil(model.place(for: "missing"))
    }

    func testRowsPutALineBetweenGroups() {
        let places = PlacesModel(home: home, bookmarks: [home.appendingPathComponent("B")],
                                 volumes: [VolumeInfo(url: URL(fileURLWithPath: "/Volumes/USB"), name: "USB")])
        let rows = SidebarModel(places: places, committedDestination: .recent).rows
        let drawn = rows.map { row -> String in
            if case .place(let place) = row { return place.name }
            return "|"
        }
        XCTAssertEqual(drawn, ["Recent", "Home", "Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Applications",
                               "Trash", "|", "B", "|", "USB"])
    }

    func testHiddenRowsAreLeftOutAndTheHighlightFindsTheNextOneOnShow() {
        let layout = SidebarLayout(hidden: ["documents", "trash"])
        let places = PlacesModel(home: home, layout: layout)
        let model = SidebarModel(places: places, committedDestination: .directory(home.appendingPathComponent("Documents/Work")))
        XCTAssertNil(model.place(for: "documents"))
        XCTAssertNil(model.place(for: "trash"))
        XCTAssertEqual(model.selectedPlaceID, "home")
        XCTAssertNil(SidebarModel(places: places, committedDestination: .trash).selectedPlaceID)
        // Hiding every favorite leaves nothing to draw, rather than an empty group.
        let none = SidebarLayout(hidden: places.natural(.favorites).map(\.id))
        XCTAssertTrue(SidebarModel(places: PlacesModel(home: home, layout: none), committedDestination: .recent).rows.isEmpty)
    }

    func testDeepestAncestorUsesCorePolicyIncludingStarredRows() {
        let documents = home.appendingPathComponent("Documents")
        let project = documents.appendingPathComponent("Project")
        let places = PlacesModel(home: home, bookmarks: [project], starred: [project.appendingPathComponent("Child")])
        let nested = SidebarModel(places: places, committedDestination: .directory(project.appendingPathComponent("Child/file")))
        XCTAssertEqual(nested.selectedPlaceID, places.starred[0].id)
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

    func testBookmarksAreRemovedAndEverythingElseHidden() {
        let places = PlacesModel(home: home, bookmarks: [home.appendingPathComponent("Bookmark")],
                                 starred: [home.appendingPathComponent("file.txt")],
                                 volumes: [VolumeInfo(url: URL(fileURLWithPath: "/Volumes/USB"), name: "USB")])
        for place in places.allPlaces {
            XCTAssertEqual(SidebarModel.contextActions(for: place), place.kind == .bookmark ? [.removeBookmark] : [.hide])
        }
        XCTAssertEqual(SidebarContextAction.removeBookmark.title, "Remove Bookmark")
        XCTAssertEqual(SidebarContextAction.hide.title, "Hide from Sidebar")
    }

    func testHighlightOnlyChangesWhenHostSuppliesCommittedDestination() {
        let places = PlacesModel(home: home)
        let before = SidebarModel(places: places, committedDestination: .recent)
        let after = SidebarModel(places: places, committedDestination: .directory(home))
        XCTAssertEqual(before.selectedPlaceID, "recent-root")
        XCTAssertEqual(after.selectedPlaceID, "home")
    }

    // MARK: Drops: rows only move within their own group

    /// Rows: 0 Recent … 9 Trash, 10 line, 11 A, 12 B, 13 line, 14 Alpha, 15 Beta.
    private var full: SidebarModel {
        let places = PlacesModel(home: home, bookmarks: [home.appendingPathComponent("A"), home.appendingPathComponent("B")],
                                 volumes: [VolumeInfo(url: URL(fileURLWithPath: "/Volumes/Beta"), name: "Beta", isCloud: true),
                                           VolumeInfo(url: URL(fileURLWithPath: "/Volumes/Alpha"), name: "Alpha", isRemovable: true)])
        return SidebarModel(places: places, committedDestination: .recent)
    }

    func testADraggedRowsLineStaysInItsGroup() {
        let model = full
        let a = "bookmark-" + home.appendingPathComponent("A").path, b = "bookmark-" + home.appendingPathComponent("B").path
        // Within the group the line goes where it's put.
        XCTAssertEqual(model.reorderTarget(moving: "home", proposedIndex: 0)?.index, 0)
        XCTAssertEqual(model.reorderTarget(moving: "home", proposedIndex: 0)?.before, "recent-root")
        XCTAssertEqual(model.reorderTarget(moving: "home", proposedIndex: 4)?.before, "downloads")
        // Over the bookmarks, or below everything, it stays at the end of Favorites.
        XCTAssertEqual(model.reorderTarget(moving: "home", proposedIndex: 12)?.index, 10)
        XCTAssertNil(model.reorderTarget(moving: "home", proposedIndex: 12)?.before)
        XCTAssertEqual(model.reorderTarget(moving: "home", proposedIndex: -1)?.index, 10)
        // A drive dragged to the top stays at the top of the drives.
        XCTAssertEqual(model.reorderTarget(moving: "volume-/Volumes/Beta", proposedIndex: 0)?.index, 14)
        XCTAssertEqual(model.reorderTarget(moving: "volume-/Volumes/Beta", proposedIndex: 0)?.before, "volume-/Volumes/Alpha")
        // Bookmarks move among the bookmarks.
        XCTAssertEqual(model.reorderTarget(moving: b, proposedIndex: 11)?.before, a)
        XCTAssertEqual(model.reorderTarget(moving: a, proposedIndex: 13)?.index, 13)
        XCTAssertNil(model.reorderTarget(moving: a, proposedIndex: 13)?.before)
        // A row that isn't on show can't be dropped.
        XCTAssertNil(model.reorderTarget(moving: "missing", proposedIndex: 0))
    }

    func testFoldersDroppedBetweenRowsAreBookmarkedAmongTheBookmarks() {
        let model = full
        XCTAssertEqual(model.bookmarkTarget(proposedIndex: 3).index, 11)
        XCTAssertEqual(model.bookmarkTarget(proposedIndex: 12).before, "bookmark-" + home.appendingPathComponent("B").path)
        XCTAssertEqual(model.bookmarkTarget(proposedIndex: 15).index, 13)
        XCTAssertNil(model.bookmarkTarget(proposedIndex: -1).before)
        // With no bookmarks on show, the line sits right under Favorites, where the new bookmark appears.
        let places = PlacesModel(home: home, volumes: [VolumeInfo(url: URL(fileURLWithPath: "/Volumes/USB"), name: "USB")])
        let bare = SidebarModel(places: places, committedDestination: .recent)
        XCTAssertEqual(bare.bookmarkTarget(proposedIndex: 12).index, 10)
        XCTAssertNil(bare.bookmarkTarget(proposedIndex: 12).before)
        let empty = SidebarModel(places: PlacesModel(home: home, layout: SidebarLayout(hidden: places.natural(.favorites).map(\.id))),
                                 committedDestination: .recent)
        XCTAssertEqual(empty.bookmarkTarget(proposedIndex: 3).index, 0)
    }

    func testDraggingOverARowTakesItsPlace() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(SidebarMove.onto("c", moving: "a", in: ids), SidebarMove(id: "a", anchor: "d"))
        XCTAssertEqual(SidebarMove.onto("d", moving: "a", in: ids), SidebarMove(id: "a", anchor: nil))
        XCTAssertEqual(SidebarMove.onto("a", moving: "c", in: ids), SidebarMove(id: "c", anchor: "a"))
        XCTAssertNil(SidebarMove.onto("a", moving: "a", in: ids))
        XCTAssertNil(SidebarMove.onto("x", moving: "a", in: ids))
        XCTAssertEqual(SidebarMove.step("b", by: -1, in: ids), SidebarMove(id: "b", anchor: "a"))
        XCTAssertEqual(SidebarMove.step("b", by: 1, in: ids), SidebarMove(id: "b", anchor: "d"))
        XCTAssertEqual(SidebarMove.step("c", by: 1, in: ids), SidebarMove(id: "c", anchor: nil))
        XCTAssertNil(SidebarMove.step("a", by: -1, in: ids))
        XCTAssertNil(SidebarMove.step("d", by: 1, in: ids))
    }

    // MARK: Hidden rows keep their places

    /// A row let go of where it already was changes nothing, even with a hidden row beside it.
    func testADropThatLeavesTheRowWhereItWasChangesNothing() {
        let ids = ["recent", "home", "desktop", "documents", "downloads"]
        let shown: Set = ["recent", "home", "documents", "downloads"]
        // Home on its own upper half, its own lower half, and just above Documents, past the hidden Desktop.
        XCTAssertNil(SidebarMove.dropped("home", before: "home", in: ids, listed: shown))
        XCTAssertNil(SidebarMove.dropped("home", before: "documents", in: ids, listed: shown))
        // The last row let go of at the end of its group, with a hidden row after it.
        XCTAssertNil(SidebarMove.dropped("icloud", before: nil, in: ["icloud", "google"], listed: ["icloud"]))
        // Rows that aren't on show, and anchors that aren't, move nothing.
        XCTAssertNil(SidebarMove.dropped("desktop", before: "recent", in: ids, listed: shown))
        XCTAssertNil(SidebarMove.dropped("home", before: "desktop", in: ids, listed: shown))
    }

    /// A row passes over as few hidden rows as it can, so they stay beside the rows they were next to.
    func testAMovedRowPassesOverAsFewHiddenRowsAsItCan() {
        let ids = ["a", "h1", "b", "h2", "c"]
        let shown: Set = ["a", "b", "c"]
        func order(_ move: SidebarMove?) -> [String] { move?.applied(to: ids) ?? ids }
        // Down: just after the row the line is below, so h2 stays before c.
        XCTAssertEqual(order(SidebarMove.dropped("a", before: "c", in: ids, listed: shown)), ["h1", "b", "a", "h2", "c"])
        XCTAssertEqual(order(SidebarMove.dropped("a", before: nil, in: ids, listed: shown)), ["h1", "b", "h2", "c", "a"])
        // Up: just before the row the line is above, so h1 stays after a.
        XCTAssertEqual(order(SidebarMove.dropped("c", before: "b", in: ids, listed: shown)), ["a", "h1", "c", "b", "h2"])
        XCTAssertEqual(order(SidebarMove.dropped("c", before: "a", in: ids, listed: shown)), ["c", "a", "h1", "b", "h2"])
        // Where everything is listed, as in Settings, rows go exactly where they're put.
        XCTAssertEqual(order(SidebarMove.dropped("a", before: "h2", in: ids, listed: Set(ids))), ["h1", "b", "a", "h2", "c"])
        XCTAssertNil(SidebarMove.dropped("a", before: "h1", in: ids, listed: Set(ids)))
        // A drive that isn't connected keeps its place right after the drive it followed.
        let drives = ["a", "b", "away"]
        let toEnd = SidebarMove.dropped("a", before: nil, in: drives, listed: ["a", "b"])
        XCTAssertEqual(toEnd, SidebarMove(id: "a", anchor: "away"))
        XCTAssertEqual(toEnd?.applied(to: drives), ["b", "a", "away"])
    }

    /// While a row is dragged in Settings it takes the place of the row under the pointer, and the rest close up.
    func testADraggedRowTakesThePlaceUnderThePointer() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(SidebarMove.placing("a", at: 2, in: ids), SidebarMove(id: "a", anchor: "d"))
        XCTAssertEqual(SidebarMove.placing("a", at: 2, in: ids)?.applied(to: ids), ["b", "c", "a", "d"])
        XCTAssertEqual(SidebarMove.placing("d", at: 0, in: ids)?.applied(to: ids), ["d", "a", "b", "c"])
        XCTAssertEqual(SidebarMove.placing("b", at: 9, in: ids), SidebarMove(id: "b", anchor: nil))
        XCTAssertEqual(SidebarMove.placing("b", at: -3, in: ids), SidebarMove(id: "b", anchor: "a"))
        XCTAssertNil(SidebarMove.placing("c", at: 2, in: ids))
        XCTAssertNil(SidebarMove.placing("x", at: 0, in: ids))
        // A move for a row that isn't in the list leaves the list alone.
        XCTAssertEqual(SidebarMove(id: "x", anchor: "a").applied(to: ids), ids)
    }

    // MARK: Letting go of a row dragged out of the sidebar

    func testOnlyARowLetGoOfOutsideWithNothingTakingItComesOut() {
        XCTAssertEqual(SidebarDragEnd(accepted: false, insideSidebar: false, cancelled: false), .takeOut)
        // Cancelled with Escape over the files: the row stays.
        XCTAssertEqual(SidebarDragEnd(accepted: false, insideSidebar: false, cancelled: true), .keep)
        // Taken by another window's sidebar, or let go of back in this one.
        XCTAssertEqual(SidebarDragEnd(accepted: true, insideSidebar: false, cancelled: false), .keep)
        XCTAssertEqual(SidebarDragEnd(accepted: false, insideSidebar: true, cancelled: false), .keep)
        XCTAssertEqual(SidebarDragEnd(accepted: true, insideSidebar: true, cancelled: true), .keep)
        // The image slides back over the sidebar, but not over the files, where letting go takes the row out.
        XCTAssertTrue(SidebarDragEnd.slidesBack(insideSidebar: true))
        XCTAssertFalse(SidebarDragEnd.slidesBack(insideSidebar: false))
    }
}
