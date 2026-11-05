// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class F18PropertiesSizeTests: XCTestCase {
    func testPackageBytesAreNotContentsAndNavigationIsUnchanged() {
        let package = FileEntry(url: URL(fileURLWithPath: "/Tool.app"), kind: .package, size: 4096)
        let model = PropertiesModel(entries: [package, package])
        XCTAssertFalse(package.isDirectoryLike)
        XCTAssertEqual(model.fileCount, 1)
        XCTAssertEqual(model.totalSize, 4096) // Preserve the legacy metadata aggregate.
        XCTAssertEqual(model.contentsSize, .calculating)
    }
    func testMixedContentsExcludeDirectoryAndPackageMetadata() {
        let items = [FileEntry(url: URL(fileURLWithPath: "/file"), size: 12),
                     FileEntry(url: URL(fileURLWithPath: "/folder"), kind: .directory, size: 100),
                     FileEntry(url: URL(fileURLWithPath: "/Tool.app"), kind: .package, size: 4096)]
        XCTAssertEqual(PropertiesModel(entries: items).contentsSize,
                       .partial(InspectorSizeTotal(bytes: 12, itemCount: 1)))
        XCTAssertEqual(PropertiesModel(entries: []).contentsSize, .unavailable)
    }
}
