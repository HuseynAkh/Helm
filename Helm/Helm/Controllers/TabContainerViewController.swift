import Cocoa

/// Manages multiple tabs, each with its own ContentViewController
class TabContainerViewController: NSViewController {

    private var tabs: [Tab] = []
    private var tabControllers: [UUID: ContentViewController] = [:]
    private var activeTabID: UUID?
    var onActiveLocationChanged: ((URL) -> Void)?

    private var tabBar: TabBarView!
    private var contentContainer: NSView!
    private var tabBarHeightConstraint: NSLayoutConstraint!

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupTabBar()
        setupContentContainer()

        // Create initial tab
        let initialURL = FileManager.default.homeDirectoryForCurrentUser
        addNewTab(at: initialURL, switchTo: true)
    }

    private func setupTabBar() {
        tabBar = TabBarView(frame: .zero)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)

        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarHeightConstraint
        ])

        tabBar.onTabSelected = { [weak self] tabID in
            self?.switchToTab(tabID)
        }
        tabBar.onTabClosed = { [weak self] tabID in
            self?.closeTab(tabID)
        }
        tabBar.onNewTab = { [weak self] in
            self?.addNewTabAtCurrentURL()
        }
    }

    private func setupContentContainer() {
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Tab Management

    @discardableResult
    func addNewTab(at url: URL, switchTo: Bool) -> UUID {
        let tab = Tab(url: url)
        tabs.append(tab)

        let contentVC = ContentViewController(initialURL: url)
        contentVC.onLocationChanged = { [weak self] newURL in
            self?.updateTab(for: tab.id, url: newURL)
        }
        tabControllers[tab.id] = contentVC
        addChild(contentVC)

        if switchTo {
            switchToTab(tab.id)
        }

        updateTabBar()
        return tab.id
    }

    func addNewTabAtCurrentURL() {
        let url = activeContentController?.activeLocationURL
            ?? FileManager.default.homeDirectoryForCurrentUser
        addNewTab(at: url, switchTo: true)
    }

    func closeTab(_ tabID: UUID) {
        guard tabs.count > 1 else { return } // Don't close last tab

        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        // If closing active tab, switch to adjacent tab
        if tabID == activeTabID {
            let newIndex = index > 0 ? index - 1 : 1
            if newIndex < tabs.count {
                switchToTab(tabs[newIndex].id)
            }
        }

        tabs.remove(at: index)
        if let controller = tabControllers.removeValue(forKey: tabID) {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }

        updateTabBar()
    }

    func closeCurrentTab() {
        guard let id = activeTabID else { return }
        if tabs.count <= 1 {
            // Close window instead
            view.window?.close()
        } else {
            closeTab(id)
        }
    }

    private func switchToTab(_ tabID: UUID) {
        guard let controller = tabControllers[tabID] else { return }

        // Hide current tab's content
        if let currentID = activeTabID, let currentVC = tabControllers[currentID] {
            currentVC.view.removeFromSuperview()
        }

        activeTabID = tabID

        // Show new tab's content
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])

        tabBar.selectedTabID = tabID

        // Update breadcrumb
        let currentURL = controller.activeLocationURL
        onActiveLocationChanged?(currentURL)
        if let windowController = view.window?.windowController as? MainWindowController {
            windowController.updateBreadcrumb(for: currentURL)
        }
    }

    private func updateTabBar() {
        tabBar.tabs = tabs
        tabBar.selectedTabID = activeTabID

        // Show tab bar only when multiple tabs exist
        let showTabBar = tabs.count > 1
        tabBarHeightConstraint.constant = showTabBar ? 30 : 0
        tabBar.isHidden = !showTabBar
    }

    // MARK: - Access active tab

    var activeContentController: ContentViewController? {
        guard let id = activeTabID else { return nil }
        return tabControllers[id]
    }

    /// Update the tab title when navigation occurs
    func updateActiveTabTitle(for url: URL) {
        guard let id = activeTabID else { return }
        updateTab(for: id, url: url)
    }

    private func updateTab(for tabID: UUID, url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].update(url: url)
        updateTabBar()

        if tabID == activeTabID,
           let windowController = view.window?.windowController as? MainWindowController {
            windowController.updateBreadcrumb(for: url)
        }
        if tabID == activeTabID {
            onActiveLocationChanged?(url)
        }
    }

    // MARK: - Forwarded actions

    func navigateTo(_ url: URL) {
        activeContentController?.navigateTo(url)
    }

    func goBack() {
        activeContentController?.goBack()
    }

    func goForward() {
        activeContentController?.goForward()
    }

    func goUp() {
        activeContentController?.goUp()
    }

    func setViewMode(_ mode: ViewMode) {
        activeContentController?.setViewMode(mode)
    }

    func toggleHiddenFiles() {
        activeContentController?.toggleHiddenFiles()
    }

    func updateSearchQuery(_ query: String) {
        activeContentController?.updateSearchQuery(query)
    }

    func performNewFolder() {
        activeContentController?.performNewFolder()
    }

    func performCopy() {
        activeContentController?.performCopy()
    }

    func performCut() {
        activeContentController?.performCut()
    }

    func performPaste() {
        activeContentController?.performPaste()
    }

    func performTrash() {
        activeContentController?.performTrash()
    }

    func performRename() {
        activeContentController?.performRename()
    }

    func performToggleStar() {
        activeContentController?.performToggleStar()
    }

    func performQuickLook() {
        activeContentController?.performQuickLook()
    }

    func performProperties() {
        activeContentController?.performProperties()
    }
}
