#if os(macOS)
import AppKit
import HelmCore
import HelmFileSystem
import HelmOperations
import HelmPersistence
import HelmUI
import SwiftUI

/// Launch options. `--home` and `--support` point a run at fixture folders, in which case no real
/// preferences, legacy data, mounts or Trash are touched. See `docs/handoff/MAC_RUN_2.md`.
public struct LaunchOptions: Equatable, Sendable {
    public var home: URL?
    public var support: URL?
    public var open: [URL] = []
    public var smokeScript: URL?
    public var screenshot: URL?
    /// `--default-viewer helm|finder`: the Settings switch, from the command line. Helm does it and quits.
    public var defaultViewer: Bool?
    /// `--dock-first on|off`: the Dock switch, from the command line. Helm does it and quits.
    public var dockFirst: Bool?
    /// `--viewer-status`: prints who the file viewer is, who opens folders, and where Helm is in the Dock.
    public var viewerStatus = false
    /// `--continue-setup viewer,access,move`: a copy just moved into Applications reopens the welcome window and
    /// carries on with the rows chosen before the move. Only Helm's own mover passes it.
    public var continueSetup: [SetupRow]?
    public var isIsolated: Bool { home != nil || support != nil }
    public var isRoleCommand: Bool { defaultViewer != nil || dockFirst != nil || viewerStatus }
    public init() {}

    /// Printed when the arguments don't parse. A scripted run needs both fixture folders.
    public static let usage = """
        usage: Helm [--home PATH] [--support PATH] [PATH ...]
               Helm --home PATH --support PATH --smoke SCRIPT
               Helm [--default-viewer helm|finder] [--dock-first on|off] [--viewer-status]

        """

    /// Nil when the arguments are wrong, including `--smoke` without both `--home` and `--support`: a script
    /// may only drive fixture folders, never the real home folder or Helm's real data.
    public static func parse(_ arguments: [String]) -> LaunchOptions? {
        guard let options = parseFlags(arguments) else { return nil }
        if options.smokeScript != nil && (options.home == nil || options.support == nil) { return nil }
        return options
    }

    private static func parseFlags(_ arguments: [String]) -> LaunchOptions? {
        var options = LaunchOptions()
        var index = 1
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--home": guard let path = value() else { return nil }; options.home = URL(fileURLWithPath: path, isDirectory: true)
            case "--support": guard let path = value() else { return nil }; options.support = URL(fileURLWithPath: path, isDirectory: true)
            case "--smoke": guard let path = value() else { return nil }; options.smokeScript = URL(fileURLWithPath: path)
            case "--screenshot": guard let path = value() else { return nil }; options.screenshot = URL(fileURLWithPath: path)
            case "--default-viewer":
                switch value() { case "helm": options.defaultViewer = true; case "finder": options.defaultViewer = false; default: return nil }
            case "--dock-first":
                switch value() { case "on": options.dockFirst = true; case "off": options.dockFirst = false; default: return nil }
            case "--viewer-status": options.viewerStatus = true
            case SetupRow.continueFlag:
                guard let rows = value() else { return nil }
                options.continueSetup = SetupRow.rows(fromFlag: rows)
            default:
                let raw = arguments[index]
                // AppKit passes its own -NS… and -Apple… defaults through the arguments.
                if raw.hasPrefix("-") { index += 1 } else { options.open.append(URL(fileURLWithPath: raw)) }
            }
            index += 1
        }
        return options
    }
}

/// Owns everything that outlives a window: the environment, the windows, the menu, launch and quit (F-001, F-068).
@MainActor public final class AppController: NSObject, NSApplicationDelegate, BrowserWindowHost, NSMenuDelegate {
    private let options: LaunchOptions
    private var environment: AppEnvironment?
    private var windows: [BrowserWindowController] = []
    private var router = LaunchRouter()
    private var registry = WindowRegistry()
    private var ids: [ObjectIdentifier: AppWindowID] = [:]
    private var quit = QuitCoordinator()
    private var dependencies: WindowDependencies?
    private var settingsWindow: SettingsWindowController?
    private var fileViewer: FileViewerModel?
    /// Paths from the command line, until the first launch takes them.
    private var launchPaths: [URL]
    /// Requests that came before there were windows to take them, in order, each with the app that sent it.
    private var pending: [(request: ViewerRequest, sender: String?)] = []
    private var isLaunched = false
    /// The first windows are being placed: requests that come now wait, then go through once the windows exist.
    private(set) var isPlacingWindows = false
    /// Helm started only to pass a request on to Finder, so it opened no window. A click on its Dock icon launches as usual.
    private(set) var startedForFinder = false
    /// Documents that couldn't be read, until Helm has a window to say so over. A launch only for Finder has none, so
    /// the alert waits for the first window this run opens rather than coming up over Finder.
    private var unreportedLoadFailures: [AppFlushFailure] = []
    /// Called in place of that alert with the documents it names, so a test sees it without one coming up.
    var loadFailuresShownForTesting: (([String]) -> Void)?
    /// Called once the launch has taken the requests waiting for it, so a test can send one that comes after.
    var launchQueueTakenForTesting: (() -> Void)?
    /// A scripted run names the app an Apple Event stands for: macOS fills in an event's sender only as it delivers
    /// one from another process, and one built here can't carry it. It's used only while an event is being handled.
    var eventSenderForTesting: String?
    /// How long a helper's hand-offs outlast it. Its last request comes as it quits.
    var lastRequestGrace: TimeInterval = 10
    private var subscription: Any?
    private var coordinator: OperationCoordinator?
    /// Full Disk Access, the welcome window and its guide.
    let access: AccessCoordinator
    /// Who sent a request, and what Helm handed Finder's helpers lately: together they decide whether Helm or Finder shows it.
    let senders = SenderDirectory()
    let handoffs = HelperHandoffs()
    /// Finder, or in a fixture run a stand-in that only notes what Finder would have been asked to show.
    let finderHandback: any FinderHandingBack
    /// Windows stay invisible and Helm never comes to the front: scripted runs, and tests. The welcome window too.
    var staysInBackground: Bool { didSet { access.isInteractive = !staysInBackground } }
    /// Whether Archive Utility is running now. A fixture run never asks the real Mac, so what runs there can't change it.
    var isArchiveUtilityRunning: () -> Bool

    public init(options: LaunchOptions) {
        self.options = options
        launchPaths = options.open
        access = AccessCoordinator(isolated: options.isIsolated, interactive: options.smokeScript == nil)
        finderHandback = options.isIsolated ? RecordingFinderHandback() : SystemFinderHandback()
        staysInBackground = options.smokeScript != nil
        isArchiveUtilityRunning = options.isIsolated ? { false } : {
            FinderFamily.isArchiveUtilityLaunch(running: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        super.init()
        senders.helperQuit = { [weak self] helper in self?.helperQuit(helper) }
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenuBuilder.install(target: self)
        // Before the launch's own event arrives, so a reveal that starts Helm is caught too.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleRevealEvent(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kAEMiscStandards), andEventID: AEEventID(kAEMakeObjectsVisible))
        senders.start()
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Services › Open in Helm and Show in Helm, declared in Info.plist.
        NSApp.servicesProvider = self
        if !options.isIsolated { NSUpdateDynamicServices() }
        Task { @MainActor in await self.compose() }
    }

    func compose() async {
        do {
            let environment = try await makeEnvironment()
            self.environment = environment
            let operations = OperationCoordinator(fileSystem: environment.fileSystem, origins: environment.trashOrigins, journal: environment.journal)
            coordinator = operations
            subscription = operations.inFlightChanges.subscribe { [weak self] count in self?.operationsChanged(count) }
            let settings = environment.settings
            let volumes = VolumeCenter(isLive: !options.isIsolated, home: environment.directories.home) { settings.snapshot.bool(.showAllMountedVolumes) }
            dependencies = WindowDependencies(settings: environment.settings, bookmarks: environment.bookmarks, stars: environment.stars,
                recents: environment.recents, trashOrigins: environment.trashOrigins, viewOptions: environment.viewOptions, fileSystem: environment.fileSystem,
                operations: operations, home: environment.directories.home, volumes: volumes, icons: IconCache(limit: settings.snapshot.integer(.maxCachedIcons), previewLimit: settings.snapshot.integer(.maxCachedThumbnails)),
                sidebarLayout: environment.sidebarLayout,
                clock: environment.clock,
                pasteboard: options.isIsolated ? NSPasteboard(name: .init("helm.fixture.\(getpid())")) : .general,
                persistsWindowFrames: !options.isIsolated, openWith: environment.openWith, permissions: access.permissions,
                handoffs: handoffs,
                // A fixture run hands files to a stand-in: no app opens and no default app changes.
                launcher: options.isIsolated ? MemoryAppLauncher() : SystemAppLauncher())
            await access.start(settings: settings, fileViewer: { [weak self] in self?.fileViewerModel() },
                               windows: { [weak self] in self?.allWindows ?? [] })
            if options.smokeScript != nil { SmokeBackground.start() }
            await launchWindows(environment)
            environment.followPrivacySettings()
            // Off the launch path: a slow or missing disk mustn't hold up the first window.
            Task { @MainActor in await environment.forgetItemsGoneFromTrash() }
            unreportedLoadFailures = environment.loadFailures
            reportLoadFailures()
            // A launch that only passed something on to Finder stays out of the way.
            if !startedForFinder { access.showWelcomeIfNeeded(continuing: options.continueSetup) }
            if let script = options.smokeScript { HostSmokeDriver.run(script: script, app: self) }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Helm couldn’t start."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func makeEnvironment() async throws -> AppEnvironment {
        if options.isIsolated {
            let home = options.home ?? FileManager.default.temporaryDirectory.appendingPathComponent("helm-home")
            let support = options.support ?? home.appendingPathComponent(".helm-support")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let trash = home.appendingPathComponent(".Trash", isDirectory: true)
            return try await AppEnvironment.live(directories: AppDirectories(home: home, applicationSupport: support),
                                                 settingsStorage: IsolatedSettings(), legacyReader: NoLegacyDefaults(),
                                                 trash: { url in
                // Stands in for the system Trash, which a fixture run must never touch.
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                var destination = trash.appendingPathComponent(url.lastPathComponent)
                var ordinal = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    destination = trash.appendingPathComponent("\(url.lastPathComponent) \(ordinal)"); ordinal += 1
                }
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            })
        }
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Helm", isDirectory: true)
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
        return try await AppEnvironment.live(directories: AppDirectories(home: manager.homeDirectoryForCurrentUser, applicationSupport: support),
                                             settingsStorage: UserDefaultsAdapter(), legacyReader: LegacyUserDefaultsReader())
    }

    /// Requests take priority over restoration, which takes priority over a fresh Home window (F-002, F-068).
    /// A request that started in Finder goes back to Finder, and a launch that only did that opens no window.
    /// `askedFor` is the launch put off until a click on the Dock icon: someone asked for Helm.
    private func launchWindows(_ environment: AppEnvironment, askedFor: Bool = false) async {
        isPlacingWindows = true
        defer { isPlacingWindows = false }
        let home = environment.directories.home
        let session = environment.session.windows
        // Launch never waits on a folder macOS is still asking about, or on a slow disk (RestoredFolders).
        let restored = session.flatMap(\.tabs).compactMap(\.location.mutationTarget)
        let folders = await RestoredFolders.availability(of: restored, fileSystem: environment.fileSystem, home: home)
        // The command line's paths are Helm's; the rest came as Apple Events before there were windows to take them.
        let queued = launchPaths.map { (request: ViewerRequest.open([$0]), sender: String?.none) } + pending
        launchPaths = []
        pending = []
        launchQueueTakenForTesting?()
        var asked: [(url: URL, reveal: Bool)] = []
        var handedToFinder = false
        for item in queued {
            switch handoffs.route(item.request, sender: item.sender) {
            case .finder(let folders): finderHandback.show(folders: folders); handedToFinder = true
            // A reopen while launching: the launch shows a window anyway.
            case .helm(let reveal, _): asked += item.request.items.map { ($0, reveal) }
            }
        }
        // A double-click on an archive in Finder, with Helm not running: Archive Utility starts Helm as it quits, naming
        // nothing. That belongs to Finder, so Helm opens no window and stays out of the way. A launch that was asked for
        // never is: the one put off until a click on the Dock icon, or the copy Set Up moved into Applications, which
        // Helm's own mover opens.
        if queued.isEmpty, !askedFor, options.continueSetup == nil, isArchiveUtilityRunning() {
            handedToFinder = true
        }
        if asked.isEmpty && handedToFinder {
            // Started only to pass a request on to Finder: no window, and Helm stays out of the way.
            startedForFinder = true
            isLaunched = true
            drainPending()
            return
        }
        let requests = await classify(asked, fileSystem: environment.fileSystem)
        if !requests.isEmpty { _ = router.receive(requests) }
        let result = router.finishLaunch(session: session, restoreSession: environment.settings.snapshot.bool(.restoreSessionOnLaunch),
                                         home: home, isAvailableDirectory: { folders[$0] ?? false })
        isLaunched = true
        reportRejected(result.rejectedRequests)
        var created = result.windows
        // Only invalid requests: say so, then launch as usual rather than showing nothing (OK2-27).
        // Windows for folders asked for count as visits in Recent; a restored session and the first Home window don't.
        let opened = !created.isEmpty && !requests.isEmpty
        if created.isEmpty {
            created = [WindowCreationRequest(frameAutosaveName: router.allocateFrameName(),
                                             tabs: [TabCreationRequest(tab: SessionTab(location: .directory(home)))])]
        }
        for request in created { open(request, intent: opened ? .open : .restore) }
        // A scripted run stays in the background, so it doesn't take focus from whatever you're doing.
        if !staysInBackground { NSApp.activate(ignoringOtherApps: true) }
        // Requests that came while the windows were being placed go through now, rather than being lost.
        drainPending()
    }

    /// Each item as a launch or a window takes it. A reveal selects a folder in its own folder, as Finder's does;
    /// otherwise a folder opens.
    private func classify(_ asked: [(url: URL, reveal: Bool)], fileSystem: any FileSystem) async -> [ExternalOpenRequest] {
        var requests: [ExternalOpenRequest] = []
        for (url, reveal) in asked {
            do {
                let entry = try await fileSystem.entry(at: url)
                let opensInside = entry.isDirectoryLike && !reveal
                // Other apps send paths as they were given, such as ~/DOCUMENTS from a Terminal tab that went
                // `cd ~/documents`, or a path through a link. Each lands where it really is, spelled as the disk spells
                // it, as a typed path does: a folder through any link, a file in its real folder under its own name.
                let spelled = await Task.detached { opensInside ? CanonicalPath.resolve(url) : CanonicalPath.spelling(of: url) }.value
                requests.append(ExternalOpenRequest(url: spelled, kind: opensInside ? .folder : .file))
            } catch let error as FileSystemError where error == .notFound {
                requests.append(ExternalOpenRequest(url: url, kind: .unavailable))
            } catch {
                // A disk that's slow, or a folder macOS is still asking permission for, isn't a missing item:
                // show it in its folder, which then says what's wrong.
                requests.append(ExternalOpenRequest(url: url, kind: url.hasDirectoryPath && !reveal ? .folder : .file))
            }
        }
        return requests
    }

    private func open(_ request: WindowCreationRequest, intent: NavigationIntent) {
        guard let dependencies else { return }
        let seeds = request.tabs.map { tab in
            BrowserTabSeed(location: tab.tab.location, viewMode: tab.tab.viewMode, sort: tab.tab.sort, showHidden: tab.tab.showHidden,
                           selecting: tab.selectedURLs, intent: intent)
        }
        let controller = BrowserWindowController(dependencies: dependencies, host: self, frameName: request.frameAutosaveName,
                                                 seeds: seeds, activeIndex: request.activeTabIndex)
        register(controller)
        show(controller)
    }
    private func show(_ controller: BrowserWindowController) {
        if !staysInBackground { controller.showWindow(nil) } else { SmokeBackground.hide(controller.window); controller.window?.orderFrontRegardless() }
    }
    private func register(_ controller: BrowserWindowController) {
        let id = AppWindowID()
        ids[ObjectIdentifier(controller)] = id
        registry.register(id)
        windows.append(controller)
        // After a launch only for Finder, the first window says what couldn't be read, once it's up.
        if !unreportedLoadFailures.isEmpty { Task { @MainActor [weak self] in self?.reportLoadFailures() } }
    }

    // MARK: External opens: folders open, files are shown in their folder (OK2-10, amended).

    /// Folders open in the front window. A file is shown selected in its folder rather than launched: when
    /// Helm is the default file viewer, macOS delivers every "Show in Finder" from other apps this way, as a
    /// plain request to open the file. Several places open as tabs beside the first, so none is lost.
    /// What one of Finder's helpers sends goes back to Finder, unless Helm handed it the item (ViewerRouter).
    public func application(_ application: NSApplication, open urls: [URL]) {
        receive(.open(urls), from: currentSender())
    }

    /// An explicit reveal ('misc'/'mvis'): each item is shown selected in its folder, as Show in Helm does.
    @objc func handleRevealEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        receive(.reveal(ViewerEvent.items(in: event)), from: sender(of: event))
    }

    /// A request from outside Helm: shown here, or handed to Finder when it started in Finder. Before the windows
    /// exist it waits, and goes through as soon as they do.
    func receive(_ request: ViewerRequest, from sender: String?) {
        if case .reopen = request { _ = reopen(from: sender, hasVisibleWindows: hasVisibleWindows); return }
        guard isLaunched, environment != nil else { pending.append((request: request, sender: sender)); return }
        switch handoffs.route(request, sender: sender) {
        case .finder(let folders): finderHandback.show(folders: folders)
        case .helm(let reveal, _): show(request.items, reveal: reveal)
        }
    }

    /// A reopen: a click on the Dock icon, a double-click on Helm in Finder, or a reveal of nothing. Returns whether
    /// AppKit should do its usual part.
    func reopen(from sender: String?, hasVisibleWindows flag: Bool) -> Bool {
        guard isLaunched, let environment else { pending.append((request: .reopen, sender: sender)); return false }
        switch handoffs.route(.reopen, sender: sender) {
        case .finder(let folders):
            // Archive Utility brings the file viewer forward as it quits. When Finder started it, Finder comes forward.
            finderHandback.show(folders: folders)
            return false
        case .helm(_, let handoff?):
            showExpanded(handoff)
            return false
        case .helm(_, nil):
            if startedForFinder {
                // Helm started only to pass something to Finder; this is the launch it put off.
                startedForFinder = false
                Task { @MainActor in await self.launchWindows(environment, askedFor: true) }
                return false
            }
            // The Dock icon opens a window where ⌘N would with no window open, as Finder's does.
            if registry.needsWindowOnReopen(hasVisibleWindows: flag) { openStartingWindow() }
            return true
        }
    }

    /// A helper quit. A little later, whatever Helm handed it before then is done with, even if its last request never
    /// came, so a double-click on an archive in Finder afterwards isn't taken for Helm's.
    func helperQuit(_ helper: String) {
        let quitAt = handoffs.now
        let grace = lastRequestGrace
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            self?.handoffs.quit(helper: helper, at: quitAt)
        }
    }

    /// Requests that came while the windows were being placed go through as they would now.
    private func drainPending() {
        let queued = pending
        pending = []
        for item in queued { receive(item.request, from: item.sender) }
    }

    private var hasVisibleWindows: Bool { windows.contains { $0.window?.isVisible == true } }

    /// The app that sent the Apple Event being handled now, if any.
    private func currentSender() -> String? {
        NSAppleEventManager.shared().currentAppleEvent.flatMap(sender(of:))
    }
    private func sender(of event: NSAppleEventDescriptor) -> String? {
        eventSenderForTesting ?? senders.identifier(of: ViewerEvent.senderPID(of: event))
    }

    /// Shows items in Helm. A reveal selects each one in its folder, folders included; otherwise a folder opens.
    private func show(_ urls: [URL], reveal: Bool) {
        guard let environment else { return }
        Task { @MainActor in
            let requests = await classify(urls.map { ($0, reveal) }, fileSystem: environment.fileSystem)
            var rejected: [ExternalOpenRequest] = []
            var places: [(folder: URL, selecting: [URL])] = []
            for request in requests {
                switch request.kind {
                case .unavailable: rejected.append(request)
                case .folder: places.append((request.url, []))
                case .file:
                    let parent = request.url.deletingLastPathComponent()
                    if let index = places.firstIndex(where: { !$0.selecting.isEmpty && BrowserWindowController.isSame($0.folder, parent) }) {
                        places[index].selecting.append(request.url)
                    } else {
                        places.append((parent, [request.url]))
                    }
                }
            }
            present(places)
            reportRejected(rejected)
        }
    }

    /// The first place in the front window, the rest as tabs beside it; then Helm comes forward.
    private func present(_ places: [(folder: URL, selecting: [URL])]) {
        guard let first = places.first else { return }
        startedForFinder = false
        let front: BrowserWindowController?
        if let window = frontmost() {
            window.show(folder: first.folder, selecting: first.selecting)
            front = window
        } else {
            openWindow(at: .directory(first.folder), selecting: first.selecting)
            front = frontmost()
        }
        for place in places.dropFirst() { front?.newTab(at: .directory(place.folder), selecting: place.selecting) }
        if let front { show(front) }
        if !staysInBackground { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Archive Utility brings the file viewer forward as it quits. When Helm handed it the archive, Helm shows the
    /// archive's folder with what appeared there selected, or the archive itself when nothing new turned up.
    private func showExpanded(_ handoff: HelperHandoff) {
        handoffs.finished(helper: handoff.helper)
        guard let environment else { return }
        Task { @MainActor in
            let names = (try? await environment.fileSystem.childNames(of: handoff.folder)) ?? []
            let added = handoff.added(in: names).filter { !$0.hasPrefix(".") }
            let selecting = added.isEmpty ? (names.contains(handoff.item.lastPathComponent) ? [handoff.item] : [])
                                          : added.map { handoff.folder.appendingPathComponent($0) }
            present([(handoff.folder, selecting)])
        }
    }

    // MARK: Services: Open in Helm, Show in Helm (P-238)

    /// Services › Open in Helm: folders open, anything else is shown in its folder. You chose Helm, so it stays here.
    @objc func openInHelm(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(on: pasteboard)
        guard !urls.isEmpty else { error.pointee = "Nothing to open." as NSString; return }
        receive(.open(urls), from: nil)
    }
    /// Services › Show in Helm: every item, folders included, is shown selected in its enclosing folder. It's a reveal,
    /// so it waits for the launch when it starts Helm, as Open in Helm does, and you chose Helm, so it stays here.
    @objc func showInHelm(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(on: pasteboard)
        guard !urls.isEmpty else { error.pointee = "Nothing to show." as NSString; return }
        receive(.reveal(urls), from: nil)
    }
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func reportRejected(_ requests: [ExternalOpenRequest]) {
        guard let first = requests.first else { return }
        let alert = NSAlert()
        alert.messageText = requests.count == 1 ? "“\(first.url.lastPathComponent)” couldn’t be found." : "\(requests.count) items couldn’t be found."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: BrowserWindowHost

    public func openWindow(at location: Location, selecting: [URL]) {
        guard let dependencies else { return }
        // A new window is a visit to its folder, which Recent records.
        let controller = BrowserWindowController(dependencies: dependencies, host: self, frameName: router.allocateFrameName(),
                                                 seeds: [BrowserTabSeed(location: location, selecting: selecting, intent: .open)], activeIndex: 0)
        register(controller)
        show(controller)
    }
    public func windowDidClose(_ controller: BrowserWindowController) {
        // The last window to close is what reopening restores. Any other closed window drops out of the session (F-068).
        if windows.count == 1 { saveSession() }
        router.releaseFrameName(controller.frameName)
        if let id = ids.removeValue(forKey: ObjectIdentifier(controller)) { registry.close(id) }
        windows.removeAll { $0 === controller }
        if !windows.isEmpty { saveSession() }
    }
    public func windowDidBecomeKey(_ controller: BrowserWindowController) {
        if let id = ids[ObjectIdentifier(controller)] { registry.activate(id) }
    }
    public func showSettings() { showSettingsWindow(nil) }
    public func showSettings(pane: SettingsPane) { showSettingsWindow(nil); settingsWindow?.select(pane) }
    public func requestQuitAnyway() { NSApp.reply(toApplicationShouldTerminate: true) }

    func frontmost() -> BrowserWindowController? {
        Self.front(of: windows, key: NSApp.keyWindow, main: NSApp.mainWindow, inBackground: staysInBackground)
    }
    /// The browser window that commands and requests go to: the key window, or the main one when Settings or a panel is
    /// key. A scripted run never makes its windows key or main, so there it's the window opened last, as a new window is
    /// the one in front.
    static func front(of windows: [BrowserWindowController], key: NSWindow?, main: NSWindow?,
                      inBackground: Bool) -> BrowserWindowController? {
        if !inBackground {
            if let key = key?.windowController as? BrowserWindowController { return key }
            if let main = main?.windowController as? BrowserWindowController { return main }
        }
        return windows.last
    }
    var allWindows: [BrowserWindowController] { windows }
    var settingsWindowForTesting: NSWindow? { settingsWindow?.window }
    var settingsControllerForTesting: SettingsWindowController? { settingsWindow }
    var fileViewerForTesting: FileViewerModel? { fileViewer }
    /// What a fixture run would have asked Finder to show: folders, or none when Finder was only brought forward.
    var finderShownForTesting: [[URL]] { (finderHandback as? RecordingFinderHandback)?.shown ?? [] }
    func setting(_ key: SettingKey, to value: Bool) { environment?.settings.set(.bool(value), for: key) }
    func setting(_ key: SettingKey, toString value: String) { environment?.settings.set(.string(value), for: key) }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Any state AppKit saves for Helm is read back only through secure coding. Browser windows and Settings save none.
    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    /// A click on the Dock icon, a double-click on Helm in Finder, or a reveal of nothing: Archive Utility sends one
    /// as it quits (ViewerRouter). AppKit's part brings Helm to the front, so a scripted run leaves it out.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopen(from: currentSender(), hasVisibleWindows: flag) && !staysInBackground
    }

    // MARK: Menu actions

    /// View › Sort By shows the front window's sort, so it's filled as it opens.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.title == "Open With" {
            if let front = frontmost() { front.fillOpenWithItems(in: menu) }
            else { menu.addItem(NSMenuItem(title: "No Window Open", action: nil, keyEquivalent: "")) }
            return
        }
        frontmost()?.fillSortItems(in: menu)
    }

    @objc func newWindow(_ sender: Any?) {
        if let front = frontmost() { openWindow(at: front.newWindowLocation, selecting: []) } else { openStartingWindow() }
    }
    /// A window at the folder Settings › General › New windows open names, when there's no front window to follow.
    private func openStartingWindow() {
        guard let environment else { return }
        let choice = NewWindowLocation(rawValue: environment.settings.snapshot.string(.newWindowLocation)) ?? .current
        openWindow(at: .directory(choice.folder(current: nil, home: environment.directories.home)), selecting: [])
    }
    @objc func quit(_ sender: Any?) { NSApp.terminate(sender) }
    @objc func orderFrontAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Helm", .credits: NSAttributedString(string: "Finder underneath, Nautilus on top.")])
    }
    @objc func showSettingsWindow(_ sender: Any?) {
        guard environment != nil else { return }
        makeSettingsWindowIfNeeded()
        fileViewer?.refresh()
        if let dependencies, settingsWindow?.sidebarModel == nil { settingsWindow?.showSidebarRows(SidebarSettingsModel(dependencies: dependencies)) }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    /// Helm › Advanced Options…: Settings, open at Advanced whichever pane was on show last.
    @objc func showAdvancedOptions(_ sender: Any?) { showSettings(pane: .advanced) }
    /// Makes the Settings window the first time it's needed, without showing it.
    func makeSettingsWindowIfNeeded() {
        guard let environment, settingsWindow == nil else { return }
        settingsWindow = SettingsWindowController(store: environment.settings, fileViewer: fileViewerModel(),
                                                  access: access.settingsSection, persistsFrame: !options.isIsolated)
    }
    /// One model for Settings and the welcome window, so both show the same switches. In a fixture run, nothing outside Helm changes.
    func fileViewerModel() -> FileViewerModel {
        if let fileViewer { return fileViewer }
        let role: any FileViewerRegistering = options.isIsolated ? MemoryFileViewerRole() : SystemFileViewerRole()
        let model = FileViewerModel(role: role)
        fileViewer = model
        return model
    }

    // MARK: Quit: wait for operations, save, then go (F-068, OK2-29).

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveSession()
        switch quit.requestQuit(inFlightOperations: coordinator?.inFlight ?? 0) {
        case .waitForOperations: return .terminateLater
        case .flushStores: flush(); return .terminateLater
        case .terminate: return .terminateNow
        case .none, .cancelQuit: return .terminateCancel
        }
    }
    private func operationsChanged(_ count: Int) {
        if quit.operationsChanged(inFlightOperations: count) == .flushStores { flush() }
    }
    private func flush() {
        guard let environment else { NSApp.reply(toApplicationShouldTerminate: true); return }
        Task { @MainActor in
            let failures = await environment.flushStores()
            switch quit.flushCompleted(succeeded: failures.isEmpty) {
            case .terminate: NSApp.reply(toApplicationShouldTerminate: true)
            default: askAboutFailedSave(failures)
            }
        }
    }
    private func askAboutFailedSave(_ failures: [AppFlushFailure]) {
        let names = failures.map(\.document).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Helm couldn’t save: \(names)."
        alert.informativeText = "If you quit now, recent changes to these will be lost. The disk may be full."
        alert.addButton(withTitle: "Try Again"); alert.addButton(withTitle: "Quit Anyway"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if quit.requestQuit(inFlightOperations: coordinator?.inFlight ?? 0) == .flushStores { flush() }
        case .alertSecondButtonReturn:
            NSApp.reply(toApplicationShouldTerminate: true)
        default:
            _ = quit.cancel()
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }
    private func saveSession() {
        guard let environment else { return }
        let saved: [SessionWindow] = windows.map { controller in
            let state = controller.store.state
            // A place macOS refused is what reopens, so quitting and reopening after giving access lands back there.
            let tabs = state.window.tabs.compactMap { state.tabs[$0] }.map {
                SessionTab(location: ContentStatePresentation.sessionLocation(for: $0, home: environment.directories.home,
                                                                              fullDiskAccess: access.permissions.fullDiskAccess),
                           viewMode: $0.viewMode, sort: $0.sort, showHidden: $0.showHidden)
            }
            return SessionWindow(frameAutosaveName: controller.frameName, tabs: tabs,
                                 activeTabIndex: state.window.tabs.firstIndex(of: state.window.activeTabID) ?? 0)
        }
        // Nothing is kept while Reopen windows and tabs is off.
        environment.saveSession(saved)
    }

    /// Says which documents couldn't be read: once, and only while Helm has a window, so a launch only for Finder
    /// never puts an alert over Finder.
    private func reportLoadFailures() {
        guard !unreportedLoadFailures.isEmpty, !windows.isEmpty else { return }
        let documents = unreportedLoadFailures.map(\.document)
        unreportedLoadFailures = []
        if let shown = loadFailuresShownForTesting { shown(documents); return }
        let alert = NSAlert()
        alert.messageText = "Some Helm data couldn’t be read."
        alert.informativeText = documents.joined(separator: ", ")
            + "\n\nHelm will keep working, but changes to these won’t be saved this time. The original files haven’t been changed."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// File › Close Tab and Close Window, and Window › Minimize and Zoom, reach a browser window through its responder
/// chain. Settings, the welcome window and About have no tabs, and nothing of their own answers those items, so they
/// come here last: ⌘W closes the window in front and ⌘M minimises it, as in Finder and System Settings.
extension AppController: NSMenuItemValidation {
    @objc func helmCommand(_ sender: NSMenuItem) {
        guard let window = windowWithoutTabs, let command = Self.windowCommand(sender), Self.window(window, allows: command) else { return }
        switch command {
        case .minimize: window.performMiniaturize(sender)
        case .zoom: window.performZoom(sender)
        default: window.performClose(sender)
        }
    }
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(helmCommand(_:)) else { return true }
        // Every other File, Edit, View and Go item needs a browser window, so it stays off.
        guard let window = windowWithoutTabs, let command = Self.windowCommand(item) else { return false }
        return Self.window(window, allows: command)
    }
    /// The window in front, when it isn't a browser window. Those answer these items themselves. While Helm isn't the
    /// active app none is key, as when its menu is used from outside it, so that's the frontmost one on show.
    private var windowWithoutTabs: NSWindow? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first(where: \.isVisible),
              !(window.windowController is BrowserWindowController) else { return nil }
        return window
    }
    private static func windowCommand(_ item: NSMenuItem) -> CommandID? {
        guard let command = (item.representedObject as? String).flatMap(CommandID.init(rawValue:)),
              [.closeTab, .closeWindow, .minimize, .zoom].contains(command) else { return nil }
        return command
    }
    private static func window(_ window: NSWindow, allows command: CommandID) -> Bool {
        switch command {
        case .minimize: return window.styleMask.contains(.miniaturizable)
        case .zoom: return window.styleMask.contains(.resizable)
        default: return window.styleMask.contains(.closable)
        }
    }
}

/// Settings for a fixture run: in memory, so nothing reaches the real preferences.
@MainActor final class IsolatedSettings: KeyValueStoring {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func register(defaults: [String: Any]) { values.merge(defaults) { old, _ in old } }
}

/// A fixture run reads no legacy preferences.
@MainActor final class NoLegacyDefaults: LegacyDefaultsReading {
    func data(forKey key: String, domain: String?) -> Data? { nil }
    func storedSetting(for key: SettingKey, domain: String) -> SettingValue? { nil }
    func hasStoredSetting(for key: SettingKey, domain: String) -> Bool { false }
}

#endif
