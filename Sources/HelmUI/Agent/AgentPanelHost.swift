#if os(macOS)
import AppKit
import SwiftUI
import HelmAgent
import HelmCore

/// The AI panel's column: under the header, beside the files, `width` wide while open and zero wide while shut.
/// The tab strip, the files, the operations rows and the status bar end at its leading edge. It is shut at every
/// launch. Opening it in a window too narrow for the files first hides the sidebar, then widens the window.
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
    private func makeRoom(in browser: BrowserWindowController) {
        guard let root = superview else { return }
        root.layoutSubtreeIfNeeded()
        var room = root.bounds.width - Self.width
        if room < Self.minimumFilesWidth, let sidebar = browser.split.splitViewItems.first, !sidebar.isCollapsed {
            sidebar.isCollapsed = true
            browser.sidebarVisibilityChanged(false, animated: false)
            browser.split.view.layoutSubtreeIfNeeded()
            room = root.bounds.width - Self.width
        }
        if room < Self.minimumFilesWidth, let window = browser.window {
            var frame = window.frame
            frame.size.width += Self.minimumFilesWidth - room
            window.setFrame(frame, display: window.isVisible)
            browser.split.view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: Drops

    /// A folder dropped on the panel is added to the folders AI mode can use. It is never moved.
    private func droppedFolders(_ info: NSDraggingInfo) -> [URL] {
        guard isOpen, model != nil else { return [] }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

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
