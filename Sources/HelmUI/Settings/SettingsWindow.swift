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
        // No crossfade: on macOS 26 a pane that faded in kept the edge AppKit draws where a scroll view meets the
        // toolbar, a frosted band with a line, a toolbar's height tall, over its first rows, until the window closed.
        tabs.transitionOptions = [.allowUserInteraction]
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneHost(pane: pane, store: store, fileViewer: fileViewer,
                                                                      access: access, supportsSingleClick: supportsSingleClick))
            host.sizingOptions = []
            host.title = pane.rawValue
            let item = NSTabViewItem(viewController: host)
            item.label = pane.rawValue
            // AI's tab draws Helm's own spark, the mark AI mode has wherever it shows.
            item.image = pane == .ai ? SparkMark.image(size: 18, lit: false)
                : NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.rawValue)
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
    func fitPane() { tabs.fit() }

    /// For fixture runs: each area of a pane that could scroll, with the height of what it holds and of what's in
    /// view. The pane shows all of itself when every area has all of it in view.
    public func scrollAreasForTesting(_ pane: SettingsPane) -> [(content: CGFloat, visible: CGFloat)] {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
        }
        guard let view = paneController(pane)?.view else { return [] }
        view.layoutSubtreeIfNeeded()
        return scrollViews(in: view).compactMap { scroll in
            guard let document = scroll.documentView else { return nil }
            let insets = scroll.contentInsets
            return (document.frame.height, scroll.contentView.bounds.height - insets.top - insets.bottom)
        }
    }
    /// The window's content height, for fixture runs.
    public var contentHeightForTesting: CGFloat { window?.contentLayoutRect.height ?? 0 }
    /// Makes the window's content this tall, as a pane that came out too short would, for fixture runs.
    public func squeezeForTesting(to height: CGFloat) {
        guard let window else { return }
        var frame = window.frame
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: height)).size
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
    }
    /// Fits the window to the pane on show, as a change to what it shows does, for fixture runs.
    public func fitPaneForTesting() { fitPane() }
    /// Each area of a pane that could scroll, in words: its frame in the window, its insets, how far it's scrolled and
    /// what it holds, with the window's content height, for fixture runs.
    public func scrollDetailsForTesting(_ pane: SettingsPane) -> String {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
        }
        guard let view = paneController(pane)?.view else { return "no pane" }
        view.layoutSubtreeIfNeeded()
        let areas = scrollViews(in: view).map { scroll -> String in
            let frame = scroll.convert(scroll.bounds, to: nil)
            let insets = scroll.contentInsets
            let flipped = scroll.documentView?.isFlipped == true
            return "frame y \(Int(frame.minY)) h \(Int(frame.height)), insets \(Int(insets.top))/\(Int(insets.bottom)), "
                + "clip y \(Int(scroll.contentView.bounds.minY)) h \(Int(scroll.contentView.bounds.height)), "
                + "document \(Int(scroll.documentView?.frame.height ?? -1))\(flipped ? " flipped" : "")"
        }
        return "content \(Int(window?.contentLayoutRect.height ?? 0)), pane view h \(Int(view.frame.height)): " + areas.joined(separator: "; ")
    }
    /// How far each area of the pane on show is scrolled from its top, for fixture runs.
    public var scrolledFromTopForTesting: [CGFloat] { tabs.scrolledFromTopForTesting }
    /// For fixture runs: how tall the edge AppKit draws where a scroll view meets the toolbar is inside the pane, in
    /// points. A pane sits below the toolbar, so it should be 0; SDK 14 builds draw no such edge at all.
    public func toolbarEdgeForTesting(_ pane: SettingsPane) -> CGFloat {
        guard let view = paneController(pane)?.view else { return 0 }
        view.layoutSubtreeIfNeeded()
        func edges(in view: NSView) -> [CGFloat] {
            guard !view.isHidden, view.alphaValue > 0 else { return [] }
            let own = String(describing: type(of: view)).contains("Pocket") ? [view.frame.height] : []
            return own + view.subviews.flatMap(edges(in:))
        }
        return edges(in: view).max() ?? 0
    }
}

/// Resizes the window to each pane as it's chosen, keeping the top edge where it was, as System Settings does.
///
/// A pane's height is its form's own, measured as it's drawn, since a form's rows are taller with a newer SDK than
/// with the one a fixed height was measured with; a pane whose form can't be measured yet uses its fixed height. The
/// window changes size at once rather than animating: a pane that fits itself again while an animation is under way,
/// as Settings › AI does when its model loads, left the window's old outline drawn below it.
private final class SettingsTabs: NSTabViewController {
    /// Panes whose height depends on what they show. The others have a fixed height.
    var heights: [SettingsPane: () -> CGFloat] = [:]
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fit()
        // Once the pane has laid out its form, which can take a turn of the run loop, fit it to what it holds.
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }
    /// The height a pane's form needs to show all it holds: what its scrolling areas hold, with their insets. Nil
    /// before the form is laid out.
    static func measuredHeight(of view: NSView) -> CGFloat? {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
        }
        view.layoutSubtreeIfNeeded()
        let needed = scrollViews(in: view).compactMap { scroll -> CGFloat? in
            guard let document = scroll.documentView, document.frame.height > 0 else { return nil }
            return document.frame.height + scroll.contentInsets.top + scroll.contentInsets.bottom
        }
        return needed.max().map { $0.rounded(.up) }
    }
    func fit(animated: Bool = false) {
        guard let window = view.window, SettingsPane.allCases.indices.contains(selectedTabViewItemIndex) else { return }
        let pane = SettingsPane.allCases[selectedTabViewItemIndex]
        let measured = tabViewItems[selectedTabViewItemIndex].viewController.map(\.view).flatMap(Self.measuredHeight(of:))
        var height: CGFloat
        if pane == .sidebar, let rows = heights[pane] {
            // Sidebar works its own height out from its rows, in two columns.
            height = rows()
        } else if let estimate = heights[pane] {
            // A pane that estimates its height, as AI does, is at least as tall as its form turns out to be.
            height = max(estimate(), measured ?? 0)
        } else {
            height = measured ?? pane.height
        }
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
        if frame != window.frame { window.setFrame(frame, display: true, animate: animated) }
        if let shown = tabViewItems[selectedTabViewItemIndex].viewController?.view { Self.showTop(of: shown) }
    }
    /// A window that shrinks keeps its forms' bottom edge where it was, which leaves a pane that came after a taller
    /// one scrolled, its first rows under the toolbar. Each area that now shows all it holds goes back to its top.
    static func showTop(of view: NSView) {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
        }
        view.layoutSubtreeIfNeeded()
        for scroll in scrollViews(in: view) {
            guard let document = scroll.documentView else { continue }
            let insets = scroll.contentInsets
            guard document.frame.height <= scroll.contentView.bounds.height - insets.top - insets.bottom + 1 else { continue }
            let top = NSPoint(x: scroll.contentView.bounds.minX,
                              y: document.isFlipped ? -insets.top : document.frame.maxY + insets.top - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: top)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    /// Where each area of the pane on show is scrolled to, for fixture runs: 0 is its top.
    var scrolledFromTopForTesting: [CGFloat] {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
        }
        guard SettingsPane.allCases.indices.contains(selectedTabViewItemIndex),
              let shown = tabViewItems[selectedTabViewItemIndex].viewController?.view else { return [] }
        return scrollViews(in: shown).compactMap { scroll in
            guard let document = scroll.documentView else { return nil }
            let y = scroll.contentView.bounds.minY
            return document.isFlipped ? y + scroll.contentInsets.top
                : document.frame.maxY + scroll.contentInsets.top - (y + scroll.contentView.bounds.height)
        }
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
