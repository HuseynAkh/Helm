#if os(macOS)
import AppKit
import SwiftUI
import HelmCore
import HelmUI

/// Smoke verbs for the views fixes: they read and drive the list, the grid, the status bar and the sort menu through
/// AppKit, the way a person would see and use them. Every path they touch must be inside the fixture home.
extension HostSmokeDriver {
    static func performHuntViewsVerb(_ verb: String, _ argument: String, step: String,
                                     window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "hunt-write-megabytes":
            // "<path> <megabytes>": a file of that size, inside the fixture home only, to change the disk's free space.
            // The size is the last word, so the path can have spaces.
            guard let space = argument.lastIndex(of: " "), let megabytes = Int(argument[argument.index(after: space)...]),
                  insideFixture(String(argument[..<space]), window) else { check(false, step, "usage"); return true }
            let path = String(argument[..<space])
            let chunk = Data(count: 1_048_576)
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: path) else { check(false, step, "can't write"); return true }
            for _ in 0..<megabytes { handle.write(chunk) }
            try? handle.synchronize()
            try? handle.close()
            check(true, step)
        case "hunt-remove":
            // Removes a file this run made, inside the fixture home only.
            guard insideFixture(argument, window) else { check(false, step, "not in the fixture home"); return true }
            check((try? FileManager.default.removeItem(atPath: argument)) != nil, step)
        case "hunt-status-has":
            // The status bar's words contain these.
            let text = statusText(window) ?? "<no status bar>"
            check(text.contains(argument), step, text)
        case "hunt-free-save":
            // Keeps the status bar's free-space words, such as "460.35 GB free".
            savedFree = freeWords(window)
            check(savedFree != nil, step, statusText(window) ?? "<no status bar>")
        case "hunt-free-changed":
            let words = freeWords(window)
            check(words != nil && words != savedFree, step, "still “\(words ?? "")” in “\(statusText(window) ?? "")”")
        case "hunt-option-arrow":
            // left or right with Option held, pressed in the list: Finder's "open or close every folder inside".
            guard let outline = filesOutline(window), let frame = window.window else { check(false, step, "no list"); return true }
            let right = argument == "right"
            guard let scalar = UnicodeScalar(UInt32(right ? NSRightArrowFunctionKey : NSLeftArrowFunctionKey)) else { return true }
            let text = String(Character(scalar))
            frame.makeFirstResponder(outline)
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .numericPad, .function],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: frame.windowNumber,
                                            context: nil, characters: text, charactersIgnoringModifiers: text,
                                            isARepeat: false, keyCode: right ? 124 : 123) {
                outline.keyDown(with: event)
            }
            await wait(seconds: 0.8)
        case "hunt-disclose-all":
            // An Option-click on the triangle of the list row with this name: the folder and every folder inside open.
            guard let outline = filesOutline(window), let row = listRow(named: argument, in: outline), let item = outline.item(atRow: row) else {
                check(false, step, "no such row"); return true
            }
            outline.expandItem(item, expandChildren: true)
            await wait(seconds: 0.8)
        case "hunt-cell-is":
            // "<file name>|<column>|<words>": what a list cell shows. Columns: name, size, dateModified, kind, location.
            let bits = argument.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard bits.count == 3, let words = cellWords(bits[0], column: bits[1], window: window) else {
                check(false, step, "no such row"); return true
            }
            check(words == bits[2], step, words)
        case "hunt-kind-finder":
            // "<path>": the Kind cell of that file's row says what Finder's Kind says, in this Mac's language.
            let url = URL(fileURLWithPath: argument)
            let finder = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? "<none>"
            let words = cellWords(url.lastPathComponent, column: "kind", window: window) ?? "<no such row>"
            check(words == finder, step, "\(words), Finder says \(finder)")
        case "hunt-column-on-screen":
            // "<column>": at least most of that list column is inside the list's visible width.
            guard let outline = filesOutline(window) else { check(false, step, "no list"); return true }
            let column = outline.column(withIdentifier: NSUserInterfaceItemIdentifier(argument))
            guard column >= 0 else { check(false, step, "no such column"); return true }
            let rect = outline.rect(ofColumn: column)
            let visible = outline.visibleRect.intersection(rect).width
            check(rect.width > 0 && visible >= rect.width * 0.8, step,
                  "\(Int(visible)) of \(Int(rect.width)) points on show; the list shows \(Int(outline.visibleRect.minX))–\(Int(outline.visibleRect.maxX)), the column is at \(Int(rect.minX))–\(Int(rect.maxX))")
        case "hunt-column-menu-is":
            // "Size:on,Modified:on,Kind:on": the ticks in the list's column menu, as a right-click on a heading shows it.
            guard let outline = filesOutline(window), let menu = outline.headerView?.menu else { check(false, step, "no column menu"); return true }
            menu.delegate?.menuNeedsUpdate?(menu)
            let shown = menu.items.map { "\($0.title):\($0.state == .on ? "on" : "off")" }.joined(separator: ",")
            let columns = outline.tableColumns.filter { !$0.isHidden }.map(\.title).joined(separator: "|")
            check(shown == argument, step, "\(shown) with columns on show \(columns)")
        case "hunt-sort-menu-is":
            // "Best Match": the rows View › Sort By ticks, as the menu bar fills it.
            let menu = NSMenu()
            window.fillSortItems(in: menu)
            let ticked = menu.items.filter { $0.state == .on }.map(\.title).joined(separator: ",")
            check(ticked == argument, step, ticked)
        case "hunt-scroll-top":
            // Scrolls the files on show to the top, as a person would with the trackpad.
            guard let scroll = filesScrollView(window) else { check(false, step, "no files"); return true }
            scroll.documentView?.scroll(.zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            await wait(seconds: 0.2)
            scrolledTop = scroll.contentView.bounds.origin.y
        case "hunt-scrolled-top":
            guard let scroll = filesScrollView(window), let top = scrolledTop else { check(false, step, "no files"); return true }
            let y = scroll.contentView.bounds.origin.y
            check(abs(y - top) < 1, step, "scrolled to \(y), top is \(top)")
        case "hunt-scrolled-away":
            // The files on show are scrolled away from the top, as after a selection was brought into view.
            guard let scroll = filesScrollView(window), let top = scrolledTop else { check(false, step, "no files"); return true }
            let y = scroll.contentView.bounds.origin.y
            check(abs(y - top) >= 1, step, "scrolled to \(y), top is \(top)")
        case "hunt-rename-type":
            // Types into the open rename field and leaves it open.
            guard let editor = window.window?.firstResponder as? NSTextView else { check(false, step, "no rename field"); return true }
            editor.selectAll(nil)
            editor.insertText(argument, replacementRange: editor.selectedRange())
            await wait(seconds: 0.2)
        case "hunt-rename-cancel":
            // Escape in the open rename field.
            guard let editor = window.window?.firstResponder as? NSTextView else { check(false, step, "no rename field"); return true }
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            await wait(seconds: 0.3)
        case "hunt-name-shown":
            // "<file name>=<words>": the words the list's name cell shows for a row.
            let bits = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard bits.count == 2, let words = cellWords(bits[0], column: "name", window: window) else { check(false, step, "no such row"); return true }
            check(words == bits[1], step, words)
        default: return false
        }
        return true
    }

    private static var savedFree: String?
    private static var scrolledTop: CGFloat?

    /// Only paths in the throwaway fixture home, however /tmp is spelled, and never through "..".
    private static func insideFixture(_ path: String, _ window: BrowserWindowController) -> Bool {
        let parts = path.split(separator: "/")
        return path.hasPrefix("/") && !parts.contains("..") && path.contains("/.build/host-smoke/fixture/home/")
            && window.dependencies.home.path.contains("/.build/host-smoke/fixture/home")
    }

    /// The status bar's free-space words, such as "460.35 GB free".
    private static func freeWords(_ window: BrowserWindowController) -> String? {
        statusText(window)?.components(separatedBy: "  •  ").last { $0.hasSuffix(" free") }
    }
    /// The status bar's words, read from the view on show.
    private static func statusText(_ window: BrowserWindowController) -> String? {
        guard let content = window.window?.contentView,
              let host = firstView(in: content, where: { $0 is NSHostingView<StatusBarView> }) as? NSHostingView<StatusBarView> else { return nil }
        return Mirror(reflecting: host.rootView).children.first { $0.label == "text" }?.value as? String
    }
    private static func firstView(in view: NSView, where match: (NSView) -> Bool) -> NSView? {
        for child in view.subviews {
            if match(child) { return child }
            if let found = firstView(in: child, where: match) { return found }
        }
        return nil
    }
    /// The files' list, when the list is on show.
    private static func filesOutline(_ window: BrowserWindowController) -> NSOutlineView? {
        guard let content = window.window?.contentView else { return nil }
        return firstView(in: content) { ($0 as? NSOutlineView)?.accessibilityLabel() == "Files" && !$0.isHiddenOrHasHiddenAncestor } as? NSOutlineView
    }
    /// The files' grid, when the grid is on show.
    private static func filesCollection(_ window: BrowserWindowController) -> NSCollectionView? {
        guard let content = window.window?.contentView else { return nil }
        return firstView(in: content) { ($0 as? NSCollectionView)?.accessibilityLabel() == "Files" && !$0.isHiddenOrHasHiddenAncestor } as? NSCollectionView
    }
    private static func filesScrollView(_ window: BrowserWindowController) -> NSScrollView? {
        (filesOutline(window) as NSView?)?.enclosingScrollView ?? (filesCollection(window) as NSView?)?.enclosingScrollView
    }
    /// The words a list cell shows on the row of the file with this name.
    private static func cellWords(_ name: String, column identifier: String, window: BrowserWindowController) -> String? {
        guard let outline = filesOutline(window), let row = listRow(named: name, in: outline, byFileName: true) else { return nil }
        let column = outline.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
        let cell = column >= 0 ? outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView : nil
        return cell?.textField?.stringValue
    }
    private static func nameCell(row: Int, in outline: NSOutlineView) -> NSTableCellView? {
        let column = outline.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard column >= 0 else { return nil }
        return outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
    }
    /// The row showing this name, or with `byFileName` the row whose file has it (an app's row shows no ".app").
    private static func listRow(named name: String, in outline: NSOutlineView, byFileName: Bool = false) -> Int? {
        for row in 0..<outline.numberOfRows {
            guard let cell = nameCell(row: row, in: outline) else { continue }
            if !byFileName, cell.textField?.stringValue == name { return row }
            if byFileName, cell.accessibilityLabel() == name { return row }
        }
        return nil
    }
}
#endif
