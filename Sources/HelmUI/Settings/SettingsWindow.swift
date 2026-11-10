#if os(macOS)
import AppKit
import HelmCore
import HelmPersistence
import SwiftUI

/// Helm › Settings: one toolbar tab per pane, as in Finder and System Settings. The window resizes to each pane.
@MainActor public final class SettingsWindowController: NSWindowController {
    private let tabs = SettingsTabs()

    /// `persistsFrame` false keeps the window's place out of the preferences, as for a fixture run or a test.
    public init(store: SettingsStore, fileViewer: FileViewerModel?, access: AccessSettings? = nil, supportsSingleClick: Bool = false,
                persistsFrame: Bool = true) {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneHost(pane: pane, store: store, fileViewer: fileViewer,
                                                                      access: access, supportsSingleClick: supportsSingleClick))
            host.sizingOptions = []
            host.title = pane.rawValue
            let item = NSTabViewItem(viewController: host)
            item.label = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.rawValue)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        // macOS keeps no saved state of Settings to bring back at the next launch.
        window.isRestorable = false
        if persistsFrame { window.setFrameAutosaveName("HelmSettings") }
        super.init(window: window)
        if window.frameAutosaveName.isEmpty || !window.setFrameUsingName("HelmSettings") { window.center() }
        tabs.fit(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The pane on show, for scripted runs and screenshots.
    public func select(_ pane: SettingsPane) {
        guard let index = SettingsPane.allCases.firstIndex(of: pane) else { return }
        tabs.selectedTabViewItemIndex = index
    }
    /// Which pane is on show, as a scripted run checks after “Sidebar Settings…”.
    public var selectedPane: SettingsPane? {
        SettingsPane.allCases.indices.contains(tabs.selectedTabViewItemIndex) ? SettingsPane.allCases[tabs.selectedTabViewItemIndex] : nil
    }

    /// Puts a view controller of its own in place of a pane's settings form, for a pane that shows more than settings,
    /// with the pane's height worked out from what it shows each time the window fits it.
    func replacePane(_ pane: SettingsPane, with controller: NSViewController, height: @escaping () -> CGFloat) {
        guard let index = SettingsPane.allCases.firstIndex(of: pane), tabs.tabViewItems.indices.contains(index) else { return }
        controller.title = pane.rawValue
        let old = tabs.tabViewItems[index]
        let item = NSTabViewItem(viewController: controller)
        item.label = old.label
        item.image = old.image
        let selected = tabs.selectedTabViewItemIndex
        tabs.removeTabViewItem(old)
        tabs.insertTabViewItem(item, at: index)
        tabs.selectedTabViewItemIndex = selected
        tabs.heights[pane] = height
        fitPane()
    }
    func paneController(_ pane: SettingsPane) -> NSViewController? {
        guard let index = SettingsPane.allCases.firstIndex(of: pane), tabs.tabViewItems.indices.contains(index) else { return nil }
        return tabs.tabViewItems[index].viewController
    }
    /// Fits the window to the pane on show again, as when what it shows has grown or shrunk.
    func fitPane() { tabs.fit(animated: window?.isVisible == true) }
}

/// Resizes the window to each pane as it's chosen, keeping the top edge where it was, as System Settings does.
private final class SettingsTabs: NSTabViewController {
    /// Panes whose height depends on what they show. The others have a fixed height.
    var heights: [SettingsPane: () -> CGFloat] = [:]
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fit(animated: view.window?.isVisible == true)
    }
    func fit(animated: Bool) {
        guard let window = view.window, SettingsPane.allCases.indices.contains(selectedTabViewItemIndex) else { return }
        let pane = SettingsPane.allCases[selectedTabViewItemIndex]
        var height = heights[pane]?() ?? pane.height
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame
        // A pane taller than the screen scrolls inside the window, rather than the window running off the screen.
        if let screen {
            let chrome = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: 100)).height - 100
            height = min(height, screen.height - chrome)
        }
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: height)).size
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let screen { frame.origin.y = max(frame.origin.y, screen.minY) }
        window.setFrame(frame, display: true, animate: animated)
    }
}

/// The settings as they are now. Every pane watches it, so a change made anywhere, such as ⌘+ or Show Hidden Files
/// in a window, shows in Settings at once, whether or not the pane is on show.
@MainActor final class SettingsSnapshotModel: ObservableObject {
    @Published private(set) var snapshot: SettingsSnapshot
    private let store: SettingsStore
    init(store: SettingsStore) {
        self.store = store
        snapshot = store.snapshot
        _ = store.changes.subscribe { [weak self] in self?.snapshot = $0 }
    }
    /// A change from the pane itself. A value the store adjusted, or left as it was, is drawn as the store has it.
    func set(_ value: SettingValue, for key: SettingKey) {
        store.set(value, for: key)
        snapshot = store.snapshot
    }
}

/// One pane, redrawn from the store after every change.
private struct SettingsPaneHost: View {
    let pane: SettingsPane
    let fileViewer: FileViewerModel?
    let access: AccessSettings?
    let supportsSingleClick: Bool
    @StateObject private var settings: SettingsSnapshotModel

    init(pane: SettingsPane, store: SettingsStore, fileViewer: FileViewerModel?, access: AccessSettings?, supportsSingleClick: Bool) {
        self.pane = pane; self.fileViewer = fileViewer; self.access = access; self.supportsSingleClick = supportsSingleClick
        _settings = StateObject(wrappedValue: SettingsSnapshotModel(store: store))
    }
    var body: some View {
        SettingsPaneView(pane: pane, snapshot: settings.snapshot, supportsSingleClick: supportsSingleClick, fileViewer: fileViewer,
                         access: access) { key, value in settings.set(value, for: key) }
        // As tall as the window: SettingsTabs.fit makes that the pane's own height, unless the screen is shorter,
        // and then the pane scrolls rather than running off the window's top and bottom.
        .frame(width: 560)
        .frame(maxHeight: .infinity)
    }
}
#endif
