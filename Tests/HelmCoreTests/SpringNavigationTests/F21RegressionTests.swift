// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmTestKit
@testable import HelmCore

final class F21RegressionTests: XCTestCase {
    private func session(_ sources: [DraggedItem] = [DraggedItem(url: URL(fileURLWithPath: "/source/file", isDirectory: false))]) -> SpringNavigationSession {
        SpringNavigationSession(original: SpringNavigationContext(tabID: TabID(), location: .recent), clock: SystemHelmClock(), delay: 0, sources: sources)
    }
    func testSameObjectDropAllowsChangedMetadata() throws {
        var state = session()
        let url = URL(fileURLWithPath: "/destination", isDirectory: true)
        let identity = FileObjectIdentity(scope: "test", object: "one")
        let before = FileEntry(url: url, kind: .directory, childCount: 0, objectIdentity: identity)
        let after = FileEntry(url: url, kind: .directory, size: 100, modificationDate: Date(), childCount: 1, isStarred: true, objectIdentity: identity)
        let request = try XCTUnwrap(state.acceptDrop(target: before, destination: DropDestination(location: .directory(url))))
        XCTAssertEqual(state.dropCompleted(request: request, success: true, destination: after), [.commit(SpringNavigationContext(tabID: state.original.tabID, location: .directory(url)))])
    }
    func testUnsafeSpringURLsRefused() throws {
        for raw in ["file://server/destination", "file:///destination?q", "file:///destination#f", "file://user@localhost/destination", "file://localhost:123/destination", "https://example.com/destination"] {
            let url = try XCTUnwrap(URL(string: raw))
            let target = FileEntry(url: url, kind: .directory)
            var state = session()
            state.beginHover(target)
            XCTAssertTrue(state.poll(openImmediately: true).isEmpty, raw)
            XCTAssertNil(state.acceptDrop(target: target, destination: DropDestination(location: .directory(url))), raw)
            var badSource = session([DraggedItem(url: url)])
            let local = FileEntry(url: URL(fileURLWithPath: "/destination", isDirectory: true), kind: .directory)
            XCTAssertNil(badSource.acceptDrop(target: local, destination: DropDestination(location: .directory(local.url))), raw)
        }
    }
    func testRealSymlinkSpellingAndShareActionArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real/child", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.path + "/link", withDestinationPath: root.path + "/real/child")
        for suffix in ["/link/..", "/link/../missing"] {
            let url = URL(fileURLWithPath: root.path + suffix, isDirectory: true)
            let model = PathPresentation(location: .directory(url), selectedEntries: [])
            XCTAssertEqual(model.segments.last?.id.path, url.path)
            XCTAssertEqual(try SharingSelectionSnapshot(urls: [url]).urls, [url])
        }
    }
    func testDirectoryHintIndependentLookup() throws {
        for hint in [false, true] {
            let url = URL(fileURLWithPath: "/F21-missing-directory", isDirectory: hint)
            let model = PathPresentation(location: .directory(url), selectedEntries: [])
            XCTAssertNotNil(model.intent(.navigate, segmentID: url))
            XCTAssertNil(model.intent(.navigate, segmentID: URL(fileURLWithPath: "/unrelated", isDirectory: true)))
        }
    }
    func testPageMovementIndependentOfImagingBudget() {
        let entries = (0..<100).map { FileEntry(url: URL(fileURLWithPath: "/\($0)", isDirectory: false)) }
        let snapshot = PresentationSnapshot(location: .recent, sortedEntries: entries)
        for prefetch in [0, 2, 128] {
            for budget in [0, 1, 128, 512] {
                var state = GalleryState(snapshot: snapshot, selection: [entries[0].id], viewport: GalleryViewport(width: 192, prefetch: prefetch, requestLimit: budget))
                state.move(.pageDown)
                XCTAssertEqual(state.filmstripIndex, 2)
                state.move(.pageUp)
                XCTAssertEqual(state.filmstripIndex, 0)
                state.select(entries[98].id); state.move(.pageDown)
                XCTAssertEqual(state.filmstripIndex, 99)
            }
        }
    }
    func testHoverRefreshRetainsDeadlineAndAllowsFreshMetadata() throws {
        let clock = FakeClock()
        var state = SpringNavigationSession(original: SpringNavigationContext(tabID: TabID(), location: .recent), clock: clock, delay: 10, sources: [])
        let url = URL(fileURLWithPath: "/hover", isDirectory: true)
        let identity = FileObjectIdentity(scope: "test", object: "hover")
        state.beginHover(FileEntry(url: url, kind: .directory, objectIdentity: identity))
        clock.advance(by: 9)
        let refreshed = FileEntry(url: url, kind: .directory, childCount: 1, isStarred: true, objectIdentity: identity)
        state.beginHover(refreshed)
        clock.advance(by: 1)
        XCTAssertEqual(state.poll().count, 1)
        let request = try XCTUnwrap(state.pending)
        XCTAssertEqual(state.hoverOpened(request: request, target: refreshed).count, 1)
        XCTAssertTrue(state.poll(openImmediately: true).isEmpty)
    }
    func testIdenticalMetadataReplacementRestoresAndMissingEvidenceIsExplicit() throws {
        let url = URL(fileURLWithPath: "/destination", isDirectory: true)
        for known in [true, false] {
            var state = session()
            let original = FileEntry(url: url, kind: .directory, objectIdentity: known ? FileObjectIdentity(scope: "test", object: "one") : nil)
            let target = FileEntry(url: url, kind: .directory, objectIdentity: known ? FileObjectIdentity(scope: "test", object: "two") : nil)
            let request = try XCTUnwrap(state.acceptDrop(target: original, destination: DropDestination(location: .directory(url))))
            let expected: [SpringNavigationEffect] = known ? [.restore(state.original)] : [.destinationUnverified(request), .restore(state.original)]
            XCTAssertEqual(state.dropCompleted(request: request, success: true, destination: target), expected)
            XCTAssertTrue(state.dropCompleted(request: request, success: true, destination: target).isEmpty)
        }
    }
    func testLocalhostAcceptedAndPathLookupIgnoresHintsForPresentDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try XCTUnwrap(URL(string: "file://localhost" + root.path))
        let target = FileEntry(url: url, kind: .directory)
        var state = session([DraggedItem(url: try XCTUnwrap(URL(string: "file://localhost/source/file")))])
        state.beginHover(target)
        XCTAssertEqual(state.poll(openImmediately: true).count, 1)
        XCTAssertNotNil(state.acceptDrop(target: target, destination: DropDestination(location: .directory(url))))
        let model = PathPresentation(location: .directory(root), selectedEntries: [])
        for hint in [true, false] {
            XCTAssertEqual(model.intent(.navigate, segmentID: URL(fileURLWithPath: root.path, isDirectory: hint)), .navigate(root))
        }
        XCTAssertEqual(model.intent(.navigate, segmentID: url), .navigate(root))
        XCTAssertNil(model.intent(.navigate, segmentID: try XCTUnwrap(URL(string: "file://remote" + root.path))))
    }
    func testVisibleCountHandlesClippingAndExtremeGeometry() {
        XCTAssertEqual(GalleryViewport(offset: 190, width: 20, itemExtent: 100).visibleCellCount(count: 10), 2)
        XCTAssertEqual(GalleryViewport(offset: 900, width: 200, itemExtent: 100).visibleCellCount(count: 10), 1)
        XCTAssertEqual(GalleryViewport(offset: 1000, width: 200, itemExtent: 100).visibleCellCount(count: 10), 0)
        for value in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(GalleryViewport(width: value).visibleCellCount(count: 100), 0)
        }
        XCTAssertEqual(GalleryViewport(width: .greatestFiniteMagnitude, itemExtent: .leastNonzeroMagnitude).visibleCellCount(count: Int.max), Int.max)
        XCTAssertEqual(GalleryViewport(width: 192).visibleCellCount(count: 0), 0)
        XCTAssertEqual(GalleryViewport(width: 192).visibleCellCount(count: -1), 0)
    }
    func testParentSpellingIsCopyOnlyAndShareDeduplicationRetainsFirstURL() throws {
        let url = URL(fileURLWithPath: "/link/../missing", isDirectory: false)
        let model = PathPresentation(location: .directory(url), selectedEntries: [])
        XCTAssertEqual(model.intent(.copyPath, segmentID: url), .copyPath(url.path))
        for action in [PathSegmentAction.navigate, .openTab, .reveal, .dropTarget] {
            XCTAssertNil(model.intent(action, segmentID: url))
        }
        let local = try XCTUnwrap(URL(string: "file://localhost/a/"))
        XCTAssertEqual(try SharingSelectionSnapshot(urls: [local, URL(fileURLWithPath: "/a", isDirectory: false)]).urls, [local])
    }

}
