#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for the README's pictures (scripts/readme/make_readme_images.sh). They only change how a scripted
/// window looks: its size, whether it's in front, and the free space its status bar names.
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
        case "activate":
            // Brings the window to the front as the key window, so its window buttons are drawn in colour. A scripted
            // run otherwise never comes to the front (HelmApplication).
            (NSApp as? HelmApplication)?.activateForScript()
            window.window?.makeKeyAndOrderFront(nil)
            await wait(seconds: 0.6)
        default:
            return false
        }
        return true
    }
}
#endif
