#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for Properties windows and Open in Terminal. Used by `scripts/rebuild/smoke.d/properties.txt`.
/// A fixture run hands folders to a stand-in, so no terminal opens.
extension HostSmokeDriver {
    static func performPropertiesVerb(_ verb: String, _ argument: String, step: String,
                                      window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "properties-wait":
            // The newest Properties window is on show and has finished counting, within ten seconds.
            for _ in 0..<100 where !(window.propertiesShownForTesting && window.propertiesFinishedForTesting) { await wait(seconds: 0.1) }
            check(window.propertiesShownForTesting && window.propertiesFinishedForTesting, step,
                  "shown \(window.propertiesShownForTesting), finished \(window.propertiesFinishedForTesting)")
        case "properties-title":
            check(window.propertiesTitleForTesting == argument, step, window.propertiesTitleForTesting ?? "no window")
        case "properties-row":
            // "<Label>=<value>": a row of the newest Properties window says exactly that.
            let bits = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let rows = window.propertiesRowsForTesting
            let found = rows.first { $0.label == bits.first }
            check(bits.count == 2 && found?.value == bits[1], step, rows.map { "\($0.label)=\($0.value)" }.joined(separator: " | "))
        case "properties-note":
            // "<Label>=<words>": the row's quieter line says those words, or, with nothing after =, it has none.
            let bits = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let row = window.propertiesRowsForTesting.first { $0.label == bits.first }
            let wanted = bits.count == 2 ? bits[1] : ""
            check(row != nil && (wanted.isEmpty ? row?.note == nil : row?.note?.contains(wanted) == true), step, row?.note ?? "no note")
        case "properties-lacks":
            // A row the newest Properties window doesn't have.
            check(!window.propertiesRowsForTesting.contains { $0.label == argument }, step,
                  window.propertiesRowsForTesting.map(\.label).joined(separator: ", "))
        case "properties-access":
            // "<Label>=<title>": the row's pop-up reads that, such as "Read only" or "Custom". With nothing after =,
            // the row has no pop-up.
            let bits = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let shown = window.propertiesAccessForTesting(bits.first ?? "")
            check(bits.count == 2 && shown == (bits[1].isEmpty ? nil : bits[1]), step, shown ?? "no pop-up")
        case "properties-choose":
            // "<Label>=<title>": chooses that in the row's pop-up, as a click does, and waits for the change.
            let bits = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let chose = bits.count == 2 ? await window.propertiesChooseForTesting(bits[0], bits[1]) : false
            check(chose, step, "nothing to choose")
        case "properties-execute":
            // on, off, or none when there's no "Allow executing file as program".
            let shown = window.propertiesExecuteForTesting.map { $0 ? "on" : "off" } ?? "none"
            check(shown == argument, step, shown)
        case "properties-execute-set":
            // on or off: clicks "Allow executing file as program" to that, and waits for the change.
            let changed = await window.propertiesAllowExecutingForTesting(argument == "on")
            check(changed, step, "nothing changed")
        case "properties-controls":
            // enabled or disabled: whether the pop-ups and the checkbox can be used.
            let enabled = window.propertiesControlsEnabledForTesting
            check(enabled == (argument == "enabled"), step, enabled ? "enabled" : "disabled")
        case "properties-footer":
            // The line under the permissions has these words, or, with none, there's no line.
            let footer = window.propertiesFooterForTesting
            check(argument.isEmpty ? footer == nil : footer?.contains(argument) == true, step, footer ?? "no line")
        case "properties-undo", "properties-redo":
            // Edit › Undo or Redo, sent to the newest Properties window as its menu item sends it. It runs in the
            // browser window's turn, then the Properties window reads the item again.
            check(window.propertiesUndoForTesting(redo: verb == "properties-redo"), step, "nothing answered")
            await wait(seconds: 0.2)
            var waited = 0.0
            while window.isRunningOperationsForTesting, waited < 10 { await wait(seconds: 0.05); waited += 0.05 }
            await wait(seconds: 0.4)
        case "properties-undo-title":
            // What Edit › Undo reads while the newest Properties window is in front, and that it can be chosen.
            await window.refreshHistoryForTesting()
            let item = window.propertiesUndoItemForTesting(redo: false)
            check(item?.title == argument && item?.enabled == true, step, item.map { "\($0.title), enabled \($0.enabled)" } ?? "no window")
        case "fixture-mode":
            // fixture-mode <octal mode> <path>: the item's permissions on disk, read without following a link.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            var info = stat()
            let read = bits.count == 2 && lstat(bits[1], &info) == 0
            let mode = String(info.st_mode & 0o7777, radix: 8)
            check(read && Int(bits[0], radix: 8) == Int(info.st_mode & 0o7777), step, read ? "mode \(mode)" : "unreadable")
        case "properties-windows":
            check(window.propertiesWindowCountForTesting == Int(argument), step, "\(window.propertiesWindowCountForTesting)")
        case "properties-close":
            // escape, or the close button when there's no argument.
            if argument == "escape" { window.propertiesKeyForTesting("escape") } else { window.closePropertiesForTesting() }
            await wait(seconds: 0.3)
        case "properties-shot":
            guard let shown = window.propertiesWindowForTesting, let content = shown.contentView?.superview,
                  let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { check(false, step, "no window"); return true }
            content.cacheDisplay(in: content.bounds, to: image)
            let data = image.representation(using: .png, properties: [:])
            try? data?.write(to: URL(fileURLWithPath: argument))
            check(data != nil, step)
        case "terminal-opens":
            // Open in Terminal from the menus: the stand-in gets exactly this folder, for the terminal chosen in Settings.
            guard let launcher = window.dependencies.launcher as? MemoryAppLauncher else { check(false, step, "no stand-in"); return true }
            let before = launcher.openings.count
            window.perform(.openInTerminal)
            await wait(seconds: 0.3)
            let opening = launcher.openings.count == before + 1 ? launcher.openings.last : nil
            let chosen = TerminalLocator.resolve(window.dependencies.settings.snapshot.string(.terminalApp))
            let app = opening.flatMap { Bundle(url: $0.application)?.bundleIdentifier }
            check(opening?.urls.map(\.path) == [argument] && app == chosen, step,
                  opening.map { "\($0.urls.map(\.path)) with \(app ?? $0.application.path)" } ?? "nothing handed over")
        case "terminal-last":
            // The folder the stand-in was last handed for a terminal, from a sidebar or path bar menu.
            guard let launcher = window.dependencies.launcher as? MemoryAppLauncher else { check(false, step, "no stand-in"); return true }
            let opening = launcher.openings.last
            let app = opening.flatMap { Bundle(url: $0.application)?.bundleIdentifier }
            check(opening?.urls.map(\.path) == [argument] && app == TerminalLocator.resolve(window.dependencies.settings.snapshot.string(.terminalApp)), step,
                  opening.map { "\($0.urls.map(\.path)) with \(app ?? $0.application.path)" } ?? "nothing handed over")
        case "settings-pane-fits":
            // settings-pane-fits <pane>: Settings opens at General, the tallest, then moves to the pane, as a click on
            // its tab does. Every area of the pane that could scroll has all it holds in view.
            guard let pane = SettingsPane.allCases.first(where: { $0.rawValue.lowercased() == argument }) else {
                check(false, step, "usage"); return true
            }
            app.showSettingsWindow(nil)
            await wait(seconds: 0.4)
            app.settingsControllerForTesting?.select(.general)
            await wait(seconds: 0.6)
            app.settingsControllerForTesting?.select(pane)
            await wait(seconds: 1.0)
            let areas = app.settingsControllerForTesting?.scrollAreasForTesting(pane) ?? []
            let height = app.settingsControllerForTesting?.contentHeightForTesting ?? 0
            // And it's at its top, its first rows below the toolbar rather than under it.
            let scrolled = app.settingsControllerForTesting?.scrolledFromTopForTesting ?? []
            // And nothing frosted over its top: the toolbar's edge belongs to the toolbar, not inside the pane.
            let edge = app.settingsControllerForTesting?.toolbarEdgeForTesting(pane) ?? 0
            let detail = "window \(Int(height)): " + areas.map { "holds \(Int($0.content)), shows \(Int($0.visible))" }.joined(separator: "; ")
                + "; scrolled \(scrolled.map { Int($0) }); toolbar edge \(Int(edge))"
            print("SETTINGS \(argument) \(detail)"); fflush(stdout)
            check(!areas.isEmpty && areas.allSatisfy { $0.content <= $0.visible + 1 } && scrolled.allSatisfy { abs($0) <= 1 } && edge <= 1,
                  step, detail)
            app.settingsWindowForTesting?.close()
        case "settings-pane-squeeze":
            // settings-pane-squeeze <pane>: the window made shorter than the pane's form, as a pane that came out short
            // in a Release build is, then fitted again, as a change to what the pane shows does. It shows all it
            // holds and is at its top.
            app.showSettingsWindow(nil)
            await wait(seconds: 0.4)
            guard let pane = SettingsPane.allCases.first(where: { $0.rawValue.lowercased() == argument }),
                  let settings = app.settingsControllerForTesting else { check(false, step, "usage or no Settings"); return true }
            settings.select(pane)
            await wait(seconds: 0.6)
            settings.squeezeForTesting(to: 180)
            await wait(seconds: 0.4)
            print("SETTINGS squeezed \(argument) \(settings.scrollDetailsForTesting(pane)) scrolled \(settings.scrolledFromTopForTesting.map { Int($0) })")
            settings.fitPaneForTesting()
            await wait(seconds: 0.6)
            let areas = settings.scrollAreasForTesting(pane)
            let scrolled = settings.scrolledFromTopForTesting
            let detail = settings.scrollDetailsForTesting(pane) + "; scrolled \(scrolled.map { Int($0) })"
            print("SETTINGS refitted \(argument) \(detail)"); fflush(stdout)
            check(!areas.isEmpty && areas.allSatisfy { $0.content <= $0.visible + 1 } && scrolled.allSatisfy { abs($0) <= 1 }, step, detail)
            app.settingsWindowForTesting?.close()
        default: return false
        }
        return true
    }
}
#endif
