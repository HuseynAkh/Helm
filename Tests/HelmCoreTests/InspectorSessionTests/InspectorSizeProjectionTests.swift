// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class InspectorSizeProjectionTests: XCTestCase {
    func entry(_ kind: FileEntryKind, _ size: Int64) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/\(kind.rawValue)"), kind: kind, size: size)
    }
    func testPackageAndDirectoryMetadataAreNotContents() {
        for kind: FileEntryKind in [.directory, .package] {
            let projection = InspectorSizeProjection(entries: [entry(kind, 4096)])
            XCTAssertEqual(projection.rawMetadata, .final(InspectorSizeTotal(bytes: 4096, itemCount: 1)))
            XCTAssertEqual(projection.contents, .calculating)
        }
    }
    func testRegularFileAndNegativeMetadata() {
        XCTAssertEqual(InspectorSizeProjection(entries: [entry(.regular, 30)]).contents,
                       .final(InspectorSizeTotal(bytes: 30, itemCount: 1)))
        XCTAssertEqual(InspectorSizeProjection(entries: [entry(.regular, -1)]).contents, .unavailable)
    }
    func testMixedSelectionPartialAndComputedTotal() {
        let file = entry(.regular, 20), package = entry(.package, 4096)
        XCTAssertEqual(InspectorSizeProjection(entries: [file, package]).contents,
                       .partial(InspectorSizeTotal(bytes: 20, itemCount: 1)))
        XCTAssertEqual(InspectorSizeProjection(entries: [file, package], computed: [package.id:
            .final(InspectorSizeTotal(bytes: 100, itemCount: 4))]).contents,
            .final(InspectorSizeTotal(bytes: 120, itemCount: 5)))
    }
    func testPartialOverflowRemainsFlagged() {
        let file = entry(.regular, .max), directory = entry(.directory, 4096)
        let result = InspectorSizeProjection(entries: [file, directory], computed: [directory.id:
            .partial(InspectorSizeTotal(bytes: 1, itemCount: .max))])
        XCTAssertEqual(result.contents, .partial(InspectorSizeTotal(bytes: .max, itemCount: .max, overflowed: true)))
    }
    func testDeduplicationEmptyAndUnrelatedResults() {
        let file = entry(.regular, 12)
        XCTAssertEqual(InspectorSizeProjection(entries: [file, file]).contents,
                       .final(InspectorSizeTotal(bytes: 12, itemCount: 1)))
        XCTAssertEqual(InspectorSizeProjection(entries: [], computed: [file.id: .calculating]).contents, .unavailable)
        XCTAssertEqual(InspectorSizeProjection(entries: [file], computed: [entry(.package, 0).id: .unavailable]).contents,
                       .final(InspectorSizeTotal(bytes: 12, itemCount: 1)))
    }
    func testSymlinkMetadataDoesNotImplyRecursiveTraversal() {
        XCTAssertEqual(InspectorSizeProjection(entries: [entry(.symlinkToDirectory, 8)]).contents,
                       .final(InspectorSizeTotal(bytes: 8, itemCount: 1)))
    }
}
