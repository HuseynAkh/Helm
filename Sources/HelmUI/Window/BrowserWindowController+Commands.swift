#if os(macOS)
import AppKit
import HelmCore
import HelmFileSystem
import HelmOperations
import HelmPersistence
import SwiftUI

/// Commands: menus, keys and context menus all arrive here, by `CommandID`.
extension BrowserWindowController {
    @objc public func helmCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = CommandID(rawValue: raw) else { return }
        perform(command)
    }

    // Standard selectors, so a focused text field gets text semantics first (F-051).
    @objc public func cut(_ sender: Any?) { perform(.cut) }
    @objc public func copy(_ sender: Any?) { perform(.copy) }
    @objc public func paste(_ sender: Any?) { perform(.paste) }
    @objc public override func selectAll(_ sender: Any?) { perform(.selectAll) }
    @objc public func undo(_ sender: Any?) { perform(.undo) }
    @objc public func redo(_ sender: Any?) { perform(.redo) }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let command: CommandID?
        switch item.action {
        case #selector(cut(_:)): command = .cut
        case #selector(copy(_:)): command = .copy
        case #selector(paste(_:)): command = .paste
        case #selector(selectAll(_:)): command = .selectAll
        case #selector(undo(_:)): command = .undo
        case #selector(redo(_:)): command = .redo
        case #selector(helmCommand(_:)): command = (item.representedObject as? String).flatMap(CommandID.init(rawValue:))
        default: command = nil
        }
        guard let command else { return true }
        updateTitle(of: item, for: command)
        let state = CommandValidation.state(for: command, in: commandContext())
        item.isHidden = state == .hidden
        return state == .enabled
    }

    private func updateTitle(of item: NSMenuItem, for command: CommandID) {
        switch command {
        case .undo:
            if case .available(let name) = historyState.undoAvailability { item.title = "Undo \(name)" } else { item.title = "Undo" }
        case .redo:
            if case .unsupported(let name) = historyState.redoAvailability { item.title = "Redo \(name)" } else { item.title = "Redo" }
        case .hidden:
            item.state = (activeTab?.showHidden ?? false) ? .on : .off
        case .grid: item.state = activeTab?.viewMode == .grid ? .on : .off
        case .list: item.state = activeTab?.viewMode == .list ? .on : .off
        case .star:
            let starred = !selectedEntries().isEmpty && selectedEntries().allSatisfy { dependencies.stars.isStarred($0.url) }
            item.title = starred ? "Remove from Starred" : "Star"
        default: break
        }
    }

    func commandContext() -> CommandContext {
        let tab = activeTab
        let firstResponder = window?.firstResponder
        let textFocused = firstResponder is NSText || firstResponder is NSTextField
        let pasteboard = dependencies.pasteboard
        var clipboard: CommandClipboardState = .empty
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            clipboard = cutTransaction?.isValid(currentChangeCount: pasteboard.changeCount) == true ? .cutFiles : .files
        } else if pasteboard.string(forType: .string) != nil { clipboard = .text }
        var canUndo = false, canRedo = false
        if case .available = historyState.undoAvailability { canUndo = true }
        if case .unsupported = historyState.redoAvailability { canRedo = true }
        var canGoUp = false
        if let url = tab?.location.mutationTarget, url.standardizedFileURL.path != "/" { canGoUp = true }
        return CommandContext(selectionCount: tab?.selection.count ?? 0, hasMutationTarget: tab?.mutationTarget != nil,
                              locationKind: tab?.location.kind ?? .directory, clipboard: clipboard,
                              textFieldFocused: textFocused, searchOverlayActive: tab?.search != nil,
                              canUndo: canUndo, canRedo: canRedo, paneFocused: !textFocused, typeSelectActive: false,
                              hasWindow: true, canGoBack: !(tab?.history.back.isEmpty ?? true),
                              canGoForward: !(tab?.history.forward.isEmpty ?? true), canGoUp: canGoUp)
    }

    public func perform(_ command: CommandID) {
        guard let tab = activeTab else { return }
        let id = tab.id
        switch command {
        // Navigation
        case .back: store.send(.tab(id, .goBack))
        case .forward: store.send(.tab(id, .goForward))
        case .up:
            store.send(.tab(id, .goUp))
        case .home: navigate(to: .directory(dependencies.home), intent: .home)
        case .recents: navigate(to: .recent)
        case .desktop: navigate(to: .directory(dependencies.home.appendingPathComponent("Desktop")))
        case .documents: navigate(to: .directory(dependencies.home.appendingPathComponent("Documents")))
        case .downloads: navigate(to: .directory(dependencies.home.appendingPathComponent("Downloads")))
        case .applications: navigate(to: .directory(URL(fileURLWithPath: "/Applications")))
        case .utilities: navigate(to: .directory(URL(fileURLWithPath: "/Applications/Utilities")))
        case .location: store.send(.tab(id, .addressBar(.beginEditing)))
        case .connectToServer: connectToServerPrompt()
        // Views
        case .grid: store.send(.tab(id, .setViewMode(.grid))); rememberViewOptions(mode: .grid)
        case .list: store.send(.tab(id, .setViewMode(.list))); rememberViewOptions(mode: .list)
        case .hidden: store.send(.tab(id, .toggleHidden))
        case .refresh: store.send(.tab(id, .refresh))
        case .sidebar: toggleSidebar()
        case .find: beginSearch()
        // Windows and tabs
        case .newWindow: host?.openWindow(at: tab.location, selecting: [])
        case .newTab: newTab(at: tab.location)
        case .closeTab: closeCurrentTab()
        case .closeWindow: window?.performClose(nil)
        case .reopenClosedTab: if let location = closedTabs.popLast() { newTab(at: location) }
        case .nextTab: stepTab(by: 1)
        case .previousTab: stepTab(by: -1)
        case .minimize: window?.performMiniaturize(nil)
        case .zoom: window?.performZoom(nil)
        // Files
        case .open: open(selectedEntries(), newTab: false)
        case .openInNewTab:
            for entry in selectedEntries() where entry.isDirectoryLike { newTab(at: .directory(CanonicalPath.resolve(entry.url))) }
        case .openInNewWindow:
            for entry in selectedEntries() where entry.isDirectoryLike { host?.openWindow(at: .directory(CanonicalPath.resolve(entry.url)), selecting: []) }
        case .reveal: if let entry = selectedEntries().first { revealInCurrentTab(entry.url) }
        case .showOriginal: showOriginal()
        case .quickLook: toggleQuickLook()
        case .cut: cutSelection()
        case .copy: copySelection()
        case .paste: pasteHere()
        case .selectAll: selectAll()
        case .undo: runUndo()
        case .redo: runRedo()
        case .rename: beginRename()
        case .trash: trashSelection()
        case .duplicate: runForSelection { .duplicate(sources: $0) }
        case .putBack: putBackSelection()
        case .emptyTrash: emptyTrash()
        case .permanentDelete: deleteImmediately()
        case .clearRecent: dependencies.recents.clear(); store.send(.tab(id, .refresh))
        case .newFolder: createFolder()
        case .newFolderWithSelection: createFolderWithSelection()
        case .newFile, .newTextFile: createTextFile()
        case .newFromTemplate: createTextFile()
        case .makeAlias: makeLinks(alias: true)
        case .makeSymbolicLink: makeLinks(alias: false)
        case .copyPath: copyPaths(of: tab.location.mutationTarget.map { [$0] } ?? [])
        case .copyAsPathname: copyPaths(of: selectedEntries().map(\.url))
        case .star: toggleStar()
        case .properties: showProperties(for: selectedEntries())
        case .directoryProperties: showDirectoryProperties()
        case .addToSidebar: sidebarAddBookmarks(selectedEntries().map(\.url))
        case .removeBookmark: if let url = tab.location.mutationTarget { dependencies.bookmarks.remove(path: url.path) }
        case .eject:
            // The external volume holding this folder, if any. Internal disks can't be ejected.
            if let url = tab.location.mutationTarget, let volume = dependencies.volumes.volumes.first(where: {
                !$0.isInternal && (url.path == $0.url.path || url.path.hasPrefix($0.url.path + "/"))
            }) { dependencies.volumes.eject(volume.url) } else { NSSound.beep() }
        case .share: showSharePicker()
        case .openWith: showOpenWithMenu()
        // Application-level commands go to the app delegate through the menu itself.
        case .settings: host?.showSettings()
        case .about, .advancedOptions, .services, .hide, .hideOthers, .showAll, .quit, .bringAllToFront, .help: break
        case .moveItemsHere: moveItemsHere()
        case .printSelection, .columns, .gallery, .previewPane, .viewOptions,
             .computer, .network, .compress, .decompress, .tags: break
        }
    }

    // MARK: Navigation

    public func navigate(to location: Location, intent: NavigationIntent = .push) {
        store.send(.tab(activeTabID, .navigate(location, intent)))
    }
    public func newTab(at location: Location, selecting: [URL] = []) {
        var tab = TabState(location: location, homeDirectory: dependencies.home, settings: dependencies.settings.snapshot)
        if let current = activeTab {
            tab.viewMode = current.viewMode; tab.sort = current.sort; tab.showHidden = current.showHidden
        }
        store.send(.addTab(tab, activate: true))
        store.send(.tab(tab.id, .navigate(location, .restore)))
        if !selecting.isEmpty { select(Set(selecting.map { ItemID(url: $0) }), in: tab.id) }
    }
    func closeTab(_ id: TabID) {
        if let location = store.state.tabs[id]?.location { closedTabs.append(location) }
        if store.state.window.tabs.count == 1 { window?.performClose(nil); return }
        store.send(.window(.closeTab(id)))
    }
    func closeCurrentTab() {
        if let location = activeTab?.location, store.state.window.tabs.count > 1 { closedTabs.append(location) }
        store.send(.window(.closeCurrentTab))
    }
    private func stepTab(by delta: Int) {
        let tabs = store.state.window.tabs
        guard tabs.count > 1, let index = tabs.firstIndex(of: activeTabID) else { return }
        store.send(.window(.activate(tabs[(index + delta + tabs.count) % tabs.count])))
    }
    public func revealInCurrentTab(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        select([ItemID(url: url)], in: activeTabID)
        if activeTab?.location.mutationTarget?.standardizedFileURL.path == parent.standardizedFileURL.path {
            store.send(.tab(activeTabID, .refreshSelecting([ItemID(url: url)])))
        } else {
            navigate(to: .directory(parent))
        }
    }
    /// Typing a file's path reveals and selects it; nothing launches (Q9).
    func revealTypedFile(_ url: URL, in tab: TabID) { revealInCurrentTab(url) }

    /// A typed `smb://` address goes to macOS, the same way Finder's Connect to Server does.
    func connect(to url: URL) {
        shownContentFocus()
        if !NSWorkspace.shared.open(url) { pathBar.shake() }
    }
    private func shownContentFocus() { focusContent() }
    private func connectToServerPrompt() {
        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = "Enter the server address, for example smb://server/share."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "smb://"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if let url = TypedLocation.serverURL(from: field.stringValue) { self?.connect(to: url) }
            else { self?.show(message: "“\(field.stringValue)” isn’t a server address.") }
        }
    }

    // MARK: Opening

    func open(_ entries: [FileEntry], newTab forceTab: Bool) {
        guard !entries.isEmpty else { return }
        let folders = entries.filter { $0.isDirectoryLike || $0.kind == .directory }
        var files = entries.filter { !$0.isDirectoryLike }
        // Aliases resolve first, so an alias to a folder navigates like the folder would.
        var resolvedFolders = folders.map { CanonicalPath.resolve($0.url) }
        files = files.filter { entry in
            guard entry.kind == .alias, let target = try? URL(resolvingAliasFileAt: entry.url) else { return true }
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &directory), directory.boolValue {
                resolvedFolders.append(target); return false
            }
            return true
        }
        if resolvedFolders.count == 1, !forceTab, files.isEmpty {
            navigate(to: .directory(resolvedFolders[0]))
        } else {
            // Several folders become tabs, as in Nautilus.
            for folder in resolvedFolders { newTab(at: .directory(folder)) }
        }
        // Each file opens in its own default app: a picture and a document chosen together don't share one.
        var byApp: [URL: [FileEntry]] = [:]
        var unclaimed: [FileEntry] = []
        for entry in files {
            if let app = NSWorkspace.shared.urlForApplication(toOpen: entry.url) { byApp[app, default: []].append(entry) } else { unclaimed.append(entry) }
        }
        for (app, group) in byApp { open(group.map(\.url), with: app, entries: group) }
        // Nothing claims these, so the Open With chooser asks, as Finder does.
        if let first = unclaimed.first { showOpenWithChooser(for: first, makeDefault: false) }
    }
    private func showOriginal() {
        guard let entry = selectedEntries().first else { return }
        let target: URL?
        switch entry.kind {
        case .alias: target = try? URL(resolvingAliasFileAt: entry.url)
        case .symlinkToDirectory, .symlinkToFile: target = CanonicalPath.resolve(entry.url)
        default: target = nil
        }
        if let target { revealInCurrentTab(target) } else { NSSound.beep() }
    }

    // MARK: Selection

    private func selectAll() {
        guard let tab = activeTab else { return }
        let ids = Set(tab.snapshot.sortedEntries.prefix(tab.snapshot.rootCount).map(\.id))
        store.send(.tab(tab.id, .setSelection(ids, source: .user)))
    }

    /// Keys a view gets first. Return renames and Space previews, as Finder and the legacy Helm both do.
    func handleContentKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case 36, 76: // Return, Enter
            if flags.isEmpty { perform(.rename); return true }
            return false
        case 120: // F2, the Nautilus rename key
            if flags.isEmpty { perform(.rename); return true }
            return false
        case 49: // Space
            if flags.isEmpty { perform(.quickLook); return true }
            return false
        case 125: // Down
            if flags == [.command] { perform(.open); return true }
            return false
        case 53: // Escape
            if activeTab?.search != nil { store.send(.tab(activeTabID, .searchEnded)); return true }
            if let tab = activeTab, !tab.cutIDs.isEmpty { clearCut(); return true }
            return false
        default: return false
        }
    }

    // MARK: Clipboard

    private func writeToPasteboard(_ urls: [URL]) -> Int {
        let pasteboard = dependencies.pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        return pasteboard.changeCount
    }
    private func copySelection() {
        let urls = selectedEntries().map(\.url)
        guard !urls.isEmpty else { return }
        cutTransaction = nil
        _ = writeToPasteboard(urls)
        clearCut()
    }
    private func cutSelection() {
        let entries = selectedEntries()
        guard !entries.isEmpty else { return }
        let count = writeToPasteboard(entries.map(\.url))
        cutTransaction = ClipboardTransaction(mode: .cut, sources: entries.map(\.url), changeCount: count)
        store.send(.tab(activeTabID, .cutSetChanged(Set(entries.map(\.id)))))
    }
    func clearCut() {
        cutTransaction = nil
        store.send(.tab(activeTabID, .cutSetChanged([])))
    }
    private func pasteHere() {
        guard let target = activeTab?.mutationTarget else { NSSound.beep(); return }
        let pasteboard = dependencies.pasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            NSSound.beep(); return
        }
        if let cut = cutTransaction, cut.isValid(currentChangeCount: pasteboard.changeCount) {
            let sources = cut.sources
            run(.move(sources: sources, destinationDirectory: target)) { [weak self] result in
                self?.clearCut()
                if result.error == nil, let self { self.dependencies.pasteboard.clearContents() }
            }
        } else {
            run(.copy(sources: urls, destinationDirectory: target))
        }
    }
    /// Finder's Option+Command+V: moves whatever is on the pasteboard, however it got there.
    private func moveItemsHere() {
        guard let target = activeTab?.mutationTarget,
              let urls = dependencies.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            NSSound.beep(); return
        }
        run(.move(sources: urls, destinationDirectory: target)) { [weak self] result in
            self?.clearCut()
            if result.error == nil, let self { self.dependencies.pasteboard.clearContents() }
        }
    }
    private func copyPaths(of urls: [URL]) {
        guard !urls.isEmpty else { return }
        dependencies.pasteboard.clearContents()
        dependencies.pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    // MARK: Running operations

    /// Runs a command, reports what went wrong and refreshes what it touched.
    public func run(_ command: Command, afterSelecting explicit: Set<ItemID>? = nil, completion: ((OperationResult) -> Void)? = nil) {
        let scope = OperationCoordinator.scope(of: command)
        let resolver = conflictResolver()
        let operations = dependencies.operations, history = history
        Task { @MainActor [weak self] in
            let outcome = await operations.run(command, sources: scope.sources, destinations: scope.destinations, history: history, resolver: resolver)
            await self?.refreshHistory()
            self?.handle(outcome, explicit: explicit, completion: completion)
        }
    }
    private func conflictResolver() -> OperationCoordinator.ConflictResolver? {
        guard dependencies.settings.snapshot.bool(.askOnConflict) else { return nil }
        return { [weak self] (conflicts: [Conflict]) async -> ConflictPolicy? in
            guard let self else { return nil }
            return await self.resolve(conflicts)
        }
    }
    private func handle(_ outcome: Result<OperationResult, OperationCoordinator.Failure>, explicit: Set<ItemID>?, completion: ((OperationResult) -> Void)?) {
        switch outcome {
        case .failure(.cancelled): return
        case .failure(.busy): NSSound.beep()
        case .failure(.message(let message)): show(message: message)
        case .success(let result):
            completion?(result)
            if let error = result.error, error != .cancelled {
                show(message: OperationRowModel.message(for: error))
            }
            let outputs = Set(result.outcomes.filter { $0.succeeded && $0.step.kind != .trash && $0.step.kind != .verifyCopy }.compactMap(\.destination).map { ItemID(url: $0) })
            refreshTabs(touching: result.affectedDirectories, selecting: explicit ?? outputs)
        }
    }
    private func refreshTabs(touching directories: Set<URL>, selecting ids: Set<ItemID>) {
        let paths = Set(directories.map { $0.standardizedFileURL.path })
        for (id, tab) in store.state.tabs {
            guard let url = tab.location.mutationTarget, paths.contains(url.standardizedFileURL.path) || id == activeTabID else { continue }
            store.send(.tab(id, id == activeTabID && !ids.isEmpty ? .refreshSelecting(ids) : .refresh))
        }
    }
    private func runForSelection(_ make: ([URL]) -> Command) {
        let urls = selectedEntries().map(\.url)
        guard !urls.isEmpty else { return }
        run(make(urls))
    }
    private func runUndo() {
        let operations = dependencies.operations, history = history
        Task { @MainActor [weak self] in
            let outcome = await operations.undo(history: history)
            await self?.refreshHistory()
            self?.handle(outcome, explicit: nil, completion: nil)
        }
    }
    private func runRedo() {
        let resolver = conflictResolver()
        let operations = dependencies.operations, history = history
        Task { @MainActor [weak self] in
            let outcome = await operations.redo(history: history, resolver: resolver)
            await self?.refreshHistory()
            self?.handle(outcome, explicit: nil, completion: nil)
        }
    }
    private func trashSelection() {
        guard let tab = activeTab else { return }
        let urls = selectedEntries().map(\.url)
        guard !urls.isEmpty else { return }
        // The next item takes the selection, or the previous one at the end (architecture 14.5).
        let order = tab.snapshot.sortedEntries.prefix(tab.snapshot.rootCount).map(\.id)
        let chosen = Set(urls.map { ItemID(url: $0) })
        var next: Set<ItemID> = []
        if let last = order.lastIndex(where: { chosen.contains($0) }) {
            if let after = order[(last + 1)...].first(where: { !chosen.contains($0) }) { next = [after] }
            else if let before = order[..<last].last(where: { !chosen.contains($0) }) { next = [before] }
        }
        // Off by default, because undo is the safety net (Q10). A stored choice to confirm is honoured.
        guard dependencies.settings.snapshot.bool(.confirmBeforeTrash), !confirmsForTesting, let window else {
            run(.trash(items: urls), afterSelecting: next)
            return
        }
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to the Trash?" : "Move \(urls.count) items to the Trash?"
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.run(.trash(items: urls), afterSelecting: next) }
        }
    }
    /// Dropping onto the sidebar's Trash.
    func trash(_ urls: [URL]) { run(.trash(items: urls)) }
    private func putBackSelection() {
        let entries = selectedEntries()
        guard !entries.isEmpty else { return }
        let origins = dependencies.trashOrigins
        Task { @MainActor in
            var groups: [URL: [URL]] = [:]
            var unknown: [String] = []
            for entry in entries {
                if let original = await origins.originalURL(forTrashed: entry.url) {
                    groups[original.deletingLastPathComponent(), default: []].append(entry.url)
                } else { unknown.append(entry.name) }
            }
            if !unknown.isEmpty {
                show(message: "Helm didn’t move “\(unknown[0])” to the Trash, so it doesn’t know where it came from.")
            }
            for (directory, urls) in groups { run(.move(sources: urls, destinationDirectory: directory)) }
        }
    }
    private func emptyTrashConfirmed(completion: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Empty Trash"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if confirmsForTesting { completion(); return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion() }
        }
    }
    func emptyTrash() {
        emptyTrashConfirmed { [weak self] in
            guard let self else { return }
            let fileSystem = self.dependencies.fileSystem
            let uid = String(getuid())
            let others = self.dependencies.volumes.volumes.filter { !$0.isInternal }.map { $0.url.appendingPathComponent(".Trashes/\(uid)") }
            Task { @MainActor in
                for trash in [self.dependencies.home.appendingPathComponent(".Trash")] + others {
                    do {
                        let names = try await fileSystem.childNames(of: trash)
                        for name in names { try await fileSystem.removeItem(at: trash.appendingPathComponent(name)) }
                    } catch FileSystemError.notFound {
                        continue // That volume has no Trash yet.
                    } catch { self.show(message: OperationText.describe(error)) }
                }
                self.store.send(.tab(self.activeTabID, .refresh))
            }
        }
    }
    private func deleteImmediately() {
        let urls = selectedEntries().map(\.url)
        guard !urls.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Delete “\(urls[0].lastPathComponent)” immediately?" : "Delete \(urls.count) items immediately?"
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let fileSystem = self.dependencies.fileSystem
            Task { @MainActor in
                do { for url in urls { try await fileSystem.removeItem(at: url) } }
                catch { self.show(message: OperationText.describe(error)) }
                self.store.send(.tab(self.activeTabID, .refresh))
            }
        }
        if confirmsForTesting { proceed(.alertFirstButtonReturn) } else { alert.beginSheetModal(for: window, completionHandler: proceed) }
    }

    // MARK: Creating

    private func createFolder() {
        guard let parent = activeTab?.mutationTarget, let name = ValidFileName("untitled folder") else { return }
        run(.createFolder(parent: parent, name: name)) { [weak self] result in
            if let output = result.outcomes.first(where: \.succeeded)?.destination { self?.expectRename(of: ItemID(url: output)) }
        }
    }
    private func createFolderWithSelection() {
        guard let parent = activeTab?.mutationTarget, let name = ValidFileName("New Folder With Items") else { return }
        let sources = selectedEntries().map(\.url)
        guard !sources.isEmpty else { return }
        run(.createFolder(parent: parent, name: name)) { [weak self] result in
            guard let self, let output = result.outcomes.first(where: \.succeeded)?.destination else { return }
            self.run(.move(sources: sources, destinationDirectory: output)) { [weak self] _ in
                self?.select([ItemID(url: output)], in: self?.activeTabID ?? TabID())
                self?.expectRename(of: ItemID(url: output))
            }
        }
    }
    private func createTextFile() {
        guard let parent = activeTab?.mutationTarget, let name = ValidFileName("Untitled.txt") else { return }
        run(.createFile(parent: parent, name: name, template: nil)) { [weak self] result in
            if let output = result.outcomes.first(where: \.succeeded)?.destination { self?.expectRename(of: ItemID(url: output)) }
        }
    }
    func createFile(from template: URL) {
        guard let parent = activeTab?.mutationTarget, let name = ValidFileName(template.lastPathComponent) else { return }
        run(.createFile(parent: parent, name: name, template: template)) { [weak self] result in
            if let output = result.outcomes.first(where: \.succeeded)?.destination { self?.expectRename(of: ItemID(url: output)) }
        }
    }
    private func makeLinks(alias: Bool) {
        let entries = selectedEntries()
        guard !entries.isEmpty else { return }
        let fileSystem = dependencies.fileSystem
        Task { @MainActor in
            var made: Set<ItemID> = []
            for entry in entries {
                let parent = entry.url.deletingLastPathComponent()
                let suffix = alias ? " alias" : " link"
                do {
                    let names = try await fileSystem.childNames(of: parent)
                    let name = try UniqueNamer.name(for: entry.name + suffix, existingNames: names)
                    let target = parent.appendingPathComponent(name.value)
                    if alias { try await fileSystem.createAlias(for: entry.url, at: target) }
                    else { try await fileSystem.createSymbolicLink(at: target, destination: entry.url) }
                    made.insert(ItemID(url: target))
                } catch { show(message: OperationText.describe(error)) }
            }
            store.send(.tab(activeTabID, .refreshSelecting(made)))
        }
    }

    // MARK: Renaming

    func beginRename() {
        let entries = selectedEntries()
        if entries.count > 1 { showBatchRename(entries); return }
        guard let entry = entries.first else { return }
        store.send(.tab(activeTabID, .beginInlineRename(entry.id)))
        shownRename(entry)
    }
    public func commitRename(_ entry: FileEntry, to raw: String) {
        switch FileNameValidator.validate(raw) {
        case .failure(let error):
            NSSound.beep()
            show(message: NewItemNameValidation.message(for: error))
        case .success(let name):
            let target = ItemID(url: entry.url.deletingLastPathComponent().appendingPathComponent(name.value))
            run(.rename(RenamePair(source: entry.url, newName: name)), afterSelecting: [target])
        }
    }
    private func showBatchRename(_ entries: [FileEntry]) {
        guard let window else { return }
        let parents = Set(entries.map { $0.url.deletingLastPathComponent() })
        let fileSystem = dependencies.fileSystem
        Task { @MainActor in
            var names: [URL: Set<String>] = [:]
            for parent in parents {
                let children = try? await fileSystem.childNames(of: parent)
                names[parent] = children ?? []
            }
            let model = BatchRenameViewModel(items: entries.map(\.url), existingNames: names, caseSensitive: false,
                                             date: dependencies.clock.now(), timeZone: .current)
            let host = BatchRenameHost(model: model)
            let sheet = NSWindow(contentViewController: NSHostingController(rootView: host.view { [weak self, weak window] plan in
                if let attached = window?.attachedSheet { window?.endSheet(attached) }
                if let plan, plan.canExecute { self?.run(.batchRename(plan.renames)) }
            }))
            window.beginSheet(sheet, completionHandler: nil)
        }
    }

    // MARK: Stars

    private func toggleStar() {
        let urls = selectedEntries().map(\.url)
        guard !urls.isEmpty else { return }
        let allStarred = urls.allSatisfy { dependencies.stars.isStarred($0) }
        for url in urls {
            if allStarred { dependencies.stars.unstar(url) } else { dependencies.stars.star(url, at: dependencies.clock.now()) }
        }
    }

    // MARK: Conflicts

    private func resolve(_ conflicts: [Conflict]) async -> ConflictPolicy? {
        var perItem: [URL: ConflictResolution] = [:]
        for conflict in conflicts {
            guard let source = conflict.source else { continue }
            let (resolution, applyToAll) = await ask(conflict)
            if resolution == .stop { return nil }
            if applyToAll { return ConflictPolicy(defaultResolution: resolution, perItem: perItem, applyToAll: perItem.isEmpty) }
            perItem[source] = resolution
        }
        return ConflictPolicy(defaultResolution: .keepBoth, perItem: perItem, applyToAll: false)
    }
    private func ask(_ conflict: Conflict) async -> (ConflictResolution, Bool) {
        await withCheckedContinuation { continuation in
            guard let window else { continuation.resume(returning: (.stop, false)); return }
            let host = ConflictHost(conflict: conflict) { [weak window] resolution, all in
                if let attached = window?.attachedSheet { window?.endSheet(attached) }
                continuation.resume(returning: (resolution, all))
            }
            let sheet = NSWindow(contentViewController: NSHostingController(rootView: host))
            window.beginSheet(sheet, completionHandler: nil)
            if let choice = conflictChoiceForTesting {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { host.choose(choice, false) }
            }
        }
    }

    // Drag and drop lives in BrowserWindowController+Drops.swift.

    // MARK: Context menus

    func contextMenu(for entries: [FileEntry]) -> NSMenu? {
        guard let tab = activeTab else { return nil }
        let kind: CommandMenuContext
        switch (tab.location, entries.count) {
        case (.trash, _): kind = .trash
        case (.recent, _): kind = .recent
        case (_, 0): kind = .background
        case (_, 1): kind = entries[0].isDirectoryLike ? .folder : .file
        default: kind = .multiple
        }
        let starred = !entries.isEmpty && entries.allSatisfy { dependencies.stars.isStarred($0.url) }
        let model = ContextMenuModel.menu(for: kind, selectionCount: entries.count, isStarred: starred)
        let menu = NSMenu()
        for (index, section) in model.sections.enumerated() where !section.isEmpty {
            if index > 0, !menu.items.isEmpty { menu.addItem(.separator()) }
            for row in section {
                let item = commandItem(row.title, row.command)
                switch row.command {
                case .openWith: item.submenu = openWithMenu(for: entries); item.action = nil
                case .share: item.submenu = shareMenu(for: entries); item.action = nil
                case .newFile: item.submenu = newFileMenu(); item.action = nil
                default: break
                }
                menu.addItem(item)
            }
        }
        if entries.count == 1, entries[0].kind == .package {
            let target = ClosureMenuTarget { [weak self] in self?.navigate(to: .directory(entries[0].url)) }
            let item = NSMenuItem(title: "Show Package Contents", action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = target
            menu.insertItem(item, at: min(2, menu.items.count))
        }
        return menu
    }
    /// View › Sort By in the menu bar: the fields, where choosing the current one reverses it, then its two directions in words.
    public func fillSortItems(in menu: NSMenu) {
        let current = activeTab?.sort ?? .defaultSort
        if activeTab?.search != nil {
            let best = closureItem(SortChoice.bestMatch.title) { [weak self] in self?.pressSort(.relevance) }
            best.state = current.field == .relevance ? .on : .off
            menu.addItem(best)
        }
        for field in SortField.all {
            let item = closureItem(field.title) { [weak self] in self?.pressSort(field.field) }
            item.state = current.field == field.field ? .on : .off
            if current.field == field.field { item.toolTip = "Choose again to reverse" }
            menu.addItem(item)
        }
        if current.field != .relevance, let field = SortField.all.first(where: { $0.field == current.field }) {
            menu.addItem(.separator())
            for ascending in [field.startsAscending, !field.startsAscending] {
                let item = closureItem(SortField.direction(field.field, ascending: ascending)) { [weak self] in
                    guard let self, let tab = self.activeTab else { return }
                    self.contentSetSort(ItemSort(field: tab.sort.field, ascending: ascending, directoriesFirst: tab.sort.directoriesFirst))
                }
                item.state = current.ascending == ascending ? .on : .off
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let folders = closureItem("Keep Folders on Top") { [weak self] in self?.toggleFoldersFirst() }
        folders.state = current.directoriesFirst ? .on : .off
        menu.addItem(folders)
    }
    /// Pressing the current sort again reverses it, as clicking a column heading does.
    public func pressSort(_ field: ItemSort.Field) {
        guard let tab = activeTab else { return }
        contentSetSort(SortField.pressing(field, on: tab.sort))
    }
    func toggleFoldersFirst() {
        guard let tab = activeTab else { return }
        contentSetSort(ItemSort(field: tab.sort.field, ascending: tab.sort.ascending, directoriesFirst: !tab.sort.directoriesFirst))
    }
    private func closureItem(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureMenuTarget(action)
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
        item.target = target; item.representedObject = target
        return item
    }
    /// Cmd+Plus and Cmd+Minus scale what's in the folder, as Ctrl+Plus and Ctrl+Minus do in Nautilus.
    @objc public func zoomIn(_ sender: Any?) { stepText(by: 1); stepIcons(by: 1) }
    @objc public func zoomOut(_ sender: Any?) { stepText(by: -1); stepIcons(by: -1) }
    @objc public func resetSizes(_ sender: Any?) { resetText(); resetIcons() }
    public func resetText() { dependencies.settings.set(SettingsSchema.defaultValue(for: .fileTextSize), for: .fileTextSize) }
    public func resetIcons() { dependencies.settings.set(SettingsSchema.defaultValue(for: .gridIconSize), for: .gridIconSize) }
    /// Text moves in steps of 10%, from 80% to 170%.
    public func stepText(by steps: Int) {
        let points = dependencies.settings.snapshot.double(.fileTextSize)
        dependencies.settings.set(.double(ContentZoom.steppedText(points, by: steps)), for: .fileTextSize)
    }
    public func stepIcons(by steps: Int) {
        let pixels = dependencies.settings.snapshot.double(.gridIconSize)
        dependencies.settings.set(.double(ContentZoom.steppedIcons(pixels, by: steps)), for: .gridIconSize)
    }
    public var textPercent: Int { ContentZoom.textPercent(dependencies.settings.snapshot.double(.fileTextSize)) }
    // Open With lives in BrowserWindowController+OpenWith.swift.
    private func showSharePicker() {
        let urls = selectedEntries().map(\.url)
        guard !urls.isEmpty, let view = window?.contentView else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
    private func shareMenu(for entries: [FileEntry]) -> NSMenu {
        let menu = NSMenu()
        let urls = entries.map(\.url)
        for service in NSSharingService.sharingServices(forItems: urls) {
            let target = ClosureMenuTarget { service.perform(withItems: urls) }
            let item = NSMenuItem(title: service.title, action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = target; item.image = service.image
            menu.addItem(item)
        }
        return menu
    }
    private func newFileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(commandItem(ContextMenuModel.newFileFallback.title, .newTextFile))
        let templates = dependencies.home.appendingPathComponent("Templates")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: templates.path) {
            let visible = names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if !visible.isEmpty { menu.addItem(.separator()) }
            for name in visible {
                let url = templates.appendingPathComponent(name)
                let target = ClosureMenuTarget { [weak self] in self?.createFile(from: url) }
                let item = NSMenuItem(title: name, action: #selector(ClosureMenuTarget.run(_:)), keyEquivalent: "")
                item.target = target; item.representedObject = target
                menu.addItem(item)
            }
        }
        return menu
    }

    // MARK: Properties

    private func showDirectoryProperties() {
        guard let url = activeTab?.mutationTarget else { return }
        let fileSystem = dependencies.fileSystem
        Task { @MainActor in
            if let entry = try? await fileSystem.entry(at: url) { showProperties(for: [entry]) }
        }
    }
    func showProperties(for entries: [FileEntry]) {
        guard !entries.isEmpty, let window else { return }
        let icon = NSWorkspace.shared.icon(forFile: entries[0].url.path)
        let model = PropertiesViewModel(entries: entries)
        let view = PropertiesView(model: model, icon: { _ in Image(nsImage: icon) },
            reveal: { [weak self] urls in if let url = urls.first { self?.revealInCurrentTab(url) } },
            dismiss: { [weak window] in if let attached = window?.attachedSheet { window?.endSheet(attached) } })
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.beginSheet(sheet, completionHandler: nil)
    }

    // MARK: Test support

    public func refreshHistoryForTesting() async { await refreshHistory() }
    public func emptyTrashForTesting() { emptyTrash() }
    public var isSearchingForTesting: Bool { header.isSearching }
    public func chooseSortForTesting(_ title: String) {
        guard let tab = activeTab, let choice = SortChoice.all.first(where: { $0.title == title }) else { return }
        contentSetSort(choice.applied(to: tab.sort))
    }
    public func pathSegmentsForTesting() -> [String] {
        guard let tab = activeTab else { return [] }
        return PathBarView.segments(for: tab.location, home: dependencies.home).map(\.title)
    }
    public var sidebarDriveNamesForTesting: [String] {
        dependencies.volumes.volumes.map(\.name)
    }
    public var hasSheetForTesting: Bool { window?.attachedSheet != nil }
    public func dismissSheetForTesting() { if let sheet = window?.attachedSheet { window?.endSheet(sheet) } }
    public func title(of command: CommandID) -> (String, Bool) {
        let item = commandItem(command.rawValue, command)
        let enabled = validateMenuItem(item)
        return (item.title, enabled)
    }
    public func typeIntoRenameFieldForTesting(_ text: String, cancel: Bool) {
        guard let editor = window?.firstResponder as? NSTextView else { return }
        editor.string = text
        editor.didChangeText()
        if cancel { editor.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        else { window?.makeFirstResponder(window?.contentView) }
    }
    public var isRenamingForTesting: Bool { window?.firstResponder is NSTextView }
    public func dropForTesting(_ urls: [URL], into url: URL) -> Bool { acceptDrop(urls, into: url) }
    public func sidebarDropForTesting(_ urls: [URL]) { sidebarAddBookmarks(urls) }
    public var undoTitleForTesting: String {
        if case .available(let name) = historyState.undoAvailability { return name }
        return ""
    }

    // MARK: Messages

    public func show(message: String) {
        if let messageObserver { messageObserver(message); return }
        guard let window, !message.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}

private struct ConflictHost: View {
    let conflict: Conflict
    let choose: (ConflictResolution, Bool) -> Void
    @State private var applyToAll = false
    var body: some View {
        ConflictSheet(conflict: conflict, applyToAll: $applyToAll, choose: choose)
    }
}

@MainActor private final class BatchRenameHost {
    private let initial: BatchRenameViewModel
    init(model: BatchRenameViewModel) { initial = model }
    func view(done: @escaping (BatchRenamePlan?) -> Void) -> some View {
        BatchRenameHostView(model: initial, done: done)
    }
}
private struct BatchRenameHostView: View {
    @State var model: BatchRenameViewModel
    let done: (BatchRenamePlan?) -> Void
    var body: some View {
        BatchRenameSheet(model: $model, rename: { done($0) }, cancel: { done(nil) })
    }
}
#endif
