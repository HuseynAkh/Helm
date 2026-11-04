// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
final class T1ContentAdversarialTests: XCTestCase {
    private func ids(_ count: Int) -> [ItemID] { (0..<count).map { ItemID(rawValue: "/root/\($0)") } }
    private func entry(_ name: String, kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/root/" + name), kind: kind)
    }
    private func snapshot(_ values: [FileEntry], path: String = "/root") -> PresentationSnapshot {
        PresentationSnapshot(location: .directory(URL(fileURLWithPath: path)), sortedEntries: values)
    }

    func testSelectionEmptyCommands()  {
        var model = SelectionModel()
        model.selectAll(); model.invert(); model.move(.end); model.contextClick(nil)
        XCTAssertTrue(model.order.isEmpty); XCTAssertTrue(model.selected.isEmpty)
        XCTAssertNil(model.anchor); XCTAssertNil(model.focus)
    }
    func testSelectionDeduplicatesFirstOccurrence()  {
        let v = ids(3)
        let model = SelectionModel(order: [v[2], v[0], v[2], v[1], v[0]])
        XCTAssertEqual(model.order, [v[2], v[0], v[1]])
    }
    func testSelectionPrunesForeignState()  {
        let v = ids(3)
        let model = SelectionModel(order: [v[0]], selected: Set(v), anchor: v[1], focus: v[2])
        XCTAssertEqual(model.selected, [v[0]]); XCTAssertNil(model.anchor); XCTAssertNil(model.focus)
    }
    func testSelectionToggleInvolution()  {
        let v = ids(3); var model = SelectionModel(order: v, selected: [v[0]])
        model.click(v[1], command: true); model.click(v[1], command: true)
        XCTAssertEqual(model.selected, [v[0]])
    }
    func testSelectionReverseRange()  {
        let v = ids(6); var model = SelectionModel(order: v)
        model.click(v[5]); model.click(v[1], shift: true)
        XCTAssertEqual(model.selected, Set(v[1...5])); XCTAssertEqual(model.anchor, v[5])
    }
    func testSelectionCommandShiftUnion()  {
        let v = ids(7); var model = SelectionModel(order: v)
        model.click(v[0]); model.click(v[4], command: true); model.click(v[6], command: true, shift: true)
        XCTAssertEqual(model.selected, [v[0], v[4], v[5], v[6]])
    }
    func testSelectionContextPreservesGroup()  {
        let v = ids(4); var model = SelectionModel(order: v, selected: [v[1], v[3]], anchor: v[1], focus: v[3])
        model.contextClick(v[1]); XCTAssertEqual(model.selected, [v[1], v[3]])
        XCTAssertEqual(model.focus, v[3]); model.contextClick(v[0]); XCTAssertEqual(model.selected, [v[0]])
    }
    func testSelectionUnknownClickIsNoOp()  {
        let v = ids(2); var model = SelectionModel(order: [v[0]], selected: [v[0]], focus: v[0])
        model.click(v[1], command: true, shift: true)
        XCTAssertEqual(model.selected, [v[0]]); XCTAssertEqual(model.focus, v[0])
    }
    func testSelectionHundredThousandRange()  {
        let v = ids(100_000); var model = SelectionModel(order: v)
        model.click(v[0]); model.click(v[99_999], shift: true)
        XCTAssertEqual(model.selected, Set(v)); model.invert(); XCTAssertTrue(model.selected.isEmpty)
        model.selectAll(); model.reconcile(order: Array(v.suffix(10)))
        XCTAssertEqual(model.selected, Set(v.suffix(10)))
    }
    func testSelectionReconcileIdempotence()  {
        let v = ids(9); var model = SelectionModel(order: v, selected: Set(v), anchor: v[3], focus: v[5])
        let order = [v[8], v[4], v[2]]; model.reconcile(order: order)
        let selected = model.selected, anchor = model.anchor, focus = model.focus
        model.reconcile(order: order)
        XCTAssertEqual(model.order, order); XCTAssertEqual(model.selected, selected)
        XCTAssertEqual(model.anchor, anchor); XCTAssertEqual(model.focus, focus)
    }
    func testSelectionRenameMapping()  {
        let v = ids(4); var model = SelectionModel(order: [v[0], v[1]], selected: [v[0]], anchor: v[0], focus: v[0])
        model.reconcile(order: [v[2], v[1]], renamed: [v[0]: v[2]])
        XCTAssertEqual(model.selected, [v[2]]); XCTAssertEqual(model.anchor, v[2]); XCTAssertEqual(model.focus, v[2])
    }
    func testSelectionNeighbourTieChoosesNext()  {
        let v = ids(3); var model = SelectionModel(order: v, selected: [v[1]], anchor: v[1], focus: v[1])
        model.reconcile(order: [v[0], v[2]])
        XCTAssertTrue(model.selected.isEmpty); XCTAssertEqual(model.focus, v[2]); XCTAssertEqual(model.anchor, v[2])
    }
    func testSelectionGridNoHorizontalWrap()  {
        let v = ids(5); var model = SelectionModel(order: v)
        model.click(v[2]); model.move(.right, columns: 3); XCTAssertEqual(model.focus, v[2])
        model.click(v[3]); model.move(.left, columns: 3); XCTAssertEqual(model.focus, v[3])
        model.click(v[2]); model.move(.down, columns: 3); XCTAssertEqual(model.focus, v[4])
    }
    func testSelectionExtremePageSize()  {
        let v = ids(5); var model = SelectionModel(order: v)
        model.click(v[2]); model.move(.pageDown, pageSize: Int.max); XCTAssertEqual(model.focus, v[4])
        model.move(.pageUp, pageSize: Int.max); XCTAssertEqual(model.focus, v[0])
        model.move(.down, columns: Int.min); XCTAssertEqual(model.focus, v[1])
    }
    func testSelectionSeededToggleOracle()  {
        let v = ids(101); var model = SelectionModel(order: v); var oracle: Set<ItemID> = []
        var seed: UInt64 = 0x71
        for _ in 0..<2_000 {
            seed = seed &* 6364136223846793005 &+ 1
            let id = v[Int(seed % UInt64(v.count))]
            if oracle.contains(id) { oracle.remove(id) } else { oracle.insert(id) }
            model.click(id, command: true); XCTAssertEqual(model.selected, oracle)
        }
    }
    func testGridEmptyAndNegativeCount()  {
        for count in [-1, 0] {
            let g = GridGeometry(itemCount: count, availableWidth: 500)
            XCTAssertEqual(g.rows, 0); XCTAssertNil(g.rect(at: 0)); XCTAssertNil(g.index(at: .zero))
            XCTAssertTrue(g.visibleRange(scrollOffset: 0, viewportHeight: 500).isEmpty)
        }
    }
    func testGridSanitizesNonfiniteMetrics()  {
        let g = GridGeometry(itemCount: 1, availableWidth: .nan, itemSize: CGSize(width: -1, height: CGFloat.infinity), horizontalSpacing: -.infinity)
        XCTAssertEqual(g.columns, 1); XCTAssertEqual(g.itemSize, CGSize(width: 1, height: 140))
        XCTAssertEqual(g.horizontalSpacing, 10); XCTAssertTrue(g.contentHeight.isFinite)
    }
    func testGridExactEdgesAndGaps()  {
        let g = GridGeometry(itemCount: 4, availableWidth: 240, itemSize: CGSize(width: 100, height: 100), horizontalSpacing: 10, verticalSpacing: 10, horizontalInset: 0, verticalInset: 0)
        XCTAssertEqual(g.index(at: CGPoint(x: 0, y: 0)), 0)
        XCTAssertNil(g.index(at: CGPoint(x: 100, y: 10))); XCTAssertNil(g.index(at: CGPoint(x: 10, y: 100)))
        XCTAssertEqual(g.index(at: CGPoint(x: 110, y: 110)), 3)
    }
    func testGridInvalidIndicesAndCoordinates()  {
        let g = GridGeometry(itemCount: 1, availableWidth: 500)
        XCTAssertNil(g.rect(at: -1)); XCTAssertNil(g.rect(at: Int.max))
        for point in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity), CGPoint(x: -1, y: -1)] { XCTAssertNil(g.index(at: point)) }
    }
    func testGridViewportInSpacing()  {
        let g = GridGeometry(itemCount: 2, availableWidth: 10, itemSize: CGSize(width: 10, height: 10), verticalSpacing: 10, horizontalInset: 0, verticalInset: 0)
        XCTAssertTrue(g.visibleRange(scrollOffset: 10, viewportHeight: 10).isEmpty)
        XCTAssertEqual(g.visibleRange(scrollOffset: 20, viewportHeight: 10), 1..<2)
    }
    func testGridHundredThousandRoundTrips() throws {
        let g = GridGeometry(itemCount: 100_000, availableWidth: 1_000)
        for index in stride(from: 0, to: 100_000, by: 97) {
            let rect = try XCTUnwrap(g.rect(at: index))
            XCTAssertEqual(g.index(at: CGPoint(x: rect.midX, y: rect.midY)), index)
            XCTAssertEqual(g.indices(intersecting: rect), [index])
        }
        let last = try XCTUnwrap(g.rect(at: 99_999))
        XCTAssertTrue(g.visibleRange(scrollOffset: last.minY, viewportHeight: last.height).contains(99_999))
    }
    func testGridSeededIntersectionOracle() throws {
        let g = GridGeometry(itemCount: 127, availableWidth: 600)
        var seed: UInt64 = 19
        for _ in 0..<150 {
            seed = seed &* 2862933555777941757 &+ 3037000493
            let x = CGFloat(seed % 700) - 50
            seed = seed &* 2862933555777941757 &+ 3037000493
            let y = CGFloat(seed % 6000) - 50
            let query = CGRect(x: x, y: y, width: 177, height: 219)
            var oracle: Set<Int> = []
            for i in 0..<127 {
                let r = try XCTUnwrap(g.rect(at: i))
                if min(r.maxX, query.maxX) > max(r.minX, query.minX) && min(r.maxY, query.maxY) > max(r.minY, query.minY) { oracle.insert(i) }
            }
            XCTAssertEqual(g.indices(intersecting: query), oracle)
        }
    }
    func testGridRejectsInvalidViewports()  {
        let g = GridGeometry(itemCount: 10, availableWidth: 500)
        for height: CGFloat in [0, -1, .nan, .infinity] { XCTAssertTrue(g.visibleRange(scrollOffset: 0, viewportHeight: height).isEmpty) }
        XCTAssertTrue(g.indices(intersecting: .zero).isEmpty)
    }
    func testRenameUnicodeUTF16Stem()  {
        var model = InlineRenameModel(); let file = entry("👩🏽‍💻.résumé.txt")
        model.begin(file)
        XCTAssertEqual(model.editing?.selectedRange, NSRange(location: 0, length: "👩🏽‍💻.résumé".utf16.count))
    }
    func testRenameDirectoryKeepsExtensionSelected()  {
        var model = InlineRenameModel(); model.begin(entry("folder.ext", kind: .directory))
        XCTAssertEqual(model.editing?.selectedRange.length, 10)
    }
    func testRenameHiddenNameSelection()  {
        var model = InlineRenameModel(); model.begin(entry(".gitignore"))
        XCTAssertEqual(model.editing?.selectedRange.length, 10)
    }
    func testRenameRejectsTraversalAndByteOverflow()  {
        var model = InlineRenameModel(); let file = entry("a"); let token = model.begin(file)
        for name in ["", ".", "..", "../escape", "a/b", "a\0b", String(repeating: "é", count: 128)] {
            model.edit(name, session: token)
            XCTAssertNotNil(model.editing?.error, name)
            XCTAssertNil(model.handle(.returnKey, session: token, visibleOrder: [file.id]))
        }
    }
    func testRenameAccepts255ByteName()  {
        var model = InlineRenameModel(); let file = entry("a"); let token = model.begin(file)
        model.edit(String(repeating: "a", count: 255), session: token)
        XCTAssertNil(model.editing?.error); XCTAssertNotNil(model.handle(.returnKey, session: token, visibleOrder: [file.id]))
    }
    func testRenameEscapeCancelsPending() throws {
        var model = InlineRenameModel(); let file = entry("a"); let token = model.begin(file)
        let request = try XCTUnwrap(model.handle(.returnKey, session: token, visibleOrder: [file.id]))
        _ = model.handle(.escape, session: token, visibleOrder: [file.id])
        XCTAssertNil(model.pending); XCTAssertNil(model.editing); XCTAssertNil(model.complete(request))
    }
    func testRenameStaleSessionCannotEdit()  {
        var model = InlineRenameModel(); let old = model.begin(entry("a")); let new = model.begin(entry("b"))
        model.edit("corrupt", session: old); XCTAssertEqual(model.editing?.text, "b")
        XCTAssertNotEqual(old, new); XCTAssertNil(model.handle(.escape, session: old, visibleOrder: []))
        XCTAssertEqual(model.editing?.token, new)
    }
    func testRenameRetriesRejectOldCompletion() throws {
        var model = InlineRenameModel(); let file = entry("a"); let token = model.begin(file)
        let old = try XCTUnwrap(model.handle(.returnKey, session: token, visibleOrder: [file.id]))
        _ = model.complete(old, error: .collision)
        model.edit("b", session: token)
        let new = try XCTUnwrap(model.handle(.returnKey, session: token, visibleOrder: [file.id]))
        XCTAssertNotEqual(old.attempt, new.attempt); _ = model.complete(old)
        XCTAssertEqual(model.pending, new); _ = model.complete(new); XCTAssertNil(model.editing)
    }
    func testRenameTabDoesNotWrap() throws {
        var model = InlineRenameModel(); let file = entry("last"); let token = model.begin(file)
        let request = try XCTUnwrap(model.handle(.tab, session: token, visibleOrder: [file.id]))
        XCTAssertNil(request.nextItem); XCTAssertNil(model.complete(request)); XCTAssertNil(model.editing)
    }
    func testRenameReconcileCancelsVanishedItem()  {
        var model = InlineRenameModel(); model.begin(entry("a")); model.reconcile(existingIDs: [])
        XCTAssertNil(model.editing); XCTAssertNil(model.pending)
    }
    func testColumnEmptyNavigation()  {
        var model = ColumnBrowserState(root: snapshot([]))
        model.moveLeft(); model.pop(); XCTAssertEqual(model.moveRight(), .none)
        XCTAssertEqual(model.columns.count, 1); XCTAssertEqual(model.activeColumn, 0)
    }
    func testColumnInvalidIndicesDoNotMutate()  {
        let file = entry("a"); var model = ColumnBrowserState(root: snapshot([file]))
        for index in [Int.min, -1, 1, Int.max] {
            XCTAssertEqual(model.select(file.id, in: index), .none)
            XCTAssertFalse(model.replaceSnapshot(snapshot([]), at: index))
        }
        XCTAssertEqual(model.columns[0].snapshot.sortedIDs, [file.id])
    }
    func testColumnRejectsFilePush()  {
        let file = entry("a"); var model = ColumnBrowserState(root: snapshot([file]))
        XCTAssertEqual(model.select(file.id, in: 0), .preview(file.id))
        XCTAssertFalse(model.push(snapshot([], path: "/root/a"), request: ColumnLoadRequest(columnID: model.columns[0].id, directory: file.id, fromColumn: 0)))
        XCTAssertEqual(model.previewTarget, file.id)
    }
    func testColumnAncestorReloadInvalidatesChild() throws {
        let folder = entry("folder", kind: .directory); var model = ColumnBrowserState(root: snapshot([folder]))
        let request = try XCTUnwrap(model.select(folder.id, in: 0).loadRequest)
        XCTAssertTrue(model.push(snapshot([], path: "/root/folder"), request: request))
        XCTAssertTrue(model.replaceSnapshot(snapshot([folder]), at: 0))
        XCTAssertEqual(model.columns.count, 1); XCTAssertEqual(model.columns[0].selection.selected, [folder.id])
    }
}
