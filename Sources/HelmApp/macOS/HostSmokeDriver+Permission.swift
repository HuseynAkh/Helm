#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for permissions: access, onboarding and overlays.
/// Everything here runs against the fixture's stand-in permission: nothing opens System Settings or Finder,
/// relaunches, or changes a real permission, and file modes change only inside the fixture home.
extension HostSmokeDriver {
    static func performPermissionVerb(_ verb: String, _ argument: String, step: String,
                              window: BrowserWindowController, app: AppController) async -> Bool {
        let privacy = app.privacyForTesting
        let card = window.contentStateForTesting
        switch verb {
        case "fda":
            // fda granted|denied|unknown: what the stand-in says, as if System Settings had changed it.
            guard let privacy, let status = PrivacyAccessStatus(rawValue: argument) else { check(false, step, "not a fixture run"); return true }
            privacy.status = status
            await app.permissionsForTesting.refresh()
            await wait(seconds: 0.3)
        case "fda-is":
            check(app.permissionsForTesting.fullDiskAccess.rawValue == argument, step, app.permissionsForTesting.fullDiskAccess.rawValue)
        case "fixture-chmod":
            // fixture-chmod <octal mode> <path>: only inside a fixture run's own home folder.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard privacy != nil, bits.count == 2, let mode = Int(bits[0], radix: 8), isInFixtureHome(bits[1], window: window) else {
                check(false, step, "refused: not a fixture path"); return true
            }
            check(chmod(bits[1], mode_t(mode)) == 0, step, String(cString: strerror(errno)))
        case "open-trash":
            window.navigate(to: .trash)
            await wait(seconds: 0.6)
        case "fixture-mkdir":
            // fixture-mkdir <path>: a folder inside a fixture run's own home folder.
            guard privacy != nil, isInFixtureHome(argument, window: window) else {
                check(false, step, "refused: not a fixture path"); return true
            }
            check((try? FileManager.default.createDirectory(atPath: argument, withIntermediateDirectories: true)) != nil, step)
        case "empty-trash":
            window.emptyTrashForTesting()
            await wait(seconds: 0.8)
        case "empty-trash-says":
            // Empties the Trash and checks what Helm said about it.
            var said: [String] = []
            window.messageObserver = { message in said.append(message); print("MSG \(message)"); fflush(stdout) }
            window.emptyTrashForTesting()
            await wait(seconds: 0.8)
            check(said.contains { $0.contains(argument) }, step, said.isEmpty ? "nothing said" : said.joined(separator: " | "))
        case "focus-in-listing":
            check(window.focusIsInListingForTesting == (argument == "true"), step, "\(window.focusIsInListingForTesting)")
        case "card-announced":
            check(window.cardAnnouncementForTesting?.contains(argument) == true, step, window.cardAnnouncementForTesting ?? "nothing")
        case "card-reads":
            check(card?.title == argument, step, card?.title ?? "no card")
        case "card-says":
            check(card?.message?.contains(argument) == true, step, card?.message ?? "no message")
        case "card-buttons":
            let titles = card?.buttons.map(\.title).joined(separator: ",") ?? ""
            check(titles == argument, step, titles)
        case "card-style":
            check(card?.style.rawValue == argument, step, card?.style.rawValue ?? "none")
        case "card-none":
            check(card == nil, step, card?.title ?? "")
        case "card-press":
            check(window.pressContentButtonForTesting(argument), step, "no such button")
            await wait(seconds: 0.6)
        case "card-preview":
            window.previewContentStateForTesting(previewState(argument, home: window.dependencies.home))
            await wait(seconds: 0.4)
        case "listing-hidden":
            check(window.isListingHiddenForTesting == (argument == "true"), step, "\(window.isListingHiddenForTesting)")
        case "sidebar-on":
            // sidebar-on <row name|none>: the row the sidebar itself highlights. While a card is up that's the place
            // that couldn't open, or the place holding it, never the folder underneath.
            check(window.sidebarSelectionForTesting == argument, step, window.sidebarSelectionForTesting)
        case "opened-pane":
            check(privacy?.openedPanes.last?.anchor == argument, step, privacy?.openedPanes.last?.anchor ?? "none")
        case "trash-in-finder":
            check(privacy?.trashOpenedInFinder == Int(argument), step, "\(privacy?.trashOpenedInFinder ?? -1)")
        case "dismiss-operations":
            // As pressing Dismiss on each finished row does, so screenshots show the content area itself.
            let operations = window.dependencies.operations
            for row in operations.currentRows where row.result != nil { operations.dismiss(row.id) }
            await wait(seconds: 0.3)
        case "appearance":
            // This process only: light, dark, or back to the system's.
            switch argument {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
            await wait(seconds: 0.6)
        case "app-icon":
            // A fixture run isn't an app bundle, so it borrows Helm's icon for the welcome window's pictures.
            let path = argument.hasPrefix("/") ? argument : FileManager.default.currentDirectoryPath + "/" + argument
            guard privacy != nil, let image = NSImage(contentsOfFile: path) else { check(false, step, "no icon"); return true }
            NSApp.applicationIconImage = image
        case "onboarding":
            // onboarding open|guide|close: the welcome checklist, as Help › Set Up Helm… opens it, or the guide on its own.
            switch argument {
            case "open": app.showSetup(nil)
            case "guide", "access": app.showFullDiskAccessGuide(nil)
            default: app.onboardingForTesting?.close()
            }
            await wait(seconds: 0.6)
        case "help-menu":
            // Chooses an item in the real Help menu as a click would: the menu validates it first, then sends it.
            guard let menu = NSApp.helpMenu, let index = menu.items.firstIndex(where: { $0.title == argument }) else {
                check(false, step, "no such item"); return true
            }
            menu.update()
            guard menu.items[index].isEnabled else { check(false, step, "disabled"); return true }
            menu.performActionForItem(at: index)
            await wait(seconds: 0.6)
        case "settings-access":
            // Settings › General › Access: its Turn On… (Show Guide… once access is on) and Show… buttons.
            let section = app.access.settingsSection
            if argument == "welcome" { section.showWelcome() } else { section.setUp() }
            await wait(seconds: 0.6)
        case "onboarding-quitting":
            // What Helm does on its way out, as after Quit & Reopen: an open welcome counts as seen.
            app.access.quitting()
        case "onboarding-frontmost":
            // onboarding-frontmost <bundle identifier|none>: as if that app had come to the front.
            app.onboardingForTesting?.frontmostChangedForTesting(argument == "none" ? nil : argument)
        case "onboarding-level":
            let level = app.onboardingForTesting?.levelForTesting ?? .normal
            check((level == .floating ? "floating" : "normal") == argument, step, level == .floating ? "floating" : "normal")
        case "onboarding-is":
            // onboarding-is setup|guide|closed
            let shown = app.onboardingForTesting?.modeForTesting ?? "closed"
            check(shown == argument, step, shown)
        case "onboarding-press":
            check(app.onboardingForTesting?.pressForTesting(argument) == true, step, "no such button")
            await wait(seconds: 0.6)
        case "onboarding-reads":
            check(app.onboardingForTesting?.model.statusLine == argument, step, app.onboardingForTesting?.model.statusLine ?? "closed")
        case "onboarding-shot":
            await wait(seconds: 0.3)
            check(app.onboardingForTesting?.captureForTesting(to: URL(fileURLWithPath: argument)) == true, step)
        case "setting-is":
            // setting-is <key> <true|false>
            let bits = argument.split(separator: " ").map(String.init)
            guard bits.count == 2, let key = SettingKey(rawValue: "helm." + bits[0]) else { check(false, step, "bad setting"); return true }
            let value = window.dependencies.settings.snapshot.bool(key)
            check(value == (bits[1] == "true"), step, "\(value)")
        default: return false
        }
        return true
    }

    /// Whether a path lies inside the fixture run's own home folder. Spelled the same way whether or not the item
    /// exists yet, since `standardizedFileURL` drops `/private` only for paths that do.
    private static func isInFixtureHome(_ path: String, window: BrowserWindowController) -> Bool {
        PathSpelling.standardPath(URL(fileURLWithPath: path)).hasPrefix(PathSpelling.standardPath(window.dependencies.home) + "/")
    }

    /// States a fixture can't produce on its own, built the same way the window builds them.
    private static func previewState(_ name: String, home: URL) -> ContentState? {
        let documents = Location.directory(home.appendingPathComponent("Documents", isDirectory: true))
        let projects = Location.directory(URL(fileURLWithPath: "/Volumes/Backup/Projects", isDirectory: true))
        switch name {
        case "waiting": return ContentStatePresentation.failure(.timedOut, attempted: documents, home: home, fullDiskAccess: .denied)
        case "disk": return ContentStatePresentation.failure(.timedOut, attempted: projects, home: home, fullDiskAccess: .denied)
        case "disconnected": return ContentStatePresentation.failure(.volumeUnmounted, attempted: projects, home: home, fullDiskAccess: .denied)
        case "not-indexed": return ContentStatePresentation.failure(.notIndexed, attempted: projects, home: home, fullDiskAccess: .denied)
        case "likely-private":
            // EPERM on a folder outside the known table, as for ~/Library/Calendars.
            let calendars = Location.directory(home.appendingPathComponent("Library/Calendars", isDirectory: true))
            return ContentStatePresentation.failure(.permissionDenied, attempted: calendars, home: home, fullDiskAccess: .denied, evidence: .privacy)
        case "cloud-slow":
            // A cloud provider that stopped answering: no macOS question explains it.
            let drive = Location.directory(home.appendingPathComponent("Library/CloudStorage/GoogleDrive-me@example.com", isDirectory: true))
            return ContentStatePresentation.failure(.timedOut, attempted: drive, home: home, fullDiskAccess: .denied)
        case "granted-other-apps":
            // Another app's data refused while Full Disk Access is on: not macOS privacy, so no Settings button.
            let container = Location.directory(home.appendingPathComponent("Library/Containers/com.example.notes", isDirectory: true))
            return ContentStatePresentation.failure(.permissionDenied, attempted: container, home: home, fullDiskAccess: .granted)
        case "other": return ContentStatePresentation.failure(.other("The folder’s contents couldn’t be read."), attempted: projects,
                                                              home: home, fullDiskAccess: .denied)
        case "trash": return ContentStatePresentation.empty(.trash)
        case "recent": return ContentStatePresentation.empty(.recent)
        case "no-results": return ContentStatePresentation.empty(.noResults)
        default: return nil
        }
    }
}
#endif
