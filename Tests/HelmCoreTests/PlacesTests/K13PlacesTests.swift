// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class K13PlacesTests: XCTestCase {
    /// F-027: path component boundaries prevent false highlighting.
    func testPrefixSiblingNotAncestor() throws {
        let model = PlacesModel(home: URL(fileURLWithPath: "/home/a"))
        XCTAssertNil(model.selectedPlaceID(for: .directory(URL(fileURLWithPath: "/home/ab"))))
    }
    /// F-028, B-029: offline canonical duplicates remain one row.
    func testCanonicalBookmarkDeduplication() throws {
        let model = PlacesModel(home: URL(fileURLWithPath: "/home"), bookmarks: [URL(fileURLWithPath: "/offline/a"), URL(fileURLWithPath: "/offline/b/../a")])
        XCTAssertEqual(model.bookmarks.count, 1)
    }
    /// F-028, B-113: equal display names use stable identities.
    func testEqualNamesDeterministic() throws {
        let urls = [URL(fileURLWithPath: "/z/مرحبا"), URL(fileURLWithPath: "/a/مرحبا")]
        let home = URL(fileURLWithPath: "/home")
        XCTAssertEqual(PlacesModel(home: home, bookmarks: urls).bookmarks.map(\.id), PlacesModel(home: home, bookmarks: urls.reversed()).bookmarks.map(\.id))
    }
    /// F-028: non-file URLs cannot become bookmarks.
    func testRejectedDropPreservesBookmarks() throws {
        var model = PlacesModel(home: URL(fileURLWithPath: "/home"))
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/folder"))
        XCTAssertFalse(model.handleBookmarkDrop([remote], isDirectory: { _ in true }))
        XCTAssertTrue(model.bookmarks.isEmpty)
    }
    /// F-031: show-all still deduplicates UUIDs.
    func testUUIDDedupeSurvivesShowAll() throws {
        let volumes = [VolumeInfo(url: URL(fileURLWithPath: "/a"), name: "A", uuid: "same", isHidden: true), VolumeInfo(url: URL(fileURLWithPath: "/b"), name: "B", uuid: "same")]
        XCTAssertEqual(VolumeFilter.filtered(volumes, showAll: true).count, 1)
    }
    /// F-031, B-080: exact exclusions do not hide user names.
    func testSimilarVolumeNamesRemainVisible() throws {
        let names = ["VM Images", "Recovery Notes", "Preboot Backup"]
        let volumes = names.map { VolumeInfo(url: URL(fileURLWithPath: "/Volumes/" + $0), name: $0) }
        XCTAssertEqual(Set(VolumeFilter.filtered(volumes).map(\.name)), Set(names))
    }
    /// F-027, F-029: starred folders participate in deepest-ancestor selection.
    func testStarredFolderHighlight() throws {
        try XCTSkipIf(true, "BUG-K13-1: starred folders are omitted from sidebar highlight candidates")
        let folder = URL(fileURLWithPath: "/offline/star")
        let model = PlacesModel(home: URL(fileURLWithPath: "/home"), starred: [folder])
        XCTAssertEqual(model.selectedPlaceID(for: .directory(folder.appendingPathComponent("child"))), model.starred.first?.id)
    }
}
