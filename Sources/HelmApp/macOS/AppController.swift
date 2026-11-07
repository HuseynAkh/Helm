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
    public var isIsolated: Bool { home != nil || support != nil }
    public init() {}

    public static func parse(_ arguments: [String]) -> LaunchOptions? {
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
    private var settingsWindow: NSWindow?
    private var pendingOpens: [URL] = []
    private var isLaunched = false
    private var subscription: Any?
    private var coordinator: OperationCoordinator?

    public init(options: LaunchOptions) { self.options = options }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenuBuilder.install(target: self)
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await self.compose() }
    }

    private func compose() async {
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
                clock: environment.clock,
                pasteboard: options.isIsolated ? NSPasteboard(name: .init("helm.fixture.\(getpid())")) : .general,
                persistsWindowFrames: !options.isIsolated, openWith: environment.openWith)
            await launchWindows(environment)
            reportLoadFailures(environment)
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
    private func launchWindows(_ environment: AppEnvironment) async {
        let requested = options.open + pendingOpens
        pendingOpens = []
        let home = environment.directories.home
        let session = environment.session.windows
        var folders: [URL: Bool] = [:]
        for window in session {
            for tab in window.tabs {
                if case .directory(let url) = tab.location { folders[url] = await environment.fileSystem.isDirectory(url, resolvingSymlinks: true) }
            }
        }
        let requests = await classify(requested, fileSystem: environment.fileSystem)
        if !requests.isEmpty { _ = router.receive(requests) }
        let result = router.finishLaunch(session: session, restoreSession: environment.settings.snapshot.bool(.restoreSessionOnLaunch),
                                         home: home, isAvailableDirectory: { folders[$0] ?? false })
        isLaunched = true
        reportRejected(result.rejectedRequests)
        var created = result.windows
        // Only invalid requests: say so, then launch as usual rather than showing nothing (OK2-27).
        if created.isEmpty {
            created = [WindowCreationRequest(frameAutosaveName: router.allocateFrameName(),
                                             tabs: [TabCreationRequest(tab: SessionTab(location: .directory(home)))])]
        }
        for request in created { open(request) }
        // A scripted run stays in the background, so it doesn't take focus from whatever you're doing.
        if options.smokeScript == nil { NSApp.activate(ignoringOtherApps: true) }
    }

    private func classify(_ urls: [URL], fileSystem: any FileSystem) async -> [ExternalOpenRequest] {
        var requests: [ExternalOpenRequest] = []
        for url in urls {
            guard let entry = try? await fileSystem.entry(at: url) else {
                requests.append(ExternalOpenRequest(url: url, kind: .unavailable)); continue
            }
            requests.append(ExternalOpenRequest(url: url, kind: entry.isDirectoryLike ? .folder : .file))
        }
        return requests
    }

    private func open(_ request: WindowCreationRequest) {
        guard let dependencies else { return }
        let seeds = request.tabs.map { tab in
            BrowserTabSeed(location: tab.tab.location, viewMode: tab.tab.viewMode, sort: tab.tab.sort, showHidden: tab.tab.showHidden, selecting: tab.selectedURLs)
        }
        let controller = BrowserWindowController(dependencies: dependencies, host: self, frameName: request.frameAutosaveName,
                                                 seeds: seeds, activeIndex: request.activeTabIndex)
        register(controller)
        show(controller)
    }
    private func show(_ controller: BrowserWindowController) {
        if options.smokeScript == nil { controller.showWindow(nil) } else { controller.window?.orderFrontRegardless() }
    }
    private func register(_ controller: BrowserWindowController) {
        let id = AppWindowID()
        ids[ObjectIdentifier(controller)] = id
        registry.register(id)
        windows.append(controller)
    }

    // MARK: External opens: folders navigate the key window, files launch (OK2-10).

    public func application(_ application: NSApplication, open urls: [URL]) {
        guard isLaunched, let environment else { pendingOpens += urls; return }
        Task { @MainActor in
            let requests = await classify(urls, fileSystem: environment.fileSystem)
            var rejected: [ExternalOpenRequest] = []
            var files: [URL] = []
            var folders: [URL] = []
            for request in requests {
                switch request.kind {
                case .unavailable: rejected.append(request)
                case .file: files.append(request.url)
                case .folder: folders.append(request.url)
                }
            }
            // The first folder shows in the front window and any others open beside it as tabs, so none is lost.
            if let first = folders.first {
                if let front = frontmost() {
                    front.navigate(to: .directory(first))
                    for folder in folders.dropFirst() { front.newTab(at: .directory(folder)) }
                    front.showWindow(nil)
                } else {
                    openWindow(at: .directory(first), selecting: [])
                    for folder in folders.dropFirst() { frontmost()?.newTab(at: .directory(folder)) }
                }
            }
            // Each file opens in its own default app, as if double-clicked.
            var byApp: [URL: [URL]] = [:]
            var unclaimed: [URL] = []
            for file in files {
                if let app = NSWorkspace.shared.urlForApplication(toOpen: file) { byApp[app, default: []].append(file) } else { unclaimed.append(file) }
            }
            for (app, group) in byApp {
                NSWorkspace.shared.open(group, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
            for file in unclaimed { NSWorkspace.shared.open(file) }
            reportRejected(rejected)
        }
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
        let controller = BrowserWindowController(dependencies: dependencies, host: self, frameName: router.allocateFrameName(),
                                                 seeds: [BrowserTabSeed(location: location, selecting: selecting)], activeIndex: 0)
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
    public func requestQuitAnyway() { NSApp.reply(toApplicationShouldTerminate: true) }

    func frontmost() -> BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? BrowserWindowController)
            ?? windows.last
    }
    var allWindows: [BrowserWindowController] { windows }
    var settingsWindowForTesting: NSWindow? { settingsWindow }
    func setting(_ key: SettingKey, to value: Bool) { environment?.settings.set(.bool(value), for: key) }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if registry.needsWindowOnReopen(hasVisibleWindows: flag), let home = environment?.directories.home {
            openWindow(at: .directory(home), selecting: [])
        }
        return true
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
        if let front = frontmost(), let location = front.activeTab?.location { openWindow(at: location, selecting: []) }
        else if let home = environment?.directories.home { openWindow(at: .directory(home), selecting: []) }
    }
    @objc func quit(_ sender: Any?) { NSApp.terminate(sender) }
    @objc func orderFrontAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Helm", .credits: NSAttributedString(string: "Finder underneath, Nautilus on top.")])
    }
    @objc func showSettingsWindow(_ sender: Any?) {
        guard let environment else { return }
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: SettingsRoot(store: environment.settings))
        let window = NSWindow(contentViewController: host)
        window.title = "Helm Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
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
            let tabs = state.window.tabs.compactMap { state.tabs[$0] }.map {
                SessionTab(location: $0.location, viewMode: $0.viewMode, sort: $0.sort, showHidden: $0.showHidden)
            }
            return SessionWindow(frameAutosaveName: controller.frameName, tabs: tabs,
                                 activeTabIndex: state.window.tabs.firstIndex(of: state.window.activeTabID) ?? 0)
        }
        if !saved.isEmpty { environment.session.replace(windows: saved) }
    }

    private func reportLoadFailures(_ environment: AppEnvironment) {
        guard !environment.loadFailures.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Some Helm data couldn’t be read."
        alert.informativeText = environment.loadFailures.map(\.document).joined(separator: ", ")
            + "\n\nHelm will keep working, but changes to these won’t be saved this time. The original files haven’t been changed."
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

/// The settings window: one tab per pane, redrawn from the store's snapshot.
private struct SettingsRoot: View {
    let store: SettingsStore
    @State private var snapshot: SettingsSnapshot
    init(store: SettingsStore) { self.store = store; _snapshot = State(initialValue: store.snapshot) }
    var body: some View {
        TabView {
            ForEach(SettingsPane.allCases) { pane in
                ScrollView {
                    SettingsPaneView(pane: pane, snapshot: snapshot) { key, value in
                        store.set(value, for: key)
                        snapshot = store.snapshot
                    }.padding(20)
                }
                .tabItem { Text(pane.rawValue.capitalized) }
            }
        }
        .frame(width: 560, height: 460)
    }
}
#endif
