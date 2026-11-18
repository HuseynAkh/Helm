#if os(macOS)
import AppKit
import SwiftUI
import HelmCore
import HelmFileSystem

/// One Properties window's answers as they come: what Helm reads about the item, then what's inside the folders,
/// counted with running totals. It never downloads anything kept in a cloud. Closing the window stops the count.
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
    func stop() { task?.cancel(); task = nil }
    /// Whether the details are read and the count has finished, or there was nothing to count.
    var isFinished: Bool { loaded && !counting }

    private func publish() {
        model = PropertiesViewModel(entries: entries, supplement: supplement, contents: contents, counting: counting, home: home)
    }
}

/// A Properties window, as Nautilus opens one for each item or selection: it stays beside the browser window,
/// several can be open, and Escape, Command-W or its close button closes it.
@MainActor final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    let session: PropertiesSession
    private let onClose: (PropertiesWindowController) -> Void

    init(session: PropertiesSession, icon: NSImage, reveal: @escaping ([URL]) -> Void,
         onClose: @escaping (PropertiesWindowController) -> Void) {
        self.session = session; self.onClose = onClose
        let window = PropertiesWindow(contentRect: NSRect(x: 0, y: 0, width: PropertiesView.width, height: 620),
                                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
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

/// Escape closes it, as it closes Nautilus's.
private final class PropertiesWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}
#endif
