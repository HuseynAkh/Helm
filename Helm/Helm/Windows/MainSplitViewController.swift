import Cocoa

class MainSplitViewController: NSSplitViewController {

    private let sidebarController = SidebarContainerController()
    let tabContainer = TabContainerViewController()

    private var sidebarItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        contentItem = NSSplitViewItem(viewController: tabContainer)
        contentItem.minimumThickness = 400

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        splitView.dividerStyle = .thin
        splitView.autosaveName = "HelmMainSplitView"

        // Wire sidebar navigation to content
        sidebarController.onPlaceSelected = { [weak self] url in
            self?.navigateTo(url)
        }
        tabContainer.onActiveLocationChanged = { [weak self] url in
            self?.sidebarController.selectLocation(url)
        }
    }

    func navigateTo(_ url: URL) {
        tabContainer.navigateTo(url)
    }

    func toggleSidebar() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            sidebarItem.animator().isCollapsed = !sidebarItem.isCollapsed
        }
        splitView.adjustSubviews()
    }

    func goBack() {
        tabContainer.goBack()
    }

    func goForward() {
        tabContainer.goForward()
    }

    func goUp() {
        tabContainer.goUp()
    }

    func setViewMode(_ mode: ViewMode) {
        tabContainer.setViewMode(mode)
    }

    func newTab() {
        tabContainer.addNewTabAtCurrentURL()
    }

    func closeTab() {
        tabContainer.closeCurrentTab()
    }

    func toggleHiddenFiles() {
        tabContainer.toggleHiddenFiles()
    }

    func updateSearchQuery(_ query: String) {
        tabContainer.updateSearchQuery(query)
    }
}
