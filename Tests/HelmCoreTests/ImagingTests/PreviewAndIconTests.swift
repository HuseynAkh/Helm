// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class PreviewAndIconTests: XCTestCase {
    func testQuickLookFollowsSelectionAndRetainsCurrentItem() {
        let a = ItemID(rawValue: "/parent/child"), b = ItemID(rawValue: "/search/result")
        var model = QuickLookSelectionModel()
        XCTAssertEqual(model.space(), [])
        XCTAssertEqual(model.selectionChanged([a, b, a]), [])
        XCTAssertEqual(model.items, [a, b])
        XCTAssertEqual(model.space(paneIsFirstResponder: false), [])
        XCTAssertEqual(model.space(hasModifiers: true), [])
        XCTAssertEqual(model.space(), [.show(items: [a, b], index: 0)])
        XCTAssertEqual(model.move(forward: false), [])
        XCTAssertEqual(model.move(forward: true), [.select(index: 1)])
        XCTAssertEqual(model.move(forward: true), [])
        XCTAssertEqual(model.selectionChanged([b, a]), [.reload(items: [b, a], index: 0)])
        XCTAssertEqual(model.selectionChanged([b, a]), [])
        XCTAssertEqual(model.selectionChanged([a]), [.reload(items: [a], index: 0)])
        XCTAssertEqual(model.selectionChanged([]), [.close])
        XCTAssertFalse(model.isOpen); XCTAssertNil(model.currentIndex)
        XCTAssertEqual(model.move(forward: true), [])
        XCTAssertEqual(model.close(), [])
    }
    func testSpaceToggleAndReverseNavigation() {
        let a = ItemID(rawValue: "/a"), b = ItemID(rawValue: "/b")
        var model = QuickLookSelectionModel()
        _ = model.selectionChanged([a, b]); _ = model.space(); _ = model.move(forward: true)
        XCTAssertEqual(model.move(forward: false), [.select(index: 0)])
        XCTAssertEqual(model.space(), [.close])
        XCTAssertEqual(model.space(), [.show(items: [a, b], index: 0)])
        XCTAssertEqual(model.close(), [.close])
    }
    func testIconPolicySharesGenericKeysAndInvalidatesSpecificKeys() {
        let dimensions = ImageDimensions(widthPoints: 18, heightPoints: 18, backingScale: 2)
        let a = FileEntry(url: URL(fileURLWithPath: "/a.JPG"))
        let b = FileEntry(url: URL(fileURLWithPath: "/b.jpg"))
        XCTAssertEqual(IconRequest(entry: a, dimensions: dimensions), IconRequest(entry: b, dimensions: dimensions))
        XCTAssertEqual(IconRequest(entry: a, dimensions: dimensions).identity, .pathExtension("jpg"))
        let typed = FileEntry(url: a.url, contentTypeIdentifier: "public.jpeg")
        XCTAssertEqual(IconRequest(entry: typed, dimensions: dimensions).identity, .contentType("public.jpeg"))
        let folder = FileEntry(url: a.url, kind: .directory, volumeIdentifier: "disk")
        XCTAssertEqual(IconRequest(entry: folder, dimensions: dimensions).identity, .folder)
        XCTAssertEqual(IconRequest(entry: folder, dimensions: dimensions, isVolumeRoot: true).identity, .volume("disk"))
        XCTAssertEqual(IconRequest(entry: a, dimensions: dimensions, isVolumeRoot: true).identity, .volume(a.id.rawValue))
        let plain = FileEntry(url: URL(fileURLWithPath: "/README"))
        XCTAssertEqual(IconRequest(entry: plain, dimensions: dimensions).identity, .genericFile)
        let changed = FileEntry(url: a.url, size: 1)
        XCTAssertNotEqual(IconRequest(entry: a, dimensions: dimensions, policy: .fileSpecific),
                          IconRequest(entry: changed, dimensions: dimensions, policy: .fileSpecific))
        XCTAssertEqual(ThumbnailKey(entry: a, dimensions: dimensions).itemID, a.id)
    }
}
