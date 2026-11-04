// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class SelectionModelTests: XCTestCase {
    private let ids: [ItemID] = (0..<10).map { ItemID(rawValue: "/\($0)") }
    func testInitializationFiltersAndDeduplicates() {
        let model = SelectionModel(order: [ids[0], ids[0]], selected: [ids[0], ids[1]], anchor: ids[1], focus: ids[1])
        XCTAssertEqual(model.order, [ids[0]]); XCTAssertEqual(model.selected, [ids[0]])
        XCTAssertNil(model.anchor); XCTAssertNil(model.focus)
    }
    func testClickToggleAndInvalidTarget() {
        var model = SelectionModel(order: ids)
        model.click(ids[2]); model.click(ids[4], command: true)
        XCTAssertEqual(model.selected, [ids[2], ids[4]])
        model.click(ids[4], command: true)
        XCTAssertEqual(model.selected, [ids[2]]); XCTAssertEqual(model.focus, ids[4])
        model.click(ItemID(rawValue: "/missing")); XCTAssertEqual(model.focus, ids[4])
    }
    func testRangeExtendsAndContractsAroundFixedAnchor() {
        var model = SelectionModel(order: ids)
        model.click(ids[4]); model.click(ids[7], shift: true)
        XCTAssertEqual(model.selected, Set(ids[4...7]))
        model.move(.up, extending: true); XCTAssertEqual(model.selected, Set(ids[4...6]))
        model.click(ids[1], shift: true); XCTAssertEqual(model.selected, Set(ids[1...4]))
        XCTAssertEqual(model.anchor, ids[4])
    }
    func testCommandShiftUnionsAndInitialShift() {
        var model = SelectionModel(order: ids)
        model.click(ids[1], shift: true); XCTAssertEqual(model.selected, [ids[1]])
        model.click(ids[7], command: true); model.click(ids[9], command: true, shift: true)
        XCTAssertEqual(model.selected, [ids[1], ids[7], ids[8], ids[9]])
    }
    func testContextSelection() {
        var model = SelectionModel(order: ids)
        model.click(ids[1]); model.click(ids[2], command: true); model.contextClick(ids[1])
        XCTAssertEqual(model.selected.count, 2)
        model.contextClick(ids[3]); XCTAssertEqual(model.selected, [ids[3]])
        model.contextClick(nil); XCTAssertTrue(model.selected.isEmpty); XCTAssertNil(model.anchor)
    }
    func testAllInvertClear() {
        var model = SelectionModel(order: ids)
        model.selectAll(); XCTAssertEqual(model.selected, Set(ids)); XCTAssertEqual(model.focus, ids[0])
        model.invert(); XCTAssertTrue(model.selected.isEmpty); XCTAssertNil(model.focus)
        model.click(ids[0]); model.invert(); XCTAssertEqual(model.selected, Set(ids.dropFirst()))
        model.clear(); XCTAssertNil(model.anchor); XCTAssertNil(model.focus)
    }
    func testListAndPages() {
        var model = SelectionModel(order: ids)
        model.move(.down); XCTAssertEqual(model.focus, ids[0])
        model.move(.right); XCTAssertEqual(model.focus, ids[0])
        model.move(.down); XCTAssertEqual(model.focus, ids[1])
        model.move(.pageDown, pageSize: 4); XCTAssertEqual(model.focus, ids[5])
        model.move(.pageUp, pageSize: 2); XCTAssertEqual(model.focus, ids[3])
        model.move(.end); XCTAssertEqual(model.focus, ids[9])
        model.move(.down); XCTAssertEqual(model.focus, ids[9])
        model.move(.home); model.move(.up); XCTAssertEqual(model.focus, ids[0])
        model.move(.pageDown, pageSize: Int.max); XCTAssertEqual(model.focus, ids[9])
    }
    func testGridEdgesAndIncompleteRow() {
        var model = SelectionModel(order: ids)
        model.click(ids[2]); model.move(.up, columns: 4); XCTAssertEqual(model.focus, ids[2])
        model.move(.right, columns: 4); model.move(.right, columns: 4); XCTAssertEqual(model.focus, ids[3])
        model.move(.down, columns: 4); XCTAssertEqual(model.focus, ids[7])
        model.move(.down, columns: 4); XCTAssertEqual(model.focus, ids[9])
        model.move(.down, columns: 4); XCTAssertEqual(model.focus, ids[9])
        model.click(ids[4]); model.move(.left, columns: 4); XCTAssertEqual(model.focus, ids[4])
        model.move(.right, columns: 4); model.move(.up, columns: 4); XCTAssertEqual(model.focus, ids[1])
    }
    func testEmptyAndInvalidMetrics() {
        var model = SelectionModel()
        model.move(.end); model.selectAll(); model.invert(); XCTAssertTrue(model.selected.isEmpty)
        model.reconcile(order: ids); model.move(.up); XCTAssertEqual(model.focus, ids.last)
        model.move(.home); model.move(.down, columns: 0, pageSize: -1); XCTAssertEqual(model.focus, ids[1])
    }
    func testReloadAndRenameMapping() {
        var model = SelectionModel(order: ids)
        model.click(ids[4]); model.click(ids[6], shift: true)
        model.reconcile(order: [ids[3], ids[5], ids[7]])
        XCTAssertEqual(model.selected, [ids[5]]); XCTAssertEqual(model.anchor, ids[5]); XCTAssertEqual(model.focus, ids[7])
        let renamed = ItemID(rawValue: "/renamed")
        model.reconcile(order: [renamed, ids[7]], renamed: [ids[5]: renamed])
        XCTAssertEqual(model.selected, [renamed]); XCTAssertEqual(model.anchor, renamed)
        model.reconcile(order: []); XCTAssertNil(model.focus); XCTAssertNil(model.anchor)
    }
    func testReorderPreservesAnchorAndFallbackReplacement() {
        var model = SelectionModel(order: ids)
        model.click(ids[8]); model.reconcile(order: ids.reversed())
        XCTAssertEqual(model.anchor, ids[8]); XCTAssertEqual(model.selected, [ids[8]])
        let fresh = ItemID(rawValue: "/fresh")
        model.reconcile(order: [fresh]); XCTAssertEqual(model.anchor, fresh); XCTAssertTrue(model.selected.isEmpty)
    }
    func testTypeSelectUsesVisibleOrder() {
        let a = FileEntry(url: URL(fileURLWithPath: "/alpha"))
        let b = FileEntry(url: URL(fileURLWithPath: "/alpine"))
        let snapshot = PresentationSnapshot(location: .recent, sortedEntries: [a, b])
        var model = SelectionModel(snapshot: snapshot)
        model.reconcile(order: [b.id, a.id])
        var matcher = TypeSelect()
        XCTAssertEqual(model.typeSelect("al", matcher: &matcher, snapshot: snapshot), b.id)
        XCTAssertNil(model.typeSelect("z", matcher: &matcher, snapshot: snapshot))
        XCTAssertEqual(model.selected, [b.id])
    }
    func testLargeSelectionIsLinearEnough() {
        let order: [ItemID] = (0..<100_000).map { ItemID(rawValue: "/\($0)") }
        let start = Date()
        var model = SelectionModel(order: order)
        model.selectAll(); model.reconcile(order: Array(order.dropFirst())); model.invert()
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }
}
