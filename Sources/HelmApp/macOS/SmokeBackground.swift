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

/// The README's pictures show each window as it looks in front: window buttons in colour, the accent on default
/// buttons and switches. A scripted run stays in the background, so AppKit draws its windows as inactive ones. With
/// this on, while a window is captured Helm answers that it's the active app (HelmApplication) and the window is told
/// it's the key and main window, as AppKit tells it when it comes to the front; once the capture is taken it's told
/// it isn't. Helm never comes to the front: macOS keeps the app in front where it was, keys go on going to it, and
/// `NSApp.keyWindow` stays empty.
/// Off by default. Only the `active-look on` step of a scripted fixture run turns it on (HostSmokeDriver+Readme).
@MainActor enum SmokeActiveLook {
    /// Whether captures draw their windows as the key and main window.
    private(set) static var isOn = false
    /// A capture with the active look is being taken now.
    private(set) static var isCapturing = false

    /// Turns it on or off for `app`. Only a scripted run on fixture folders may turn it on; anywhere else it stays off
    /// and this says no.
    @discardableResult
    static func set(_ on: Bool, for app: AppController) -> Bool {
        guard !on || mayTurnOn(app.options, inBackground: app.staysInBackground) else { return false }
        isOn = on
        return true
    }

    /// Whether a launch may turn it on: a scripted run (`--smoke`, which needs both fixture folders) that stays in the
    /// background. A launch without a script never may.
    static func mayTurnOn(_ options: LaunchOptions, inBackground: Bool) -> Bool {
        options.smokeScript != nil && options.isIsolated && inBackground
    }

    /// Runs `capture` with each window drawn as the key and main window, when it's on, and puts them back after.
    static func drawingInFront<Result>(_ windows: [NSWindow?], _ capture: () -> Result) async -> Result {
        let shown = isOn ? windows.compactMap { $0 }.filter { !$0.isKeyWindow } : []
        guard !shown.isEmpty else { return capture() }
        isCapturing = true
        for window in shown {
            window.becomeKey()
            if window.canBecomeMain { window.becomeMain() }
        }
        // SwiftUI's views take the change on their next pass, as they do when a window comes to the front.
        await HostSmokeDriver.wait(seconds: 0.3)
        for window in shown {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let result = capture()
        isCapturing = false
        for window in shown {
            window.resignKey()
            if window.canBecomeMain { window.resignMain() }
        }
        return result
    }
}
#endif
