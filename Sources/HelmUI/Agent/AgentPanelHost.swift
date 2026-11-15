#if os(macOS)
import AppKit
import SwiftUI
import HelmAgent
import HelmCore

/// The AI panel's column: under the header, beside the files, as wide as the person chose while open and zero wide
/// while shut. The tab strip, the files, the operations rows and the status bar end at its leading edge. It is shut at
/// every launch. Opening it in a window too narrow for the files first hides the sidebar, then widens the window;
/// shutting it gives both back, unless the person has moved the sidebar or the window's edge since. Its leading edge
/// can be dragged, from 300 points to 560 or 45% of the window, whichever is less, and a double click on it puts back
/// 340. The width is kept in Settings for the next time the panel opens.
@MainActor final class AgentPanelHost: NSView {
    /// The width the panel opens at until its edge is dragged, and the one a double click on its edge puts back.
    static let width: CGFloat = 340, minimumFilesWidth: CGFloat = 420
    static let minimumWidth: CGFloat = 300, maximumWidth: CGFloat = 560
    /// The most of the window the panel may take by a drag of its edge.
    static let maximumShare: CGFloat = 0.45
    /// The fixed space above the folders row. The panel never takes a top inset from the title bar, which is taller
    /// in some builds than in others.
    static let topInset: CGFloat = 8

    /// The widest the panel may be in a window `windowWidth` wide: 560 points, or 45% of the window when that is less.
    /// It never drops under the width the panel starts at, so a narrow window still opens it as it always did and
    /// makes room for it.
    static func widest(inWindowWidth windowWidth: CGFloat) -> CGFloat {
        max(width, min(maximumWidth, (windowWidth * maximumShare).rounded(.down)))
    }
    /// `wanted`, kept to the panel's limits in a window `windowWidth` wide.
    static func clamped(_ wanted: CGFloat, windowWidth: CGFloat) -> CGFloat {
        min(max(wanted.rounded(), minimumWidth), widest(inWindowWidth: windowWidth))
    }

    /// Zero while shut, `shownWidth` while open. The window activates it with the rest of its layout.
    private(set) lazy var widthConstraint: NSLayoutConstraint = widthAnchor.constraint(equalToConstant: 0)
    private weak var browser: BrowserWindowController?
    /// What the panel shows, made the first time it opens and kept while AI mode stays ready.
    private(set) var model: AgentPanelModel?
    private(set) var isOpen = false
    /// How wide the panel is while open, or would open in a window as wide as this one is now.
    private(set) var shownWidth: CGFloat = AgentPanelHost.width

    /// Always `shownWidth` wide and pinned to the leading edge, so a shut panel squeezes nothing and widens nothing.
    private let column = NSView()
    private lazy var columnWidth: NSLayoutConstraint = column.widthAnchor.constraint(equalToConstant: Self.width)
    private let divider = NSBox()
    /// The leading edge's handle, over the divider: drag it to resize, double-click it to put back 340.
    private let edge = Edge()
    /// The width when the edge's drag began, while it lasts.
    private var dragStart: CGFloat?
    private var resizeObserver: NSObjectProtocol?
    private var hosting: NSHostingView<AgentPanelView>?
    private let composer = AgentComposerView()
    private var runtimeToken: Broadcast<AgentRuntimeState>.Token?
    private var configToken: Broadcast<AIConfig>.Token?
    private var closeObserver: NSObjectProtocol?
    /// The files' own minimum, put back when the panel shuts.
    private var filesMinimum: CGFloat?
    /// What opening took to make room: the sidebar it hid, and the width it added and the width that left the window.
    private var hidSidebar = false
    private var added: (width: CGFloat, leftAt: CGFloat)?

    /// Whether the keys are in the panel: its first responder is the panel or inside it.
    var holdsKeys: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// Called once, after the window has laid out its content.
    func install(in window: BrowserWindowController) {
        browser = window
        column.translatesAutoresizingMaskIntoConstraints = false
        column.isHidden = true
        addSubview(column)
        divider.boxType = .separator
        for view in [divider, composer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(view)
        }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor), columnWidth,
            divider.topAnchor.constraint(equalTo: column.topAnchor), divider.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: column.leadingAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
            composer.leadingAnchor.constraint(equalTo: divider.trailingAnchor), composer.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: column.bottomAnchor)
        ])
        installEdge()
        registerForDraggedTypes([.fileURL])
        runtimeToken = window.dependencies.agent.runtime.changes.subscribe { [weak self] state in self?.runtimeChanged(state) }
        // A check that answered, a key that went or a model chosen anywhere changes what the model menu offers.
        configToken = window.dependencies.agent.config.changes.subscribe { [weak self] _ in self?.refreshModelMenu() }
        if let shown = window.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: shown,
                                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowWillClose() }
            }
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: shown,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidResize() }
            }
        }
        updateSpark()
    }

    func setOpen(_ open: Bool, animated: Bool) {
        guard let browser else { return }
        guard open != isOpen else {
            if open { focusComposer() }
            return
        }
        if open {
            if model == nil {
                guard let made = browser.makeAgentPanelModel() else { return }
                attach(made)
            }
            // The width the person chose, as much of it as this window allows.
            let width = min(chosenWidth, Self.widest(inWindowWidth: browser.window?.frame.width ?? 0))
            shownWidth = width
            columnWidth.constant = width
            makeRoom(in: browser)
            isOpen = true
            column.isHidden = false
            widthConstraint.constant = width
            if let files = browser.split.splitViewItems.last {
                filesMinimum = files.minimumThickness
                files.minimumThickness = width + Self.minimumFilesWidth
            }
            superview?.layoutSubtreeIfNeeded()
            windowDidRender()
            refreshModelMenu()
            focusComposer()
            browser.refreshLocalModelLists()
        } else {
            let hadKeys = holdsKeys
            dragStart = nil
            isOpen = false
            widthConstraint.constant = 0
            if let files = browser.split.splitViewItems.last, let filesMinimum { files.minimumThickness = filesMinimum }
            filesMinimum = nil
            superview?.layoutSubtreeIfNeeded()
            giveRoomBack(in: browser)
            if hadKeys { browser.focusContent() }
            column.isHidden = true
        }
        updateSpark()
    }

    /// The tab, its folder or its selection may have changed.
    func windowDidRender() {
        guard isOpen, let browser, let model else { return }
        model.update(tab: browser.agentTabContext)
    }

    /// The caret goes to the composer.
    func focusComposer() {
        guard isOpen else { return }
        composer.focus()
    }

    /// The composer's text view, for tests that press keys in it.
    var composerTextViewForTesting: NSTextView { composer.textView }
    /// The name under the composer, and whether it shows as a menu.
    var modelNameForTesting: (name: String, isMenu: Bool) { (composer.modelNameForTesting, composer.modelNameIsMenuForTesting) }
    /// The rows of the menu under the composer, by title: section names, models and AI Settings…. Empty with no menu.
    var modelMenuTitlesForTesting: [String] { composer.makeModelMenu()?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [] }
    /// Picks a row of the menu under the composer by its title, as a click on it would, under one section if named.
    @discardableResult func pickModelMenuRowForTesting(_ title: String, under section: String? = nil) -> Bool {
        composer.pickModelMenuRowForTesting(title, under: section)
    }

    // MARK: The model

    private func attach(_ model: AgentPanelModel) {
        self.model = model
        let view = AgentPanelView(model: model)
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            // The panel's width is fixed and its top inset is its own: nothing inside may widen it or lower it.
            hosting.sizingOptions = []
            hosting.safeAreaRegions = []
            hosting.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: column.topAnchor),
                hosting.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
                hosting.trailingAnchor.constraint(equalTo: column.trailingAnchor),
                hosting.bottomAnchor.constraint(equalTo: composer.topAnchor)
            ])
            self.hosting = hosting
        }
        composer.attach(model, dropTarget: self)
        refreshModelMenu()
    }

    /// What the model's name under the composer offers, worked out again.
    private func refreshModelMenu() {
        guard let browser, let model else { return }
        model.modelMenuChanged(browser.agentModelMenu)
    }

    /// AI mode turned off or lost its model: the panel shuts and its conversation goes. A provider or model that
    /// changed is named from now on.
    private func runtimeChanged(_ state: AgentRuntimeState) {
        if case .ready = state, let browser, let provider = browser.agentProvider {
            model?.providerChanged(provider)
            refreshModelMenu()
        } else {
            if isOpen { setOpen(false, animated: false) }
            model?.close()
            model = nil
        }
        updateSpark()
    }

    private func windowWillClose() {
        model?.close()
        if let runtimeToken, let browser { browser.dependencies.agent.runtime.changes.cancel(runtimeToken) }
        if let configToken, let browser { browser.dependencies.agent.config.changes.cancel(configToken) }
        runtimeToken = nil
        configToken = nil
        for observer in [closeObserver, resizeObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        closeObserver = nil
        resizeObserver = nil
    }

    func updateSpark() {
        guard let browser else { return }
        var ready = false
        if case .ready = browser.dependencies.agent.runtime.state { ready = true }
        browser.header.setAIPanel(open: isOpen, working: model?.isWorking ?? false, ready: ready)
    }

    /// Room for the files beside the panel, at least `minimumFilesWidth` and as much as the list needs for every column's words:
    /// the sidebar goes first, then the window grows by what is still missing. What it took is kept, to give back when
    /// the panel shuts.
    private func makeRoom(in browser: BrowserWindowController) {
        hidSidebar = false
        added = nil
        guard let root = superview else { return }
        root.layoutSubtreeIfNeeded()
        var room = root.bounds.width - shownWidth
        let needed = max(Self.minimumFilesWidth, browser.filesRoomNeeded)
        if room < needed, let sidebar = browser.split.splitViewItems.first, !sidebar.isCollapsed {
            sidebar.isCollapsed = true
            browser.sidebarVisibilityChanged(false, animated: false)
            browser.split.view.layoutSubtreeIfNeeded()
            room = root.bounds.width - shownWidth
            hidSidebar = true
        }
        if room < needed, let window = browser.window {
            var frame = window.frame
            let grow = ceil(needed - room)
            frame.size.width += grow
            window.setFrame(frame, display: window.isVisible)
            browser.split.view.layoutSubtreeIfNeeded()
            added = (grow, window.frame.width)
        }
    }

    /// The panel shut: the width it added goes, if the window is still the width it left it at, and a sidebar it
    /// hid comes back, if it is still hidden.
    private func giveRoomBack(in browser: BrowserWindowController) {
        defer { hidSidebar = false; added = nil }
        guard let window = browser.window else { return }
        if let added {
            // The person resized the window meanwhile: what they chose stays, sidebar and all.
            guard abs(window.frame.width - added.leftAt) < 0.5 else { return }
            var frame = window.frame
            frame.size.width -= added.width
            window.setFrame(frame, display: window.isVisible)
        }
        if hidSidebar, let sidebar = browser.split.splitViewItems.first, sidebar.isCollapsed {
            browser.setSidebarShown(true, animated: false)
        }
        browser.split.view.layoutSubtreeIfNeeded()
    }

    /// The person showed or hid the sidebar while the panel was open: it is theirs now, and so is the width.
    func sidebarToggledByPerson() {
        hidSidebar = false
        added = nil
    }

    /// For tests: whether shutting the panel would give back a hidden sidebar or added width.
    var givesBackForTesting: (sidebar: Bool, width: CGFloat) { (hidSidebar, added?.width ?? 0) }

    // MARK: The width

    /// The width the person last chose by dragging the edge, from Settings.
    private var chosenWidth: CGFloat {
        guard let browser else { return Self.width }
        return CGFloat(browser.dependencies.settings.snapshot.double(.agentPanelWidth))
    }

    private func installEdge() {
        edge.translatesAutoresizingMaskIntoConstraints = false
        // Over the divider and the first points of the panel, above everything else in the column.
        column.addSubview(edge, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            edge.topAnchor.constraint(equalTo: column.topAnchor), edge.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: column.leadingAnchor), edge.widthAnchor.constraint(equalToConstant: Edge.thickness)
        ])
        edge.began = { [weak self] in self?.edgeBegan() }
        edge.moved = { [weak self] distance in self?.edgeMoved(by: distance) }
        edge.ended = { [weak self] in self?.edgeEnded() }
        edge.reset = { [weak self] in self?.edgeReset() }
    }

    private func edgeBegan() {
        guard isOpen else { return }
        dragStart = shownWidth
    }
    /// `distance` is how far the pointer has gone towards the leading side since the drag began.
    private func edgeMoved(by distance: CGFloat) {
        guard let start = dragStart else { return }
        resize(to: start + distance)
    }
    private func edgeEnded() {
        guard dragStart != nil else { return }
        dragStart = nil
        keep(shownWidth)
    }
    private func edgeReset() {
        dragStart = nil
        guard isOpen else { return }
        resize(to: Self.width)
        keep(Self.width)
    }

    /// Shows the open panel `wanted` wide, within its limits. A drag never takes the files under their minimum, never
    /// hides the sidebar and never widens the window: the panel stops growing when the files have no more to give.
    private func resize(to wanted: CGFloat) {
        guard isOpen, let browser, let window = browser.window else { return }
        var width = Self.clamped(wanted, windowWidth: window.frame.width)
        if let root = superview, width > shownWidth {
            width = min(width, max(shownWidth, (root.bounds.width - Self.minimumFilesWidth).rounded(.down)))
        }
        apply(width)
    }

    private func apply(_ width: CGFloat) {
        guard width != shownWidth, let browser else { return }
        shownWidth = width
        columnWidth.constant = width
        widthConstraint.constant = width
        if let files = browser.split.splitViewItems.last { files.minimumThickness = width + Self.minimumFilesWidth }
        superview?.layoutSubtreeIfNeeded()
    }

    /// Kept in Settings, for the next time the panel opens, in this window or another.
    private func keep(_ width: CGFloat) {
        guard let settings = browser?.dependencies.settings else { return }
        let value = SettingValue.double(Double(width.rounded()))
        if settings.snapshot.double(.agentPanelWidth) != Double(width.rounded()) { settings.set(value, for: .agentPanelWidth) }
    }

    /// A window made narrower takes the panel down with it, to at most 45% of the window. Made wider again, the
    /// panel stays as it is until it's dragged or opened again.
    private func windowDidResize() {
        guard isOpen, dragStart == nil, let window = browser?.window else { return }
        let widest = Self.widest(inWindowWidth: window.frame.width)
        if shownWidth > widest { apply(widest) }
    }

    /// For tests and scripted runs: a drag of the edge `distance` points towards the leading side (negative goes
    /// back), from press to release, and a double click on it.
    func dragEdgeForTesting(by distance: CGFloat) {
        edgeBegan()
        edgeMoved(by: distance)
        edgeEnded()
    }
    func doubleClickEdgeForTesting() { edgeReset() }
    /// The edge's handle: where it sits in the panel, and the cursor it shows.
    var edgeFrameForTesting: NSRect { edge.frame }
    var edgeCursorForTesting: NSCursor { Edge.cursor }

    /// The panel's leading edge. It shows the resize cursor, and reports a drag and a double click.
    @MainActor private final class Edge: NSView {
        static let thickness: CGFloat = 6
        static var cursor: NSCursor {
            if #available(macOS 15.0, *) { return .columnResize }
            return .resizeLeftRight
        }
        var began: () -> Void = {}
        var moved: (CGFloat) -> Void = { _ in }
        var ended: () -> Void = {}
        var reset: () -> Void = {}
        /// Where the pointer was on the screen when the drag began.
        private var startX: CGFloat?

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: Self.cursor) }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                startX = nil
                reset()
                return
            }
            startX = NSEvent.mouseLocation.x
            began()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            moved(startX - NSEvent.mouseLocation.x)
        }
        override func mouseUp(with event: NSEvent) {
            guard startX != nil else { return }
            startX = nil
            ended()
        }
    }

    // MARK: Drops

    /// A folder dropped on the panel is added to the folders AI mode can use. It is never moved.
    private func droppedFolders(_ info: NSDraggingInfo) -> [URL] {
        guard isOpen, let model else { return [] }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return Self.folders(urls, home: model.homePath)
    }

    /// The dropped items that may be folders AI mode can use. The place test runs on the path's text first, as the
    /// scope gate's does, so an item in a place AI mode never uses, such as a host under /net, is not looked up on
    /// the disk while it is dragged.
    nonisolated static func folders(_ urls: [URL], home: String, isFolder: (URL) -> Bool = AgentPanelHost.isFolder) -> [URL] {
        urls.filter { url in
            url.isFileURL && AgentItemFilter.area(ofPath: url.path, home: home) != .refused && (url.hasDirectoryPath || isFolder(url))
        }
    }

    private nonisolated static func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { droppedFolders(sender).isEmpty ? [] : .link }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { droppedFolders(sender).isEmpty ? [] : .link }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let folders = droppedFolders(sender)
        guard let model, !folders.isEmpty else { return false }
        for folder in folders { model.drop(folder) }
        return true
    }
}
#endif
