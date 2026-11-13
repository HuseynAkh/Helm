#if os(macOS)
import AppKit
import HelmUI

/// Smoke verbs for searching with a model's help: the field's toggle, Return, each result's reason and the
/// status bar's line.
/// None is handled here, so every step goes on to the next file.
extension HostSmokeDriver {
    static func performAISearchVerb(_ verb: String, _ argument: String, step: String,
                                    window: BrowserWindowController, app: AppController) async -> Bool {
        false
    }
}
#endif
