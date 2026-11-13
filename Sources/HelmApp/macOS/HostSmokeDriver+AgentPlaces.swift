#if os(macOS)
import AppKit
import HelmUI

/// Smoke verbs that stand in for where a folder is: cloud and server places, files not downloaded,
/// slow places and places with no Trash.
/// None is handled here, so every step goes on to the next file.
extension HostSmokeDriver {
    static func performAgentPlacesVerb(_ verb: String, _ argument: String, step: String,
                                       window: BrowserWindowController, app: AppController) async -> Bool {
        false
    }
}
#endif
