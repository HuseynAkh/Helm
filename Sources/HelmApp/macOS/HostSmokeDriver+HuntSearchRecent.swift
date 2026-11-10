#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for Search and Recent. They only read the window or send it keys, as a person would, through public
/// AppKit calls; files are made only inside the fixture home.
extension HostSmokeDriver {
    static func performHuntSearchRecentVerb(_ verb: String, _ argument: String, step: String,
                                            window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "hunt-key":
            // "return" or "f2", pressed in the files, which take the keys first, as a click on them does.
            window.focusFilesForTesting()
            await wait(seconds: 0.1)
            check(sendKey(argument, to: window), step, "no such key, or nothing has the keys")
            await wait(seconds: 0.3)
        case "hunt-renaming":
            // "yes" while a rename field is open, "no" otherwise.
            let renaming = window.isRenamingForTesting
            check(renaming == (argument == "yes"), step, renaming ? "yes" : "no")
        case "hunt-state-is":
            // The words the content area shows in place of the listing, or "none".
            let title = window.contentStateForTesting?.title ?? "none"
            check(title == argument, step, title)
        case "hunt-snapshot-sort-is":
            // The order the items on show are really in, as the store built them.
            let field = window.activeTab?.snapshot.sort.field.rawValue ?? "none"
            check(field == argument, step, field)
        case "hunt-header-sort-is":
            // The sort button's words, when it shows them.
            let words = window.headerSortTitleForTesting.isEmpty ? "none" : window.headerSortTitleForTesting
            check(words == argument, step, words)
        case "hunt-best-match":
            // Presses Best Match, as its row in the sort popover and View › Sort By do during a search.
            window.pressSort(.relevance)
            await wait(seconds: 0.4)
        case "hunt-sort-keep":
            // Notes the folder's sort, whatever earlier steps left it as, for hunt-sort-kept.
            keptSort = window.activeTab?.sort
        case "hunt-sort-kept":
            // The folder's sort is still the one noted, and outside a search the items on show are in it.
            guard let keptSort, let tab = window.activeTab else { check(false, step, "nothing noted"); return true }
            check(tab.sort == keptSort && (tab.search != nil || tab.snapshot.sort == keptSort), step,
                  "\(tab.sort.field.rawValue), showing \(tab.snapshot.sort.field.rawValue)")
        case "hunt-not-best-match":
            // Neither the folder's sort nor the sort button is Best Match, which only orders search results.
            let field = window.activeTab?.sort.field.rawValue ?? "none"
            let words = window.headerSortTitleForTesting
            check(field != ItemSort.Field.relevance.rawValue && words != SortChoice.bestMatch.title, step, "\(field), \(words)")
        case "hunt-list-select-row":
            // Selects one row of the list by its place on screen, headings counted, as a click on that row does.
            guard let outline = filesList(window), let row = Int(argument), row < outline.numberOfRows else {
                check(false, step, "no list, or no such row"); return true
            }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await wait(seconds: 0.4)
        case "hunt-list-selected-rows":
            // The rows the list shows selected, by their place on screen, such as "1" or "2,5".
            let rows = filesList(window)?.selectedRowIndexes.map(String.init).joined(separator: ",") ?? "no list"
            check(rows == argument, step, rows)
        case "hunt-list-disclose-row":
            // Clicks the disclosure triangle on one row of the list, by its place on screen.
            guard let outline = filesList(window), let row = Int(argument), row < outline.numberOfRows,
                  let rowView = outline.rowView(atRow: row, makeIfNecessary: true),
                  let button = firstView(in: rowView, where: { ($0 as? NSButton)?.identifier == NSOutlineView.disclosureButtonIdentifier }) as? NSButton
            else { check(false, step, "no such row, or no triangle"); return true }
            button.performClick(nil)
            await wait(seconds: 0.6)
        case "hunt-list-open-rows":
            // The rows whose folders the list shows open, by their place on screen.
            guard let outline = filesList(window) else { check(false, step, "no list"); return true }
            let open = (0..<outline.numberOfRows).filter { outline.isItemExpanded(outline.item(atRow: $0)) }.map(String.init).joined(separator: ",")
            check(open == argument, step, open.isEmpty ? "none" : open)
        default: return false
        }
        return true
    }

    /// The folder's sort noted by hunt-sort-keep.
    private static var keptSort: ItemSort?

    private static func sendKey(_ name: String, to window: BrowserWindowController) -> Bool {
        let keys: [String: (code: UInt16, text: String)] = [
            "return": (36, "\r"), "f2": (120, String(Character(UnicodeScalar(UInt32(NSF2FunctionKey)) ?? " ")))]
        guard let key = keys[name], let frameWindow = window.window, let responder = frameWindow.firstResponder,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: name == "f2" ? .function : [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: frameWindow.windowNumber,
                                           context: nil, characters: key.text, charactersIgnoringModifiers: key.text,
                                           isARepeat: false, keyCode: key.code) else { return false }
        responder.keyDown(with: event)
        return true
    }

    /// The list of files, when the list is on show.
    private static func filesList(_ window: BrowserWindowController) -> NSOutlineView? {
        firstView(in: window.window?.contentView, where: { $0 is NSOutlineView && $0.accessibilityLabel() == "Files" && !$0.isHiddenOrHasHiddenAncestor }) as? NSOutlineView
    }

    private static func firstView(in root: NSView?, where matches: (NSView) -> Bool) -> NSView? {
        guard let root else { return nil }
        if matches(root) { return root }
        for child in root.subviews { if let found = firstView(in: child, where: matches) { return found } }
        return nil
    }
}
#endif
