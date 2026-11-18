#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for the README's pictures (scripts/readme/make_readme_images.sh). They only change how a scripted
/// window looks: its size, whether it's drawn as the window in front, the screen it sits on, and the free space its
/// status bar names.
extension HostSmokeDriver {
    static func performReadmeVerb(_ verb: String, _ argument: String, step: String,
                                  window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "free-space":
            // free-space <bytes|hidden|real>: what the status bar says is free, so a picture never shows a real disk.
            switch argument {
            case "real": BrowserWindowController.freeSpaceOverrideForTesting = nil
            case "hidden": BrowserWindowController.freeSpaceOverrideForTesting = -1
            default:
                guard let bytes = Int64(argument) else { check(false, step, "usage: free-space <bytes|hidden|real>"); return true }
                BrowserWindowController.freeSpaceOverrideForTesting = bytes
            }
            window.refreshStatusForTesting()
            await wait(seconds: 0.2)
        case "window-size":
            // window-size <width> <height>, in points, for the window's frame. The window is centred on its screen.
            let bits = argument.split(separator: " ").compactMap { Double($0) }
            guard bits.count == 2, let frameWindow = window.window else { check(false, step, "usage: window-size <width> <height>"); return true }
            let visible = frameWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let size = NSSize(width: bits[0], height: bits[1])
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            frameWindow.setFrame(NSRect(origin: origin, size: size), display: true)
            await wait(seconds: 0.5)
            check(abs(frameWindow.frame.width - size.width) < 1 && abs(frameWindow.frame.height - size.height) < 1, step,
                  "\(frameWindow.frame.size)")
        case "active-look":
            // active-look <on|off>: each capture draws its window as the key and main window, as it looks in front,
            // while the run stays in the background (SmokeActiveLook). Only a scripted fixture run may turn it on.
            guard argument == "on" || argument == "off" else { check(false, step, "usage: active-look <on|off>"); return true }
            check(SmokeActiveLook.set(argument == "on", for: app), step, "not a scripted fixture run")
        case "screen":
            // screen <sharpest|any>: keeps the run's invisible windows on the screen with the most pixels to a point,
            // so pictures come out sharp when the main screen is a plainer one. Only a scripted fixture run may.
            guard argument == "sharpest" || argument == "any" else { check(false, step, "usage: screen <sharpest|any>"); return true }
            guard SmokeActiveLook.mayTurnOn(app.options, inBackground: app.staysInBackground) else {
                check(false, step, "not a scripted fixture run"); return true
            }
            SmokeBackground.setKeepsOnSharpestScreen(argument == "sharpest")
            await wait(seconds: 0.5)
            let scale = window.window?.backingScaleFactor ?? 0
            let sharpest = NSScreen.screens.map(\.backingScaleFactor).max() ?? 0
            check(argument == "any" || scale == sharpest, step, "the window draws at \(scale)x, the sharpest screen at \(sharpest)x")
        default:
            return false
        }
        return true
    }
}
#endif
