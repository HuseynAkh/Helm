#if os(macOS)
import AppKit

/// How rows move when a folder opens or closes in the list: one curve both ways, a touch longer than AppKit's own
/// (about a quarter of a second), so it reads as the same speed, only smooth. Rows fade and slide together; with
/// Reduce Motion on they only fade. Files that come and go inside an open folder fade in place.
@MainActor enum ListMotion {
    /// The one length for opening and closing. Change it here to try 0.25 or 0.3.
    static let duration: TimeInterval = 0.28
    static let timing = CAMediaTimingFunction(name: .easeInEaseOut)
    /// Tests turn motion off, which makes every change instant.
    static var enabled = true

    /// Lets tests and scripted runs try Reduce Motion without changing the Mac's own setting.
    static var reducesMotionForTesting: Bool?
    static var reducesMotion: Bool { reducesMotionForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Rows arriving under a folder that opens.
    static var reveal: NSTableView.AnimationOptions { !enabled ? [] : reducesMotion ? .effectFade : [.effectFade, .slideDown] }
    /// Rows leaving as a folder closes.
    static var conceal: NSTableView.AnimationOptions { !enabled ? [] : reducesMotion ? .effectFade : [.effectFade, .slideUp] }
    /// Files appearing or disappearing inside a folder that's already open.
    static var churn: NSTableView.AnimationOptions { enabled ? .effectFade : [] }

    /// Runs row changes on the list's curve. Table row animations take their length and timing from the
    /// current animation context.
    static func run(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = enabled ? duration : 0
            context.timingFunction = timing
            changes()
        }
    }
}
#endif
