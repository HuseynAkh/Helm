#if os(macOS)
import AppKit
import XCTest
import HelmCore
@testable import HelmUI

/// Records what the views hand back to the window when a rename ends.
@MainActor private final class HuntOperationsRenameHost: FileContentHost {
    let icons = IconCache()
    var gridIconSize = 96
    var fileTextSize: CGFloat = 14
    var starred: Set<ItemID> = []
    var finished: [(entry: FileEntry, newName: String?)] = []
    func contentSelectionChanged(_ ids: Set<ItemID>) {}
    func contentOpen(_ entries: [FileEntry], newTab: Bool) {}
    func contentMenu(for entries: [FileEntry]) -> NSMenu? { nil }
    func contentRenameFinished(_ entry: FileEntry, newName: String?) { finished.append((entry, newName)) }
    func contentSetSort(_ sort: ItemSort) {}
    func contentExpand(_ id: ItemID) {}
    func contentCollapse(_ id: ItemID) {}
    func contentDropOperation(_ info: NSDraggingInfo, onto entry: FileEntry?) -> NSDragOperation { [] }
    func contentPerformDrop(_ info: NSDraggingInfo, onto entry: FileEntry?) -> Bool { false }
    func contentDragEnded() {}
    func contentKeyDown(_ event: NSEvent) -> Bool { false }
    func contentActivated() {}
}

/// An app's name is shown without ".app", as everywhere on a Mac. Renaming it in place must still hand back a
/// name that keeps it an app: pressing Return without typing changes nothing (the window treats the same name
/// as no rename), and a typed name keeps ".app", as in Finder.
@MainActor final class HuntOperationsRenameTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/hunt-rename", isDirectory: true)
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: root) }
    private var app: FileEntry { FileEntry(url: root.appendingPathComponent("Tool.app", isDirectory: true), kind: .package) }

    private func tab() -> TabState {
        var tab = TabState(location: .directory(root), homeDirectory: root)
        tab.isLoading = true
        let snapshot = SnapshotBuilder.build(location: .directory(root), entries: [app, FileEntry(url: root.appendingPathComponent("notes.txt"))])
        tab = TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, snapshot), context: context).0
        return TabReducer.reduce(tab, .setSelection([app.id], source: .user), context: context).0
    }

    /// Starts renaming, then ends it the way a click elsewhere or Return does, after `typing` (nil types nothing).
    private func rename(in content: FileContentPresenting, host: HuntOperationsRenameHost, typing: String?) -> String? {
        ListMotion.enabled = false
        defer { ListMotion.enabled = true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content.view
        content.host = host
        content.render(tab(), force: true)
        window.layoutIfNeeded()
        content.beginRename(app)
        guard let editor = window.firstResponder as? NSTextView else { XCTFail("renaming didn't start"); return nil }
        if let typing {
            editor.string = typing
            editor.didChangeText()
        }
        window.makeFirstResponder(nil)
        return host.finished.last?.newName ?? "<not finished>"
    }

    func testListReturnWithoutTypingKeepsTheApp() {
        let host = HuntOperationsRenameHost()
        let name = rename(in: FileListController(), host: host, typing: nil)
        XCTAssertEqual(name, "Tool.app", "nothing was typed, so the app keeps its name; the window would rename it to “\(name ?? "")”")
    }

    func testGridReturnWithoutTypingKeepsTheApp() {
        let host = HuntOperationsRenameHost()
        let name = rename(in: FileGridController(), host: host, typing: nil)
        XCTAssertEqual(name, "Tool.app", "nothing was typed, so the app keeps its name; the window would rename it to “\(name ?? "")”")
    }

    func testATypedNameKeepsTheAppAnApp() {
        let host = HuntOperationsRenameHost()
        let name = rename(in: FileListController(), host: host, typing: "Hammer")
        XCTAssertEqual(name, "Hammer.app", "the field shows the name without .app, so the .app stays on")
    }

    /// Typing the ending yourself doesn't double it, an emptied field stays empty so it's refused, and names that show
    /// in full, such as a document's, are used as typed.
    func testTheHiddenEndingIsAddedOnlyWhenItsMissing() {
        XCTAssertEqual(RenameEditor.fullName(for: "Widget.app", entry: app), "Widget.app")
        XCTAssertEqual(RenameEditor.fullName(for: "Widget.APP", entry: app), "Widget.APP")
        XCTAssertEqual(RenameEditor.fullName(for: "", entry: app), "")
        XCTAssertEqual(RenameEditor.fullName(for: "Tool", entry: app), "Tool.app")
        let notes = FileEntry(url: root.appendingPathComponent("notes.txt"))
        XCTAssertEqual(RenameEditor.fullName(for: "notes", entry: notes), "notes")
        let folder = FileEntry(url: root.appendingPathComponent("Old.app", isDirectory: true), kind: .directory)
        XCTAssertEqual(RenameEditor.fullName(for: "New", entry: folder), "New", "a folder named .app shows its full name")
    }
}
#endif
