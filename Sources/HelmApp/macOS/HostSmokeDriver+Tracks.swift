#if os(macOS)
import AppKit
import HelmUI

/// Verbs that separate pieces of work add, each in a file of its own, so the main switch stays untouched.
extension HostSmokeDriver {
    static func performTrackVerb(_ verb: String, _ argument: String, step: String,
                                 window: BrowserWindowController, app: AppController) async -> Bool {
        if await performHeaderVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performSidebarVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performPermissionVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performRecentVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performPolishVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performHuntNavigationVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performHuntOperationsVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performHuntSearchRecentVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performHuntViewsVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performHuntPermissionsVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performHuntSidebarSettingsVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performReadmeVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performSetupVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performPrivacyVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performRouteVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performOpenWithVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performGridNamesVerb(verb, argument, step: step, window: window, app: app) { return true }
        if await performThumbnailsVerb(verb, argument, step: step, window: window, app: app) { return true }
        return false
    }
}
#endif
