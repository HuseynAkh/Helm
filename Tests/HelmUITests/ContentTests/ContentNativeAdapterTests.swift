// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest
import HelmCore
@testable import HelmUI

/// MAC-ONLY: these delegate checks require the macOS HelmUITests target to be enabled.
@MainActor
final class ContentNativeAdapterTests: XCTestCase {
    func testRenameKeysAreConsumedLocallyAndOtherSelectorsFallThrough() {
        let session = InlineRenameSession(token: 1, item: ItemID(url: URL(fileURLWithPath: "/a.txt")),
                                          originalName: "a.txt", text: "a.txt", selectedRange: NSRange(location: 0, length: 1))
        var keys: [InlineRenameKey] = []
        let parent = RenameTextField(session: session, pending: false, edit: { _ in }, key: { keys.append($0) })
        let coordinator = parent.makeCoordinator()
        let field = NSTextField()
        let editor = NSTextView()
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertEqual(keys, [.escape, .returnKey, .tab])
    }
    func testLiveEditsForwardTextAndPendingRequestRestoresSubmittedText() {
        let session = InlineRenameSession(token: 1, item: ItemID(url: URL(fileURLWithPath: "/a")),
                                          originalName: "a", text: "a", selectedRange: NSRange(location: 0, length: 1))
        var edits: [String] = []
        let coordinator = RenameTextField(session: session, pending: false, edit: { edits.append($0) }, key: { _ in }).makeCoordinator()
        let field = NSTextField()
        field.stringValue = "invalid/name"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(edits, ["invalid/name"])
        coordinator.parent = RenameTextField(session: session, pending: true, edit: { edits.append($0) }, key: { _ in })
        field.stringValue = "changed while pending"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(field.stringValue, "a")
        XCTAssertEqual(edits.count, 1)
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nil))
        XCTAssertEqual(edits.count, 1)
    }
}
#endif
