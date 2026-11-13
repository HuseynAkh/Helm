#if os(macOS)
import AppKit
import HelmUI

/// Smoke verbs for the AI panel: opening it, its folders, suggestions, thread, plan card, Apply and Undo.
/// None is handled here, so every step goes on to the next file.
extension HostSmokeDriver {
    static func performAgentVerb(_ verb: String, _ argument: String, step: String,
                                 window: BrowserWindowController, app: AppController) async -> Bool {
        false
    }
}
#endif
