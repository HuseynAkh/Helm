// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class ColumnBrowserStateTests: XCTestCase {
    private func entry(_ path: String, _ kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: path), kind: kind)
    }
    private func snapshot(_ path: String, _ entries: [FileEntry]) -> PresentationSnapshot {
        PresentationSnapshot(location: .directory(URL(fileURLWithPath: path)), sortedEntries: entries)
    }
    func testDirectoryPushPreviewAndLeft() {
        let folder = entry("/root/folder", .directory), file = entry("/root/folder/file")
        var state = ColumnBrowserState(root: snapshot("/root", [folder]))
        XCTAssertEqual(state.select(folder.id, in: 0), .load(directory: folder.id, fromColumn: 0))
        XCTAssertTrue(state.push(snapshot("/root/folder", [file]), from: 0, directory: folder.id))
        XCTAssertEqual(state.activeColumn, 1)
        XCTAssertEqual(state.select(file.id, in: 1), .preview(file.id)); XCTAssertEqual(state.previewTarget, file.id)
        XCTAssertEqual(state.moveRight(), .preview(file.id))
        state.moveLeft(); XCTAssertEqual(state.columns.count, 1); XCTAssertEqual(state.activeColumn, 0)
        XCTAssertEqual(state.columns[0].selection.selected, [folder.id]); XCTAssertNil(state.previewTarget)
        state.moveLeft(); XCTAssertEqual(state.columns.count, 1)
    }
    func testAncestorChangeTruncatesAndRejectsStalePush() {
        let a = entry("/root/a", .directory), b = entry("/root/b", .directory)
        var state = ColumnBrowserState(root: snapshot("/root", [a, b]))
        _ = state.select(a.id, in: 0)
        XCTAssertTrue(state.push(snapshot("/root/a", []), from: 0, directory: a.id))
        _ = state.select(b.id, in: 0); XCTAssertEqual(state.columns.count, 1)
        XCTAssertFalse(state.push(snapshot("/root/a", []), from: 0, directory: a.id))
        XCTAssertFalse(state.push(snapshot("/wrong", []), from: 0, directory: b.id))
        XCTAssertEqual(state.moveRight(), .load(directory: b.id, fromColumn: 0))
    }
    func testMultiSelectionDoesNotNavigateOrPreview() {
        let a = entry("/a"), b = entry("/b")
        var state = ColumnBrowserState(root: snapshot("/", [a, b]))
        _ = state.select(a.id, in: 0)
        XCTAssertEqual(state.select(b.id, in: 0, command: true), .none)
        XCTAssertNil(state.previewTarget); XCTAssertEqual(state.moveRight(), .none)
        XCTAssertEqual(state.select(b.id, in: 0, command: true), .preview(a.id))
    }
    func testPackageAndSymlinkSemantics() {
        for kind in [FileEntryKind.package, .symlinkToFile, .danglingSymlink, .alias] {
            let file = entry("/thing", kind)
            var state = ColumnBrowserState(root: snapshot("/", [file]))
            XCTAssertEqual(state.select(file.id, in: 0), .preview(file.id))
        }
        let folder = entry("/link", .symlinkToDirectory)
        var state = ColumnBrowserState(root: snapshot("/", [folder]))
        XCTAssertEqual(state.select(folder.id, in: 0), .load(directory: folder.id, fromColumn: 0))
    }
    func testReloadReconcilesAndTruncates() {
        let folder = entry("/a", .directory)
        var state = ColumnBrowserState(root: snapshot("/", [folder]))
        _ = state.select(folder.id, in: 0); _ = state.push(snapshot("/a", []), from: 0, directory: folder.id)
        XCTAssertTrue(state.replaceSnapshot(snapshot("/", []), at: 0))
        XCTAssertEqual(state.columns.count, 1); XCTAssertEqual(state.activeColumn, 0)
        XCTAssertTrue(state.columns[0].selection.selected.isEmpty); XCTAssertNil(state.previewTarget)
        XCTAssertFalse(state.replaceSnapshot(snapshot("/wrong", []), at: 0))
    }
    func testPopInvalidInputsAndSameSelection() {
        let folder = entry("/a", .directory)
        var state = ColumnBrowserState(root: snapshot("/", [folder]))
        XCTAssertEqual(state.select(folder.id, in: -1), .none)
        XCTAssertEqual(state.select(ItemID(rawValue: "/absent"), in: 0), .none)
        XCTAssertFalse(state.push(snapshot("/a", []), from: 2, directory: folder.id))
        XCTAssertFalse(state.replaceSnapshot(snapshot("/", []), at: 2))
        _ = state.select(folder.id, in: 0); _ = state.push(snapshot("/a", []), from: 0, directory: folder.id)
        _ = state.select(folder.id, in: 0); XCTAssertEqual(state.columns.count, 2)
        state.pop(); state.pop(); XCTAssertEqual(state.columns.count, 1)
    }
    func testRightFocusesExistingColumn() {
        let folder = entry("/a", .directory), file = entry("/a/file")
        var state = ColumnBrowserState(root: snapshot("/", [folder]))
        _ = state.select(folder.id, in: 0)
        _ = state.push(snapshot("/a", [file]), from: 0, directory: folder.id)
        _ = state.select(file.id, in: 1)
        _ = state.select(folder.id, in: 0)
        XCTAssertEqual(state.activeColumn, 0)
        XCTAssertEqual(state.moveRight(), .preview(file.id))
        XCTAssertEqual(state.activeColumn, 1)
    }
    func testBrowserColumnDropsForeignSelection() {
        let folder = entry("/a", .directory)
        let column = BrowserColumn(snapshot: snapshot("/", []), selection: SelectionModel(order: [folder.id], selected: [folder.id]))
        XCTAssertTrue(column.selection.selected.isEmpty)
    }
}
