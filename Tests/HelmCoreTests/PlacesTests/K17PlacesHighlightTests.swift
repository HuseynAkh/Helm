// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class K17PlacesHighlightTests: XCTestCase {
    /// F-027/F-029: starred candidates support exact matches and the deepest containing folder.
    func testStarredExactAndDeepestAncestor() {
        let model = PlacesModel(home: url("/home"), bookmarks: [url("/work")],
                                starred: [url("/work/star"), url("/work/star/deep")])
        XCTAssertEqual(model.selectedPlaceID(for: .directory(url("/work/star"))), "starred-/work/star")
        XCTAssertEqual(model.selectedPlaceID(for: .directory(url("/work/star/deep/child"))), "starred-/work/star/deep")
        XCTAssertEqual(model.selectedPlaceID(for: .directory(url("/work/starling"))), "bookmark-/work")
    }

    /// F-027: existing exact-match priority survives duplicate starred paths.
    func testExistingExactPriority() {
        let home = url("/home")
        let model = PlacesModel(home: home, bookmarks: [url("/work/star/exact")],
                                starred: [home, url("/home/.Trash"), url("/work/star"), url("/work/star/exact")])
        XCTAssertEqual(model.selectedPlaceID(for: .directory(home)), model.favorites.first { $0.url == home }?.id)
        XCTAssertEqual(model.selectedPlaceID(for: .directory(url("/home/.Trash"))), model.trash.id)
        XCTAssertEqual(model.selectedPlaceID(for: .directory(url("/work/star/exact"))), "bookmark-/work/star/exact")
        XCTAssertEqual(model.selectedPlaceID(for: .starred), model.starredRoot.id)
    }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
}
