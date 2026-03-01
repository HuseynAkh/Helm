import Cocoa
import SwiftUI
import Combine

class ContentViewController: NSViewController, FileContextMenuDelegate {

    private let navigationState: NavigationState
    private let initialURL: URL
    private let fileSystemService = FileSystemService()
    private let starredService = StarredFilesService()
    private let recentItemsService = RecentItemsService.shared
    private let searchViewModel: SearchViewModel
    private let fileMonitor = FileMonitorService()
    private let fileOperationService = FileOperationService()
    private let undoService = UndoService()
    private let clipboardService = ClipboardService.shared
    private let contextMenuBuilder = FileContextMenuBuilder()

    let directoryViewModel: DirectoryViewModel
    var onLocationChanged: ((URL) -> Void)?

    private var fileListController: FileListViewController?
    private var statusBar: StatusBar?

    private var monitorTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var lastStableDirectoryURL: URL
    private(set) var activeLocationURL: URL
    private var cancellables: Set<AnyCancellable> = []

    init(initialURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.initialURL = initialURL
        self.navigationState = NavigationState(initialURL: initialURL)
        self.lastStableDirectoryURL = initialURL
        self.activeLocationURL = initialURL
        self.searchViewModel = SearchViewModel(starredService: starredService)
        self.directoryViewModel = DirectoryViewModel(
            fileSystemService: fileSystemService,
            starredService: starredService,
            fileMonitor: fileMonitor
        )
        self.directoryViewModel.currentURL = initialURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        contextMenuBuilder.delegate = self
        setupFileList()
        setupStatusBar()
        bindSearch()
        queueLocationLoad(initialURL, restoreSelection: nil, useCache: true, notify: true)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        navigationTask?.cancel()
        monitorTask?.cancel()
        directoryViewModel.stopMonitoring()
        searchViewModel.exitSearch()
    }

    private func setupFileList() {
        let fileListVC = FileListViewController(viewModel: directoryViewModel)
        addChild(fileListVC)
        fileListVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fileListVC.view)
        fileListController = fileListVC

        fileListVC.onNavigate = { [weak self] url in
            self?.navigateTo(url)
        }
        fileListVC.onOpenItem = { [weak self] item in
            self?.openItem(item)
        }

        fileListVC.onContextMenu = { [weak self] items, directoryURL, event in
            self?.showContextMenu(for: items, in: directoryURL, event: event)
        }

        fileListVC.onSelectionChanged = { [weak self] in
            self?.updateStatusBar()
        }

        fileListVC.onDirectoryMutated = { [weak self] in
            self?.refreshDirectory()
        }
    }

    private func setupStatusBar() {
        let bar = StatusBar(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        statusBar = bar

        if let fileListView = fileListController?.view {
            NSLayoutConstraint.activate([
                fileListView.topAnchor.constraint(equalTo: view.topAnchor),
                fileListView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                fileListView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                fileListView.bottomAnchor.constraint(equalTo: bar.topAnchor),

                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                bar.heightAnchor.constraint(equalToConstant: 24)
            ])
        }
    }

    // MARK: - Navigation

    func navigateTo(_ url: URL) {
        let target = normalizedLocationURL(url)
        guard canNavigate(to: target) else {
            presentNavigationError(for: url)
            return
        }

        exitSearchIfNeeded()
        navigationState.currentSelectedItems = directoryViewModel.selectedItems
        navigationState.navigateTo(target)
        queueLocationLoad(target, restoreSelection: nil, useCache: true, notify: true)
    }

    func goBack() {
        exitSearchIfNeeded()
        navigationState.currentSelectedItems = directoryViewModel.selectedItems
        guard let entry = navigationState.goBack() else { return }
        queueLocationLoad(navigationState.currentURL, restoreSelection: entry.selectedItems, useCache: true, notify: true)
    }

    func goForward() {
        exitSearchIfNeeded()
        navigationState.currentSelectedItems = directoryViewModel.selectedItems
        guard let entry = navigationState.goForward() else { return }
        queueLocationLoad(navigationState.currentURL, restoreSelection: entry.selectedItems, useCache: true, notify: true)
    }

    func goUp() {
        guard activeLocationURL.isFileURL else { return }
        exitSearchIfNeeded()
        guard let parent = navigationState.goUp() else { return }
        queueLocationLoad(parent, restoreSelection: nil, useCache: true, notify: true)
    }

    func setViewMode(_ mode: ViewMode) {
        directoryViewModel.viewMode = mode
        fileListController?.switchViewMode(mode)
    }

    func updateSearchQuery(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            clearSearch()
            return
        }

        searchViewModel.query = query
        directoryViewModel.selectedItems = []

        if activeLocationURL.isHelmRecentsLocation {
            searchViewModel.activeDirectoryURL = directoryURLForOperations()
            searchViewModel.searchEverywhere()
        } else {
            searchViewModel.startSearch(in: directoryURLForOperations())
        }
    }

    func toggleHiddenFiles() {
        directoryViewModel.showHiddenFiles.toggle()
        UserDefaults.standard.set(directoryViewModel.showHiddenFiles, forKey: "helm.showHiddenFiles")
        if activeLocationURL.isHelmRecentsLocation {
            queueLocationLoad(activeLocationURL, restoreSelection: nil, useCache: false, notify: false)
            return
        }

        Task { @MainActor in
            await directoryViewModel.loadDirectory(useCache: false)
            fileListController?.reloadData()
            updateStatusBar()
            startMonitoring()
            if hasSearchQuery {
                updateSearchQuery(searchViewModel.query)
            }
        }
    }

    func refreshDirectory() {
        if activeLocationURL.isHelmRecentsLocation {
            queueLocationLoad(activeLocationURL, restoreSelection: nil, useCache: false, notify: false)
            return
        }

        Task { @MainActor in
            await directoryViewModel.refresh()
            fileListController?.reloadData()
            updateStatusBar()
            startMonitoring()
            if hasSearchQuery {
                updateSearchQuery(searchViewModel.query)
            }
        }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task {
            await directoryViewModel.startMonitoring()
        }
    }

    func updateStatusBar() {
        let itemCount = directoryViewModel.displayItems.count
        let selectedCount = directoryViewModel.selectedItems.count
        statusBar?.update(itemCount: itemCount, selectedCount: selectedCount, url: activeLocationURL)
    }

    private func handleLocationChanged(_ url: URL) {
        onLocationChanged?(url)

        if let windowController = view.window?.windowController as? MainWindowController {
            windowController.updateBreadcrumb(for: url)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func canNavigate(to url: URL) -> Bool {
        if url.isHelmRecentsLocation {
            return true
        }
        guard url.isFileURL else { return false }
        return isDirectory(url)
    }

    private func normalizedLocationURL(_ url: URL) -> URL {
        if url.isHelmVirtualLocation {
            return url
        }
        return url.standardizedFileURL
    }

    private func queueLocationLoad(
        _ url: URL,
        restoreSelection: Set<URL>?,
        useCache: Bool,
        notify: Bool
    ) {
        let target = normalizedLocationURL(url)
        navigationTask?.cancel()
        navigationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let didLoad = await self.loadLocation(target, useCache: useCache)
            guard !Task.isCancelled, didLoad else { return }

            if let restoreSelection {
                self.directoryViewModel.selectedItems = restoreSelection
                    .intersection(Set(self.directoryViewModel.items.map(\.url)))
            }

            self.activeLocationURL = target
            self.updateStatusBar()
            if self.hasSearchQuery {
                self.updateSearchQuery(self.searchViewModel.query)
            }
            if notify {
                self.handleLocationChanged(target)
            }
        }
    }

    @MainActor
    private func loadLocation(_ url: URL, useCache: Bool) async -> Bool {
        if url.isHelmRecentsLocation {
            return await loadRecents()
        }

        guard isDirectory(url) else {
            presentNavigationError(for: url)
            // Fall back to home directory so the breadcrumb shows something valid
            let fallback = FileManager.default.homeDirectoryForCurrentUser
            if url != fallback {
                queueLocationLoad(fallback, restoreSelection: nil, useCache: true, notify: true)
            }
            return false
        }

        lastStableDirectoryURL = url
        directoryViewModel.currentURL = url
        await directoryViewModel.loadDirectory(useCache: useCache)
        fileListController?.reloadData()
        startMonitoring()
        await recentItemsService.recordAccess(to: url)
        return true
    }

    @MainActor
    private func loadRecents() async -> Bool {
        monitorTask?.cancel()
        directoryViewModel.stopMonitoring()
        directoryViewModel.error = nil
        directoryViewModel.currentURL = lastStableDirectoryURL
        directoryViewModel.selectedItems = []
        directoryViewModel.items = await recentItemsService.recentItems(limit: 180, starredService: starredService)
        fileListController?.reloadData()
        return true
    }

    private var hasSearchQuery: Bool {
        !searchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func directoryURLForOperations() -> URL {
        if activeLocationURL.isFileURL && !activeLocationURL.isHelmRecentsLocation {
            return activeLocationURL
        }
        return lastStableDirectoryURL
    }

    private func clearSearch() {
        guard hasSearchQuery || searchViewModel.searchMode else { return }
        searchViewModel.exitSearch()
        clearSearchField()
        queueLocationLoad(activeLocationURL, restoreSelection: nil, useCache: true, notify: false)
    }

    /// Clears the search field text in the toolbar without reloading the directory.
    private func clearSearchField() {
        if let windowController = view.window?.windowController as? MainWindowController {
            windowController.clearSearchField()
        }
    }

    /// Exits search mode if active, clearing both the model and the toolbar field.
    /// Used before navigation so directory contents aren't overwritten by stale search results.
    private func exitSearchIfNeeded() {
        guard hasSearchQuery || searchViewModel.searchMode else { return }
        searchViewModel.exitSearch()
        clearSearchField()
    }

    private func bindSearch() {
        searchViewModel.$results
            .receive(on: RunLoop.main)
            .sink { [weak self] results in
                guard let self else { return }
                guard self.hasSearchQuery else { return }
                self.directoryViewModel.items = results
                self.directoryViewModel.selectedItems = []
                self.fileListController?.reloadData()
                self.updateStatusBar()
            }
            .store(in: &cancellables)
    }

    private func presentNavigationError(for url: URL) {
        let alert = NSAlert()
        alert.messageText = "Unable to Open Folder"
        alert.informativeText = "\(url.path) is not an accessible folder."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func openItem(_ item: FileItem) {
        if item.isDirectory && !item.isPackage {
            navigateTo(item.url)
            return
        }

        let didOpen = directoryViewModel.openItem(item)
        if didOpen {
            Task {
                await recentItemsService.recordAccess(to: item.url)
            }
            return
        }
        presentOpenError(for: item.url)
    }

    private func presentOpenError(for url: URL) {
        let alert = NSAlert()
        alert.messageText = "Unable to Open Item"
        alert.informativeText = "The item \"\(url.lastPathComponent)\" could not be opened."
        alert.alertStyle = .warning
        alert.runModal()
    }

    @MainActor
    private func applyOperationResult(_ result: FileOperationResult) async {
        undoService.registerUndo(for: result, undoManager: view.window?.undoManager)
        await directoryViewModel.refresh()
        fileListController?.reloadData()
        updateStatusBar()
    }

    // MARK: - Context Menu

    private func showContextMenu(for items: [FileItem], in directoryURL: URL, event: NSEvent) {
        let menu = contextMenuBuilder.buildMenu(for: items, in: directoryURL)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    // MARK: - FileContextMenuDelegate

    @objc func contextMenuOpen(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        openItem(item)
    }

    @objc func contextMenuOpenMultiple(_ sender: NSMenuItem) {
        guard let items = sender.representedObject as? [FileItem] else { return }
        for item in items {
            openItem(item)
        }
    }

    @objc func contextMenuOpenWith(_ sender: NSMenuItem) {
        guard let (fileURL, appURL) = sender.representedObject as? (URL, URL) else { return }
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] app, error in
            guard app == nil else { return }
            if let error {
                let alert = NSAlert(error: error)
                alert.runModal()
            } else {
                self?.presentOpenError(for: fileURL)
            }
        }
    }

    @objc func contextMenuCut(_ sender: NSMenuItem) {
        guard let items = sender.representedObject as? [FileItem] else { return }
        clipboardService.cutFiles(items.map(\.url))
    }

    @objc func contextMenuCopy(_ sender: NSMenuItem) {
        guard let items = sender.representedObject as? [FileItem] else { return }
        clipboardService.copyFiles(items.map(\.url))
    }

    @objc func contextMenuPaste(_ sender: NSMenuItem) {
        guard let directoryURL = sender.representedObject as? URL,
              let pasteData = clipboardService.pasteFiles() else { return }

        Task { @MainActor in
            do {
                let result: FileOperationResult
                if pasteData.isCut {
                    result = try await fileOperationService.moveItems(pasteData.urls, to: directoryURL)
                } else {
                    result = try await fileOperationService.copyItems(pasteData.urls, to: directoryURL)
                }
                await applyOperationResult(result)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc func contextMenuToggleStar(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        directoryViewModel.toggleStar(for: item)
    }

    @objc func contextMenuRename(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        showRenameAlert(for: item)
    }

    @objc func contextMenuBatchRename(_ sender: NSMenuItem) {
        guard let items = sender.representedObject as? [FileItem] else { return }
        showBatchRename(for: items)
    }

    @objc func contextMenuTrash(_ sender: NSMenuItem) {
        guard let items = sender.representedObject as? [FileItem] else { return }
        Task { @MainActor in
            do {
                let result = try await fileOperationService.trashItems(items.map(\.url))
                await applyOperationResult(result)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc func contextMenuProperties(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        showProperties(for: item.url)
    }

    @objc func contextMenuDirectoryProperties(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        showProperties(for: url)
    }

    @objc func contextMenuShare(_ sender: NSMenuItem) {
        guard let (service, urls) = sender.representedObject as? (NSSharingService, [URL]) else { return }
        service.perform(withItems: urls)
    }

    @objc func contextMenuNewFolder(_ sender: NSMenuItem) {
        guard let directoryURL = sender.representedObject as? URL else { return }
        Task { @MainActor in
            do {
                let result = try await fileOperationService.createDirectory(at: directoryURL, name: "New Folder")
                await applyOperationResult(result)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc func contextMenuNewFromTemplate(_ sender: NSMenuItem) {
        guard let (templateURL, directoryURL) = sender.representedObject as? (URL, URL) else { return }
        Task { @MainActor in
            do {
                let result = try await fileOperationService.createFileFromTemplate(template: templateURL, in: directoryURL)
                await applyOperationResult(result)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc func contextMenuNewTextFile(_ sender: NSMenuItem) {
        guard let directoryURL = sender.representedObject as? URL else { return }
        Task { @MainActor in
            do {
                let result = try await fileOperationService.createFile(at: directoryURL, name: "Untitled.txt")
                await applyOperationResult(result)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    // MARK: - Rename Helpers

    private func showRenameAlert(for item: FileItem) {
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = item.name
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        // Select just the name part (without extension)
        let nameWithoutExt = (item.name as NSString).deletingPathExtension
        textField.currentEditor()?.selectedRange = NSRange(location: 0, length: nameWithoutExt.count)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != item.name else { return }

        Task { @MainActor in
            do {
                let result = try await fileOperationService.renameItem(at: item.url, to: newName)
                await applyOperationResult(result)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    private func showBatchRename(for items: [FileItem]) {
        let batchView = BatchRenameView(
            items: items,
            onRename: { [weak self] renames in
                self?.dismiss(nil)
                self?.performBatchRename(renames)
            },
            onCancel: { [weak self] in
                self?.dismiss(nil)
            }
        )

        let hostingController = NSHostingController(rootView: batchView)
        presentAsSheet(hostingController)
    }

    private func performBatchRename(_ renames: [(URL, String)]) {
        Task { @MainActor in
            var didMutate = false
            for (url, newName) in renames {
                do {
                    let result = try await fileOperationService.renameItem(at: url, to: newName)
                    undoService.registerUndo(for: result, undoManager: view.window?.undoManager)
                    didMutate = true
                } catch {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                    break
                }
            }

            if didMutate {
                await directoryViewModel.refresh()
                fileListController?.reloadData()
                updateStatusBar()
            }
        }
    }

    // MARK: - Public Actions (for menu items)

    func performNewFolder() {
        Task { @MainActor in
            do {
                let result = try await fileOperationService.createDirectory(
                    at: directoryViewModel.currentURL,
                    name: "New Folder"
                )
                await applyOperationResult(result)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    func performCopy() {
        let selectedItems = directoryViewModel.displayItems.filter { directoryViewModel.selectedItems.contains($0.url) }
        guard !selectedItems.isEmpty else { return }
        clipboardService.copyFiles(selectedItems.map(\.url))
    }

    func performCut() {
        let selectedItems = directoryViewModel.displayItems.filter { directoryViewModel.selectedItems.contains($0.url) }
        guard !selectedItems.isEmpty else { return }
        clipboardService.cutFiles(selectedItems.map(\.url))
    }

    func performPaste() {
        guard let pasteData = clipboardService.pasteFiles() else { return }
        let targetURL = directoryViewModel.currentURL

        Task { @MainActor in
            do {
                let result: FileOperationResult
                if pasteData.isCut {
                    result = try await fileOperationService.moveItems(pasteData.urls, to: targetURL)
                } else {
                    result = try await fileOperationService.copyItems(pasteData.urls, to: targetURL)
                }
                await applyOperationResult(result)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    func performTrash() {
        let selectedItems = directoryViewModel.displayItems.filter { directoryViewModel.selectedItems.contains($0.url) }
        guard !selectedItems.isEmpty else { return }

        Task { @MainActor in
            do {
                let result = try await fileOperationService.trashItems(selectedItems.map(\.url))
                await applyOperationResult(result)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    func performRename() {
        let selectedItems = directoryViewModel.displayItems.filter { directoryViewModel.selectedItems.contains($0.url) }
        if selectedItems.count == 1, let item = selectedItems.first {
            showRenameAlert(for: item)
        } else if selectedItems.count > 1 {
            showBatchRename(for: selectedItems)
        }
    }

    func performToggleStar() {
        let selectedItems = directoryViewModel.displayItems.filter { directoryViewModel.selectedItems.contains($0.url) }
        for item in selectedItems {
            directoryViewModel.toggleStar(for: item)
        }
    }

    func performQuickLook() {
        fileListController?.toggleQuickLook()
    }

    func performProperties() {
        let selectedItems = directoryViewModel.displayItems.filter { directoryViewModel.selectedItems.contains($0.url) }
        if let first = selectedItems.first {
            showProperties(for: first.url)
        } else {
            showProperties(for: directoryViewModel.currentURL)
        }
    }

    // MARK: - Properties

    private func showProperties(for url: URL) {
        let vm = PropertiesViewModel()
        vm.load(url: url)
        let propertiesView = PropertiesView(viewModel: vm) { [weak self] in
            self?.dismiss(nil)
        }
        let hostingController = NSHostingController(rootView: propertiesView)
        presentAsSheet(hostingController)
    }
}
