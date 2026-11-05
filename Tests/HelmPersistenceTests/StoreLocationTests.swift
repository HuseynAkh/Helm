// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
import HelmPersistence

final class StoreLocationTests: XCTestCase {
    func testSevenDistinctDocumentsUnderInjectedRoot() {
        let root = URL(fileURLWithPath: "/tmp/helm-location-fixture")
        let location = StoreLocation(directory: root)
        let urls = [location.stars, location.bookmarks, location.recent, location.session,
                    location.trashOrigins, location.tagCatalog, location.viewOptions]
        XCTAssertEqual(Set(urls).count, 7)
        XCTAssertTrue(urls.allSatisfy { $0.deletingLastPathComponent().path == root.path })
        XCTAssertEqual(location.tagCatalog.lastPathComponent, "tag-catalog.json")
        XCTAssertEqual(location.viewOptions.lastPathComponent, "view-options.json")
    }
}
