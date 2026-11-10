import Foundation
import XCTest
@testable import HelmCore

final class AddressBarEditorTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/test")
    private let current = URL(fileURLWithPath: "/work")
    private func editor() -> AddressEditorState {
        AddressEditor.reduce(AddressEditorState(currentDirectory: current, home: home), .beginEditing).0
    }
    private func row(_ name: String, directory: Bool = true) -> CompletionRow {
        CompletionRow(name: name, path: "/work/" + name, isDirectory: directory)
    }
    private func populate(_ state: AddressEditorState, _ rows: [CompletionRow]) -> AddressEditorState {
        AddressEditor.reduce(state, .completions(state.generation, rows)).0
    }

    func testBeginEditingListsImmediatelyWithTrailingSlash() throws {
        let (state, effects) = AddressEditor.reduce(AddressEditorState(currentDirectory: current, home: home), .beginEditing)
        XCTAssertEqual(state.text, "/work/")
        XCTAssertTrue(state.isEditing)
        XCTAssertTrue(state.caretAtEnd)
        guard case .requestCompletions(let request) = try XCTUnwrap(effects.last) else { return XCTFail("Expected request") }
        XCTAssertTrue(request.isSlashBrowsing)
        XCTAssertEqual(request.generation, state.generation)
    }

    func testRepeatedBeginPreservesTextAndClosedEditorRetainsHiddenSetting() {
        let typed = AddressEditor.reduce(editor(), .textChanged("/unfinished")).0
        let (reentered, effects) = AddressEditor.reduce(typed, .beginEditing)
        XCTAssertEqual(reentered, typed)
        XCTAssertTrue(effects.isEmpty)
        let closed = AddressEditorState(currentDirectory: current, home: home)
        let updated = AddressEditor.reduce(closed, .showHiddenChanged(true)).0
        XCTAssertTrue(updated.showHidden)
        XCTAssertFalse(updated.isEditing)
        XCTAssertTrue(AddressEditor.reduce(updated, .beginEditing).0.showHidden)
    }

    func testArrowsClampAndSelectionUpdatesGhost() {
        var state = AddressEditor.reduce(editor(), .textChanged("/work/D")).0
        state = populate(state, [row("Docs"), row("Downloads")])
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertEqual(state.ghostSuffix, "ocs/")
        state = AddressEditor.reduce(state, .arrowUp).0
        XCTAssertEqual(state.selectedIndex, 0)
        state = AddressEditor.reduce(state, .arrowDown).0
        XCTAssertEqual(state.ghostSuffix, "ownloads/")
        state = AddressEditor.reduce(state, .arrowDown).0
        XCTAssertEqual(state.selectedIndex, 1)
        state = AddressEditor.reduce(state, .select(0)).0
        XCTAssertEqual(state.ghostSuffix, "ocs/")
        state = AddressEditor.reduce(state, .select(900)).0
        XCTAssertNil(state.selectedRow)
        XCTAssertNil(state.ghostSuffix)
    }

    func testTabTabTabDrillShowsLastDirectoryAndDiscardsLateResults() {
        var state = editor()
        var oldGenerations: [Generation] = []
        for path in ["/work/a", "/work/a/b", "/work/a/b/c"] {
            oldGenerations.append(state.generation)
            let row = CompletionRow(name: "child", path: path, isDirectory: true)
            state = populate(state, [row])
            let (accepted, effects) = AddressEditor.reduce(state, .tab)
            state = accepted
            XCTAssertEqual(state.text, path + "/")
            XCTAssertFalse(state.isPopupVisible)
            XCTAssertTrue(effects.contains { effect in
                if case .requestCompletions(let request) = effect {
                    return request.parent.path == path && request.generation == state.generation
                }
                return false
            })
        }
        state = populate(state, [row("last")])
        for old in oldGenerations {
            XCTAssertEqual(AddressEditor.reduce(state, .completions(old, [row("stale")])).0, state)
        }
        XCTAssertEqual(state.rows.first?.name, "last")
    }

    func testParentTabNormalizesRootAndFileTabOnlyFills() {
        var state = populate(editor(), [CompletionRow(name: "..", path: "/", isDirectory: true, isParentLink: true)])
        state = AddressEditor.reduce(state, .tab).0
        XCTAssertEqual(state.text, "/")
        XCTAssertTrue(state.isEditing)
        state = populate(state, [row("file.txt", directory: false)])
        let (filled, effects) = AddressEditor.reduce(state, .tab)
        XCTAssertEqual(filled.text, "/work/file.txt")
        XCTAssertFalse(filled.isPopupVisible)
        XCTAssertTrue(filled.isEditing)
        XCTAssertEqual(effects, [.cancelCompletions])
    }

    func testTabWithoutRowsRequestsAndBacktabDoesNothing() {
        let state = editor()
        XCTAssertEqual(AddressEditor.reduce(state, .backtab).0, state)
        let (_, effects) = AddressEditor.reduce(state, .tab)
        XCTAssertEqual(effects.count, 2)
        let empty = AddressEditor.reduce(state, .textChanged("")).0
        XCTAssertEqual(AddressEditor.reduce(empty, .tab).1, [.cancelCompletions])
    }

    func testReturnPrefixAcceptsButSlashCommitsField() {
        var state = AddressEditor.reduce(editor(), .textChanged("/work/Do")).0
        state = populate(state, [row("Docs")])
        let (prefix, prefixEffects) = AddressEditor.reduce(state, .returnKey)
        XCTAssertEqual(prefix.pendingCommit?.path, "/work/Docs")
        XCTAssertEqual(prefixEffects.last, .validate(URL(fileURLWithPath: "/work/Docs", isDirectory: true), prefix.generation))
        state = populate(editor(), [CompletionRow(name: "..", path: "/", isDirectory: true, isParentLink: true)])
        let (slash, _) = AddressEditor.reduce(state, .returnKey)
        XCTAssertEqual(slash.pendingCommit?.path, current.path)
    }

    func testTypingPasteAndEmptyInvalidateStaleRowsBeforeReturn() {
        let state = populate(editor(), [row("old")])
        for action: AddressEditorAction in [.textChanged("/new"), .paste("/new"), .textChanged("")] {
            let changed = AddressEditor.reduce(state, action).0
            XCTAssertTrue(changed.rows.isEmpty)
            XCTAssertFalse(changed.isPopupVisible)
            XCTAssertGreaterThan(changed.generation, state.generation)
            XCTAssertEqual(AddressEditor.reduce(changed, .completions(state.generation, [row("old")])).0, changed)
            let (commit, _) = AddressEditor.reduce(changed, .returnKey)
            XCTAssertEqual(commit.pendingCommit?.path, changed.text.isEmpty ? home.path : "/new")
        }
    }

    func testEscapeTwiceAndOutsideCancelIgnoreLateResults() {
        let state = populate(editor(), [row("Docs")])
        let (dismissed, _) = AddressEditor.reduce(state, .escape)
        XCTAssertTrue(dismissed.isEditing)
        XCTAssertFalse(dismissed.isPopupVisible)
        XCTAssertNil(dismissed.ghostSuffix)
        XCTAssertEqual(AddressEditor.reduce(dismissed, .completions(state.generation, [row("late")])).0, dismissed)
        let (cancelled, effects) = AddressEditor.reduce(dismissed, .escape)
        XCTAssertFalse(cancelled.isEditing)
        XCTAssertEqual(effects.last, .cancelled)
        XCTAssertFalse(AddressEditor.reduce(state, .cancel).0.isEditing)
        XCTAssertEqual(AddressEditor.reduce(cancelled, .textChanged("ignored")).0, cancelled)
    }

    func testRightArrowRequiresCaretAtEndAndCanonicalizesTilde() {
        var state = AddressEditor.reduce(editor(), .textChanged("~/doc")).0
        state = populate(state, [CompletionRow(name: "Documents", path: home.path + "/Documents", isDirectory: true)])
        let moved = AddressEditor.reduce(state, .caretChanged(atEnd: false)).0
        XCTAssertNil(moved.ghostSuffix)
        XCTAssertEqual(AddressEditor.reduce(moved, .arrowRight).0, moved)
        let accepted = AddressEditor.reduce(state, .arrowRight).0
        XCTAssertEqual(accepted.text, "~/Documents/")
        XCTAssertTrue(accepted.isEditing)
    }

    func testValidationSuccessFileDirectoryAndFailurePreservesText() throws {
        for kind: AddressCommitKind in [.directory, .file, .invalid] {
            var state = AddressEditor.reduce(editor(), .textChanged("/target")).0
            state = AddressEditor.reduce(state, .returnKey).0
            let url = try XCTUnwrap(state.pendingCommit)
            let (result, effects) = AddressEditor.reduce(state, .validated(state.generation, url, kind))
            if kind == .invalid {
                XCTAssertEqual(result.text, "/target")
                XCTAssertTrue(result.isEditing)
                XCTAssertNotNil(result.error)
                XCTAssertEqual(effects, [.invalidPathFeedback])
            } else {
                XCTAssertFalse(result.isEditing)
                XCTAssertEqual(effects, [kind == .directory ? .navigate(url) : .openFile(url)])
            }
            XCTAssertNil(result.pendingCommit)
        }
    }

    func testValidationAndFailureRepliesCannotOverwriteNewEdits() throws {
        var state = AddressEditor.reduce(editor(), .returnKey).0
        let token = state.generation
        let url = try XCTUnwrap(state.pendingCommit)
        XCTAssertEqual(AddressEditor.reduce(state, .completions(token, [row("late")])).0, state)
        XCTAssertEqual(AddressEditor.reduce(state, .validated(token, home, .directory)).0, state)
        state = AddressEditor.reduce(state, .textChanged("/new")).0
        XCTAssertEqual(AddressEditor.reduce(state, .validated(token, url, .directory)).0, state)
        XCTAssertEqual(AddressEditor.reduce(state, .completionFailed(token, "old failure")).0, state)
        let failed = AddressEditor.reduce(state, .completionFailed(state.generation, "Missing directory")).0
        XCTAssertEqual(failed.error, "Missing directory")
        XCTAssertTrue(failed.rows.isEmpty)
        XCTAssertTrue(failed.isEditing)
        let corrected = AddressEditor.reduce(failed, .textChanged("/corrected")).0
        XCTAssertNil(corrected.error)
    }

    func testHiddenChangeRefreshesMouseAcceptAndNulCommitFeedback() {
        var state = populate(editor(), [row("Docs")])
        state = AddressEditor.reduce(state, .acceptSelection).0
        XCTAssertEqual(state.text, "/work/Docs/")
        let (hidden, effects) = AddressEditor.reduce(state, .showHiddenChanged(true))
        XCTAssertTrue(hidden.showHidden)
        XCTAssertTrue(effects.contains { if case .requestCompletions(let request) = $0 { return request.showHidden }; return false })
        state = AddressEditor.reduce(hidden, .paste("bad\0path")).0
        let (invalid, invalidEffects) = AddressEditor.reduce(state, .returnKey)
        XCTAssertNotNil(invalid.error)
        XCTAssertTrue(invalid.isEditing)
        XCTAssertEqual(invalidEffects.last, .invalidPathFeedback)
    }
}
