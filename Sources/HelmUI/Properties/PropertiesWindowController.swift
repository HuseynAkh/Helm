#if os(macOS)
import AppKit
import SwiftUI
import HelmCore
import HelmFileSystem

/// One Properties window's answers as they come: what Helm reads about the item, then what's inside the folders,
/// counted with running totals. It never downloads anything kept in a cloud. Closing the window stops the count.
/// For an item the person owns it also changes the permissions, through the browser window it came from.
@MainActor final class PropertiesSession: ObservableObject {
    @Published private(set) var model: PropertiesViewModel
    private let entries: [FileEntry]
    private let home: URL
    private var supplement = PropertiesSupplement()
    private var contents: FolderContentsCount?
    private var counting = false
    /// The details are read and the count, if any, has started.
    private var loaded = false
    private var task: Task<Void, Never>?
    /// What the last change to the permissions came to when it didn't simply happen, and the change under way.
    private var permissionMessage: String?
    private var change: Task<Void, Never>?
    /// Makes a change to the item's permissions, from the mode and identity read here to a new mode, in the browser
    /// window this came from, whose history keeps it for Undo. Answers what to say when it didn't simply happen.
    var changePermissions: (@MainActor (URL, FileObjectIdentity, UInt16, UInt16) async -> String?)?
    private var events: (broadcast: Broadcast<PermissionEvent>, token: Broadcast<PermissionEvent>.Token)?

    init(entries: [FileEntry], home: URL) {
        self.entries = entries; self.home = home
        model = PropertiesViewModel(entries: entries, home: home)
    }

    /// Reads the one item's details, which is quick, then starts the count. `opener` names the app that opens a file.
    func load(fileSystem: any FileSystem, opener: @MainActor (URL) -> String?) async {
        if entries.count == 1 {
            supplement = await PropertiesReader.read(entries[0])
            // An app or other package opens itself, so only a file names the app that opens it.
            if !entries[0].isDirectoryLike, entries[0].kind != .package { supplement.defaultApplication = opener(entries[0].url) }
        }
        let folders = entries.filter { $0.isDirectoryLike || $0.kind == .package }.map(\.url)
        counting = !folders.isEmpty
        loaded = true
        publish()
        guard counting else { return }
        let files = entries.filter { !$0.isDirectoryLike && $0.kind != .package }
        // Made inside `off`, so the count's own reads run with downloads off wherever the stream is read.
        let stream = await DatalessGuard.off { FolderCounter.count(folders: folders, files: files, in: fileSystem) }
        task = Task { [weak self] in
            for await progress in stream {
                guard let self else { return }
                // Several items count themselves too; one folder counts only what's inside it.
                self.contents = progress.count
                self.counting = !progress.finished
                self.publish()
            }
        }
    }
    func stop() {
        task?.cancel(); task = nil
        if let events { events.broadcast.cancel(events.token) }
        events = nil
    }
    /// Whether the details are read and the count has finished, or there was nothing to count.
    var isFinished: Bool { loaded && !counting }

    // MARK: Permissions

    /// Chooses `access` in `subject`'s pop-up. The change applies at once, as in Finder and Nautilus.
    func choose(_ access: FinderAccess, for subject: PermissionSubject) {
        guard let mode = model.mode(choosing: access, for: subject) else { return }
        changeMode(to: mode)
    }
    /// Turns "Allow executing file as program" on or off, at once.
    func allowExecuting(_ on: Bool) {
        guard let mode = model.mode(allowingExecution: on) else { return }
        changeMode(to: mode)
    }
    /// Changes the item's mode, unless it already has it, and reads the item again afterwards, whatever came of it,
    /// so the window shows what the disk now says. One change at a time: the controls wait while one is under way.
    @discardableResult func changeMode(to mode: UInt16) -> Task<Void, Never>? {
        guard model.permissionControlsEnabled, let target = supplement.permissionTarget, mode != target.mode,
              let item = entries.first?.url, let apply = changePermissions else { return nil }
        permissionMessage = nil
        let changeTask = Task { @MainActor [weak self] in
            let message = await apply(item, target.identity, target.mode, mode)
            guard let self else { return }
            self.permissionMessage = message
            await self.reread()
            self.change = nil
            self.publish()
        }
        change = changeTask
        publish()
        return changeTask
    }

    /// Reads the item again when its permissions change through Helm elsewhere, as an Undo in the browser window does,
    /// and shows what an Undo or Redo that was refused said.
    func follow(_ broadcast: Broadcast<PermissionEvent>) {
        let token = broadcast.subscribe { [weak self] event in self?.permissionsChanged(event) }
        events = (broadcast, token)
    }
    private func permissionsChanged(_ event: PermissionEvent) {
        // A change this window makes reads the item again itself.
        guard change == nil, entries.count == 1,
              event.item.standardizedFileURL.path == entries[0].url.standardizedFileURL.path else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.permissionMessage = event.message
            await self.reread()
            self.publish()
        }
    }
    private func reread() async {
        guard entries.count == 1 else { return }
        var fresh = await PropertiesReader.read(entries[0])
        fresh.defaultApplication = supplement.defaultApplication
        supplement = fresh
    }

    private func publish() {
        model = PropertiesViewModel(entries: entries, supplement: supplement, contents: contents, counting: counting, home: home,
                                    permissionMessage: permissionMessage, changingPermissions: change != nil)
    }
}

/// A Properties window, as Nautilus opens one for each item or selection: it stays beside the browser window,
/// several can be open, and Escape, Command-W or its close button closes it. Edit › Undo and Redo in it are the
/// browser window's, so a change to the permissions made here is undone with that window's other changes.
@MainActor final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    let session: PropertiesSession
    private let onClose: (PropertiesWindowController) -> Void

    init(session: PropertiesSession, icon: NSImage, browser: BrowserWindowController?, reveal: @escaping ([URL]) -> Void,
         onClose: @escaping (PropertiesWindowController) -> Void) {
        self.session = session; self.onClose = onClose
        let window = PropertiesWindow(contentRect: NSRect(x: 0, y: 0, width: PropertiesView.width, height: 620),
                                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.browser = browser
        window.title = session.model.windowTitle
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: PropertiesView.width, height: 320)
        window.contentMaxSize = NSSize(width: PropertiesView.width + 200, height: 2_000)
        super.init(window: window)
        let view = PropertiesView(session: session, icon: Image(nsImage: icon), reveal: reveal)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: PropertiesView.width, height: 620))
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        session.stop()
        onClose(self)
    }

    /// Command-W and Shift-Command-W arrive as Helm's commands; here they close this window.
    @objc func helmCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = CommandID(rawValue: raw) else { return }
        if command == .closeTab || command == .closeWindow { window?.performClose(nil) }
    }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(helmCommand(_:)) else { return true }
        let command = (item.representedObject as? String).flatMap(CommandID.init(rawValue:))
        return command == .closeTab || command == .closeWindow
    }
}

/// Escape closes it, as it closes Nautilus's. Edit › Undo and Redo go to the browser window it came from, whose
/// history holds the changes made here, and read as they read there: "Undo Change Permissions".
private final class PropertiesWindow: NSWindow {
    weak var browser: BrowserWindowController?
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
    // A window answers Undo and Redo with its own undo manager, which holds nothing here.
    @objc func undo(_ sender: Any?) { browser?.perform(.undo) }
    @objc func redo(_ sender: Any?) { browser?.perform(.redo) }
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)), #selector(redo(_:)):
            guard let browser else {
                item.title = item.action == #selector(undo(_:)) ? "Undo" : "Redo"
                return false
            }
            return browser.validateMenuItem(item)
        default:
            return super.validateMenuItem(item)
        }
    }
}
#endif
