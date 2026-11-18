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
        default: return false
        }
        return true
    }
}
#endif
