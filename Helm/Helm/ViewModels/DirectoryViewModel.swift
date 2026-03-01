import Foundation
import AppKit
import Combine

@MainActor
final class DirectoryViewModel: ObservableObject {

    @Published var items: [FileItem] = []
    @Published var selectedItems: Set<URL> = []
    @Published var currentURL: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published var viewMode: ViewMode = .grid
    @Published var sortDescriptor: FileItemSort = .defaultSort
    @Published var isLoading: Bool = false
    @Published var error: Error?
    @Published var showHiddenFiles: Bool = false

    var displayItems: [FileItem] {
        sortDescriptor.sorted(items)
    }

    private let fileSystemService: FileSystemService
    private let starredService: StarredFilesService
    private let fileMonitor: FileMonitorService
    private var monitorTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0

    init(
        fileSystemService: FileSystemService,
        starredService: StarredFilesService,
        fileMonitor: FileMonitorService
    ) {
        self.fileSystemService = fileSystemService
        self.starredService = starredService
        self.fileMonitor = fileMonitor
        self.showHiddenFiles = UserDefaults.standard.bool(forKey: "helm.showHiddenFiles")
    }

    func loadDirectory(useCache: Bool = true) async {
        let targetURL = currentURL
        loadGeneration &+= 1
        let generation = loadGeneration

        isLoading = true
        error = nil

        do {
            let newItems = try await fileSystemService.contentsOfDirectory(
                at: targetURL,
                showHidden: showHiddenFiles,
                starredService: starredService,
                useCache: useCache
            )
            guard generation == loadGeneration, targetURL == currentURL else { return }
            items = newItems
            // Clear selection when loading a new directory
            selectedItems.removeAll()
        } catch {
            guard generation == loadGeneration, targetURL == currentURL else { return }
            self.error = error
            items = []
        }

        guard generation == loadGeneration, targetURL == currentURL else { return }
        isLoading = false
    }

    func refresh() async {
        let savedSelection = selectedItems
        await fileSystemService.invalidateDirectoryCache(at: currentURL)
        await loadDirectory(useCache: false)
        // Restore selection for items that still exist
        selectedItems = savedSelection.intersection(Set(items.map(\.url)))
    }

    func navigateTo(_ url: URL) async {
        currentURL = url
        await loadDirectory()
    }

    func startMonitoring() async {
        monitorTask?.cancel()

        guard AppSettings.liveMonitoringEnabled else {
            return
        }

        let url = currentURL
        let stream = await fileMonitor.monitor(directory: url)
        monitorTask = Task { [weak self] in
            var refreshTask: Task<Void, Never>?
            for await _ in stream {
                guard !Task.isCancelled else { return }
                guard let self = self else { return }
                // Only refresh if we're still monitoring the same directory
                guard self.currentURL == url else { return }

                refreshTask?.cancel()
                refreshTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 250_000_000)
                    } catch {
                        return
                    }
                    guard let self else { return }
                    guard self.currentURL == url else { return }
                    await self.refresh()
                }
            }
            refreshTask?.cancel()
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        Task {
            await fileMonitor.stopMonitoring()
        }
    }

    func toggleStar(for item: FileItem) {
        starredService.toggleStar(url: item.url)
        if let index = items.firstIndex(where: { $0.url == item.url }) {
            items[index].isStarred.toggle()
        }
    }

    @discardableResult
    func openItem(_ item: FileItem) -> Bool {
        if item.isDirectory && !item.isPackage {
            // Navigation handled by controller
            return false
        }
        return NSWorkspace.shared.open(item.url)
    }
}
