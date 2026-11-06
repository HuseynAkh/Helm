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

/// One Helm window. It renders the store's state and turns user intent into store actions and file commands.
/// Nautilus's shape: a clean header bar, a Places sidebar and one content pane with tabs.
@MainActor public final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSSearchFieldDelegate, FileContentHost, SidebarDelegate, PathBarDelegate, TabStripDelegate {

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
    let pathBar = PathBarView()
    let tabStrip = TabStripView()
    private let contentContainer = NSView()
    private let list = FileListController()
    private let grid = FileGridController()
    private let statusHost = NSHostingView(rootView: StatusBarView(status: StatusPresentation(itemCount: 0)))
    private let overlay = NSTextField(wrappingLabelWithString: "")
    private let operationsHost = NSHostingView(rootView: AnyView(EmptyView()))
    private var operationsHeight: NSLayoutConstraint?
    private var tabStripHeight: NSLayoutConstraint?
    private var searchItem: NSSearchToolbarItem?
    private var viewSwitch: NSSegmentedControl?
    private var backForward: NSSegmentedControl?
    private var shownContent: FileContentPresenting?
    private var shownMode: ViewMode?
    private var subscriptions: [Any] = []
    private var pendingSelections: [TabID: Set<ItemID>] = [:]
    private var pendingRename: (tab: TabID, id: ItemID)?
    private var freeBytes: [String: Int64] = [:]
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
        window.titlebarAppearsTransparent = false
        window.tabbingMode = .disallowed // Our own strip owns tabs.
        window.minSize = NSSize(width: 520, height: 320)
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true // Tab moves between sidebar, content and path bar.
        if dependencies.persistsWindowFrames { window.setFrameAutosaveName(frameName) }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170; sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebar.delegate = self
        let contentController = NSViewController()
        contentController.view = buildContentArea()
        let contentItem = NSSplitViewItem(contentListWithViewController: contentController)
        contentItem.minimumThickness = 320
        split.addSplitViewItem(sidebarItem); split.addSplitViewItem(contentItem)
        if dependencies.persistsWindowFrames { split.splitView.autosaveName = "HelmSplit" }
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1040, height: 680))
        if !dependencies.persistsWindowFrames || !window.setFrameUsingName(frameName) { window.center() }

        let toolbar = NSToolbar(identifier: "HelmToolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.subtitle = ""

        list.host = self; grid.host = self
        pathBar.delegate = self; tabStrip.delegate = self
    }

    private func buildContentArea() -> NSView {
        let root = NSView()
        for view in [tabStrip, contentContainer, overlay, operationsHost, statusHost] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        overlay.alignment = .center; overlay.textColor = .secondaryLabelColor; overlay.font = .systemFont(ofSize: 15)
        overlay.isHidden = true; overlay.isSelectable = false
        let stripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        tabStripHeight = stripHeight
        let operations = operationsHost.heightAnchor.constraint(equalToConstant: 0)
        operationsHeight = operations
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
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
            statusHost.bottomAnchor.constraint(equalTo: root.bottomAnchor), statusHost.heightAnchor.constraint(equalToConstant: 24)
        ])
        return root
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
        renderContent(force: true)
        dependencies.volumes.reload()
    }

    // MARK: Rendering

    private func render(_ snapshot: WindowStoreSnapshot) {
        guard let tab = snapshot.tabs[snapshot.window.activeTabID] else { return }
        applyRememberedViewOptions(tab)
        window?.title = title(for: tab)
        if case .directory(let url) = tab.location, tab.search == nil { window?.representedURL = url } else { window?.representedURL = nil }
        pathBar.render(location: tab.location, editor: tab.addressBar)
        let many = snapshot.window.tabs.count > 1
        tabStripHeight?.constant = many ? 29 : 0
        tabStrip.isHidden = !many
        if many { tabStrip.render(window: snapshot.window, tabs: snapshot.tabs) }
        renderContent(tab: tab, force: lastRenderedTab != tab.id)
        lastRenderedTab = tab.id
        updateChrome(tab)
        renderSidebar(for: tab)
        renderStatus(tab)
        finishPendingWork(tab)
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
        backForward?.setEnabled(!tab.history.back.isEmpty, forSegment: 0)
        backForward?.setEnabled(!tab.history.forward.isEmpty, forSegment: 1)
        viewSwitch?.selectedSegment = tab.viewMode == .grid ? 0 : 1
        if let searchItem, tab.search == nil, searchItem.searchField.stringValue != "", window?.firstResponder !== searchItem.searchField.currentEditor() {
            searchItem.searchField.stringValue = ""
        }
    }

    private func renderSidebar() { if let tab = activeTab { renderSidebar(for: tab) } }
    private func renderSidebar(for tab: TabState) {
        let places = PlacesModel(home: dependencies.home,
                                 bookmarks: dependencies.bookmarks.records.map { URL(fileURLWithPath: $0.path, isDirectory: true) },
                                 starred: dependencies.stars.records.map { URL(fileURLWithPath: $0.path) },
                                 volumes: dependencies.volumes.volumes,
                                 showAllVolumes: dependencies.settings.snapshot.bool(.showAllMountedVolumes))
        let destination: PlaceDestination
        switch tab.location {
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
        if case .failed(.permissionDenied, _) = tab.snapshot.phase { activity = .denied }
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
                                                                       selectedBytes: hasFile ? bytes : nil, freeBytes: free, activity: activity))
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
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: Toolbar

    private enum ToolbarID {
        static let navigation = NSToolbarItem.Identifier("helm.navigation")
        static let path = NSToolbarItem.Identifier("helm.path")
        static let search = NSToolbarItem.Identifier("helm.search")
        static let view = NSToolbarItem.Identifier("helm.view")
        static let actions = NSToolbarItem.Identifier("helm.actions")
    }
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.navigation, ToolbarID.path, ToolbarID.search, ToolbarID.view, ToolbarID.actions]
    }
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ToolbarID.navigation:
            let control = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back") ?? NSImage(),
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward") ?? NSImage()
            ], trackingMode: .momentary, target: self, action: #selector(backForwardClicked(_:)))
            control.setToolTip("Back", forSegment: 0); control.setToolTip("Forward", forSegment: 1)
            backForward = control
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control; item.label = "Back/Forward"
            return item
        case ToolbarID.path:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = pathBar; item.label = "Location"
            item.visibilityPriority = .high
            // The toolbar gives its spare width to whichever item can take it, which is what centres the path bar.
            pathBar.translatesAutoresizingMaskIntoConstraints = false
            pathBar.setContentHuggingPriority(.init(1), for: .horizontal)
            pathBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pathBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            pathBar.widthAnchor.constraint(lessThanOrEqualToConstant: 2400).isActive = true
            return item
        case ToolbarID.search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.delegate = self
            item.searchField.placeholderString = "Search"
            item.searchField.target = self; item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            searchItem = item
            return item
        case ToolbarID.view:
            let control = NSSegmentedControl(images: [
                NSImage(systemSymbolName: ViewMode.grid.systemImageName, accessibilityDescription: "Grid") ?? NSImage(),
                NSImage(systemSymbolName: ViewMode.list.systemImageName, accessibilityDescription: "List") ?? NSImage()
            ], trackingMode: .selectOne, target: self, action: #selector(viewSwitchClicked(_:)))
            viewSwitch = control
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control; item.label = "View"
            item.visibilityPriority = .low
            return item
        case ToolbarID.actions:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Actions")
            item.label = "Actions"; item.showsIndicator = false
            item.menu = headerMenu()
            return item
        default: return nil
        }
    }
    /// Nautilus's main menu: what you reach for without leaving the keyboard's home row.
    private func headerMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, command) in [("New Folder", CommandID.newFolder), ("New Tab", .newTab), ("New Window", .newWindow)] {
            menu.addItem(commandItem(title, command))
        }
        menu.addItem(.separator())
        let sort = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        sort.submenu = NSMenu(title: "Sort By")
        sort.submenu?.delegate = self
        menu.addItem(sort)
        menu.addItem(commandItem("Show Hidden Files", .hidden))
        menu.addItem(commandItem("Refresh", .refresh))
        menu.addItem(.separator())
        menu.addItem(commandItem("Settings…", .settings))
        return menu
    }
    func commandItem(_ title: String, _ command: CommandID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(helmCommand(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = command.rawValue
        return item
    }

    @objc private func backForwardClicked(_ sender: NSSegmentedControl) {
        perform(sender.selectedSegment == 0 ? .back : .forward)
    }
    @objc private func viewSwitchClicked(_ sender: NSSegmentedControl) {
        perform(sender.selectedSegment == 0 ? .grid : .list)
    }

    // MARK: Search

    @objc private func searchChanged(_ sender: NSSearchField) {
        let text = sender.stringValue
        let delay = dependencies.settings.snapshot.integer(.searchDebounceMilliseconds)
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay)) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.search(text)
        }
    }
    public func search(_ text: String) {
        guard let tab = activeTab else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.send(.tab(tab.id, .searchEnded)); return
        }
        let settings = dependencies.settings.snapshot
        // Nautilus searches where you are; virtual locations have no folder to search within (OK2-23).
        let scope: SearchScope
        if let url = tab.location.mutationTarget { scope = .currentFolder(url) } else { scope = .thisMac }
        let query = SearchQuery(text: text, scope: scope, bookmarkPaths: dependencies.bookmarks.records.map(\.path),
                                homeDirectory: dependencies.home, lastDirectory: tab.lastDirectory, showHidden: tab.showHidden,
                                limit: settings.integer(.searchResultLimit))
        store.send(.tab(tab.id, .searchStarted(query)))
    }
    public func searchFieldDidEndSearching(_ sender: NSSearchField) {
        guard let tab = activeTab else { return }
        store.send(.tab(tab.id, .searchEnded))
        shownContent?.focusContent()
    }
    func beginSearch() {
        searchItem?.beginSearchInteraction()
    }

    // MARK: FileContentHost

    public var icons: IconCache { dependencies.icons }
    var gridIconSize: Int { Int(dependencies.settings.snapshot.double(.gridIconSize)) }
    func contentSelectionChanged(_ ids: Set<ItemID>) {
        store.send(.tab(activeTabID, .setSelection(ids, source: .user)))
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { reloadQuickLook() }
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
    func contentCanAcceptDrop(into url: URL?, from urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        return (url ?? activeTab?.mutationTarget) != nil && activeTab?.search == nil
    }
    func contentDragOperation(from urls: [URL], into url: URL?) -> NSDragOperation {
        guard let target = url ?? activeTab?.mutationTarget else { return [] }
        return dragOperation(from: urls, into: target)
    }
    func contentAcceptDrop(_ urls: [URL], into url: URL?) -> Bool {
        guard let target = url ?? activeTab?.mutationTarget else { return false }
        return acceptDrop(urls, into: target)
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
    func pathBarAcceptDrop(_ urls: [URL], into url: URL) -> Bool { acceptDrop(urls, into: url) }
    func locationBarRejected() { pathBar.shake() }

    // MARK: TabStripDelegate

    func tabStripActivate(_ id: TabID) { store.send(.window(.activate(id))) }
    func tabStripClose(_ id: TabID) { closeTab(id) }
    func tabStripNewTab() { newTab(at: activeTab?.location ?? .directory(dependencies.home)) }

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
    func sidebarAddBookmarks(_ urls: [URL]) {
        let fileSystem = dependencies.fileSystem, bookmarks = dependencies.bookmarks, clock = dependencies.clock
        Task { @MainActor in
            for url in urls {
                let directory = await fileSystem.isDirectory(url, resolvingSymlinks: true)
                _ = bookmarks.add(url, isDirectory: directory, at: clock.now())
            }
        }
    }
    func sidebarAcceptDrop(_ urls: [URL], into url: URL) -> Bool { acceptDrop(urls, into: url) }
    func sidebarTrash(_ urls: [URL]) { trash(urls) }
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
        quickLookEntries = selectedEntries()
        QLPreviewPanel.shared()?.reloadData()
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
}

extension BrowserWindowController: NSMenuDelegate {
    /// The sort menu shows the active tab's choice, so it's rebuilt when it opens.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Sort By" else { return }
        let fresh = sortMenu()
        menu.removeAllItems()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }
}

extension BrowserWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }
    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewItems[index].url as NSURL
    }
    /// Arrow keys keep moving the selection while the panel is open, and the panel follows.
    public func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [123, 124, 125, 126].contains(Int(event.keyCode)) else { return false }
        return forwardToContent(event)
    }
    public func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = item.previewItemURL, let entry = previewItems.first(where: { $0.url == url }) else { return .zero }
        return previewFrame(entry)
    }
}
#endif
