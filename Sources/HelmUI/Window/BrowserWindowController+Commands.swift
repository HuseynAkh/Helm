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
    /// New File › a template from ~/Templates.
    @objc func newFromTemplate(_ sender: NSMenuItem) {
        if let template = sender.representedObject as? URL { createFile(from: template) }
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
        case #selector(newFromTemplate(_:)): command = .newFromTemplate
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
        // While this window's work is under way, what Undo and Redo would act on is still changing: they read plainly and are off.
        case .undo:
            if case .available(let name) = historyState.undoAvailability, !isRunningOperations { item.title = "Undo \(name)" } else { item.title = "Undo" }
        case .redo:
            if case .unsupported(let name) = historyState.redoAvailability, !isRunningOperations { item.title = "Redo \(name)" } else { item.title = "Redo" }
        case .hidden:
            item.state = (activeTab?.showHidden ?? false) ? .on : .off
        case .grid: item.state = activeTab?.viewMode == .grid ? .on : .off
        case .list: item.state = activeTab?.viewMode == .list ? .on : .off
        case .star:
            let starred = !selectedEntries().isEmpty && selectedEntries().allSatisfy { dependencies.stars.isStarred($0.url) }
            item.title = starred ? "Remove from Starred" : "Star"
        case .compress: item.title = compressTitle()
        default: break
        }
    }

    func commandContext() -> CommandContext {
        let tab = activeTab
        let firstResponder = window?.firstResponder
        let textFocused = firstResponder is NSText || firstResponder is NSTextField
        let pasteboard = dependencies.pasteboard
        var clipboard: CommandClipboardState = .empty
        // Only what kind of thing is on the clipboard, never what it says: that's read when you paste.
        if pasteboard.availableType(from: [.fileURL]) != nil {
            clipboard = cutTransaction?.isValid(currentChangeCount: pasteboard.changeCount) == true ? .cutFiles : .files
        } else if pasteboard.availableType(from: [.string]) != nil { clipboard = .text }
        var canUndo = false, canRedo = false
        if case .available = historyState.undoAvailability, !isRunningOperations { canUndo = true }
        if case .unsupported = historyState.redoAvailability, !isRunningOperations { canRedo = true }
        var canGoUp = false
        if let url = tab?.location.mutationTarget, url.standardizedFileURL.path != "/" { canGoUp = true }
        var context = CommandContext(selectionCount: tab?.selection.count ?? 0, hasMutationTarget: tab?.mutationTarget != nil,
                              locationKind: tab?.location.kind ?? .directory, clipboard: clipboard,
                              textFieldFocused: textFocused, searchOverlayActive: tab?.search != nil,
                              canUndo: canUndo, canRedo: canRedo, paneFocused: !textFocused, typeSelectActive: false,
                              hasWindow: true, canGoBack: !(tab?.history.back.isEmpty ?? true),
                              canGoForward: !(tab?.history.forward.isEmpty ?? true), canGoUp: canGoUp)
        applyContentState(to: &context)
        return context
    }

    public func perform(_ command: CommandID) {
        guard let tab = activeTab else { return }
        let id = tab.id
        switch command {
        // Navigation
        case .back: if !returnFromFailedPlace() { store.send(.tab(id, .goBack)) }
        case .forward: store.send(.tab(id, .goForward))
        case .up:
            if !goUpFromFailedPlace() { store.send(.tab(id, .goUp)) }
        case .home: navigate(to: .directory(dependencies.home), intent: .home)
        case .recents: navigate(to: .recent)
        case .desktop: navigate(to: .directory(dependencies.home.appendingPathComponent("Desktop")))
        case .documents: navigate(to: .directory(dependencies.home.appendingPathComponent("Documents")))
        case .downloads: navigate(to: .directory(dependencies.home.appendingPathComponent("Downloads")))
        case .applications: navigate(to: .directory(URL(fileURLWithPath: "/Applications")))
        // Since macOS 10.15 Apple's utilities, such as Terminal and Disk Utility, live here; /Applications/Utilities
        // holds only those other installers put there.
        case .utilities: navigate(to: .directory(URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)))
        case .goToTrash: navigate(to: .trash)
        case .location: store.send(.tab(id, .addressBar(.beginEditing)))
        case .connectToServer: connectToServerPrompt()
        // Views
        case .grid: store.send(.tab(id, .setViewMode(.grid))); rememberViewOptions(mode: .grid)
        case .list: store.send(.tab(id, .setViewMode(.list))); rememberViewOptions(mode: .list)
        case .hidden: store.send(.tab(id, .toggleHidden))
        case .refresh: refreshPlaceOnShow()
        case .sidebar: toggleSidebar()
        case .find: beginSearch()
        // Windows and tabs
        case .newWindow: host?.openWindow(at: newWindowLocation, selecting: [])
        // The place on show, which while a card is up is the place it's about, not the folder hidden under it.
        case .newTab: newTab(at: Self.placeOnShow(tab))
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
        // Recent lists itself again as the record changes (recentsChanged). The apps you've used go too.
        case .clearRecent: dependencies.forgetRecentItems()
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
        case .compress: compressSelection()
        case .decompress: expandSelection()
        case .viewOptions: header.showViewOptions()
        // Every mounted disk, as Finder's Computer shows them.
        case .computer: navigate(to: .directory(URL(fileURLWithPath: "/Volumes", isDirectory: true)))
        case .printSelection, .columns, .gallery, .previewPane, .network, .tags: break
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
        // A new tab starts its own history, and the folder it opens at goes into Recent like any folder you visit.
        store.send(.tab(tab.id, .navigate(location, .open)))
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
    /// Where File › New Window opens, from Settings › General (P-017). Virtual places such as Recent
    /// stay as they are when the setting follows the front window. The front window's place is the one on show:
    /// while a card is up, the place it's about.
    public var newWindowLocation: Location {
        let choice = NewWindowLocation(rawValue: dependencies.settings.snapshot.string(.newWindowLocation)) ?? .current
        let current = activeTab.map(Self.placeOnShow)
        if choice == .current, let current { return current }
        return .directory(choice.folder(current: current?.mutationTarget, home: dependencies.home))
    }

    /// Shows a folder, with some of its items selected: how other apps' "Show in Finder" and Services arrive.
    public func show(folder: URL, selecting items: [URL]) {
        leaveSearch()
        guard !items.isEmpty else { navigate(to: .directory(folder)); return }
        listHiddenItems(items)
        let ids = Set(items.map { ItemID(url: $0) })
        select(ids, in: activeTabID)
        if let here = activeTab?.location.mutationTarget, Self.isSame(here, folder) {
            showOwnFolder(of: activeTabID, reloading: .refreshSelecting(ids))
        } else {
            navigate(to: .directory(folder))
        }
    }

    public func revealInCurrentTab(_ url: URL) {
        leaveSearch()
        let parent = url.deletingLastPathComponent()
        listHiddenItems([url])
        select([ItemID(url: url)], in: activeTabID)
        if activeTab?.location.mutationTarget?.standardizedFileURL.path == parent.standardizedFileURL.path {
            showOwnFolder(of: activeTabID, reloading: .refreshSelecting([ItemID(url: url)]))
        } else {
            navigate(to: .directory(parent))
        }
    }
    /// Typing a file's path reveals and selects it; nothing launches (Q9).
    func revealTypedFile(_ url: URL, in tab: TabID) { revealInCurrentTab(url) }
    /// An item asked for by name is shown and selected even when it's hidden, as Finder's reveal does: the tab lists
    /// hidden items, as View › Show Hidden Files would, but only this tab and without changing the setting.
    private func listHiddenItems(_ items: [URL]) {
        guard let tab = activeTab, !tab.showHidden, items.contains(where: Self.isHiddenItem) else { return }
        store.send(.tab(tab.id, .showHiddenItems))
    }
    /// A name starting with a dot, or an item macOS marks hidden, such as ~/Library: what hidden files leave out.
    static func isHiddenItem(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(".") || (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
    }

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
            if let app = dependencies.launcher.defaultApplication(toOpen: entry.url) { byApp[app, default: []].append(entry) } else { unclaimed.append(entry) }
        }
        for (app, group) in byApp { open(group.map(\.url), with: app, entries: group) }
        // Nothing claims these, so the Open With chooser asks, as Finder does: for all of them, so none is dropped.
        if !unclaimed.isEmpty { showOpenWithChooser(for: unclaimed, makeDefault: false) }
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
        case 36, 76, 120: // Return, Enter, and F2, the Nautilus rename key
            guard flags.isEmpty else { return false }
            // Only where Edit › Rename is on: Recent and search results aren't folders, so nothing renames there.
            if CommandValidation.state(for: .rename, in: commandContext()) == .enabled { perform(.rename) }
            else if activeTab?.selection.isEmpty == false { NSSound.beep() }
            return true
        case 49: // Space
            if flags.isEmpty { perform(.quickLook); return true }
            return false
        case 125: // Down
            if flags == [.command] { perform(.open); return true }
            return false
        case 53: // Escape closes the search, field and all, and the keys stay here.
            if header.isSearching || activeTab?.search != nil { header.endSearch(); headerSearchClosed(); return true }
            if let tab = activeTab, !tab.cutIDs.isEmpty { clearCut(); return true }
            return false
        default: return false
        }
    }

    // MARK: Clipboard

    /// The items, and their names as text, as Finder's Copy writes them. Full paths are for Copy as Pathname.
    private func writeToPasteboard(_ urls: [URL]) -> Int {
        let pasteboard = dependencies.pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pasteboard.setString(urls.map(\.lastPathComponent).joined(separator: "\n"), forType: .string)
        return pasteboard.changeCount
    }
    private func copySelection() {
        let urls = OperationPlanner.outermost(selectedEntries().map(\.url))
        guard !urls.isEmpty else { return }
        _ = writeToPasteboard(urls)
        clearCut()
    }
    private func cutSelection() {
        let entries = selectedEntries()
        let urls = OperationPlanner.outermost(entries.map(\.url))
        guard !urls.isEmpty else { return }
        let count = writeToPasteboard(urls)
        // Shared with every window, so a paste in any of them moves; other windows' cut items stop looking cut.
        dependencies.cut.set(ClipboardTransaction(mode: .cut, sources: urls, changeCount: count), by: self)
        store.send(.tab(activeTabID, .cutSetChanged(Set(entries.map(\.id)))))
    }
    /// Ends the cut everywhere: every window lets its cut items go.
    func clearCut() {
        dependencies.cut.clear()
    }
    /// The cut changed, here or in another window: no tab of this window draws anything as cut any more.
    func dropCutMarks() {
        for id in store.state.window.tabs where store.state.tabs[id]?.cutIDs.isEmpty == false {
            store.send(.tab(id, .cutSetChanged([])))
        }
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
    /// Copy Path and Copy as Pathname: full paths, as text only.
    func copyPaths(of urls: [URL]) {
        guard !urls.isEmpty else { return }
        dependencies.pasteboard.clearContents()
        dependencies.pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    // MARK: Running operations

    /// Runs a command, reports what went wrong and refreshes what it touched. Commands run one after another, in the
    /// order they were asked for: one asked for while another runs waits its turn, as the window's history requires.
    public func run(_ command: Command, afterSelecting explicit: Set<ItemID>? = nil, completion: ((OperationResult) -> Void)? = nil) {
        // A folder chosen with something inside it takes that along, as in Finder: the inner item isn't a second source.
        let command = OperationPlanner.outermostSources(of: command)
        let scope = OperationCoordinator.scope(of: command)
        let resolver = conflictResolver()
        let dependencies = dependencies, operations = dependencies.operations, history = history
        let asked = FailurePromptRecord()
        let onFailure: OperationCoordinator.FailureResolver = { [weak self] failure in
            guard let self else { return .stop }
            asked.didAsk = true
            return await self.askAboutFailure(failure, verb: OperationText.verb(for: command))
        }
        enqueueOperation { [weak self] in
            let outcome = await operations.run(command, sources: scope.sources, destinations: scope.destinations, history: history,
                                               resolver: resolver, onFailure: onFailure)
            // Even if this window closed meanwhile: the sidebar is every window's.
            dependencies.followMovedItems(outcome)
            await self?.refreshHistory()
            let told = await self?.settleReconciliation(outcome, alreadyAsked: asked.didAsk) ?? false
            self?.handle(outcome, explicit: explicit, completion: completion, alreadyAsked: asked.didAsk || told)
        }
    }
    /// Runs `work` after everything this window asked for before it, so operations keep the order they were asked in.
    private func enqueueOperation(_ work: @escaping @MainActor () async -> Void) {
        let previous = operationQueue
        pendingOperations += 1
        operationQueue = Task { @MainActor [weak self] in
            await previous?.value
            await work()
            self?.pendingOperations -= 1
        }
    }
    /// Whether this window has an operation running or waiting its turn. Undo and Redo don't start then, since what
    /// they'd undo or redo is still changing; they say so instead.
    var isRunningOperations: Bool { pendingOperations > 0 }
    /// A change Helm made outside the operation engine, such as a new archive, can't be undone. Once the window's
    /// earlier work is done, Undo and Redo let go of older changes rather than reach back past this one.
    func forgetUndoAfterUntrackedChange() {
        let history = history
        enqueueOperation { [weak self] in
            await history.discardEntries()
            await self?.refreshHistory()
        }
    }

    /// A batch that ended partly done leaves Undo unsure of what's on disk, and the window's history refuses
    /// everything else until someone confirms they know (B-038). Without this, one unreadable file left every
    /// later copy, move and rename in the window beeping. Say what happened, then let work go on.
    /// Returns whether it told the person something.
    func settleReconciliation(_ outcome: Result<OperationResult, OperationCoordinator.Failure>, alreadyAsked: Bool) async -> Bool {
        guard historyState.reconciliation != nil else { return false }
        var told = false
        if !alreadyAsked, case .success(let result) = outcome {
            await confirmPartlyDone(result)
            told = true
        }
        await history.acknowledgeReconciliation()
        await refreshHistory()
        return told
    }
    private func confirmPartlyDone(_ result: OperationResult) async {
        let verb = OperationText.verb(for: result.command)
        // Items, as chosen: a replaced file is one item, named as itself, never by Helm's private working copy.
        let items = result.items
        let failed = result.failedItemNames
        let name = failed.first ?? "An item"
        let title = failed.count > 1 ? "\(failed.count) items couldn’t be \(verb)." : "“\(name)” couldn’t be \(verb)."
        var detail = result.error.map { OperationRowModel.message(for: $0) + " " } ?? ""
        detail += "\(result.succeededItemCount) of \(items.count) finished."
        let unsure = result.outcomes.filter(\.requiresReconciliation)
        if let index = result.outcomes.firstIndex(where: \.requiresReconciliation) {
            detail += " “\(items.name(ofStepAt: index))” may be only partly \(verb). Check before you use it."
        }
        detail += " This can’t be undone."
        if let messageObserver { messageObserver(title + " " + detail); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        let shown = unsure.first?.destination.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if shown != nil { alert.addButton(withTitle: "Show Item") }
        guard let window else { return }
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        if response == .alertSecondButtonReturn, let shown { show(folder: shown.deletingLastPathComponent(), selecting: [shown]) }
    }

    /// One item failed partway through a batch: Skip, Try Again or Stop, as Finder asks (P-139).
    func askAboutFailure(_ failure: StepFailure, verb: String) async -> FailureDecision {
        if let failureObserver { return failureObserver(failure) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(failure.name)” couldn’t be \(verb)."
        var detail = OperationRowModel.message(for: failure.error)
        if failure.remaining > 0 {
            detail += failure.remaining == 1 ? " 1 more item is still to do." : " \(failure.remaining) more items are still to do."
        }
        alert.informativeText = detail
        var answers: [FailureDecision] = []
        if failure.remaining > 0 { alert.addButton(withTitle: "Skip"); answers.append(.skip) }
        if failure.canRetry { alert.addButton(withTitle: "Try Again"); answers.append(.retry) }
        alert.addButton(withTitle: "Stop"); answers.append(.stop)
        if failure.remaining > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Skip any other items that can’t be \(verb)"
        }
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let decision = answers.indices.contains(index) ? answers[index] : .stop
        if decision == .skip, alert.suppressionButton?.state == .on { return .skipAll }
        return decision
    }
    private func conflictResolver() -> OperationCoordinator.ConflictResolver? {
        guard dependencies.settings.snapshot.bool(.askOnConflict) else { return nil }
        return { [weak self] (conflicts: [Conflict]) async -> ConflictPolicy? in
            guard let self else { return nil }
            return await self.resolve(conflicts)
        }
    }
    private func handle(_ outcome: Result<OperationResult, OperationCoordinator.Failure>, explicit: Set<ItemID>?,
                        completion: ((OperationResult) -> Void)?, alreadyAsked: Bool = false) {
        switch outcome {
        case .failure(.cancelled): return
        case .failure(.busy): show(message: Self.busyMessage)
        case .failure(.message(let message)): show(message: message)
        case .success(let result):
            completion?(result)
            // Someone who already chose Skip or Stop for a failure has seen it; the panel keeps the details.
            if let error = result.error, error != .cancelled, !alreadyAsked {
                show(message: OperationRowModel.message(for: error))
            }
            let outputs = Set(result.outcomes.filter { $0.succeeded && $0.step.kind != .trash && $0.step.kind != .verifyCopy }.compactMap(\.destination).map { ItemID(url: $0) })
            refreshTabs(touching: result.affectedDirectories, selecting: explicit ?? outputs)
            forgetFreeSpace()
        }
    }
    /// Reloads the tabs an operation may have changed: those showing a folder it touched, the Trash and Recent, which
    /// any operation can change, and the tab in front.
    private func refreshTabs(touching directories: Set<URL>, selecting ids: Set<ItemID>) {
        let paths = Set(directories.map { $0.standardizedFileURL.path })
        for (id, tab) in store.state.tabs {
            // A card standing in for a place that couldn't open stays up: a refresh would put the folder it covers
            // back on show. That folder reloads when you go back to it.
            if ContentStatePresentation.coveredPlace(tab) != nil { continue }
            let touched = tab.location.mutationTarget.map { paths.contains($0.standardizedFileURL.path) } ?? true
            guard touched || id == activeTabID else { continue }
            store.send(.tab(id, id == activeTabID && !ids.isEmpty ? .refreshSelecting(ids) : .refresh))
        }
    }
    private func runForSelection(_ make: ([URL]) -> Command) {
        let urls = selectedEntries().map(\.url)
        guard !urls.isEmpty else { return }
        run(make(urls))
    }
    static let busyMessage = "Helm is still working on a change in this window. Try again when it’s done."
    private func runUndo() {
        guard !isRunningOperations else { show(message: Self.busyMessage); return }
        let dependencies = dependencies, operations = dependencies.operations, history = history
        enqueueOperation { [weak self] in
            let outcome = await operations.undo(history: history)
            dependencies.followMovedItems(outcome)
            await self?.refreshHistory()
            let told = await self?.settleReconciliation(outcome, alreadyAsked: false) ?? false
            self?.handle(outcome, explicit: nil, completion: nil, alreadyAsked: told)
        }
    }
    private func runRedo() {
        guard !isRunningOperations else { show(message: Self.busyMessage); return }
        let resolver = conflictResolver()
        let dependencies = dependencies, operations = dependencies.operations, history = history
        enqueueOperation { [weak self] in
            let outcome = await operations.redo(history: history, resolver: resolver)
            dependencies.followMovedItems(outcome)
            await self?.refreshHistory()
            let told = await self?.settleReconciliation(outcome, alreadyAsked: false) ?? false
            self?.handle(outcome, explicit: nil, completion: nil, alreadyAsked: told)
        }
    }
    private func trashSelection() {
        guard let tab = activeTab else { return }
        let urls = OperationPlanner.outermost(selectedEntries().map(\.url))
        guard !urls.isEmpty else { return }
        // The next item on show takes the selection, or the previous one at the end (architecture 14.5). On show
        // includes what's inside open folders in the list; an item inside a folder going to the Trash goes with it.
        let order = tab.shownIDs
        let gone = urls.map(\.standardizedFileURL.path)
        let chosen = Set(order.filter { id in
            guard let path = tab.snapshot.entry(id)?.url.standardizedFileURL.path else { return false }
            return gone.contains { path == $0 || path.hasPrefix($0 + "/") }
        })
        let next: Set<ItemID> = SelectionModel.successor(afterRemoving: chosen, in: order).map { [$0] } ?? []
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
            // One move per folder the items came from, one after another in a steady order: each waits its turn.
            for (directory, urls) in groups.sorted(by: { $0.key.path < $1.key.path }) {
                run(.move(sources: urls, destinationDirectory: directory))
            }
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
    /// Helm can't erase what it can't see, so it looks in your Trash before asking anything. Without Full Disk Access
    /// macOS keeps it out, and the guide to giving that access comes straight away, with no question about erasing
    /// items Helm was never going to reach.
    func emptyTrash() {
        let fileSystem = dependencies.fileSystem
        let home = dependencies.home.appendingPathComponent(".Trash")
        Task { @MainActor [weak self] in
            // The Trash folder's own entry says whether Helm may look inside, without listing it. One that isn't
            // there yet, or some other problem, is left to emptying it, which names what went wrong.
            var refused = false
            do { refused = try await fileSystem.entry(at: home).isReadable == false }
            catch { refused = FileSystemError.mapping(error) == .permissionDenied }
            guard let self else { return }
            guard !refused else {
                if self.dependencies.permissions.fullDiskAccess != .granted { self.dependencies.permissions.showGuide(.fullDiskAccess) }
                else { self.show(message: OperationText.describe(FileSystemError.permissionDenied)) }
                return
            }
            self.emptyCheckedTrash()
        }
    }
    private func emptyCheckedTrash() {
        emptyTrashConfirmed { [weak self] in
            guard let self else { return }
            let fileSystem = self.dependencies.fileSystem
            let uid = String(getuid())
            let others = self.dependencies.volumes.volumes.filter { !$0.isInternal }.map { $0.url.appendingPathComponent(".Trashes/\(uid)") }
            let home = self.dependencies.home.appendingPathComponent(".Trash")
            Task { @MainActor in
                for trash in [home] + others {
                    let names: Set<String>
                    do {
                        names = try await fileSystem.childNames(of: trash)
                    } catch FileSystemError.notFound {
                        continue // That volume has no Trash yet.
                    } catch FileSystemError.permissionDenied where trash == home && self.dependencies.permissions.fullDiskAccess != .granted {
                        // Without Full Disk Access, macOS won't let Helm look inside your Trash: show how to give it
                        // rather than a bare refusal.
                        self.dependencies.permissions.showGuide(.fullDiskAccess)
                        continue
                    } catch { self.show(message: OperationText.describe(error)); continue }
                    // An item that won't go, such as a locked one, doesn't keep the rest; it's named afterwards.
                    var stuck: [(name: String, error: Error)] = []
                    var erased: [URL] = []
                    for name in names.sorted() {
                        let item = trash.appendingPathComponent(name)
                        do { try await fileSystem.removeItem(at: item); erased.append(item) }
                        catch { stuck.append((name, error)) }
                    }
                    // Where the erased items came from goes with them.
                    self.dependencies.trashOrigins.removeOrigins(for: erased)
                    if let first = stuck.first {
                        let which = stuck.count == 1 ? "“\(first.name)”" : "“\(first.name)” and \(stuck.count - 1) more"
                        self.show(message: "\(which) couldn’t be deleted. \(OperationText.describe(first.error))")
                    }
                }
                self.refreshPlaceOnShow()
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
                var erased: [URL] = []
                do { for url in urls { try await fileSystem.removeItem(at: url); erased.append(url) } }
                catch { self.show(message: OperationText.describe(error)) }
                // Erased from the Trash, an item's record of where it came from goes too.
                self.dependencies.trashOrigins.removeOrigins(for: erased)
                self.store.send(.tab(self.activeTabID, .refresh))
                self.forgetFreeSpace()
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
    /// Through the operation engine, like any other change, so Undo takes the new aliases or links away.
    private func makeLinks(alias: Bool) {
        let urls = selectedEntries().map(\.url)
        guard !urls.isEmpty else { return }
        run(.link(sources: urls, destinationDirectory: nil, alias: alias))
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
        if !allStarred { urls.forEach(dependencies.showStarred) }
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
                let item: NSMenuItem
                switch row.command {
                case .openWith: item = submenuItem(row.title, row.command, openWithMenu(for: entries))
                case .share: item = submenuItem(row.title, row.command, shareMenu(for: entries))
                case .newFile: item = submenuItem(row.title, row.command, newFileMenu())
                default: item = commandItem(row.title, row.command)
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
    /// A row that opens a submenu. It has no action until its submenu is in place, so AppKit gives it the submenu's own
    /// action, which keeps it enabled. A row whose action is cleared afterwards is greyed out, and its submenu can't be
    /// opened. The rows inside are checked as usual.
    private func submenuItem(_ title: String, _ command: CommandID, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = command.rawValue
        item.submenu = submenu
        return item
    }
    /// View › Sort By in the menu bar: the fields, where choosing the current one reverses it, then its two directions in words.
    /// During a search it's about the results' order.
    public func fillSortItems(in menu: NSMenu) {
        let current = activeTab?.shownSort ?? .defaultSort
        if activeTab?.search != nil {
            let best = closureItem(SortChoice.bestMatch.title) { [weak self] in self?.pressSort(.relevance) }
            best.state = current.field == .relevance ? .on : .off
            menu.addItem(best)
        }
        if let item = lastOpenedSortItem(current) { menu.addItem(item) }
        for field in SortField.all {
            let item = closureItem(field.title) { [weak self] in self?.pressSort(field.field) }
            item.state = current.field == field.field ? .on : .off
            if current.field == field.field { item.toolTip = "Choose again to reverse" }
            menu.addItem(item)
        }
        if current.field != .relevance, let field = SortField.describing(current.field) {
            menu.addItem(.separator())
            for ascending in [field.startsAscending, !field.startsAscending] {
                let item = closureItem(SortField.direction(field.field, ascending: ascending)) { [weak self] in
                    guard let self, let sort = self.activeTab?.shownSort else { return }
                    self.contentSetSort(ItemSort(field: sort.field, ascending: ascending, directoriesFirst: sort.directoriesFirst))
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
    /// Pressing the current sort again reverses it, as clicking a column heading does. Both work on the order on
    /// show, so during a search they change the results' order and leave the folder's alone. Best Match is only
    /// offered during a search, and does nothing once it has ended.
    public func pressSort(_ field: ItemSort.Field) {
        guard let tab = activeTab, field != .relevance || tab.search != nil else { return }
        contentSetSort(SortField.pressing(field, on: tab.shownSort))
    }
    func toggleFoldersFirst() {
        guard let sort = activeTab?.shownSort else { return }
        contentSetSort(ItemSort(field: sort.field, ascending: sort.ascending, directoriesFirst: !sort.directoriesFirst))
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
                // Checked like New Folder, so a template never lands in a folder hidden under a card.
                let item = NSMenuItem(title: name, action: #selector(newFromTemplate(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = templates.appendingPathComponent(name)
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
        let icon = icons.icon(for: entries[0])
        let model = PropertiesViewModel(entries: entries)
        let view = PropertiesView(model: model, icon: { _ in Image(nsImage: icon) },
            reveal: { [weak self] urls in if let url = urls.first { self?.revealInCurrentTab(url) } },
            dismiss: { [weak window] in if let attached = window?.attachedSheet { window?.endSheet(attached) } })
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.beginSheet(sheet, completionHandler: nil)
    }

    // MARK: Test support

    public func refreshHistoryForTesting() async { await refreshHistory() }
    /// Whether a change is running or waiting its turn in this window, which makes Undo and Redo say so instead.
    public var isRunningOperationsForTesting: Bool { isRunningOperations }
    public func emptyTrashForTesting() { emptyTrash() }
    public var isSearchingForTesting: Bool { header.isSearching }
    public func chooseSortForTesting(_ title: String) {
        guard let tab = activeTab, let choice = SortChoice.all.first(where: { $0.title == title }) else { return }
        contentSetSort(choice.applied(to: tab.shownSort))
    }
    /// The path's pieces as the path bar shows them.
    public func pathSegmentsForTesting() -> [String] { pathBar.segmentTitles }
    /// The tabs' names as the tab strip shows them, or the one tab's name while the strip is hidden.
    public var tabTitlesForTesting: [String] {
        tabStrip.isHidden ? [TabStripView.title(activeTab)] : tabStrip.titlesForTesting
    }
    /// Whether the whole of the active tab is in the tab strip's view; true with one tab, when there's no strip.
    public var activeTabInViewForTesting: Bool { tabStrip.isHidden || tabStrip.activeTabInViewForTesting }
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
