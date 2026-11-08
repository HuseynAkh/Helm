#if os(macOS)
import AppKit
import HelmCore
import HelmPersistence
import SwiftUI

/// Helm › Settings: one toolbar tab per pane, as in Finder and System Settings. The window resizes to each pane.
@MainActor public final class SettingsWindowController: NSWindowController {
    private let tabs = SettingsTabs()

    public init(store: SettingsStore, fileViewer: FileViewerModel?, supportsSingleClick: Bool = false) {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneHost(pane: pane, store: store, fileViewer: fileViewer,
                                                                      supportsSingleClick: supportsSingleClick))
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
        window.setFrameAutosaveName("HelmSettings")
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
}

/// Resizes the window to each pane as it's chosen, keeping the top edge where it was, as System Settings does.
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fit(animated: view.window?.isVisible == true)
    }
    func fit(animated: Bool) {
        guard let window = view.window, SettingsPane.allCases.indices.contains(selectedTabViewItemIndex) else { return }
        let pane = SettingsPane.allCases[selectedTabViewItemIndex]
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: pane.height)).size
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true, animate: animated)
    }
}

/// One pane, redrawn from the store after every change.
private struct SettingsPaneHost: View {
    let pane: SettingsPane
    let store: SettingsStore
    let fileViewer: FileViewerModel?
    let supportsSingleClick: Bool
    @State private var snapshot: SettingsSnapshot

    init(pane: SettingsPane, store: SettingsStore, fileViewer: FileViewerModel?, supportsSingleClick: Bool) {
        self.pane = pane; self.store = store; self.fileViewer = fileViewer; self.supportsSingleClick = supportsSingleClick
        _snapshot = State(initialValue: store.snapshot)
    }
    var body: some View {
        SettingsPaneView(pane: pane, snapshot: snapshot, supportsSingleClick: supportsSingleClick, fileViewer: fileViewer) { key, value in
            store.set(value, for: key)
            snapshot = store.snapshot
        }
        .frame(width: 560, height: pane.height)
        .onAppear { snapshot = store.snapshot }
    }
}
#endif
