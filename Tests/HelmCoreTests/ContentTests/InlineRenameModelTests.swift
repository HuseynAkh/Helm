// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class InlineRenameModelTests: XCTestCase {
    private func entry(_ name: String, kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/root").appendingPathComponent(name), kind: kind)
    }
    func testStemSelectionUsesUTF16AndLastExtension() {
        for (name, stem) in [("photo.jpg", "photo"), ("archive.tar.gz", "archive.tar"),
                             (".hidden", ".hidden"), (".config.json", ".config"),
                             ("plain", "plain"), ("😀é.txt", "😀é"), ("trailing.", "trailing")] {
            var model = InlineRenameModel(); _ = model.begin(entry(name))
            XCTAssertEqual(model.editing?.selectedRange, NSRange(location: 0, length: stem.utf16.count))
        }
        var model = InlineRenameModel(); _ = model.begin(entry("folder.ext", kind: .directory))
        XCTAssertEqual(model.editing?.selectedRange.length, 10)
    }
    func testLiveValidationAllErrorsAndColon() {
        var model = InlineRenameModel(); let token = model.begin(entry("a"))
        let cases: [(String, FileNameError)] = [("  ", .empty), ("a/b", .separator), ("a\0b", .nul),
                                               (".", .dot), ("..", .dot), (String(repeating: "é", count: 128), .tooLong)]
        for (text, error) in cases {
            model.edit(text, session: token)
            XCTAssertEqual(model.editing?.error, .invalid(error))
            XCTAssertFalse(model.editing?.error?.message.isEmpty ?? true)
            XCTAssertNil(model.handle(.returnKey, session: token, visibleOrder: [entry("a").id]))
        }
        model.edit("  a:b  ", session: token); XCTAssertNil(model.editing?.error)
        XCTAssertEqual(model.handle(.returnKey, session: token, visibleOrder: [entry("a").id])?.name.value, "a:b")
    }
    func testReturnCommitAndDuplicateSuppression() throws {
        let file = entry("a")
        var model = InlineRenameModel(); let token = model.begin(file)
        model.edit("b", session: token)
        let request = try XCTUnwrap(model.handle(.returnKey, session: token, visibleOrder: [file.id]))
        XCTAssertEqual(request.item, file.id); XCTAssertEqual(request.name.value, "b"); XCTAssertNil(request.nextItem)
        XCTAssertNil(model.handle(.returnKey, session: token, visibleOrder: [file.id]))
        model.edit("ignored", session: token); XCTAssertEqual(model.editing?.text, "b")
        XCTAssertNil(model.complete(request)); XCTAssertNil(model.editing); XCTAssertNil(model.pending)
    }
    func testTabAdvancesOnlyOnSuccessWithoutWrapping() throws {
        let file = entry("a"), next = entry("b")
        var model = InlineRenameModel(); let token = model.begin(file)
        let request = try XCTUnwrap(model.handle(.tab, session: token, visibleOrder: [file.id, next.id]))
        XCTAssertEqual(request.nextItem, next.id); XCTAssertEqual(model.complete(request), next.id)
        let lastToken = model.begin(next)
        XCTAssertNil(model.handle(.tab, session: lastToken, visibleOrder: [file.id, next.id])?.nextItem)
    }
    func testCollisionRetainsTextAndCanRetry() throws {
        let file = entry("a")
        var model = InlineRenameModel(); let token = model.begin(file)
        model.edit("taken", session: token)
        let request = try XCTUnwrap(model.handle(.returnKey, session: token, visibleOrder: [file.id]))
        XCTAssertNil(model.complete(request, error: .collision)); XCTAssertEqual(model.editing?.text, "taken")
        XCTAssertEqual(model.editing?.error, .collision); XCTAssertFalse(InlineRenameError.collision.message.isEmpty)
        model.edit("free", session: token); XCTAssertNil(model.editing?.error)
        let retry = try XCTUnwrap(model.handle(.returnKey, session: token, visibleOrder: [file.id]))
        _ = model.complete(request, error: .collision)
        XCTAssertEqual(model.pending, retry); XCTAssertNil(model.editing?.error)
        _ = model.complete(retry); XCTAssertNil(model.editing)
    }
    func testEscapeAndStaleSessionCannotAffectNewEditor() throws {
        let file = entry("a")
        var model = InlineRenameModel(); let old = model.begin(file)
        let request = try XCTUnwrap(model.handle(.returnKey, session: old, visibleOrder: [file.id]))
        let new = model.begin(entry("b"))
        model.edit("stale", session: old)
        XCTAssertNil(model.handle(.escape, session: old, visibleOrder: []))
        _ = model.complete(request, error: .collision); XCTAssertEqual(model.editing?.text, "b")
        _ = model.handle(.escape, session: new, visibleOrder: []); XCTAssertNil(model.editing)
        model.cancel(); XCTAssertNil(model.pending)
    }
    func testVanishedEntryNeverCommits() {
        let file = entry("a")
        var model = InlineRenameModel(); let token = model.begin(file)
        XCTAssertNil(model.handle(.returnKey, session: token, visibleOrder: [])); XCTAssertNil(model.editing)
        _ = model.begin(file); model.reconcile(existingIDs: [file.id]); XCTAssertNotNil(model.editing)
        model.reconcile(existingIDs: []); XCTAssertNil(model.editing)
    }
    func testIdenticalRetryRejectsEarlierCompletion() throws {
        let file = entry("a")
        var model = InlineRenameModel(); let token = model.begin(file)
        let first = try XCTUnwrap(model.handle(.returnKey, session: token, visibleOrder: [file.id]))
        _ = model.complete(first, error: .collision)
        let retry = try XCTUnwrap(model.handle(.returnKey, session: token, visibleOrder: [file.id]))
        XCTAssertNotEqual(first.attempt, retry.attempt)
        _ = model.complete(first)
        XCTAssertEqual(model.pending, retry); XCTAssertNotNil(model.editing)
        _ = model.complete(retry); XCTAssertNil(model.editing)
    }
    func testPublicValueInitializers() throws {
        let file = entry("a"), name = try XCTUnwrap(ValidFileName("b"))
        let request = InlineRenameRequest(session: 1, item: file.id, name: name)
        XCTAssertEqual(request.name, name)
        let session = InlineRenameSession(token: 1, item: file.id, originalName: "a", text: "b", selectedRange: NSRange(location: 0, length: 1))
        XCTAssertEqual(session.text, "b"); XCTAssertNil(session.error)
    }
}
