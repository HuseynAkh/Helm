#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for sidebar: reordering and hiding places.
/// Groups are named as in Settings: favorites, bookmarks, starred, locations. Names may hold spaces, so a step
/// reads "<group> <name>", and "<group> <name> > <more>" where it needs a second part.
extension HostSmokeDriver {
    static func performSidebarVerb(_ verb: String, _ argument: String, step: String,
                              window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "sidebar-rows":
            // sidebar-rows <group> <name,name,…>: one group's rows as the list draws them, in order.
            guard let (group, rest) = groupAndRest(argument) else { check(false, step, "usage"); return true }
            let names = window.sidebarRowNamesForTesting(group)
            check(names == list(rest), step, names.joined(separator: ","))
        case "sidebar-drawn":
            // sidebar-drawn <name,…>: the whole list as drawn, with | for the lines between groups.
            let drawn = window.sidebarDrawnForTesting
            check(drawn == list(argument), step, drawn.joined(separator: ","))
        case "sidebar-close-newest-window":
            // Closes the window opened last.
            guard app.allWindows.count > 1, let newest = app.allWindows.last else { check(false, step, "only one window"); return true }
            newest.window?.performClose(nil)
            await wait(seconds: 0.4)
        case "sidebar-all-windows":
            // sidebar-all-windows <group> <names>: every window's sidebar agrees.
            guard let (group, rest) = groupAndRest(argument) else { check(false, step, "usage"); return true }
            let seen = app.allWindows.map { $0.sidebarRowNamesForTesting(group).joined(separator: ",") }
            check(app.allWindows.count > 1 && seen.allSatisfy { $0 == list(rest).joined(separator: ",") }, step, seen.joined(separator: " / "))
        case "sidebar-hide", "sidebar-show":
            guard let (group, name) = groupAndRest(argument) else { check(false, step, "usage"); return true }
            check(window.sidebarSetShownForTesting(group, name, shown: verb == "sidebar-show"), step, "no such row")
            await wait(seconds: 0.2)
        case "sidebar-move":
            // sidebar-move <group> <name> > <anchor>|<group>:<anchor>|end: the drop at the end of a drag, with the
            // insertion line above the anchor's row. An anchor in another group shows the line staying in its own.
            guard let (group, rest) = groupAndRest(argument), let (name, anchor) = split(rest) else { check(false, step, "usage"); return true }
            var target: (group: SidebarGroup, name: String)?
            if anchor != "end" {
                let bits = anchor.split(separator: ":", maxSplits: 1).map(String.init)
                if bits.count == 2, let other = SidebarGroup(rawValue: bits[0]) { target = (other, bits[1]) } else { target = (group, anchor) }
            }
            check(window.sidebarDropForTesting(group, name, onto: target), step, "refused")
            await wait(seconds: 0.2)
        case "sidebar-drag":
            // sidebar-drag <group> <name> > <group>:<name> upper|lower: dragged over a row's upper or lower half and let
            // go, through the outline view's own drop handling. The row lands above or below it, within its own group.
            guard let (group, rest) = groupAndRest(argument), let (name, over) = split(rest), let target = place(over) else {
                check(false, step, "usage"); return true
            }
            check(window.sidebarScriptedDragForTesting(group, name, over: target.place, lowerHalf: target.lower), step, "refused")
            await wait(seconds: 0.3)
        case "sidebar-drop-folder":
            // sidebar-drop-folder <path> > favorites:Recent upper|lower: a folder from elsewhere let go over Recent,
            // which takes no drops of its own, so it's bookmarked among the bookmarks. Other rows are refused, since
            // over a folder row or Trash the drop would really move the folder.
            guard let (path, over) = split(argument), let target = place(over) else { check(false, step, "usage"); return true }
            let outcome = window.sidebarScriptedFolderDropForTesting(URL(fileURLWithPath: path, isDirectory: true), over: target.place, lowerHalf: target.lower)
            check(outcome == "link", step, outcome)
            await wait(seconds: 0.5)
        case "sidebar-drag-out", "sidebar-drag-cancel":
            // The end of a real drag of a row on show, through the code AppKit calls when it ends, with the pointer over
            // the files and nothing taking the drop. Let go of there, a bookmark goes and any other row hides; cancelled
            // with Escape there, nothing happens. Starting the drag and the poof itself still need a person.
            guard let (group, name) = groupAndRest(argument) else { check(false, step, "usage"); return true }
            check(window.sidebarDragEndForTesting(group, name, inside: false, cancelled: verb == "sidebar-drag-cancel"), step, "no such row on show")
            await wait(seconds: 0.2)
        case "sidebar-drag-hook":
            // A row dragged over the files doesn't slide back when it's let go of, and one over the sidebar does: the
            // outline view has the hook AppKit calls as a drag moves, and it tells the two places apart.
            guard let slide = window.sidebarSlideBackForTesting else { check(false, step, "no window"); return true }
            check(slide.hooked && slide.inside && !slide.outside, step, "hooked \(slide.hooked), slides back in the sidebar \(slide.inside), over the files \(slide.outside)")
        case "sidebar-highlight":
            let name = window.sidebarHighlightForTesting ?? "none"
            check(name == argument, step, name)
        case "sidebar-menu":
            // sidebar-menu <group> <name> > <titles, | for a separator>, or "sidebar-menu empty > …" for the space below the rows.
            guard let (target, titles) = split(argument) else { check(false, step, "usage"); return true }
            let found: [String]
            if target == "empty" { found = window.sidebarMenuTitlesForTesting(.favorites, nil) }
            else if let (group, name) = groupAndRest(target) { found = window.sidebarMenuTitlesForTesting(group, name) }
            else { check(false, step, "usage"); return true }
            check(found == list(titles), step, found.joined(separator: ","))
        case "sidebar-menu-pick":
            // sidebar-menu-pick <group> <name> > <title>: chooses the item, as clicking it does.
            guard let (target, title) = split(argument), let (group, name) = groupAndRest(target) else { check(false, step, "usage"); return true }
            check(window.sidebarMenuPickForTesting(group, name, title), step, "no such item")
            await wait(seconds: 0.5)
        case "sidebar-appearance":
            // light, dark or system: Helm's own appearance only, so both can be captured whatever the Mac uses.
            NSApp.appearance = argument == "system" ? nil : NSAppearance(named: argument == "dark" ? .darkAqua : .aqua)
            await wait(seconds: 0.4)
        case "sidebar-settings-pane":
            // The Settings window is open at this pane. Closes it afterwards.
            let pane = app.settingsControllerForTesting?.selectedPane?.rawValue.lowercased() ?? "none"
            check(app.settingsWindowForTesting?.isVisible == true && pane == argument, step, "visible \(app.settingsWindowForTesting?.isVisible == true), pane \(pane)")
            app.settingsWindowForTesting?.close()
        case "sidebar-settings", "sidebar-settings-toggle", "sidebar-settings-drag", "sidebar-settings-drag-cancel",
             "sidebar-settings-step", "sidebar-settings-volumes", "sidebar-settings-can-restore", "sidebar-settings-fits",
             "sidebar-reset":
            await performSidebarSettingsVerb(verb, argument, step: step, app: app)
        default: return false
        }
        return true
    }

    /// Settings › Sidebar, through the model its checkboxes, drags and buttons use.
    private static func performSidebarSettingsVerb(_ verb: String, _ argument: String, step: String, app: AppController) async {
        app.showSettingsWindow(nil)
        defer { app.settingsWindowForTesting?.close() }
        guard let model = app.settingsControllerForTesting?.sidebarModel else { check(false, step, "no Sidebar pane model"); return }
        switch verb {
        case "sidebar-settings":
            // sidebar-settings <group> <name,-hidden name,…>: the pane's rows, hidden ones marked with a minus.
            guard let (group, rest) = groupAndRest(argument) else { check(false, step, "usage"); return }
            let rows = model.rowsForTesting(group).map { ($0.isShown ? "" : "-") + $0.name }
            check(rows == list(rest), step, rows.joined(separator: ","))
        case "sidebar-settings-toggle":
            // sidebar-settings-toggle <group> <name> > on|off: the row's checkbox.
            guard let (target, state) = split(argument), let (group, name) = groupAndRest(target),
                  let place = model.placeForTesting(group, named: name) else { check(false, step, "no such row"); return }
            model.setShown(place, state == "on")
        case "sidebar-settings-drag", "sidebar-settings-drag-cancel":
            // sidebar-settings-drag <group> <name> > [<group>:]<other name>: drags a row over another row, as the
            // pane's drop delegate sees it. The pane makes room, but nothing is saved, and no window's sidebar changes,
            // until the row is let go of over its own group. The -cancel form leaves it with Escape instead.
            guard let (target, over) = split(argument), let (group, name) = groupAndRest(target),
                  let place = model.placeForTesting(group, named: name) else { check(false, step, "no such row"); return }
            let others = over.split(separator: ":", maxSplits: 1).map(String.init)
            let overGroup = others.count == 2 ? SidebarGroup(rawValue: others[0]) ?? group : group
            guard let destination = model.placeForTesting(overGroup, named: others.last ?? over),
                  let index = model.indexForTesting(of: destination) else { check(false, step, "no such row"); return }
            let windowsBefore = app.allWindows.map { $0.sidebarRowNamesForTesting(group) }
            let paneBefore = model.rowsForTesting(group).map(\.name)
            model.beginDrag(place)
            let accepted = model.canDrop(in: overGroup)
            model.dragOver(overGroup, at: index)
            let paneDuring = model.rowsForTesting(group).map(\.name)
            let windowsDuring = app.allWindows.map { $0.sidebarRowNamesForTesting(group) }
            if verb == "sidebar-settings-drag-cancel" {
                model.dragLeft()
                model.endDrag()
                let paneAfter = model.rowsForTesting(group).map(\.name)
                check(accepted && paneDuring != paneBefore && windowsDuring == windowsBefore && paneAfter == paneBefore
                      && app.allWindows.map { $0.sidebarRowNamesForTesting(group) } == windowsBefore, step,
                      "pane during \(paneDuring.joined(separator: ",")), after \(paneAfter.joined(separator: ","))")
            } else {
                let dropped = accepted && model.drop(in: overGroup)
                if !accepted { model.endDrag() }
                check(accepted == (overGroup == group) && dropped == accepted && windowsDuring == windowsBefore, step,
                      "accepted \(accepted), sidebar changed before the drop \(windowsDuring != windowsBefore)")
            }
        case "sidebar-settings-step":
            // sidebar-settings-step <group> <name> > up|down: Move Up or Move Down.
            guard let (target, direction) = split(argument), let (group, name) = groupAndRest(target),
                  let place = model.placeForTesting(group, named: name) else { check(false, step, "no such row"); return }
            model.step(place, by: direction == "up" ? -1 : 1)
        case "sidebar-settings-volumes":
            model.setShowsAllVolumes(argument == "on")
            check(app.frontmost()?.dependencies.settings.snapshot.bool(.showAllMountedVolumes) == (argument == "on"), step)
        case "sidebar-settings-fits":
            // Settings › Sidebar shows every row without scrolling: each area that could scroll has all of it in view.
            app.settingsControllerForTesting?.select(.sidebar)
            await wait(seconds: 0.8)
            let areas = app.settingsControllerForTesting?.sidebarScrollAreasForTesting ?? []
            check(!areas.isEmpty && areas.allSatisfy { $0.content <= $0.visible + 1 }, step,
                  areas.isEmpty ? "no scrolling areas found" : areas.map { "\(Int($0.content)) in \(Int($0.visible))" }.joined(separator: ", "))
        case "sidebar-settings-can-restore":
            // sidebar-settings-can-restore yes|no: whether Restore Defaults would change anything, so it's enabled.
            check(model.canRestoreForTesting == (argument == "yes"), step, "can restore \(model.canRestoreForTesting)")
        case "sidebar-reset":
            // Restore Defaults.
            model.restoreDefaults()
            check(!model.canRestoreForTesting, step, "layout still customized")
        default: break
        }
        await wait(seconds: 0.3)
    }

    /// "<group>:<name> upper|lower", the row a drag is let go over.
    private static func place(_ text: String) -> (place: (group: SidebarGroup, name: String), lower: Bool)? {
        guard let space = text.range(of: " ", options: .backwards) else { return nil }
        let half = text[space.upperBound...]
        let bits = text[..<space.lowerBound].split(separator: ":", maxSplits: 1).map(String.init)
        guard half == "upper" || half == "lower", bits.count == 2, let group = SidebarGroup(rawValue: bits[0]) else { return nil }
        return ((group, bits[1]), half == "lower")
    }
    private static func groupAndRest(_ text: String) -> (SidebarGroup, String)? {
        let bits = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = bits.first, let group = SidebarGroup(rawValue: first) else { return nil }
        return (group, bits.count > 1 ? bits[1] : "")
    }
    private static func split(_ text: String) -> (String, String)? {
        guard let range = text.range(of: " > ") else { return nil }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }
    private static func list(_ text: String) -> [String] {
        text.isEmpty ? [] : text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }
}
#endif
