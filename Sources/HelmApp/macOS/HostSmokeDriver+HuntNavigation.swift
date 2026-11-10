#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for navigation: the window's width with many tabs or a long name, what the tabs and the title say,
/// the search's room in a narrow window, hidden items asked for by name and the Dock icon.
extension HostSmokeDriver {
    static func performHuntNavigationVerb(_ verb: String, _ argument: String, step: String,
                                          window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "hunt-width-is":
            // The window's width now, within a point.
            let width = window.window?.frame.width ?? -1
            check(abs(width - CGFloat(Double(argument) ?? -1)) < 1, step, "\(width)")
        case "hunt-set-width":
            // Asks for a width as dragging the edge does, without checking what the window kept: it stops at its narrowest.
            guard let frameWindow = window.window, let width = Double(argument) else { check(false, step, "usage"); return true }
            var frame = frameWindow.frame
            frame.size.width = CGFloat(width)
            frameWindow.setFrame(frame, display: true)
            await wait(seconds: 0.5)
        case "hunt-active-tab-shown":
            // The tab on show is in the strip's view, whether or not the strip had to scroll to it.
            window.window?.contentView?.superview?.layoutSubtreeIfNeeded()
            check(window.activeTabInViewForTesting, step, "out of view")
        case "hunt-tab-title-is":
            // The active tab's name, as the tab strip shows it.
            let index = window.store.state.window.tabs.firstIndex(of: window.activeTabID) ?? -1
            let titles = window.tabTitlesForTesting
            let title = titles.indices.contains(index) ? titles[index] : "none"
            check(title == argument, step, title)
        case "hunt-title-is":
            check(window.window?.title == argument, step, window.window?.title ?? "none")
        case "hunt-search-room":
            // The search field leaves at least this much room for the words you type.
            window.window?.contentView?.superview?.layoutSubtreeIfNeeded()
            let room = window.searchTextRoomForTesting
            check(room + 0.5 >= CGFloat(Double(argument) ?? .infinity), step, "\(room) points, scope \(window.searchScopeWidthForTesting)")
        case "hunt-hidden-shown":
            // Whether the tab on show lists hidden items, and that the setting itself is still off.
            let shown = window.activeTab?.showHidden ?? false
            let setting = window.dependencies.settings.snapshot.showHiddenFiles
            check(shown == (argument == "true") && !setting, step, "tab \(shown), setting \(setting)")
        case "hunt-dock-reopen":
            // A click on the Dock icon with no window on show: a new window opens at this folder. It's closed again,
            // so the windows the run goes on with are left as they were.
            let before = app.allWindows.count
            _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            await wait(seconds: 0.8)
            guard app.allWindows.count == before + 1, let opened = app.allWindows.last else {
                check(false, step, "\(app.allWindows.count) windows"); return true
            }
            let path = opened.activeTab?.location.mutationTarget?.standardizedFileURL.path ?? "none"
            let wanted = URL(fileURLWithPath: argument).standardizedFileURL.path
            check(PathSpelling.identity(path) == PathSpelling.identity(wanted), step, path)
            opened.window?.performClose(nil)
            await wait(seconds: 0.4)
        case "hunt-fixture-remove":
            // Removes a folder inside the fixture home only, as another app or a person in Terminal would.
            let home = PathSpelling.standardPath(window.dependencies.home)
            guard PathSpelling.standardPath(URL(fileURLWithPath: argument)).hasPrefix(home + "/") else {
                check(false, step, "refused: not a fixture path"); return true
            }
            check((try? FileManager.default.removeItem(atPath: argument)) != nil, step)
        default: return false
        }
        return true
    }
}
#endif
