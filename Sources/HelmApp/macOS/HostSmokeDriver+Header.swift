#if os(macOS)
import AppKit
import HelmAgent
import HelmCore
import HelmUI

/// Smoke verbs for header: the top bar and search.
extension HostSmokeDriver {
    static func performHeaderVerb(_ verb: String, _ argument: String, step: String,
                              window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "search-type":
            // Types into the header's search field as a person would, opening it first.
            window.typeIntoSearchForTesting(argument)
            await wait(seconds: 0.1)
            check(window.searchTextForTesting == argument, step, window.searchTextForTesting)
        case "search-key":
            // down, escape, return or tab, pressed in the search field.
            check(window.searchFieldKeyForTesting(argument), step, "the search field hasn't got the caret")
            await wait(seconds: 0.4)
        case "focus-files":
            // What a click on the files does: they take the keys.
            window.focusFilesForTesting()
            await wait(seconds: 0.2)
        case "focus-is":
            // files, search, kinds (the AI search's kind row), path, sidebar, window or other.
            check(window.focusOwnerForTesting == argument, step, window.focusOwnerForTesting)
        case "search-shown":
            check(window.isSearchingForTesting == (argument == "true"), step, "\(window.isSearchingForTesting)")
        case "search-text-is":
            check(window.searchTextForTesting == argument, step, window.searchTextForTesting)
        case "search-looks":
            // typing (the stronger fill) or resting (the path bar's resting fill).
            let looks = window.searchFieldLooksEditingForTesting ? "typing" : "resting"
            check(looks == argument, step, looks)
        case "location-escape":
            // Escape in the location bar until it closes, as its field sends it. With completions showing, the first
            // press only hides them.
            for _ in 0..<2 where window.activeTab?.addressBar.isEditing == true {
                window.store.send(.tab(window.activeTabID, .addressBar(.escape)))
            }
            await wait(seconds: 0.4)
            check(window.activeTab?.addressBar.isEditing == false, step, "still editing")
        case "location-press":
            // location-press path|panel|files|sidebar|header: a click in the middle of that part of the window, as a
            // person's click there, while the location bar may be typed in. It fails when that part isn't on show.
            check(window.pressForTesting(in: argument), step, "\(argument) isn't on show")
            await wait(seconds: 0.3)
        case "location-typing":
            // location-typing true|false: whether the location bar is being typed in, and so watches for presses.
            let typing = window.activeTab?.addressBar.isEditing == true
            let watched = window.watchesLocationPressesForTesting
            check(typing == (argument == "true") && watched == typing, step, "typing \(typing), watching \(watched)")
        case "escape-files":
            window.pressEscapeInFilesForTesting()
            await wait(seconds: 0.4)
        case "header-view-is":
            // The view the header's view button says the tab is in.
            check(window.headerViewModeForTesting.rawValue == argument, step, window.headerViewModeForTesting.rawValue)
        case "header-switch":
            // grid or list: a click on the header's view button that chooses that view, wherever the keys are. It
            // fails when the button offers the other view.
            guard let mode = ViewMode(rawValue: argument) else { check(false, step, "grid or list"); return true }
            let offered = window.headerViewOfferedForTesting
            check(offered == mode, step, "the button offers \(offered.rawValue)")
            window.clickHeaderViewForTesting(mode)
            await wait(seconds: 0.4)
        case "sidebar-width-save":
            // Keeps the sidebar's width, so a later step can check that a narrower window left it alone.
            savedSidebarWidth = window.sidebarWidthForTesting
        case "sidebar-width-kept":
            guard let savedSidebarWidth else { check(false, step, "nothing saved"); return true }
            let width = window.sidebarWidthForTesting
            check(savedSidebarWidth > 0 && abs(width - savedSidebarWidth) < 1, step, "\(width), was \(savedSidebarWidth)")
        case "sort-title-is":
            // The words on the sort button, or none when a narrow window has dropped them, on a button that has
            // already grown or shrunk to fit them.
            let title = window.headerSortTitleForTesting
            let widths = window.headerSortWidthsForTesting
            check((title.isEmpty ? "none" : title) == argument && abs(widths.shown - widths.needed) < 1, step,
                  "\(title), \(widths.shown) points wide for \(widths.needed)")
        case "sort-fits":
            // Whatever the sort, the button is as wide as its icon, words and chevron need.
            let widths = window.headerSortWidthsForTesting
            check(abs(widths.shown - widths.needed) < 1, step, "\(widths.shown) points wide for \(widths.needed)")
        case "sort-save":
            // Keeps the tab's sort, so these steps can change it and put it back for the steps after them.
            savedSort = window.activeTab?.sort
        case "sort-restore":
            guard let savedSort else { check(false, step, "nothing saved"); return true }
            window.contentSetSortForTesting(savedSort)
            await wait(seconds: 0.4)
            check(window.activeTab?.sort == savedSort, step)
        case "header-tooltips":
            // Each control's tooltip names its shortcut. The view button names the view it switches to, so only
            // that view's key; the spark names its key once a model is ready, and otherwise says it sets AI mode up.
            let tips = window.headerToolTipsForTesting
            let grid = window.headerViewModeForTesting == .grid
            let offeredKey = grid ? "⌘2" : "⌘1", shownKey = grid ? "⌘1" : "⌘2"
            var missing = ["⌃⌘S", "⌘[", "⌘]", "⌘F", offeredKey, "⌘J"].filter { key in !tips.contains { $0.contains(key) } }
            if !tips.contains(where: { $0 == AgentText.sparkSetUp || $0.contains("⌃⌘I") }) { missing.append("the spark") }
            let extra = tips.filter { $0.contains(shownKey) }
            check(missing.isEmpty && extra.isEmpty, step, "missing \(missing), extra \(extra) in \(tips)")
        case "window-width":
            guard let frameWindow = window.window, let width = Double(argument) else { check(false, step, "usage"); return true }
            var frame = frameWindow.frame
            frame.size.width = CGFloat(width)
            frameWindow.setFrame(frame, display: true)
            await wait(seconds: 0.5)
            check(abs(frameWindow.frame.width - CGFloat(width)) < 1, step, "\(frameWindow.frame.width)")
        case "sidebar-collapse":
            // What dragging the divider all the way does: the split item collapses without the header's button.
            window.setSidebarCollapsedForTesting(argument == "true")
            await wait(seconds: 0.6)
        case "sidebar-divider":
            // Moves the divider through the split view, as a drag does: all the way left collapses the sidebar.
            _ = window.moveSidebarDividerForTesting(to: CGFloat(Double(argument) ?? 0))
            await wait(seconds: 0.6)
        case "header-leading-is":
            let wanted = Double(argument).map { CGFloat($0) } ?? -1
            check(abs(window.headerLeadingForTesting - wanted) < 0.5, step, "\(window.headerLeadingForTesting)")
        case "sidebar-visible-is":
            check(window.isSidebarVisibleForTesting == (argument == "true"), step, "\(window.isSidebarVisibleForTesting)")
        case "header-shot":
            // "<file> [points]": the top band of the window, the header bar and what's just under it. Paths can have
            // spaces, so only a number at the very end is read as the height.
            var path = argument
            var points: CGFloat = 64
            if let space = argument.lastIndex(of: " "), let number = Double(argument[argument.index(after: space)...]) {
                path = String(argument[..<space])
                points = CGFloat(number)
            }
            let taken = await SmokeActiveLook.drawingInFront([window.window]) { captureTop(of: window, points: points, to: path) }
            check(taken, step)
        case "window-edges-native":
            check(edgeProblems(window).isEmpty, step, edgeProblems(window).joined(separator: "; "))
        case "view-options":
            // open or close: the sort button's popover, which keeps the button lit while it's open.
            if argument == "open" {
                check(window.showViewOptionsForTesting() != nil, step, "no popover")
                await wait(seconds: 0.6)
            } else {
                window.closeViewOptionsForTesting()
                await wait(seconds: 0.4)
            }
        case "menu-lit":
            // The main menu button as it looks while its menu is open. A real menu would hold the run until it closed.
            window.lightMainMenuForTesting(argument == "true")
            await wait(seconds: 0.3)
        case "appearance":
            // light, dark or system, for this app only.
            switch argument {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
            await wait(seconds: 0.5)
        case "title-bar-fits-header":
            check(titleBarProblems(window).isEmpty, step, titleBarProblems(window).joined(separator: "; "))
        case "header-menu-whole":
            // The main menu's dots in a circle are drawn whole: the button is 34 by 32, 8 points from the header's
            // trailing edge, and its ink, about 15 points square, lies inside it with room to spare. The spark's
            // ink is about the same size.
            check(menuProblems(window).isEmpty, step, menuProblems(window).joined(separator: "; "))
        case "header-buttons-even":
            // Every header button's fill is the same height: 32 points, or 26 for the ⋯ inside the path. The view
            // button and the spark are among them.
            let buttons = headerButtons(window)
            let uneven = buttons.filter { $0.height != ($0.inPath ? 26 : 32) }
            let kinds = Set(buttons.map(\.kind))
            let absent = ["ViewModeButton", "SparkButton"].filter { !kinds.contains($0) }
            check(uneven.isEmpty && absent.isEmpty, step,
                  (uneven.map { "\($0.name) \($0.height)" } + absent.map { "no \($0)" }).joined(separator: ", "))
        default: return false
        }
        return true
    }

    /// The sort that `sort-save` kept.
    private static var savedSort: ItemSort?
    /// The sidebar width that `sidebar-width-save` kept.
    private static var savedSidebarWidth: CGFloat?

    /// Captures the top of the window, title bar and all, as a PNG.
    private static func captureTop(of window: BrowserWindowController, points: CGFloat, to path: String) -> Bool {
        guard !path.isEmpty, let frameView = window.window?.contentView?.superview,
              let image = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: image)
        let scale = CGFloat(image.pixelsHigh) / max(1, frameView.bounds.height)
        guard let whole = withMaterials(image, of: frameView).cgImage,
              let band = whole.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(whole.width), height: min(CGFloat(whole.height), points * scale))),
              let data = NSBitmapImageRep(cgImage: band).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// The window keeps macOS's own resizing: it's resizable, nothing of Helm's is in the frame view or the title
    /// bar's accessories, and the window frame itself takes a click just inside each edge, where the resize band is.
    private static func edgeProblems(_ window: BrowserWindowController) -> [String] {
        guard let frameWindow = window.window, let frameView = frameWindow.contentView?.superview else { return ["no frame view"] }
        var problems: [String] = []
        if !frameWindow.styleMask.contains(.resizable) { problems.append("not resizable") }
        if !frameWindow.titlebarAccessoryViewControllers.isEmpty { problems.append("title bar accessories") }
        for view in frameView.subviews where view !== frameWindow.contentView && isHelms(view) {
            problems.append("\(type(of: view)) in the frame view")
        }
        let bounds = frameView.bounds
        let probes = [NSPoint(x: bounds.maxX - 1.5, y: bounds.midY), NSPoint(x: bounds.minX + 1.5, y: bounds.midY),
                      NSPoint(x: bounds.midX, y: bounds.minY + 1.5), NSPoint(x: bounds.midX, y: bounds.maxY - 1.5),
                      NSPoint(x: bounds.maxX - 1.5, y: bounds.minY + 40), NSPoint(x: bounds.maxX - 60, y: bounds.minY + 1.5)]
        for point in probes {
            let hit = frameView.hitTest(point)
            if hit !== frameView {
                problems.append("\(hit.map { String(describing: type(of: $0)) } ?? "nothing") takes \(Int(point.x)),\(Int(point.y))")
            }
        }
        return problems
    }
    private static func isHelms(_ view: NSView) -> Bool { Bundle(for: type(of: view)) == Bundle.main }

    /// The title bar ends where the header does, so a click just under the header reaches the files or the sidebar
    /// rather than dragging the window.
    private static func titleBarProblems(_ window: BrowserWindowController) -> [String] {
        guard let frameWindow = window.window, let frameView = frameWindow.contentView?.superview,
              let content = frameWindow.contentView else { return ["no frame view"] }
        var problems: [String] = []
        let header = window.headerFrameForTesting
        if abs(frameWindow.contentLayoutRect.maxY - header.minY) > 0.5 {
            problems.append("title bar ends at \(frameWindow.contentLayoutRect.maxY), header at \(header.minY)")
        }
        // The frame view has no superview, so it hit-tests in window coordinates.
        for x in [header.maxX - 300, 60] {
            let point = NSPoint(x: x, y: header.minY - 4)
            let hit = frameView.hitTest(point)
            if hit.map({ !$0.isDescendant(of: content) }) ?? true {
                problems.append("\(hit.map { String(describing: type(of: $0)) } ?? "nothing") takes \(Int(x)) under the header")
            }
        }
        return problems
    }

    /// What keeps the main menu button from being drawn whole, if anything.
    private static func menuProblems(_ window: BrowserWindowController) -> [String] {
        let measure = window.headerMenuMeasureForTesting
        var problems: [String] = []
        if abs(measure.size.width - 34) > 0.5 || abs(measure.size.height - 32) > 0.5 { problems.append("size \(measure.size)") }
        if abs(measure.trailingGap - 8) > 0.5 { problems.append("\(measure.trailingGap) from the trailing edge") }
        guard let ink = measure.ink else { return problems + ["no ink"] }
        if !measure.bounds.insetBy(dx: 1, dy: 1).contains(ink) { problems.append("ink \(ink) reaches the edge of \(measure.bounds)") }
        if ink.width < 13.5 || ink.width > 16.5 || ink.height < 13.5 || ink.height > 16.5 { problems.append("ink \(ink.size)") }
        if let spark = measure.sparkInk, spark.width < 13.5 || spark.width > 16.5 { problems.append("spark ink \(spark.size)") }
        return problems
    }

    /// The header's flat buttons, of every kind.
    private static let flatButtonKinds: Set<String> = ["FlatButton", "FlatMenuButton", "ViewModeButton", "SparkButton"]
    /// The window's buttons as laid out: name, kind, height, and whether it sits inside the path field.
    private static func headerButtons(_ window: BrowserWindowController)
        -> [(name: String, kind: String, height: CGFloat, inPath: Bool)] {
        var found: [(name: String, kind: String, height: CGFloat, inPath: Bool)] = []
        func walk(_ view: NSView, inPath: Bool) {
            let kind = String(describing: type(of: view))
            let path = inPath || kind == "PathBarView"
            if flatButtonKinds.contains(kind), !view.isHiddenOrHasHiddenAncestor {
                found.append((view.accessibilityLabel() ?? kind, kind, view.frame.height, path))
            }
            view.subviews.forEach { walk($0, inPath: path) }
        }
        if let content = window.window?.contentView { walk(content, inPath: false) }
        return found
    }
}
#endif
