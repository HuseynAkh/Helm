import Foundation
import XCTest
import HelmCore

/// Sidebar order and hidden rows (P-188, P-189, P-306): rows move within their group, any row can be hidden,
/// and the highlight only lands on rows on show.
final class SidebarLayoutTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")
    private let favorites = ["recent-root", "home", "desktop", "documents", "downloads", "pictures", "music", "movies", "applications", "trash"]

    private func model(_ layout: SidebarLayout = SidebarLayout(), bookmarks: [URL] = [], starred: [URL] = [],
                       volumes: [VolumeInfo] = []) -> PlacesModel {
        PlacesModel(home: home, bookmarks: bookmarks, starred: starred, volumes: volumes, layout: layout)
    }
    private func ids(_ places: [Place]) -> [String] { places.map(\.id) }
    private func moved(_ id: String, before anchor: String?, from layout: SidebarLayout = SidebarLayout()) -> SidebarLayout {
        var next = layout
        next.move(id, before: anchor, in: .favorites, natural: favorites)
        return next
    }

    func testFavoritesRunFromRecentToTrashInEveryGroupOrder() {
        let places = model()
        XCTAssertEqual(ids(places.natural(.favorites)), favorites)
        XCTAssertEqual(ids(places.shown(.favorites)), favorites)
        XCTAssertEqual(SidebarGroup.allCases.map(\.title), ["Favorites", "Bookmarks", "Starred", "Locations"])
        XCTAssertTrue(SidebarLayout().isDefault)
    }

    func testHidingKeepsTheRowsPlaceAndShowingPutsItBack() {
        var layout = SidebarLayout()
        layout.setHidden("music", true)
        layout.setHidden("music", true)
        XCTAssertEqual(layout.hidden, ["music"])
        XCTAssertFalse(ids(model(layout).shown(.favorites)).contains("music"))
        XCTAssertEqual(ids(model(layout).arranged(.favorites))[6], "music")
        layout.setHidden("music", false)
        XCTAssertEqual(ids(model(layout).shown(.favorites)), favorites)
        XCTAssertTrue(layout.isDefault)
        // Recent and Trash can go too.
        layout.setHidden("trash", true); layout.setHidden("recent-root", true)
        XCTAssertEqual(ids(model(layout).shown(.favorites)), Array(favorites.dropFirst().dropLast()))
        XCTAssertEqual(layout.hidden, ["recent-root", "trash"])
    }

    func testMovesGoBeforeTheAnchorOrToTheEnd() {
        let first = moved("downloads", before: "recent-root")
        XCTAssertEqual(ids(model(first).shown(.favorites)).prefix(2), ["downloads", "recent-root"])
        let last = moved("recent-root", before: nil, from: first)
        XCTAssertEqual(ids(model(last).shown(.favorites)).first, "downloads")
        XCTAssertEqual(ids(model(last).shown(.favorites)).last, "recent-root")
        XCTAssertFalse(last.isDefault)
        // Moving everything back to where it started forgets the order altogether.
        let back = moved("downloads", before: "pictures", from: moved("recent-root", before: "downloads", from: last))
        XCTAssertEqual(back.favorites, [])
        XCTAssertTrue(back.isDefault)
    }

    func testMovesThatChangeNothingAreIgnored() {
        XCTAssertEqual(moved("home", before: "home"), SidebarLayout())
        XCTAssertEqual(moved("home", before: "desktop"), SidebarLayout())
        XCTAssertEqual(moved("trash", before: nil), SidebarLayout())
        // An anchor from another group, a row that isn't there, and bookmarks, which keep their own order.
        XCTAssertEqual(moved("home", before: "bookmark-/elsewhere"), SidebarLayout())
        XCTAssertEqual(moved("volume-/Volumes/USB", before: "home"), SidebarLayout())
        var layout = SidebarLayout()
        layout.move("bookmark-/a", before: nil, in: .bookmarks, natural: ["bookmark-/a", "bookmark-/b"])
        XCTAssertEqual(layout, SidebarLayout())
    }

    func testMovesCountHiddenRows() {
        var layout = SidebarLayout()
        layout.setHidden("desktop", true)
        // Shown: Recent, Home, Documents… Dropping Recent between Home and Documents lands it there.
        layout.move("recent-root", before: "documents", in: .favorites, natural: favorites)
        XCTAssertEqual(ids(model(layout).shown(.favorites)).prefix(3), ["home", "recent-root", "documents"])
        XCTAssertEqual(ids(model(layout).arranged(.favorites)).prefix(4), ["home", "desktop", "recent-root", "documents"])
    }

    func testAnUnpluggedDriveComesBackToItsPlace() {
        let drives = ["A", "B", "C"].map { VolumeInfo(url: URL(fileURLWithPath: "/Volumes/\($0)"), name: $0, isRemovable: true) }
        var layout = SidebarLayout()
        layout.move("volume-/Volumes/C", before: "volume-/Volumes/A", in: .locations, natural: ids(model(volumes: drives).natural(.locations)))
        XCTAssertEqual(model(layout, volumes: drives).shown(.locations).map(\.name), ["C", "A", "B"])
        XCTAssertEqual(model(layout, volumes: [drives[0], drives[2]]).shown(.locations).map(\.name), ["C", "A"])
        XCTAssertEqual(model(layout, volumes: drives).shown(.locations).map(\.name), ["C", "A", "B"])
        // A drive seen for the first time follows the drive it comes after by name.
        let d = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/D"), name: "D", isRemovable: true)
        XCTAssertEqual(model(layout, volumes: drives + [d]).shown(.locations).map(\.name), ["C", "D", "A", "B"])
    }

    func testNewRowsSlotInAfterTheirNaturalNeighbour() {
        XCTAssertEqual(SidebarLayout.merged(saved: ["C", "A", "B"], natural: ["A", "B", "C", "D"]), ["C", "D", "A", "B"])
        XCTAssertEqual(SidebarLayout.merged(saved: ["C", "A", "B"], natural: ["X", "A", "B", "C"]), ["X", "C", "A", "B"])
        XCTAssertEqual(SidebarLayout.merged(saved: ["B", "A"], natural: ["A", "N1", "N2", "B"]), ["B", "A", "N1", "N2"])
        XCTAssertEqual(SidebarLayout.merged(saved: [], natural: ["A", "B"]), ["A", "B"])
        XCTAssertEqual(SidebarLayout.merged(saved: ["gone", "A"], natural: ["A"]), ["gone", "A"])
    }

    func testBookmarksKeepTheirStoreOrderButCanBeHidden() {
        let a = URL(fileURLWithPath: "/work/a"), b = URL(fileURLWithPath: "/work/b")
        var layout = SidebarLayout()
        layout.setHidden("bookmark-/work/a", true)
        let places = model(layout, bookmarks: [b, a])
        XCTAssertEqual(ids(places.arranged(.bookmarks)), ["bookmark-/work/b", "bookmark-/work/a"])
        XCTAssertEqual(ids(places.shown(.bookmarks)), ["bookmark-/work/b"])
        XCTAssertEqual(layout.order(of: .bookmarks), [])
    }

    func testStarredItemsCanBeReorderedAndHidden() {
        let starred = ["/s/a", "/s/b", "/s/c"].map { URL(fileURLWithPath: $0) }
        var layout = SidebarLayout()
        layout.move("starred-/s/c", before: "starred-/s/a", in: .starred, natural: ids(model(starred: starred).natural(.starred)))
        layout.setHidden("starred-/s/b", true)
        XCTAssertEqual(model(layout, starred: starred).shown(.starred).map(\.name), ["c", "a"])
    }

    func testDecodingIsLosslessAndForgiving() throws {
        var layout = moved("trash", before: "recent-root")
        layout.setHidden("music", true)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(SidebarLayout.self, from: data), layout)
        XCTAssertEqual(try JSONDecoder().decode(SidebarLayout.self, from: Data("{}".utf8)), SidebarLayout())
        let messy = Data(#"{"hidden":["b","a","b",""],"favorites":["home","home","trash"],"unknown":1}"#.utf8)
        let decoded = try JSONDecoder().decode(SidebarLayout.self, from: messy)
        XCTAssertEqual(decoded.hidden, ["a", "b"])
        XCTAssertEqual(decoded.favorites, ["home", "trash"])
        XCTAssertEqual(decoded.starred, [])
        // IDs nothing has any more are harmless when the layout is applied.
        XCTAssertEqual(ids(model(SidebarLayout(hidden: ["nothing"], favorites: ["nothing"])).shown(.favorites)), favorites)
    }

    /// Restore Defaults is on only when it would change something you can see, or a drive that's away.
    func testCustomizedOnlyWhenRestoringWouldChangeSomething() {
        let starred = [URL(fileURLWithPath: "/s/a"), URL(fileURLWithPath: "/s/b")]
        let usb = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/USB"), name: "USB", isRemovable: true)
        XCTAssertFalse(model(starred: starred, volumes: [usb]).isCustomized)
        XCTAssertTrue(model(SidebarLayout(hidden: ["music"])).isCustomized)
        XCTAssertTrue(model(moved("trash", before: "recent-root")).isCustomized)
        // A starred item hidden and then unstarred, or a bookmark hidden and then removed, leaves nothing to restore.
        let hiddenStar = SidebarLayout(hidden: ["starred-/s/a", "bookmark-/gone"])
        XCTAssertTrue(model(hiddenStar, starred: starred).isCustomized)
        XCTAssertFalse(model(hiddenStar, starred: [starred[1]]).isCustomized)
        // Nor does an order that's natural once the unstarred item has gone.
        let order = SidebarLayout(starred: ["starred-/s/b", "starred-/s/a", "starred-/s/c"])
        XCTAssertTrue(model(order, starred: starred).isCustomized)
        XCTAssertFalse(model(order, starred: [starred[0], URL(fileURLWithPath: "/s/c")]).isCustomized)
        // A drive that's away keeps its place and its hidden state for when it's back, which Restore Defaults clears.
        XCTAssertTrue(model(SidebarLayout(hidden: ["volume-/Volumes/USB"])).isCustomized)
        XCTAssertTrue(model(SidebarLayout(locations: ["volume-/Volumes/Away", "volume-/Volumes/USB"]), volumes: [usb]).isCustomized)
        // IDs nothing knows, as from a newer Helm, don't count.
        XCTAssertFalse(model(SidebarLayout(hidden: ["nothing"], favorites: ["nothing"])).isCustomized)
    }

    /// A starred item or bookmark that goes is forgotten: its place and its hidden state. Starred again, it's a new row
    /// after the row it follows by name, and on show. A drive that's away, and every other row, keeps its own.
    func testForgettingAStarOrBookmarkLeavesNothingOfItsRow() {
        let starred = ["/s/a", "/s/b", "/s/c"].map { URL(fileURLWithPath: $0) }
        var layout = SidebarLayout(hidden: ["starred-/s/c", "bookmark-/b", "volume-/Volumes/Away", "music", "starred-root"],
                                   starred: ["starred-/s/c", "starred-/s/b", "starred-/s/a"],
                                   locations: ["volume-/Volumes/Away", "volume-/Volumes/USB"])
        XCTAssertEqual(layout.starAndBookmarkIDs, ["starred-/s/a", "starred-/s/b", "starred-/s/c", "bookmark-/b"])
        // Before, c came back where it was, and hidden.
        XCTAssertEqual(model(layout, starred: starred).shown(.starred).map(\.name), ["b", "a"])
        layout.forget(["starred-/s/c", "bookmark-/b"])
        XCTAssertEqual(layout.hidden, ["music", "starred-root", "volume-/Volumes/Away"])
        XCTAssertEqual(layout.starred, ["starred-/s/b", "starred-/s/a"])
        XCTAssertEqual(layout.locations, ["volume-/Volumes/Away", "volume-/Volumes/USB"])
        XCTAssertEqual(model(layout, starred: starred).shown(.starred).map(\.name), ["b", "c", "a"])
        XCTAssertEqual(model(layout, bookmarks: [URL(fileURLWithPath: "/b")]).shown(.bookmarks).map(\.name), ["b"])
        // Forgetting what isn't there changes nothing.
        let before = layout
        layout.forget(["starred-/s/x"]); layout.forget([])
        XCTAssertEqual(layout, before)
        XCTAssertEqual(SidebarLayout(hidden: ["music"], favorites: ["trash", "home"]).starAndBookmarkIDs, [])
    }

    func testTheFullOrderKeepsDrivesThatAreAway() {
        let a = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/A"), name: "A", isRemovable: true)
        let layout = SidebarLayout(locations: ["volume-/Volumes/Away", "volume-/Volumes/A"])
        XCTAssertEqual(model(layout, volumes: [a]).fullOrder(.locations), ["volume-/Volumes/Away", "volume-/Volumes/A"])
        XCTAssertEqual(model(volumes: [a]).fullOrder(.locations), ["volume-/Volumes/A"])
        XCTAssertEqual(model().fullOrder(.favorites), favorites)
        let b = URL(fileURLWithPath: "/b")
        XCTAssertEqual(model(SidebarLayout(hidden: ["bookmark-/b"]), bookmarks: [b]).fullOrder(.bookmarks), ["bookmark-/b"])
    }

    func testLongListsDropRowsThatArentThereFirst() {
        let absent = (0..<(SidebarLayout.limit + 50)).map { "volume-/Volumes/gone\($0)" }
        let present = ["volume-/Volumes/A", "volume-/Volumes/B"]
        var layout = SidebarLayout(locations: Array(absent.prefix(SidebarLayout.limit - 2)) + present)
        layout.move("volume-/Volumes/B", before: "volume-/Volumes/A", in: .locations, natural: present + absent.suffix(50))
        XCTAssertLessThanOrEqual(layout.locations.count, SidebarLayout.limit)
        XCTAssertTrue(present.allSatisfy(layout.locations.contains))
        XCTAssertEqual(layout.locations.filter(present.contains), ["volume-/Volumes/B", "volume-/Volumes/A"])
    }

    func testGroupsAndIDs() {
        let places = model(bookmarks: [URL(fileURLWithPath: "/b")], starred: [URL(fileURLWithPath: "/s")],
                           volumes: [VolumeInfo(url: URL(fileURLWithPath: "/Volumes/USB"), name: "USB")])
        XCTAssertEqual(Set(places.natural(.favorites).map(\.group)), [.favorites])
        XCTAssertEqual(places.bookmarks.map(\.group), [.bookmarks])
        XCTAssertEqual(places.starred.map(\.group), [.starred])
        XCTAssertEqual(places.devices.map(\.group), [.locations])
        XCTAssertEqual(places.devices.map(\.id), [Place.id(.device, path: "/Volumes/USB")])
        XCTAssertEqual(Place.id(.device, path: "/Volumes/USB"), "volume-/Volumes/USB")
        XCTAssertEqual(Place.id(.bookmark, path: "/b"), places.bookmarks[0].id)
        XCTAssertEqual(Place.id(.starred, path: "/s"), places.starred[0].id)
    }

    // MARK: The highlight lands only on rows on show

    func testInsideAHiddenFolderTheHighlightFallsToTheNextRowOnShow() {
        let inside = PlaceDestination.directory(home.appendingPathComponent("Documents/x"))
        XCTAssertEqual(model().selectedPlaceID(for: inside), "documents")
        XCTAssertEqual(model(SidebarLayout(hidden: ["documents"])).selectedPlaceID(for: inside), "home")
        XCTAssertNil(model(SidebarLayout(hidden: ["documents", "home"])).selectedPlaceID(for: inside))
    }

    func testAnExactMatchFallsToABookmarkOfTheSameFolderWhenTheStandardRowIsHidden() {
        let documents = home.appendingPathComponent("Documents")
        XCTAssertEqual(model(bookmarks: [documents]).selectedPlaceID(for: .directory(documents)), "documents")
        XCTAssertEqual(model(SidebarLayout(hidden: ["documents"]), bookmarks: [documents]).selectedPlaceID(for: .directory(documents)),
                       Place.id(.bookmark, path: documents.standardizedFileURL.path))
    }

    func testHiddenRecentAndTrashHighlightNothing() {
        let layout = SidebarLayout(hidden: ["recent-root", "trash"])
        XCTAssertNil(model(layout).selectedPlaceID(for: .recent))
        XCTAssertNil(model(layout).selectedPlaceID(for: .trash))
        XCTAssertEqual(model(layout).selectedPlaceID(for: .directory(home.appendingPathComponent(".Trash/item"))), "home")
        XCTAssertEqual(model().selectedPlaceID(for: .trash), "trash")
    }
}
