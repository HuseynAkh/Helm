// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore

final class PlacesTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")
    func testLosslessDestinationResolution() {
        XCTAssertEqual(PlaceDestination.directory(home).resolved, .directory(home))
        XCTAssertEqual(PlaceDestination.recent.resolved, .recentCollection)
        XCTAssertEqual(PlaceDestination.starred.resolved, .starredCollection)
        XCTAssertEqual(PlaceDestination.trash.resolved, .trashCollection)
        let offline = URL(fileURLWithPath: "/Volumes/offline/folder")
        XCTAssertEqual(PlaceDestination.directory(offline).resolved, .directory(offline))
    }
    func testFavoritesAndVirtualDestinations() throws {
        let model = PlacesModel(home: home)
        XCTAssertEqual(model.favorites.map(\.name), ["Home", "Desktop", "Documents", "Downloads", "Applications"])
        XCTAssertEqual(model.favorites[1].url?.path, "/Users/test/Desktop")
        XCTAssertEqual(model.recentsRoot.destination.location, .recent)
        XCTAssertNil(model.starredRoot.destination.location)
        XCTAssertNil(model.starredRoot.url)
        XCTAssertEqual(model.trash.destination.location, .trash)
        XCTAssertEqual(PlaceDestination.directory(home).location, .directory(home))
        XCTAssertEqual(model.selectedPlaceID(for: .recent), "recent-root")
        XCTAssertEqual(model.selectedPlaceID(for: .starred), "starred-root")
        XCTAssertEqual(model.selectedPlaceID(for: .trash), "trash")
        XCTAssertEqual(model.place(for: "home")?.name, "Home")
        XCTAssertNil(model.place(for: "missing"))
        let encoded = try JSONEncoder().encode(model.favorites[0])
        XCTAssertEqual(try JSONDecoder().decode(Place.self, from: encoded), model.favorites[0])
        XCTAssertEqual(Set([model.favorites[0], model.favorites[0]]).count, 1)
    }
    func testHighlightExactThenDeepestExcludesStarred() {
        let deep = home.appendingPathComponent("Documents/work")
        let model = PlacesModel(home: home, bookmarks: [deep, home],
                                starred: [deep.appendingPathComponent("stars")])
        XCTAssertEqual(model.selectedPlaceID(for: .directory(home)), "home")
        XCTAssertEqual(model.selectedPlaceID(for: .directory(deep.appendingPathComponent("stars/child"))),
                       "bookmark-/Users/test/Documents/work")
        XCTAssertEqual(model.selectedPlaceID(for: .directory(home.appendingPathComponent("Documents2"))), "home")
        XCTAssertEqual(model.selectedPlaceID(for: .directory(home.appendingPathComponent(".Trash/item"))), "trash")
        XCTAssertNil(model.selectedPlaceID(for: .directory(URL(fileURLWithPath: "/Users/test2"))))
        let root = PlacesModel(home: home, bookmarks: [URL(fileURLWithPath: "/")])
        XCTAssertEqual(root.selectedPlaceID(for: .directory(URL(fileURLWithPath: "/elsewhere"))), "bookmark-/")
    }
    func testDropsValidateDirectoriesDeduplicateSortAndRetainOfflineBookmarks() throws {
        let offline = URL(fileURLWithPath: "/Volumes/offline/z")
        var model = PlacesModel(home: home, bookmarks: [offline])
        let file = home.appendingPathComponent("file")
        XCTAssertTrue(model.handleBookmarkDrop([file], isDirectory: { _ in false }))
        XCTAssertEqual(model.bookmarks.count, 1)
        XCTAssertTrue(model.handleBookmarkDrop([home, home.appendingPathComponent("../test")], isDirectory: { _ in true }))
        XCTAssertEqual(model.bookmarks.map(\.name), ["Home", "z"])
        XCTAssertFalse(model.handleBookmarkDrop([], isDirectory: { _ in true }))
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/a"))
        XCTAssertFalse(model.handleBookmarkDrop([remote], isDirectory: { _ in true }))
        model.removeBookmark(id: "home") // favorites cannot be removed
        XCTAssertEqual(model.bookmarks.count, 2)
        model.removeBookmark(id: "bookmark-/Volumes/offline/z")
        XCTAssertEqual(model.bookmarks.count, 1)
    }
    func testVolumeFiltersExactNamesAndShowAllBypass() {
        let names = ["Preboot", "RECOVERY", "VM", "Update", "Hardware", "xarts", "Disk - Data", "VM Images", "Recovery Photos"]
        let volumes = names.map { VolumeInfo(url: URL(fileURLWithPath: "/Volumes/\($0)"), name: $0) }
        XCTAssertEqual(Set(VolumeFilter.filtered(volumes).map(\.name)), Set(["VM Images", "Recovery Photos"]))
        XCTAssertEqual(VolumeFilter.filtered(volumes, showAll: true).count, names.count)
        let hidden = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/hidden"), name: "hidden", isHidden: true)
        let privateMount = VolumeInfo(url: URL(fileURLWithPath: "/private/disk"), name: "private")
        let unbrowsable = VolumeInfo(url: URL(fileURLWithPath: "/dev/disk"), name: "device", isBrowsable: false)
        XCTAssertTrue(VolumeFilter.filtered([hidden, privateMount, unbrowsable]).isEmpty)
        XCTAssertEqual(VolumeFilter.filtered([hidden, privateMount, unbrowsable], showAll: true).count, 3)
    }
    func testVolumeDedupeAndInternalFirst() {
        let a = VolumeInfo(url: URL(fileURLWithPath: "/"), name: "System", uuid: "a", isInternal: true)
        let b = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/second"), name: "SYSTEM", uuid: "b", isInternal: true)
        let c = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/c"), name: "AAA", uuid: "c", isRemovable: true)
        let duplicate = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/duplicate"), name: "Duplicate", uuid: "c")
        XCTAssertEqual(VolumeFilter.filtered([a, b, c, duplicate]).map(\.name), ["System", "AAA"])
        XCTAssertEqual(VolumeFilter.filtered([a, b, c, duplicate], showAll: true).count, 3)
        let noID = VolumeInfo(url: URL(fileURLWithPath: "/Volumes/noID"), name: "No ID")
        XCTAssertEqual(VolumeFilter.filtered([noID, noID], showAll: true).count, 1)
        let model = PlacesModel(home: home, volumes: [a, c])
        XCTAssertEqual(model.devices.map(\.iconName), ["internaldrive", "externaldrive"])
    }
}
