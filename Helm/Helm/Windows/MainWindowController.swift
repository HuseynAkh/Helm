import Cocoa

class MainWindowController: NSWindowController, NSToolbarDelegate {

    private let splitViewController = MainSplitViewController()
    private var breadcrumbBar: BreadcrumbBar?
    private weak var viewModeSegment: NSSegmentedControl?
    private weak var searchField: NSSearchField?

    private let initialURL: URL

    // Toolbar item identifiers
    private static let toolbarIdentifier = NSToolbar.Identifier("HelmToolbar")
    private static let backForwardIdentifier = NSToolbarItem.Identifier("backForward")
    private static let breadcrumbIdentifier = NSToolbarItem.Identifier("breadcrumb")
    private static let searchIdentifier = NSToolbarItem.Identifier("search")
    private static let viewModeIdentifier = NSToolbarItem.Identifier("viewMode")
    private static let sidebarToggleIdentifier = NSToolbarItem.Identifier("sidebarToggle")

    convenience init() {
        self.init(initialURL: FileManager.default.homeDirectoryForCurrentUser)
    }

    init(initialURL: URL) {
        self.initialURL = initialURL

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.title = "Helm"
        window.setFrameAutosaveName("HelmMainWindow")
        window.minSize = NSSize(width: 700, height: 450)
        window.center()

        super.init(window: window)

        window.contentViewController = splitViewController
        setupToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func navigateTo(_ url: URL) {
        splitViewController.navigateTo(url)
    }

    func updateBreadcrumb(for url: URL) {
        breadcrumbBar?.url = url
    }

    func clearSearchField() {
        searchField?.stringValue = ""
    }

    // MARK: - Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.sidebarToggleIdentifier,
            Self.backForwardIdentifier,
            Self.breadcrumbIdentifier,
            Self.viewModeIdentifier,
            Self.searchIdentifier
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.sidebarToggleIdentifier:
            return makeSidebarToggleItem()

        case Self.backForwardIdentifier:
            return makeBackForwardItem()

        case Self.breadcrumbIdentifier:
            return makeBreadcrumbItem()

        case Self.viewModeIdentifier:
            return makeViewModeItem()

        case Self.searchIdentifier:
            return makeSearchItem()

        default:
            return nil
        }
    }

    // MARK: - Toolbar Items

    private func makeSidebarToggleItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.sidebarToggleIdentifier)
        item.label = "Toggle Sidebar"
        item.toolTip = "Show or hide the sidebar"
        item.isBordered = true
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
        item.target = self
        item.action = #selector(toggleSidebar)
        return item
    }

    private func makeBackForwardItem() -> NSToolbarItem {
        let group = NSToolbarItemGroup(itemIdentifier: Self.backForwardIdentifier)

        let backItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("back"))
        backItem.label = "Back"
        backItem.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backItem.target = self
        backItem.action = #selector(goBack)
        backItem.isBordered = true

        let forwardItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("forward"))
        forwardItem.label = "Forward"
        forwardItem.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        forwardItem.target = self
        forwardItem.action = #selector(goForward)
        forwardItem.isBordered = true

        group.subitems = [backItem, forwardItem]
        group.controlRepresentation = .automatic
        group.selectionMode = .momentary
        group.label = "Navigation"

        return group
    }

    private func makeBreadcrumbItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.breadcrumbIdentifier)
        let bar = BreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 620, height: 34))
        bar.url = initialURL
        bar.onSegmentClicked = { [weak self] url in
            self?.navigateTo(url)
        }
        breadcrumbBar = bar

        item.view = bar
        item.label = "Path"

        // Size constraints via auto layout on the bar view
        bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        bar.widthAnchor.constraint(lessThanOrEqualToConstant: 1000).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 34).isActive = true

        return item
    }

    private func makeViewModeItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.viewModeIdentifier)
        item.label = "View Mode"
        item.toolTip = "Change view mode"

        let segmented = NSSegmentedControl(images: [
            NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid")!,
            NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!
        ], trackingMode: .selectOne, target: self, action: #selector(viewModeSegmentChanged(_:)))
        segmented.selectedSegment = 0
        segmented.segmentStyle = .automatic

        viewModeSegment = segmented
        item.view = segmented
        return item
    }

    private func makeSearchItem() -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: Self.searchIdentifier)
        item.label = "Search"
        item.searchField.placeholderString = "Search files and folders"
        item.searchField.sendsSearchStringImmediately = true
        item.searchField.sendsWholeSearchString = false
        item.searchField.target = self
        item.searchField.action = #selector(searchFieldChanged(_:))
        searchField = item.searchField
        return item
    }

    // MARK: - Actions

    @objc func toggleSidebar() {
        splitViewController.toggleSidebar()
    }

    @objc func goBack() {
        splitViewController.goBack()
    }

    @objc func goForward() {
        splitViewController.goForward()
    }

    @objc func goUp() {
        splitViewController.goUp()
    }

    @objc func switchToGridView() {
        splitViewController.setViewMode(.grid)
        viewModeSegment?.selectedSegment = 0
    }

    @objc func switchToListView() {
        splitViewController.setViewMode(.list)
        viewModeSegment?.selectedSegment = 1
    }

    @objc private func viewModeSegmentChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            splitViewController.setViewMode(.grid)
        } else {
            splitViewController.setViewMode(.list)
        }
    }

    @objc func toggleSearch() {
        guard let searchField else { return }
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        splitViewController.updateSearchQuery(sender.stringValue)
    }

    @objc func newTab() {
        splitViewController.newTab()
    }

    @objc func closeTab() {
        splitViewController.closeTab()
    }

    @objc func toggleHiddenFiles() {
        splitViewController.toggleHiddenFiles()
    }

    @objc func performNewFolder() {
        splitViewController.tabContainer.performNewFolder()
    }

    @objc func performCopy() {
        splitViewController.tabContainer.performCopy()
    }

    @objc func performCut() {
        splitViewController.tabContainer.performCut()
    }

    @objc func performPaste() {
        splitViewController.tabContainer.performPaste()
    }

    // Standard copy:/cut:/paste: overrides so the Edit menu (Cmd+C/V/X)
    // routes correctly: when a text field editor is first responder it
    // handles these naturally (text copy/paste); when it's NOT first
    // responder, the responder chain falls through to us and we perform
    // file operations.
    @objc func copy(_ sender: Any?) {
        splitViewController.tabContainer.performCopy()
    }

    @objc func cut(_ sender: Any?) {
        splitViewController.tabContainer.performCut()
    }

    @objc func paste(_ sender: Any?) {
        splitViewController.tabContainer.performPaste()
    }

    @objc func performTrash() {
        splitViewController.tabContainer.performTrash()
    }

    @objc func performRename() {
        splitViewController.tabContainer.performRename()
    }

    @objc func performToggleStar() {
        splitViewController.tabContainer.performToggleStar()
    }

    @objc func goHome() {
        navigateTo(FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func editPathBar() {
        breadcrumbBar?.startEditing()
    }

    @objc func refreshDirectory() {
        splitViewController.tabContainer.activeContentController?.refreshDirectory()
    }

    @objc func performQuickLook() {
        splitViewController.tabContainer.performQuickLook()
    }

    @objc func performProperties() {
        splitViewController.tabContainer.performProperties()
    }
}
