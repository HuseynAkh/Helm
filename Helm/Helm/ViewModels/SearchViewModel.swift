import Foundation
import AppKit
import Combine

@MainActor
final class SearchViewModel: ObservableObject {

    @Published var query: String = ""
    @Published var results: [FileItem] = []
    @Published var isSearching: Bool = false
    @Published var searchMode: Bool = false
    @Published var scope: SearchScope = .currentFolder(FileManager.default.homeDirectoryForCurrentUser)

    /// The user's current browsing directory, used to boost nearby results in "everywhere" search.
    var activeDirectoryURL: URL?

    private let searchService = SpotlightSearchService()
    private let starredService: StarredFilesService?
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(starredService: StarredFilesService? = nil) {
        self.starredService = starredService
    }

    func startSearch(in directoryURL: URL) {
        activeDirectoryURL = directoryURL
        runDebouncedSearch(for: .currentFolder(directoryURL))
    }

    func searchEverywhere() {
        runDebouncedSearch(for: .everywhere)
    }

    func exitSearch() {
        debounceTask?.cancel()
        searchTask?.cancel()
        searchService.stopSearch()
        searchMode = false
        query = ""
        results = []
        isSearching = false
    }

    private func runDebouncedSearch(for newScope: SearchScope) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            searchMode = false
            debounceTask?.cancel()
            searchTask?.cancel()
            searchService.stopSearch()
            return
        }

        scope = newScope
        searchMode = true
        isSearching = true

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: AppSettings.searchDebounceNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            guard self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            self.performSearch(text: trimmed, scope: newScope)
        }
    }

    private func performSearch(text: String, scope: SearchScope) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            let stream = searchService.search(
                text: text,
                scope: scope,
                activeDirectoryURL: activeDirectoryURL,
                starredService: starredService
            )
            for await items in stream {
                guard !Task.isCancelled else { return }
                self.results = items
                self.isSearching = false
            }
        }
    }
}
