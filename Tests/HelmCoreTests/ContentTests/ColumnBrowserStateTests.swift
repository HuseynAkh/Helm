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
    func testDirectoryPushPreviewAndLeft() throws {
        let folder = entry("/root/folder", .directory), file = entry("/root/folder/file")
        var state = ColumnBrowserState(root: snapshot("/root", [folder]))
        let request = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
        XCTAssertEqual(request.directory, folder.id); XCTAssertEqual(request.fromColumn, 0)
        XCTAssertTrue(state.push(snapshot("/root/folder", [file]), request: request))
        XCTAssertEqual(state.activeColumn, 1)
        XCTAssertEqual(state.select(file.id, in: 1), .preview(file.id)); XCTAssertEqual(state.previewTarget, file.id)
        XCTAssertEqual(state.moveRight(), .preview(file.id))
        state.moveLeft(); XCTAssertEqual(state.columns.count, 1); XCTAssertEqual(state.activeColumn, 0)
        XCTAssertEqual(state.columns[0].selection.selected, [folder.id]); XCTAssertNil(state.previewTarget)
        state.moveLeft(); XCTAssertEqual(state.columns.count, 1)
    }
    func testAncestorChangeTruncatesAndRejectsStalePush() throws {
        let a = entry("/root/a", .directory), b = entry("/root/b", .directory)
        var state = ColumnBrowserState(root: snapshot("/root", [a, b]))
        let request = try XCTUnwrap(state.select(a.id, in: 0).loadRequest)
        XCTAssertTrue(state.push(snapshot("/root/a", []), request: request))
        let nextRequest = try XCTUnwrap(state.select(b.id, in: 0).loadRequest); XCTAssertEqual(state.columns.count, 1)
        XCTAssertFalse(state.push(snapshot("/root/a", []), request: request))
        XCTAssertFalse(state.push(snapshot("/wrong", []), request: nextRequest))
        let rightRequest = try XCTUnwrap(state.moveRight().loadRequest)
        XCTAssertEqual(rightRequest.directory, b.id); XCTAssertEqual(rightRequest.fromColumn, 0)
    }
    func testMultiSelectionDoesNotNavigateOrPreview() throws {
        let a = entry("/a"), b = entry("/b")
        var state = ColumnBrowserState(root: snapshot("/", [a, b]))
        _ = state.select(a.id, in: 0)
        XCTAssertEqual(state.select(b.id, in: 0, command: true), .none)
        XCTAssertNil(state.previewTarget); XCTAssertEqual(state.moveRight(), .none)
        XCTAssertEqual(state.select(b.id, in: 0, command: true), .preview(a.id))
    }
    func testPackageAndSymlinkSemantics() throws {
        for kind in [FileEntryKind.package, .symlinkToFile, .danglingSymlink, .alias] {
            let file = entry("/thing", kind)
            var state = ColumnBrowserState(root: snapshot("/", [file]))
            XCTAssertEqual(state.select(file.id, in: 0), .preview(file.id))
        }
        let folder = entry("/link", .symlinkToDirectory)
        var state = ColumnBrowserState(root: snapshot("/", [folder]))
        let request = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
        XCTAssertEqual(request.directory, folder.id); XCTAssertEqual(request.fromColumn, 0)
    }
    func testReloadReconcilesAndTruncates() throws {
        let folder = entry("/a", .directory)
        var state = ColumnBrowserState(root: snapshot("/", [folder]))
        let request = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest); _ = state.push(snapshot("/a", []), request: request)
        XCTAssertTrue(state.replaceSnapshot(snapshot("/", []), at: 0))
        XCTAssertEqual(state.columns.count, 1); XCTAssertEqual(state.activeColumn, 0)
        XCTAssertTrue(state.columns[0].selection.selected.isEmpty); XCTAssertNil(state.previewTarget)
        XCTAssertFalse(state.replaceSnapshot(snapshot("/wrong", []), at: 0))
    }
    func testPopInvalidInputsAndSameSelection() throws {
        let folder = entry("/a", .directory)
        var state = ColumnBrowserState(root: snapshot("/", [folder]))
        XCTAssertEqual(state.select(folder.id, in: -1), .none)
        XCTAssertEqual(state.select(ItemID(rawValue: "/absent"), in: 0), .none)
        XCTAssertFalse(state.push(snapshot("/a", []), request: ColumnLoadRequest(columnID: UUID(), directory: folder.id, fromColumn: 2)))
        XCTAssertFalse(state.replaceSnapshot(snapshot("/", []), at: 2))
        let request = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest); _ = state.push(snapshot("/a", []), request: request)
        _ = state.select(folder.id, in: 0); XCTAssertEqual(state.columns.count, 2)
        state.pop(); state.pop(); XCTAssertEqual(state.columns.count, 1)
    }
    func testRightFocusesExistingColumn() throws {
        let folder = entry("/a", .directory), file = entry("/a/file")
        var state = ColumnBrowserState(root: snapshot("/", [folder]))
        let request = try XCTUnwrap(state.select(folder.id, in: 0).loadRequest)
        _ = state.push(snapshot("/a", [file]), request: request)
        _ = state.select(file.id, in: 1)
        _ = state.select(folder.id, in: 0)
        XCTAssertEqual(state.activeColumn, 0)
        XCTAssertEqual(state.moveRight(), .preview(file.id))
        XCTAssertEqual(state.activeColumn, 1)
    }
    func testBrowserColumnDropsForeignSelection() throws {
        let folder = entry("/a", .directory)
        let column = BrowserColumn(snapshot: snapshot("/", []), selection: SelectionModel(order: [folder.id], selected: [folder.id]))
        XCTAssertTrue(column.selection.selected.isEmpty)
    }
}
