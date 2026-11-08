#if os(macOS)
import AppKit
import HelmCore
import HelmFileSystem
import HelmOperations
import HelmPersistence
import Quartz
import SwiftUI

/// One tab's starting point.
public struct BrowserTabSeed {
    public let location: Location
    public let viewMode: ViewMode?
    public let sort: ItemSort?
    public let showHidden: Bool?
    public let selecting: [URL]
    public init(location: Location, viewMode: ViewMode? = nil, sort: ItemSort? = nil, showHidden: Bool? = nil, selecting: [URL] = []) {
        self.location = location; self.viewMode = viewMode; self.sort = sort
        self.showHidden = showHidden; self.selecting = selecting
    }
}

@MainActor private final class StoreBox { weak var store: WindowStore? }

/// A wash of the window colour over the blur, so files stay readable on any wallpaper.
@MainActor final class TintView: NSView {
    var fraction: CGFloat = 0.55 { didSet { refresh() } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; refresh() }
    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(fraction).cgColor
        }
    }
}

/// How much solid colour lies over each part of the window for a transparency percentage.
/// The sidebar clears first, the files later, so names stay readable.
struct WindowTints: Equatable {
    let sidebar: CGFloat
    let content: CGFloat
    init(percent: Double) {
        let amount = CGFloat(min(100, max(0, percent))) / 100
        sidebar = max(0, 1 - 2 * amount)
        content = max(0, 1 - 1.1 * amount)
    }
}

/// One Helm window. It renders the store's state and turns user intent into store actions and file commands.
/// Nautilus's shape: a clean header bar, a Places sidebar and one content pane with tabs.
@MainActor public final class BrowserWindowController: NSWindowController, NSWindowDelegate,
    NSMenuItemValidation, FileContentHost, SidebarDelegate, PathBarDelegate, TabStripDelegate, HeaderBarDelegate {

    public let dependencies: WindowDependencies
    public private(set) weak var host: BrowserWindowHost?
    public let frameName: String
    public let store: WindowStore
    let history = WindowOperationHistory()
    var historyState = OperationHistoryState()
    private let effects: HostEffectRunner
    private let directoryRunner: DirectoryEffectRunner

    let split = NSSplitViewController()
    let sidebar = SidebarController()
    let header = HeaderBarView()
    var pathBar: PathBarView { header.pathBar }
    private var sidebarItem: NSSplitViewItem?
    private let contentEffect = NSVisualEffectView()
    private let contentTint = TintView()
    private let viewOptions = ViewOptionsPopover()
    /// Opens a folder held under a drag.
    let springs = SpringLoader()
    /// Per drag: whether an app can open what's dragged over it.
    var appDropAnswers: [String: Bool] = [:]
    let tabStrip = TabStripView()
    private let contentContainer = NSView()
    private let list = FileListController()
    private let grid = FileGridController()
    private let statusHost = NSHostingView(rootView: StatusBarView(status: StatusPresentation(itemCount: 0)))
    private let overlay = NSTextField(wrappingLabelWithString: "")
    private let operationsHost = NSHostingView(rootView: AnyView(EmptyView()))
    private var operationsHeight: NSLayoutConstraint?
    private var tabStripHeight: NSLayoutConstraint?
    private var shownContent: FileContentPresenting?
    private var shownMode: ViewMode?
    private var subscriptions: [Any] = []
    private var pendingSelections: [TabID: Set<ItemID>] = [:]
    private var pendingRename: (tab: TabID, id: ItemID)?
    private var freeBytes: [String: Int64] = [:]
    /// Shown in the status bar while the window works on something with no operations row, such as compressing.
    private var busyMessage: String?
    private var freeRequested: String?
    private var searchDebounce: Task<Void, Never>?
    var closedTabs: [Location] = []
    var cutTransaction: ClipboardTransaction?
    private var lastRenderedTab: TabID?
    private var starredIDs: Set<ItemID> = []
    private var quickLookEntries: [FileEntry] = []
    private var rememberedLocations: [TabID: Location] = [:]
    /// Scripted runs answer dialogs through these, since nobody is there to click.
    public var conflictChoiceForTesting: ConflictResolution?
    public var confirmsForTesting = false
    /// Scripted runs read messages here, since nobody is there to dismiss a sheet.
    public var messageObserver: ((String) -> Void)?
    /// Scripted runs answer failure prompts here instead of in a sheet.
    public var failureObserver: ((StepFailure) -> FailureDecision)?

    public init(dependencies: WindowDependencies, host: BrowserWindowHost, frameName: String, seeds: [BrowserTabSeed], activeIndex: Int) {
        self.dependencies = dependencies; self.host = host; self.frameName = frameName
        let settings = dependencies.settings.snapshot
        let seeds = seeds.isEmpty ? [BrowserTabSeed(location: .directory(dependencies.home))] : seeds
        var tabs: [TabState] = []
        var selections: [TabID: Set<ItemID>] = [:]
        for seed in seeds {
            var tab = TabState(location: seed.location, homeDirectory: dependencies.home, settings: settings)
            if let mode = seed.viewMode { tab.viewMode = mode }
            if let sort = seed.sort { tab.sort = sort }
            if let hidden = seed.showHidden { tab.showHidden = hidden }
            tabs.append(tab)
            if !seed.selecting.isEmpty { selections[tab.id] = Set(seed.selecting.map { ItemID(url: $0) }) }
        }
        let active = tabs[min(max(0, activeIndex), tabs.count - 1)].id
        effects = HostEffectRunner(dependencies: dependencies)
        let loader = DirectoryLoader(fileSystem: dependencies.fileSystem)
        // Monitor reloads must use the tab's own hidden-files and sort choices, not the defaults.
        let storeBox = StoreBox()
        let live = settings.bool(.liveMonitoringEnabled)
        // With live monitoring off, no watch is started and folders refresh only on request.
        let noMonitor: @MainActor (Location) -> (any DirectoryMonitor)? = { _ in nil }
        directoryRunner = DirectoryEffectRunner(loader: loader, options: { id in
            guard let tab = storeBox.store?.state.tabs[id] else { return LoadOptions() }
            return LoadOptions(showHidden: tab.showHidden, sort: tab.sort)
        }, fallback: effects, monitorFactory: live ? nil : noMonitor)
        store = WindowStore(window: WindowState(tabs: tabs.map(\.id), activeTabID: active), tabs: tabs, runner: directoryRunner,
                            clock: dependencies.clock,
                            context: ReducerContext(now: dependencies.clock.now(), homeDirectory: dependencies.home, settings: settings))
        storeBox.store = store
        pendingSelections = selections
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        effects.window = self
        configureWindow(window)
        subscribe()
        for tab in tabs { store.send(.tab(tab.id, .navigate(tab.location, .restore))) }
        render(store.state)
        focusContent()
    }
    required init?(coder: NSCoder) { nil }

    public var activeTab: TabState? { store.state.tabs[store.state.window.activeTabID] }
    public var activeTabID: TabID { store.state.window.activeTabID }

    // MARK: Window

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed // Our own strip owns tabs.
        window.minSize = NSSize(width: 620, height: 380)
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true // Tab moves between sidebar, content and path bar.
        window.isMovableByWindowBackground = false
        if dependencies.persistsWindowFrames { window.setFrameAutosaveName(frameName) }

        // Plain split items: a system sidebar item would float on macOS's own glass panel, which is Finder's look.
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 190; sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .init(260)
        self.sidebarItem = sidebarItem
        sidebar.delegate = self
        springs.open = { [weak self] url in self?.navigate(to: .directory(url)) }
        let contentController = NSViewController()
        contentController.view = buildContentArea()
        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 420
        split.addSplitViewItem(sidebarItem); split.addSplitViewItem(contentItem)
        split.splitView.dividerStyle = .thin
        if dependencies.persistsWindowFrames { split.splitView.autosaveName = "HelmSplit" }
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1040, height: 680))
        if !dependencies.persistsWindowFrames || !window.setFrameUsingName(frameName) { window.center() }
        split.view.layoutSubtreeIfNeeded()
        if !dependencies.persistsWindowFrames || split.splitView.subviews.first.map({ $0.frame.width > 340 || $0.frame.width < 190 }) == true {
            split.splitView.setPosition(232, ofDividerAt: 0)
        }

        // An empty toolbar only sets the title bar's height, which centres the window buttons on the header bar.
        window.toolbar = NSToolbar(identifier: "HelmHeader")
        window.toolbarStyle = .unified

        list.host = self; grid.host = self
        pathBar.delegate = self; tabStrip.delegate = self; header.delegate = self
        applyTransparency()
    }

    private func buildContentArea() -> NSView {
        let root = contentEffect
        root.blendingMode = .behindWindow
        root.state = .active
        for view in [contentTint, header, tabStrip, contentContainer, overlay, operationsHost, statusHost] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        overlay.alignment = .center; overlay.textColor = .secondaryLabelColor; overlay.font = .systemFont(ofSize: 16)
        overlay.isHidden = true; overlay.isSelectable = false
        let stripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        tabStripHeight = stripHeight
        let operations = operationsHost.heightAnchor.constraint(equalToConstant: 0)
        operationsHeight = operations
        NSLayoutConstraint.activate([
            contentTint.topAnchor.constraint(equalTo: root.topAnchor), contentTint.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentTint.leadingAnchor.constraint(equalTo: root.leadingAnchor), contentTint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: header.bottomAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor), tabStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripHeight,
            contentContainer.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor), contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: operationsHost.topAnchor),
            overlay.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor), overlay.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: contentContainer.widthAnchor, multiplier: 0.8),
            operationsHost.leadingAnchor.constraint(equalTo: root.leadingAnchor), operationsHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            operations,
            operationsHost.bottomAnchor.constraint(equalTo: statusHost.topAnchor),
            statusHost.leadingAnchor.constraint(equalTo: root.leadingAnchor), statusHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusHost.bottomAnchor.constraint(equalTo: root.bottomAnchor), statusHost.heightAnchor.constraint(equalToConstant: 28)
        ])
        return root
    }

    /// The window lets the desktop show through, more in the sidebar than behind the files, which keeps text readable.
    /// The amount runs from 0% (solid) through 50% (Helm's own look) to 100% (as clear as the materials allow).
    private func applyTransparency() {
        let settings = dependencies.settings.snapshot
        let transparent = settings.bool(.sidebarLiquidGlass)
        let tints = WindowTints(percent: transparent ? settings.double(.windowTransparency) : 0)
        sidebar.setTransparent(transparent, tint: tints.sidebar)
        contentEffect.material = transparent ? .underWindowBackground : .windowBackground
        contentEffect.blendingMode = transparent ? .behindWindow : .withinWindow
        contentTint.fraction = tints.content
    }

    private func subscribe() {
        subscriptions.append(store.snapshots.subscribe { [weak self] snapshot in self?.render(snapshot) })
        subscriptions.append(dependencies.bookmarks.changes.subscribe { [weak self] _ in self?.renderSidebar() })
        subscriptions.append(dependencies.stars.changes.subscribe { [weak self] records in
            self?.starredIDs = Set(records.map { ItemID(rawValue: $0.path) })
            self?.renderSidebar(); self?.renderContent(force: true)
        })
        starredIDs = Set(dependencies.stars.records.map { ItemID(rawValue: $0.path) })
        subscriptions.append(dependencies.volumes.changes.subscribe { [weak self] _ in self?.renderSidebar() })
        subscriptions.append(dependencies.operations.changes.subscribe { [weak self] rows in self?.renderOperations(rows) })
        subscriptions.append(dependencies.settings.changes.subscribe { [weak self] settings in self?.settingsChanged(settings) })
    }

    private func settingsChanged(_ settings: SettingsSnapshot) {
        for id in store.state.window.tabs { store.send(.tab(id, .settingsChanged(settings))) }
        applyTransparency()
        renderContent(force: true)
        if viewOptions.isShown { refreshViewOptions() }
        dependencies.volumes.reload()
    }

    // MARK: Rendering

    private func render(_ snapshot: WindowStoreSnapshot) {
        guard let tab = snapshot.tabs[snapshot.window.activeTabID] else { return }
        applyRememberedViewOptions(tab)
        window?.title = title(for: tab)
        if case .directory(let url) = tab.location, tab.search == nil { window?.representedURL = url } else { window?.representedURL = nil }
        pathBar.render(location: tab.location, home: dependencies.home, editor: tab.addressBar)
        let many = snapshot.window.tabs.count > 1
        tabStripHeight?.constant = many ? 36 : 0
        tabStrip.isHidden = !many
        if many { tabStrip.render(window: snapshot.window, tabs: snapshot.tabs) }
        renderContent(tab: tab, force: lastRenderedTab != tab.id)
        lastRenderedTab = tab.id
        updateChrome(tab)
        renderSidebar(for: tab)
        renderStatus(tab)
        finishPendingWork(tab)
        followSelectionInQuickLook()
    }

    /// A folder you've set up keeps its view and sort when you come back. Elsewhere the tab keeps its current choice.
    private func applyRememberedViewOptions(_ tab: TabState) {
        guard rememberedLocations[tab.id] != tab.location else { return }
        rememberedLocations[tab.id] = tab.location
        let saved = dependencies.viewOptions.options(for: tab.location)
        guard saved != dependencies.viewOptions.defaults else { return }
        if saved.viewMode != tab.viewMode { store.send(.tab(tab.id, .setViewMode(saved.viewMode))) }
        if saved.sort != tab.sort, tab.search == nil { store.send(.tab(tab.id, .setSort(saved.sort))) }
    }
    func rememberViewOptions(mode: ViewMode? = nil, sort: ItemSort? = nil) {
        guard let tab = activeTab, tab.search == nil else { return }
        let current = dependencies.viewOptions.options(for: tab.location)
        let next = ViewOptions(viewMode: mode ?? tab.viewMode, sort: sort ?? tab.sort, groupBy: current.groupBy,
                               iconSize: current.iconSize, showColumns: current.showColumns, textSize: current.textSize)
        // A store that went read-only at launch keeps this for the session only (OK2-9).
        try? dependencies.viewOptions.set(next, for: tab.location)
    }

    private func renderContent(force: Bool) {
        if let tab = activeTab { renderContent(tab: tab, force: force) }
    }
    private func renderContent(tab: TabState, force: Bool) {
        let content: FileContentPresenting = tab.viewMode == .grid ? grid : list
        if shownMode != tab.viewMode || shownContent == nil {
            shownContent?.view.removeFromSuperview()
            let contentView = content.view
            contentView.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: contentContainer.topAnchor), contentView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
                contentView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor), contentView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor)
            ])
            let hadFocus = shownContent != nil
            shownContent = content; shownMode = tab.viewMode
            content.render(tab, force: true)
            if hadFocus { content.focusContent() }
        } else {
            content.render(tab, force: force)
        }
        overlay.stringValue = overlayText(tab) ?? ""
        overlay.isHidden = overlay.stringValue.isEmpty
    }

    private func overlayText(_ tab: TabState) -> String? {
        switch tab.snapshot.phase {
        case .failed(let error, let attempted):
            return Self.message(for: error, attempted: attempted)
        case .loading:
            return nil
        case .ready:
            guard tab.snapshot.rootCount == 0 else { return nil }
            if tab.search != nil { return tab.search?.isGathering == true ? nil : "No results" }
            switch tab.location {
            case .trash: return "Trash is empty"
            case .recent: return "No recent items"
            case .directory: return tab.isLoading ? nil : "Folder is empty"
            }
        }
    }
    static func message(for error: LoadError, attempted: Location) -> String {
        let name: String
        if case .directory(let url) = attempted { name = "“\(url.lastPathComponent)”" } else if case .trash = attempted { name = "the Trash" } else { name = "this location" }
        switch error {
        case .notFound: return "\(name.prefix(1).uppercased() + name.dropFirst()) no longer exists."
        case .permissionDenied:
            if case .trash = attempted {
                return "Helm doesn’t have permission to read the Trash. Allow Helm in System Settings › Privacy & Security › Full Disk Access."
            }
            return "You don’t have permission to view \(name)."
        case .volumeUnmounted: return "The disk holding \(name) was disconnected."
        case .timedOut: return "The disk holding \(name) stopped responding."
        case .notIndexed: return "This location isn’t indexed by Spotlight."
        case .cancelled: return ""
        case .other(let message): return "Couldn’t open \(name): \(message)"
        }
    }

    private func title(for tab: TabState) -> String {
        if let search = tab.search { return "Search: \(search.query.text)" }
        switch tab.location {
        case .recent: return "Recent"
        case .trash: return "Trash"
        case .directory(let url): return url.path == "/" ? "/" : url.lastPathComponent
        }
    }

    private func updateChrome(_ tab: TabState) {
        header.render(tab: tab)
        if viewOptions.isShown { refreshViewOptions() }
    }

    private func renderSidebar() { if let tab = activeTab { renderSidebar(for: tab) } }
    private func renderSidebar(for tab: TabState) {
        let places = PlacesModel(home: dependencies.home,
                                 bookmarks: dependencies.bookmarks.records.map { URL(fileURLWithPath: $0.path, isDirectory: true) },
                                 starred: dependencies.stars.records.map { URL(fileURLWithPath: $0.path) },
                                 volumes: dependencies.volumes.volumes,
                                 showAllVolumes: dependencies.settings.snapshot.bool(.showAllMountedVolumes))
        // The highlight follows where the tab is going, so a click doesn't flick back to the old place while the
        // new folder loads. If that load fails, the pending target clears and the highlight returns (F-027).
        let destination: PlaceDestination
        switch tab.pendingNavigation?.target ?? tab.location {
        case .directory(let url): destination = .directory(url)
        case .recent: destination = .recent
        case .trash: destination = .trash
        }
        sidebar.render(SidebarModel(places: places, committedDestination: destination))
    }

    private func renderStatus(_ tab: TabState) {
        let selected = tab.selection.compactMap { tab.snapshot.entry($0) }
        let bytes = selected.reduce(into: Int64(0)) { total, entry in
            if !entry.isDirectoryLike && entry.kind != .package { total = total.addingReportingOverflow(entry.size).partialValue }
        }
        var activity: StatusActivity = .idle
        if let busyMessage { activity = .working(busyMessage) }
        else if case .failed(.permissionDenied, _) = tab.snapshot.phase { activity = .denied }
        else if tab.search?.isGathering == true { activity = .searching }
        else if tab.isLoading { activity = .gathering }
        var free: Int64?
        if case .directory(let url) = tab.location {
            free = freeBytes[url.path]
            requestFreeSpace(url)
        }
        // A selected folder's size isn't known without walking it, so say nothing rather than "Zero KB".
        let hasFile = selected.contains { !$0.isDirectoryLike && $0.kind != .package }
        statusHost.rootView = StatusBarView(status: StatusPresentation(itemCount: tab.snapshot.rootCount, selectedCount: selected.count,
                                                                       selectedBytes: hasFile ? bytes : nil, freeBytes: free, activity: activity,
                                                                       isSearch: tab.search != nil))
    }
    func setBusy(_ busy: Bool, message: String?) {
        busyMessage = busy ? message : nil
        if let tab = activeTab { renderStatus(tab) }
    }
    private func requestFreeSpace(_ url: URL) {
        guard freeRequested != url.path, freeBytes[url.path] == nil else { return }
        freeRequested = url.path
        let fileSystem = dependencies.fileSystem
        Task { [weak self] in
            let value = try? await fileSystem.availableCapacity(of: url)
            guard let self, let value else { return }
            self.freeBytes[url.path] = value
            if let tab = self.activeTab { self.renderStatus(tab) }
        }
    }

    private func renderOperations(_ rows: [OperationRowModel]) {
        if rows.isEmpty {
            operationsHost.rootView = AnyView(EmptyView()); operationsHeight?.constant = 0
            return
        }
        let operations = dependencies.operations
        operationsHost.rootView = AnyView(OperationsPanel(rows: rows, cancel: { operations.cancel($0) }, dismiss: { operations.dismiss($0) }))
        operationsHeight?.constant = min(CGFloat(rows.count) * 56 + 8, 200)
    }

    /// Work that waits for a listing to arrive: selecting pasted items, or naming a new folder.
    private func finishPendingWork(_ tab: TabState) {
        guard !tab.isLoading, tab.pendingNavigation == nil else { return }
        if let ids = pendingSelections.removeValue(forKey: tab.id) {
            store.send(.tab(tab.id, .setSelection(ids, source: .operation)))
        }
        if let pending = pendingRename, pending.tab == tab.id, let entry = tab.snapshot.entry(pending.id) {
            pendingRename = nil
            store.send(.tab(tab.id, .setSelection([pending.id], source: .operation)))
            store.send(.tab(tab.id, .beginInlineRename(pending.id)))
            DispatchQueue.main.async { [weak self] in self?.shownContent?.beginRename(entry) }
        }
    }

    func expectRename(of id: ItemID) { pendingRename = (activeTabID, id) }
    func shownRename(_ entry: FileEntry) { shownContent?.beginRename(entry) }
    func select(_ ids: Set<ItemID>, in tab: TabID) { pendingSelections[tab] = ids }
    func focusContent() { shownContent?.focusContent() }

    // MARK: NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) {
        host?.windowDidBecomeKey(self)
        Task { await refreshHistory() }
    }
    public func windowWillClose(_ notification: Notification) {
        store.send(.shutdown)
        host?.windowDidClose(self)
    }
    func closeFromStore() { window?.performClose(nil) }

    func refreshHistory() async {
        historyState = await history.snapshot()
    }

    // MARK: Header bar

    func headerToggleSidebar() { toggleSidebar() }
    func toggleSidebar() {
        guard let sidebarItem else { return }
        let hide = !sidebarItem.isCollapsed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            sidebarItem.animator().isCollapsed = hide
        }
        header.setSidebarVisible(!hide)
        store.send(.window(.setSidebarVisible(!hide)))
    }
    func headerBack() { perform(.back) }
    func headerForward() { perform(.forward) }
    func headerToggleViewMode() { perform(activeTab?.viewMode == .grid ? .list : .grid) }
    func headerShowViewOptions(from button: NSView) {
        let model = viewOptions.model
        model.pressSort = { [weak self] in self?.pressSort($0) }
        model.toggleFoldersFirst = { [weak self] in self?.toggleFoldersFirst() }
        model.toggleHidden = { [weak self] in self?.perform(.hidden) }
        model.stepText = { [weak self] in self?.stepText(by: $0) }
        model.resetText = { [weak self] in self?.resetText() }
        model.stepIcons = { [weak self] in self?.stepIcons(by: $0) }
        model.resetIcons = { [weak self] in self?.resetIcons() }
        viewOptions.onClose = { [weak self] in self?.header.setViewOptionsShown(false) }
        refreshViewOptions()
        viewOptions.show(from: button)
        header.setViewOptionsShown(viewOptions.isShown)
    }
    /// For the smoke run: opens the view options popover and returns what it shows.
    public func showViewOptionsForTesting() -> NSView? {
        header.openViewOptionsForTesting()
        return viewOptions.contentView
    }
    public func closeViewOptionsForTesting() { viewOptions.close() }
    /// Keeps the open popover in step with the tab and settings, so pressing again shows the new state at once.
    private func refreshViewOptions() {
        guard let tab = activeTab else { return }
        let settings = dependencies.settings.snapshot
        let next = HeaderViewOptionsState(sort: tab.sort, searching: tab.search != nil, showHidden: tab.showHidden, isGrid: tab.viewMode == .grid,
                                    textPoints: settings.double(.fileTextSize), iconPixels: settings.double(.gridIconSize))
        if viewOptions.model.state != next { viewOptions.model.state = next }
    }
    /// Nautilus's main menu: what you reach for without going to the menu bar.
    func headerMainMenu() -> NSMenu? {
        let menu = NSMenu()
        for (title, command) in [("New Window", CommandID.newWindow), ("New Tab", .newTab), ("New Folder", .newFolder)] {
            menu.addItem(commandItem(title, command))
        }
        menu.addItem(.separator())
        menu.addItem(commandItem("Undo", .undo))
        menu.addItem(commandItem("Redo", .redo))
        menu.addItem(.separator())
        menu.addItem(commandItem("Connect to Server…", .connectToServer))
        menu.addItem(commandItem("Settings…", .settings))
        return menu
    }
    func commandItem(_ title: String, _ command: CommandID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(helmCommand(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = command.rawValue
        return item
    }

    // MARK: Search

    func headerSearchChanged(_ text: String) {
        let delay = dependencies.settings.snapshot.integer(.searchDebounceMilliseconds)
        searchDebounce?.cancel()
        searchDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay)) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.search(text)
        }
    }
    func headerSearchScopeChanged() {
        searchDebounce?.cancel()
        let typed = header.searchText
        search(typed.isEmpty ? (activeTab?.search?.query.text ?? "") : typed)
    }
    /// Scripted runs: searches the whole Mac or the folder, as the scope menu does.
    public func setSearchScopeForTesting(everywhere: Bool) { header.chooseSearchScopeForTesting(everywhere: everywhere) }
    func headerSearchClosed() {
        searchDebounce?.cancel()
        store.send(.tab(activeTabID, .searchEnded))
        shownContent?.focusContent()
    }
    public func search(_ text: String) {
        guard let tab = activeTab else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.send(.tab(tab.id, .searchEnded)); return
        }
        let settings = dependencies.settings.snapshot
        // Nautilus searches where you are; virtual locations have no folder to search within (OK2-23).
        // The scope pill in the search field widens it to the whole Mac, as Finder's "This Mac" does (P-170).
        let scope: SearchScope
        if let url = tab.location.mutationTarget, !header.searchesEverywhere { scope = .currentFolder(url) } else { scope = .thisMac }
        let query = SearchQuery(text: text, scope: scope, bookmarkPaths: dependencies.bookmarks.records.map(\.path),
                                homeDirectory: dependencies.home, lastDirectory: tab.lastDirectory, showHidden: tab.showHidden,
                                limit: settings.integer(.searchResultLimit), includesContents: settings.bool(.searchFileContents))
        store.send(.tab(tab.id, .searchStarted(query)))
    }
    func beginSearch() { header.beginSearch() }

    // MARK: FileContentHost

    public var icons: IconCache { dependencies.icons }
    var gridIconSize: Int { Int(dependencies.settings.snapshot.double(.gridIconSize)) }
    var fileTextSize: CGFloat { CGFloat(dependencies.settings.snapshot.double(.fileTextSize)) }
    func contentSelectionChanged(_ ids: Set<ItemID>) {
        store.send(.tab(activeTabID, .setSelection(ids, source: .user)))
    }
    func contentOpen(_ entries: [FileEntry], newTab: Bool) { open(entries, newTab: newTab) }
    func contentMenu(for entries: [FileEntry]) -> NSMenu? { contextMenu(for: entries) }
    func contentRenameFinished(_ entry: FileEntry, newName: String?) {
        store.send(.tab(activeTabID, .endInlineRename))
        shownContent?.focusContent()
        guard let newName, newName != entry.name else { return }
        commitRename(entry, to: newName)
    }
    public func contentSetSortForTesting(_ sort: ItemSort) { contentSetSort(sort) }
    func contentSetSort(_ sort: ItemSort) {
        store.send(.tab(activeTabID, .setSort(sort)))
        rememberViewOptions(sort: sort)
    }
    func contentExpand(_ id: ItemID) { store.send(.tab(activeTabID, .expand(id))) }
    func contentCollapse(_ id: ItemID) { store.send(.tab(activeTabID, .collapse(id))) }
    func contentActivated() {}
    func contentKeyDown(_ event: NSEvent) -> Bool { handleContentKey(event) }
    /// `entry` is the item under the pointer when it takes drops; nil means the folder on show.
    func contentDropOperation(_ info: NSDraggingInfo, onto entry: FileEntry?) -> NSDragOperation {
        guard let destination = contentDestination(entry) else { springs.cancel(); return [] }
        let operation = dropOperation(info, into: destination)
        springs.hover(operation != [] && entry?.isDirectoryLike == true ? entry?.url : nil)
        return operation
    }
    func contentPerformDrop(_ info: NSDraggingInfo, onto entry: FileEntry?) -> Bool {
        guard let destination = contentDestination(entry) else { return false }
        return performDrop(info, into: destination)
    }
    func contentDragEnded() { springs.cancel() }
    private func contentDestination(_ entry: FileEntry?) -> WindowDropTarget? {
        if let entry, entry.takesDrops { return entry.isApplicationBundle ? .application(entry.url) : .folder(entry.url) }
        // Search results and Recent aren't folders, so there's nowhere to put a drop between their items.
        guard let tab = activeTab, tab.search == nil else { return nil }
        if case .trash = tab.location { return .trash }
        return tab.mutationTarget.map(WindowDropTarget.folder)
    }
    var starred: Set<ItemID> { starredIDs }

    // MARK: PathBarDelegate

    func pathBarNavigate(to url: URL) { navigate(to: .directory(url)) }
    func pathBarOpenInNewTab(_ url: URL) { newTab(at: .directory(url)) }
    func pathBarBeginEditing() { store.send(.tab(activeTabID, .addressBar(.beginEditing))) }
    func pathBarAction(_ action: AddressEditorAction) {
        store.send(.tab(activeTabID, .addressBar(action)))
        if case .cancel = action { shownContent?.focusContent() }
    }
    func pathBarDropOperation(_ info: NSDraggingInfo, into url: URL?) -> NSDragOperation {
        guard let url else { springs.cancel(); return [] }
        let operation = dropOperation(info, into: .folder(url))
        springs.hover(operation != [] ? url : nil)
        return operation
    }
    func pathBarPerformDrop(_ info: NSDraggingInfo, into url: URL) -> Bool { performDrop(info, into: .folder(url)) }
    func pathBarDragEnded() { springs.cancel() }
    func pathBarFolderMenu() -> NSMenu? { contextMenu(for: []) }
    func locationBarRejected() { pathBar.shake() }

    // MARK: TabStripDelegate

    func tabStripActivate(_ id: TabID) { store.send(.window(.activate(id))) }
    func tabStripClose(_ id: TabID) { closeTab(id) }
    func tabStripNewTab() { newTab(at: activeTab?.location ?? .directory(dependencies.home)) }
    func tabStripDropOperation(_ info: NSDraggingInfo, onto id: TabID) -> NSDragOperation {
        if id != activeTabID { springs.hover(id) { [weak self] in self?.store.send(.window(.activate(id))) } }
        guard let tab = store.state.tabs[id], tab.search == nil else { return [] }
        if case .trash = tab.location { return dropOperation(info, into: .trash) }
        guard let url = tab.mutationTarget else { return [] }
        return dropOperation(info, into: .folder(url))
    }
    func tabStripPerformDrop(_ info: NSDraggingInfo, onto id: TabID) -> Bool {
        guard let tab = store.state.tabs[id], tab.search == nil else { return false }
        if case .trash = tab.location { return performDrop(info, into: .trash) }
        guard let url = tab.mutationTarget else { return false }
        return performDrop(info, into: .folder(url))
    }
    func tabStripDragEnded() { springs.cancel() }

    // MARK: SidebarDelegate

    func sidebarActivate(_ place: Place, newTab: Bool) {
        let location: Location
        switch place.destination {
        case .directory(let url):
            if place.kind == .starred, !isDirectory(url) {
                // A starred file reveals in its folder rather than launching (F-029).
                revealInCurrentTab(url); return
            }
            location = .directory(url)
        case .recent: location = .recent
        case .trash: location = .trash
        case .starred: return
        }
        if newTab { self.newTab(at: location) } else { navigate(to: location) }
    }
    private func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
    func sidebarRemoveBookmark(_ place: Place) { if let url = place.url { dependencies.bookmarks.remove(path: url.path) } }
    func sidebarEject(_ place: Place) { if let url = place.url { dependencies.volumes.eject(url) } }
    public func sidebarAddBookmarks(_ urls: [URL]) { sidebarInsertBookmarks(urls, at: nil) }
    public func sidebarInsertBookmarks(_ urls: [URL], at index: Int?) {
        let fileSystem = dependencies.fileSystem, bookmarks = dependencies.bookmarks, clock = dependencies.clock
        Task { @MainActor in
            var position = index
            for url in urls {
                let directory = await fileSystem.isDirectory(url, resolvingSymlinks: true)
                if let at = position {
                    if bookmarks.insert(url, isDirectory: directory, at: at, date: clock.now()) { position = at + 1 }
                } else {
                    _ = bookmarks.add(url, isDirectory: directory, at: clock.now())
                }
            }
        }
    }
    public func sidebarMoveBookmark(_ path: String, to index: Int) { dependencies.bookmarks.move(path: path, to: index) }
    func sidebarDropOperation(_ info: NSDraggingInfo, onto place: Place) -> NSDragOperation {
        guard let destination = dropDestination(for: place) else { springs.cancel(); return [] }
        let operation = dropOperation(info, into: destination)
        // Holding a drag over a place opens it, so you can drop deeper inside.
        if case .folder(let url) = destination, operation != [] { springs.hover(url) } else { springs.cancel() }
        return operation
    }
    func sidebarPerformDrop(_ info: NSDraggingInfo, onto place: Place) -> Bool {
        guard let destination = dropDestination(for: place) else { return false }
        return performDrop(info, into: destination)
    }
    func sidebarDragEnded() { springs.cancel() }
    private func dropDestination(for place: Place) -> WindowDropTarget? {
        switch place.destination {
        case .trash: return .trash
        case .directory(let url):
            guard place.kind == .starred, !isDirectory(url) else { return .folder(url) }
            // A starred app opens what's dropped on it; a starred document takes nothing.
            return url.pathExtension == "app" ? .application(url) : nil
        case .recent, .starred: return nil
        }
    }
    func sidebarEmptyTrash() { emptyTrash() }

    // MARK: Quick Look

    public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = self; panel.dataSource = self
        reloadQuickLook()
    }
    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = nil; panel.dataSource = nil
    }
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }
    private func reloadQuickLook() {
        quickLookEntries = quickLookSelection()
        QLPreviewPanel.shared()?.reloadData()
    }
    /// The selection in the order it's shown, including inside expanded folders, so paging matches the screen.
    private func quickLookSelection() -> [FileEntry] {
        guard let tab = activeTab else { return [] }
        let chosen = selectedEntries()
        let order = tab.snapshot.visibleIDs(expanding: tab.expandedIDs)
        var rank: [ItemID: Int] = [:]
        for (offset, id) in order.enumerated() { rank[id] = offset }
        return chosen.enumerated().sorted { (rank[$0.element.id] ?? order.count + $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset) }
            .map(\.element)
    }
    /// While the panel is open it follows the selection however it changed: clicks, Select All, an operation,
    /// a new folder or another tab. The item on show stays on show if it's still selected.
    private func followSelectionInQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
              panel.dataSource === self else { return }
        let next = quickLookSelection()
        guard next.map(\.url) != quickLookEntries.map(\.url) else { return }
        let showing = (panel.currentPreviewItem as? NSURL) as URL?
        quickLookEntries = next
        panel.reloadData()
        if let showing, let index = next.firstIndex(where: { $0.url == showing }) { panel.currentPreviewItemIndex = index }
    }
    public func selectedEntries() -> [FileEntry] {
        guard let tab = activeTab else { return [] }
        return tab.snapshot.sortedEntries.filter { tab.selection.contains($0.id) }
    }
    fileprivate var previewItems: [FileEntry] { quickLookEntries }
    fileprivate func forwardToContent(_ event: NSEvent) -> Bool {
        guard let responder = shownContent?.keyResponder else { return false }
        responder.keyDown(with: event)
        return true
    }

    // MARK: Services: the system's Services menu acts on the selected files.

    public override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, sendType == .fileURL || sendType == .string, !selectedEntries().isEmpty, !(window?.firstResponder is NSText) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    @objc public func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let urls = selectedEntries().map(\.url)
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls.map { $0 as NSURL })
    }
    fileprivate func previewFrame(_ entry: FileEntry) -> NSRect { shownContent?.screenFrame(of: entry.id) ?? .zero }
    fileprivate func previewImage(_ entry: FileEntry) -> NSImage? { shownContent?.image(of: entry.id) }
    /// Where an item is on screen, if it's in view.
    func screenFrame(of id: ItemID) -> NSRect? { shownContent?.screenFrame(of: id) }
}

extension BrowserWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }
    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewItems[index].url as NSURL
    }
    /// With one item, arrow keys move the selection and the panel follows, as in Finder.
    /// With several, the panel pages through them itself.
    public func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [123, 124, 125, 126].contains(Int(event.keyCode)), previewItems.count <= 1 else { return false }
        return forwardToContent(event)
    }
    /// The panel zooms out of the picture the item shows now.
    public func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                             contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item.previewItemURL, let entry = previewItems.first(where: { $0.url == url }) else { return nil }
        return previewImage(entry)
    }
    public func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = item.previewItemURL, let entry = previewItems.first(where: { $0.url == url }) else { return .zero }
        return previewFrame(entry)
    }
}
#endif
