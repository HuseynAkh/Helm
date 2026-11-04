// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

private final class HoverClock: HelmClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date = Date(timeIntervalSince1970: 0)
    init() {}
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

final class DragInteractionTests: XCTestCase {
    private let folder = ItemID(rawValue: "/folder")
    func testSpringDeadlineRepeatedUpdatesAndReentry() {
        let clock = HoverClock()
        var model = SpringLoadingModel(clock: clock, delay: 1)
        XCTAssertNil(model.poll())
        model.beginHover(id: folder, isDirectory: true)
        clock.advance(0.5)
        model.beginHover(id: folder, isDirectory: true)
        XCTAssertNil(model.poll())
        clock.advance(0.5)
        XCTAssertEqual(model.poll(), folder)
        XCTAssertNil(model.poll(openImmediately: true))
        model.cancel()
        XCTAssertNil(model.hoveredID)
        model.beginHover(id: folder, isDirectory: true)
        XCTAssertNil(model.poll())
        XCTAssertEqual(model.poll(openImmediately: true), folder)
    }
    func testSpringTargetChangesAndCancellation() {
        let clock = HoverClock()
        var model = SpringLoadingModel(clock: clock, delay: 1)
        model.beginHover(id: folder, isDirectory: true)
        clock.advance(0.9)
        let next = ItemID(rawValue: "/next")
        model.beginHover(id: next, isDirectory: true)
        clock.advance(0.2)
        XCTAssertNil(model.poll())
        clock.advance(1)
        XCTAssertEqual(model.poll(), next)
        for _ in ["leave", "drop", "escape"] {
            model.beginHover(id: folder, isDirectory: true)
            model.cancel()
            clock.advance(2)
            XCTAssertNil(model.poll())
        }
    }
    func testSpringEligibilityClockAndInvalidDelay() {
        let clock = HoverClock()
        var model = SpringLoadingModel(clock: clock, delay: -1)
        XCTAssertEqual(model.delay, 0)
        XCTAssertEqual(SpringLoadingModel(clock: clock, delay: .nan).delay, 1)
        model.beginHover(id: folder, isDirectory: false)
        XCTAssertNil(model.poll(openImmediately: true))
        model.beginHover(id: folder, isDirectory: true, isPackage: true)
        XCTAssertNil(model.poll(openImmediately: true))
        model.beginHover(id: folder, isDirectory: true, isPackage: true, allowsPackageContents: true)
        clock.advance(-1)
        XCTAssertNil(model.poll())
        clock.advance(1)
        XCTAssertEqual(model.poll(), folder)
        model.beginHover(id: folder, isDirectory: false)
        XCTAssertNil(model.hoveredID)
    }
    func testSelectionOrderMissingIDsAndImageCounts() {
        let items = (0..<5).map { DraggedItem(url: URL(fileURLWithPath: "/\($0)")) }
        let ids = Set(items.map(\.id))
        let selected = DragSourceModel(clickedID: items[2].id, selectedIDs: ids, orderedItems: items + [items[0]])
        XCTAssertEqual(selected.items, items)
        XCTAssertEqual(selected.itemCountBadge, 5)
        XCTAssertEqual(selected.imageCount, 3)
        let single = DragSourceModel(clickedID: items[2].id, selectedIDs: [items[0].id], orderedItems: items, maximumImages: -1)
        XCTAssertEqual(single.items, [items[2]])
        XCTAssertNil(single.itemCountBadge)
        XCTAssertEqual(single.imageCount, 0)
        let missing = DragSourceModel(clickedID: folder, selectedIDs: ids.union([folder]), orderedItems: items)
        XCTAssertTrue(missing.items.isEmpty)
        XCTAssertNil(missing.itemCountBadge)
        XCTAssertEqual(missing.imageCount, 0)
    }
    func testThresholdBoundaries() {
        XCTAssertTrue(DragSourceModel.exceedsThreshold(deltaX: 3, deltaY: 4, threshold: 5))
        XCTAssertTrue(DragSourceModel.exceedsThreshold(deltaX: -4, deltaY: 0))
        XCTAssertFalse(DragSourceModel.exceedsThreshold(deltaX: 3, deltaY: 0))
        XCTAssertFalse(DragSourceModel.exceedsThreshold(deltaX: 0, deltaY: 0, threshold: 0))
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(DragSourceModel.exceedsThreshold(deltaX: value, deltaY: 0))
            XCTAssertFalse(DragSourceModel.exceedsThreshold(deltaX: 10, deltaY: value))
            XCTAssertFalse(DragSourceModel.exceedsThreshold(deltaX: 10, deltaY: 0, threshold: value))
        }
        XCTAssertFalse(DragSourceModel.exceedsThreshold(deltaX: 10, deltaY: 0, threshold: -1))
    }
    func testExternalRepresentations() throws {
        let web = try XCTUnwrap(URL(string: "https://example.invalid"))
        let file = URL(fileURLWithPath: "/file")
        let promise = PromisedFilePlaceholder(identifier: "1", suggestedName: "../unsafe", contentTypeIdentifier: "public.image")
        XCTAssertEqual(promise.suggestedName, "../unsafe")
        XCTAssertEqual(promise.contentTypeIdentifier, "public.image")
        XCTAssertEqual(DragSourceModel.classify(urls: [web, file, file], promises: [promise], text: "text"), .fileURLs([file]))
        XCTAssertEqual(DragSourceModel.classify(urls: [web], promises: [promise], text: "text"), .promisedFiles([promise]))
        XCTAssertEqual(DragSourceModel.classify(urls: [web], text: "text"), .text("text"))
        XCTAssertEqual(DragSourceModel.classify(urls: [web]), .unsupported)
        XCTAssertEqual(DragSourceModel.classify(urls: [], text: ""), .unsupported)
    }
    func testAutoScrollBoundariesAndInvalidGeometry() {
        let model = DragAutoScrollModel(edgeExtent: 20, maximumSpeed: 100)
        for (position, speed) in [(0.0, -100.0), (10, -50), (20, 0), (50, 0), (80, 0), (90, 50), (100, 100)] {
            XCTAssertEqual(model.velocity(position: position, viewportExtent: 100), speed)
        }
        XCTAssertEqual(model.velocity(position: 5, viewportExtent: 10), 0)
        XCTAssertEqual(model.velocity(position: 2.5, viewportExtent: 10), -50)
        for position in [-1, 101, Double.nan, .infinity] {
            XCTAssertEqual(model.velocity(position: position, viewportExtent: 100), 0)
        }
        for extent in [0, -1, Double.nan, .infinity] {
            XCTAssertEqual(model.velocity(position: 0, viewportExtent: extent), 0)
        }
        for value in [0, -1, Double.nan, .infinity] {
            XCTAssertEqual(DragAutoScrollModel(edgeExtent: value).velocity(position: 0, viewportExtent: 100), 0)
            XCTAssertEqual(DragAutoScrollModel(maximumSpeed: value).velocity(position: 0, viewportExtent: 100), 0)
        }
    }
}
