#if os(macOS)
import AppKit

/// Keeps a scripted run out of the way of whoever is using the Mac: its windows are invisible and let clicks
/// through, and the app never comes to the front (HelmApplication). Views still lay out and draw, so checks and
/// screenshots work.
@MainActor enum SmokeBackground {
    private static var observer: NSObjectProtocol?

    /// Hides every window the run has open now, and every one it opens later.
    static func start() {
        guard observer == nil else { return }
        hideAll()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { hideAll() }
        }
    }

    /// Hides one window before it's ordered in, so it never flashes up.
    static func hide(_ window: NSWindow?) {
        guard let window else { return }
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
    }

    private static func hideAll() {
        for window in NSApp.windows { hide(window) }
    }
}
#endif
