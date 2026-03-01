import Foundation
import AppKit
import Combine

@MainActor
final class SidebarViewModel: ObservableObject {

    @Published var recentsRoot: Place = Place.recentsRoot()
    @Published var favorites: [Place] = Place.defaultFavorites()
    @Published var bookmarks: [Place] = []
    @Published var starred: [Place] = []
    @Published var devices: [Place] = []
    @Published var trash: Place = Place.trash()
    @Published var selectedPlaceID: String?

    var onPlaceSelected: ((URL) -> Void)?

    private let starredService = StarredFilesService()
    private let volumeService = VolumeService()
    private var cancellables: Set<AnyCancellable> = []
    private var currentDirectoryURL: URL?

    private let bookmarksKey = "helm.bookmarks"

    init() {
        bindServices()
        loadBookmarks()
        refreshStarred()
        refreshDevices()
    }

    func selectPlace(_ place: Place) {
        onPlaceSelected?(place.url)
    }

    func selectLocation(_ url: URL) {
        let normalized = url.isFileURL ? url.standardizedFileURL : url
        currentDirectoryURL = normalized
        selectedPlaceID = matchingPlace(for: normalized)?.id
    }

    func place(for id: String) -> Place? {
        allPlaces.first { $0.id == id }
    }

    func addBookmark(url: URL) {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        guard !bookmarks.contains(where: { $0.url.standardizedFileURL == standardized }) else {
            return
        }

        let place = Place(
            id: "bookmark-\(standardized.path)",
            name: displayName(for: standardized),
            url: standardized,
            iconName: "bookmark.fill",
            kind: .bookmark
        )
        bookmarks.append(place)
        bookmarks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        saveBookmarks()
        refreshSelection()
    }

    func removeBookmark(_ place: Place) {
        guard place.kind == .bookmark else { return }
        bookmarks.removeAll { $0.id == place.id }
        saveBookmarks()
        refreshSelection()
    }

    func handleBookmarkDrop(providers: [NSItemProvider]) -> Bool {
        let bookmarkProviders = providers.filter { $0.canLoadObject(ofClass: NSURL.self) }
        guard !bookmarkProviders.isEmpty else { return false }

        for provider in bookmarkProviders {
            provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
                guard let url = object as? URL else { return }
                Task { @MainActor [weak self] in
                    self?.addBookmark(url: url)
                }
            }
        }

        return true
    }

    func refreshStarred() {
        let starredURLs = starredService.allStarred()
        starred = starredURLs.map { url in
            Place(
                id: "starred-\(url.path)",
                name: url.lastPathComponent,
                url: url,
                iconName: "star.fill",
                kind: .starred
            )
        }
        refreshSelection()
    }

    func refreshDevices() {
        devices = volumeService.mountedVolumes
        refreshSelection()
    }

    private func bindServices() {
        volumeService.$mountedVolumes
            .receive(on: RunLoop.main)
            .sink { [weak self] mounted in
                self?.devices = mounted
                self?.refreshSelection()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.volumeService.refreshVolumes()
            }
            .store(in: &cancellables)
    }

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: bookmarksKey),
              let urls = try? JSONDecoder().decode([URL].self, from: data) else {
            return
        }

        bookmarks = urls
            .map(\.standardizedFileURL)
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .map { url in
                Place(
                    id: "bookmark-\(url.path)",
                    name: displayName(for: url),
                    url: url,
                    iconName: "bookmark.fill",
                    kind: .bookmark
                )
            }
        bookmarks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func saveBookmarks() {
        let urls = bookmarks.map(\.url)
        if let data = try? JSONEncoder().encode(urls) {
            UserDefaults.standard.set(data, forKey: bookmarksKey)
        }
    }

    private var allPlaces: [Place] {
        [recentsRoot] + favorites + bookmarks + starred + devices + [trash]
    }

    private func refreshSelection() {
        guard let currentDirectoryURL else { return }
        selectedPlaceID = matchingPlace(for: currentDirectoryURL)?.id
    }

    private func matchingPlace(for url: URL) -> Place? {
        if url.isHelmRecentsLocation {
            return recentsRoot
        }

        guard url.isFileURL else { return nil }

        let standardized = url.standardizedFileURL
        let candidates = favorites + bookmarks + devices + [trash]

        if let exact = candidates.first(where: { $0.url.standardizedFileURL == standardized }) {
            return exact
        }

        return candidates
            .filter { contains(standardized, in: $0.url.standardizedFileURL) }
            .max(by: { $0.url.path.count < $1.url.path.count })
    }

    private func contains(_ url: URL, in base: URL) -> Bool {
        let path = url.path
        let basePath = base.path
        if path == basePath { return true }
        let normalizedBase = basePath.hasSuffix("/") ? basePath : "\(basePath)/"
        return path.hasPrefix(normalizedBase)
    }

    private func displayName(for url: URL) -> String {
        if url.path == FileManager.default.homeDirectoryForCurrentUser.path {
            return "Home"
        }
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}
