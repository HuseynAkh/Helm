// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class GalleryTests: XCTestCase {
    private func entry(_ name: String, childCount: Int? = nil) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/" + name), childCount: childCount)
    }
    private func snapshot(_ entries: [FileEntry]) -> PresentationSnapshot {
        PresentationSnapshot(location: .recent, sortedEntries: entries)
    }
    private func state() -> GalleryState {
        let entries = [entry("a"), entry("b"), entry("c")]
        return GalleryState(snapshot: snapshot(entries), selection: [entries[0].id], eligibleIDs: Set(entries.map(\.id)), viewport: GalleryViewport(width: 192))
    }
    func testEmptyHasNoMetadataOrPreview() {
        let value = GalleryState(snapshot: snapshot([]))
        XCTAssertNil(value.selectedEntry); XCTAssertNil(value.previewRequest); XCTAssertTrue(value.filmstripRequests.isEmpty)
    }
    func testDefaultEligibilityDoesNotReadContent() {
        let a = entry("a"); let value = GalleryState(snapshot: snapshot([a]), selection: [a.id], viewport: GalleryViewport(width: 500))
        XCTAssertNotNil(value.selectedEntry); XCTAssertNil(value.previewRequest); XCTAssertTrue(value.filmstripRequests.isEmpty)
    }
    func testMetadataAndIndexFollowSelection() {
        var value = state(); value.select(entry("b").id)
        XCTAssertEqual(value.selectedEntry, entry("b")); XCTAssertEqual(value.filmstripIndex, 1)
        XCTAssertEqual(value.previewRequest?.key.itemID, entry("b").id)
    }
    func testKeyboardBoundaries() {
        var value = state(); value.move(.left); XCTAssertEqual(value.filmstripIndex, 0)
        value.move(.end); value.move(.right); XCTAssertEqual(value.filmstripIndex, 2)
        value.move(.home); value.move(.right); XCTAssertEqual(value.filmstripIndex, 1)
    }
    func testClearAndUnknownSelection() {
        var value = state(); value.select(entry("unknown").id); XCTAssertEqual(value.filmstripIndex, 0)
        value.select(nil); XCTAssertNil(value.previewRequest); XCTAssertNil(value.selectedEntry)
    }
    func testDeletedSelectionDoesNotLabelNeighbour() {
        var value = state(); value.replaceSnapshot(snapshot([entry("b")]), eligibleIDs: [entry("b").id])
        XCTAssertNil(value.selectedEntry); XCTAssertNil(value.previewRequest)
    }
    func testReorderingRetainsIdentity() {
        var value = state(); value.replaceSnapshot(snapshot([entry("c"), entry("b"), entry("a")]), eligibleIDs: [entry("a").id])
        XCTAssertEqual(value.filmstripIndex, 2); XCTAssertEqual(value.selectedEntry?.id, entry("a").id)
    }
    func testABAAndDuplicatePreviewCompletionRejected() throws {
        var value = state(); let old = try XCTUnwrap(value.previewRequest)
        value.select(entry("b").id); value.select(entry("a").id)
        XCTAssertFalse(value.previewCompleted(old))
        let current = try XCTUnwrap(value.previewRequest)
        XCTAssertTrue(value.previewCompleted(current)); XCTAssertFalse(value.previewCompleted(current))
    }
    func testBackingScaleInvalidatesPreview() throws {
        var value = state(); let old = try XCTUnwrap(value.previewRequest)
        value.updateViewport(value.viewport, dimensions: ImageDimensions(widthPoints: 640, heightPoints: 480, backingScale: 2))
        XCTAssertFalse(value.previewCompleted(old)); XCTAssertEqual(value.previewRequest?.key.dimensions.pixelWidth, 1280)
    }
    func testChildTokenChangeInvalidatesEvenSameThumbnailKey() throws {
        var value = state(); let old = try XCTUnwrap(value.previewRequest)
        value.replaceSnapshot(snapshot([entry("a", childCount: 1)]), eligibleIDs: [entry("a").id])
        XCTAssertEqual(old.key, value.previewRequest?.key); XCTAssertNotEqual(old.changeToken, value.previewRequest?.changeToken)
        XCTAssertFalse(value.previewCompleted(old))
    }
    func testViewportChangesKeepSelectedPreview() throws {
        var value = state(); let request = try XCTUnwrap(value.previewRequest)
        value.updateViewport(GalleryViewport(offset: 96, width: 96), dimensions: value.dimensions)
        XCTAssertTrue(value.previewCompleted(request))
    }
    func testViewportClipsAndBoundsPrefetch() {
        XCTAssertEqual(GalleryViewport(offset: 190, width: 20, itemExtent: 100, prefetch: 1).indices(count: 10), 0..<4)
        XCTAssertEqual(GalleryViewport(offset: 900, width: 200, itemExtent: 100).indices(count: 10), 7..<10)
        XCTAssertTrue(GalleryViewport(offset: 1000, width: 100, itemExtent: 100).indices(count: 10).isEmpty)
    }
    func testPrefetchCannotStarveVisibleCells() {
        XCTAssertEqual(GalleryViewport(offset: 500, width: 100, itemExtent: 100, prefetch: 128, requestLimit: 1).indices(count: 100), 5..<6)
    }
    func testNonfiniteAndExtremeGeometryCannotTrap() {
        for number in [Double.nan, .infinity, -.infinity, -10, Double.greatestFiniteMagnitude] {
            let viewport = GalleryViewport(offset: number, width: number, itemExtent: .leastNonzeroMagnitude, prefetch: Int.max, requestLimit: Int.max)
            XCTAssertLessThanOrEqual(viewport.indices(count: 100_000).count, 512)
        }
        XCTAssertTrue(GalleryViewport(width: 0).indices(count: 10).isEmpty)
        XCTAssertTrue(GalleryViewport(width: 100, requestLimit: 0).indices(count: 10).isEmpty)
        XCTAssertTrue(GalleryViewport(width: 100).indices(count: -1).isEmpty)
    }
    func testHundredThousandItemsHaveBoundedDemand() {
        let entries = (0..<100_000).map { entry(String($0)) }
        let value = GalleryState(snapshot: snapshot(entries), eligibleIDs: Set(entries.map(\.id)),
                                 viewport: GalleryViewport(offset: 480_000, width: 960, prefetch: 2))
        XCTAssertEqual(value.filmstripRequests.count, 14)
        XCTAssertEqual(value.filmstripRequests.first?.key.itemID, entries[4998].id)
        XCTAssertNil(value.previewRequest)
    }
}
