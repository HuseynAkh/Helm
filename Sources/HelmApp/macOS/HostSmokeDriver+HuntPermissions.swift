#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for the permissions hunt: what the rest of the window says while a card stands in for the listing, what
/// still could reach the listing hidden under it, the menus' submenu rows and the status bar's words. Used by
/// `scripts/rebuild/smoke.d/hunt-permissions.txt`. Fixture runs only: nothing here touches real files, System Settings,
/// the Dock or the default file viewer.
extension HostSmokeDriver {
    static func performHuntPermissionsVerb(_ verb: String, _ argument: String, step: String,
                                           window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "hunt-title-is":
            // The window's own title, which Mission Control, the Window menu and VoiceOver read out.
            let title = window.window?.title ?? ""
            check(title == argument, step, title)
        case "hunt-proxy-is":
            // The folder the title bar's proxy icon stands for (what a Command-click on the title shows): a path or none.
            let path = window.window?.representedURL.map { PathSpelling.standardPath($0) } ?? "none"
            let wanted = argument == "none" ? "none" : PathSpelling.standardPath(URL(fileURLWithPath: argument))
            check(path == wanted, step, path)
        case "hunt-file-openwith":
            // File › Open With in the menu bar, filled the way AppKit fills it as it opens. The argument is the first
            // row it should show, such as "Select a File" when nothing is selected.
            guard let file = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu,
                  let item = file.items.first(where: { $0.title == "Open With" }), let submenu = item.submenu else {
                check(false, step, "no File › Open With"); return true
            }
            file.update()
            app.menuNeedsUpdate(submenu)
            let rows = submenu.items.filter { !$0.isSeparatorItem && !$0.isAlternate }.map(\.title)
            print("HUNT openwith enabled=\(item.isEnabled) rows=\(rows.prefix(6).joined(separator: " | "))"); fflush(stdout)
            check(rows.first == argument, step, "first row \(rows.first ?? "none"), \(rows.count) rows, parent enabled \(item.isEnabled)")
        case "hunt-services-offered":
            // Whether the window offers the system's Services the selected files (true or false), as the Services
            // menu asks the responder chain before it lists anything.
            let requestor = window.validRequestor(forSendType: .fileURL, returnType: nil)
            let offered = requestor != nil && (requestor as AnyObject) === window
            check(offered == (argument == "true"), step, "\(offered), selected \(window.selectedEntries().map(\.name))")
        case "hunt-search-placeholder":
            // The header search field's resting words, which name the folder a search would look in.
            let fields = allViews(in: window.window?.contentView?.superview).compactMap { $0 as? NSTextField }
            let words = fields.compactMap(\.placeholderString).first { $0.hasPrefix("Search") } ?? "none"
            check(words == argument, step, words)
        case "hunt-context-item", "hunt-context-bg":
            // "<enabled|disabled> <title>": right-clicks the selected row of the list view (or, for -bg, the empty space
            // under the last row), as a person would, and checks one row of the menu that comes up once AppKit has
            // enabled or disabled its items for showing.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            let background = verb == "hunt-context-bg"
            guard bits.count == 2, let window = window.window,
                  let outline = allViews(in: window.contentView).compactMap({ $0 as? NSOutlineView }).first(where: { !$0.isHiddenOrHasHiddenAncestor && $0.tableColumns.count > 1 }),
                  background || outline.selectedRow >= 0 else { check(false, step, "no list view with a selected row"); return true }
            let row = background ? outline.rect(ofRow: max(0, outline.numberOfRows - 1)).offsetBy(dx: 0, dy: outline.rowHeight * 2)
                                 : outline.rect(ofRow: outline.selectedRow)
            let point = outline.convert(NSPoint(x: row.minX + 40, y: row.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let menu = outline.menu(for: event) else { check(false, step, "no menu"); return true }
            menu.update()
            let rows = menu.items.filter { !$0.isSeparatorItem }
            print("HUNT context " + rows.map { "\($0.title)=\($0.isEnabled ? "on" : "off")\($0.hasSubmenu ? "▸\($0.submenu?.items.count ?? 0)" : "")" }.joined(separator: " | "))
            fflush(stdout)
            guard let item = rows.first(where: { $0.title == bits[1] }) else { check(false, step, "no “\(bits[1])” row"); return true }
            check(item.isEnabled == (bits[0] == "enabled"), step,
                  "\(item.isEnabled ? "enabled" : "disabled"), action \(item.action.map(NSStringFromSelector) ?? "none"), \(item.submenu?.items.count ?? 0) rows inside")
        case "hunt-menubar-item":
            // "<enabled|disabled> <menu> › <title>": a row in the menu bar once its menu is brought up to date, as AppKit
            // does just before showing it.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            let path = bits.count == 2 ? bits[1].components(separatedBy: " › ") : []
            guard path.count == 2, let menu = NSApp.mainMenu?.items.first(where: { $0.title == path[0] })?.submenu,
                  let item = menu.items.first(where: { $0.title == path[1] }) else {
                check(false, step, "no such row in " + (NSApp.mainMenu?.items.map(\.title).joined(separator: ",") ?? "")); return true
            }
            menu.update()
            check(item.isEnabled == (bits[0] == "enabled"), step,
                  "\(item.isEnabled ? "enabled" : "disabled"), action \(item.action.map(NSStringFromSelector) ?? "none"), submenu \(item.hasSubmenu)")
        case "hunt-status-says", "hunt-status-lacks":
            // Words the status bar shows now, anywhere in it, or doesn't.
            let text = window.statusTextForTesting
            check(text.contains(argument) == (verb == "hunt-status-says"), step, text)
        default: return false
        }
        return true
    }

    private static func allViews(in root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { allViews(in: $0) }
    }
}
#endif
