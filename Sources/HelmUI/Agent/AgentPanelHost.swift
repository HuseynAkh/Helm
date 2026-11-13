#if os(macOS)
import AppKit
import SwiftUI
import HelmAgent
import HelmCore

/// The AI panel's column: under the header, beside the files, `width` wide while open and zero wide while shut.
/// The tab strip, the files, the operations rows and the status bar end at its leading edge. It is shut at every
/// launch. Opening it in a window too narrow for the files first hides the sidebar, then widens the window; shutting
/// it gives both back, unless the person has moved the sidebar or the window's edge since.
@MainActor final class AgentPanelHost: NSView {
    static let width: CGFloat = 340, minimumFilesWidth: CGFloat = 420
    /// The fixed space above the folders row. The panel never takes a top inset from the title bar, which is taller
    /// in some builds than in others.
    static let topInset: CGFloat = 8

    /// Zero while shut, `width` while open. The window activates it with the rest of its layout.
    private(set) lazy var widthConstraint: NSLayoutConstraint = widthAnchor.constraint(equalToConstant: 0)
    private weak var browser: BrowserWindowController?
    /// What the panel shows, made the first time it opens and kept while AI mode stays ready.
    private(set) var model: AgentPanelModel?
    private(set) var isOpen = false

    /// Always `width` wide and pinned to the leading edge, so a shut panel squeezes nothing and widens nothing.
    private let column = NSView()
    private let divider = NSBox()
    private var hosting: NSHostingView<AgentPanelView>?
    private let composer = AgentComposerView()
    private var runtimeToken: Broadcast<AgentRuntimeState>.Token?
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
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.widthAnchor.constraint(equalToConstant: Self.width),
            divider.topAnchor.constraint(equalTo: column.topAnchor), divider.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: column.leadingAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
            composer.leadingAnchor.constraint(equalTo: divider.trailingAnchor), composer.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: column.bottomAnchor)
        ])
        registerForDraggedTypes([.fileURL])
        runtimeToken = window.dependencies.agent.runtime.changes.subscribe { [weak self] state in self?.runtimeChanged(state) }
        if let shown = window.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: shown,
                                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowWillClose() }
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
            makeRoom(in: browser)
            isOpen = true
            column.isHidden = false
            widthConstraint.constant = Self.width
            if let files = browser.split.splitViewItems.last {
                filesMinimum = files.minimumThickness
                files.minimumThickness = Self.width + Self.minimumFilesWidth
            }
            superview?.layoutSubtreeIfNeeded()
            windowDidRender()
            focusComposer()
        } else {
            let hadKeys = holdsKeys
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
    }

    /// AI mode turned off or lost its model: the panel shuts and its conversation goes. A provider or model that
    /// changed is named from now on.
    private func runtimeChanged(_ state: AgentRuntimeState) {
        if case .ready = state, let browser, let provider = browser.agentProvider {
            model?.providerChanged(provider)
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
        runtimeToken = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    func updateSpark() {
        guard let browser else { return }
        var ready = false
        if case .ready = browser.dependencies.agent.runtime.state { ready = true }
        browser.header.setAIPanel(open: isOpen, working: model?.isWorking ?? false, ready: ready)
    }

    /// Room for the files beside the panel: the sidebar goes first, then the window grows by what is still missing.
    /// What it took is kept, to give back when the panel shuts.
    private func makeRoom(in browser: BrowserWindowController) {
        hidSidebar = false
        added = nil
        guard let root = superview else { return }
        root.layoutSubtreeIfNeeded()
        var room = root.bounds.width - Self.width
        if room < Self.minimumFilesWidth, let sidebar = browser.split.splitViewItems.first, !sidebar.isCollapsed {
            sidebar.isCollapsed = true
            browser.sidebarVisibilityChanged(false, animated: false)
            browser.split.view.layoutSubtreeIfNeeded()
            room = root.bounds.width - Self.width
            hidSidebar = true
        }
        if room < Self.minimumFilesWidth, let window = browser.window {
            var frame = window.frame
            let grow = Self.minimumFilesWidth - room
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
