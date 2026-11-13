#if os(macOS)
import AppKit
import HelmUI

/// Smoke verbs for the AI mode screen and Settings › AI: the switch, the provider, a key and the connection state.
/// None is handled here, so every step goes on to the next file.
extension HostSmokeDriver {
    static func performAgentSetupVerb(_ verb: String, _ argument: String, step: String,
                                      window: BrowserWindowController, app: AppController) async -> Bool {
        false
    }
}
#endif
