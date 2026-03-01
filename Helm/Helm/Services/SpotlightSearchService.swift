import Foundation
import AppKit
import UniformTypeIdentifiers

enum SearchScope {
    case currentFolder(URL)
    case everywhere
}

/// Wraps NSMetadataQuery for Spotlight-based file search
@MainActor
class SpotlightSearchService {

    private var query: NSMetadataQuery?
    private var continuation: AsyncStream<[FileItem]>.Continuation?
    private var observerTokens: [NSObjectProtocol] = []

    nonisolated private static let systemPathPrefixes: [String] = [
        "/system/",
        "/library/",
        "/private/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/dev/",
        "/opt/"
    ]

    func search(
        text: String,
        scope: SearchScope,
        activeDirectoryURL: URL? = nil,
        starredService: StarredFilesService? = nil
    ) -> AsyncStream<[FileItem]> {
        stopSearch()

        let trimmedQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return AsyncStream { continuation in
                continuation.yield([])
                continuation.finish()
            }
        }

        return AsyncStream { [weak self] continuation in
            self?.continuation = continuation

            let metadataQuery = NSMetadataQuery()
            metadataQuery.predicate = Self.makePredicate(queryText: trimmedQuery)
            metadataQuery.searchScopes = self?.searchScopes(for: scope) ?? [NSMetadataQueryUserHomeScope]
            metadataQuery.sortDescriptors = [
                NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: false),
                NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)
            ]

            let queryID = ObjectIdentifier(metadataQuery)
            let emitResults: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in
                    guard let self,
                          let activeQuery = self.query,
                          ObjectIdentifier(activeQuery) == queryID else { return }
                    let items = self.processResults(
                        activeQuery,
                        queryText: trimmedQuery,
                        scope: scope,
                        activeDirectoryURL: activeDirectoryURL,
                        starredService: starredService
                    )
                    self.continuation?.yield(items)
                }
            }

            let finishObserver = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery,
                queue: .main
            ) { _ in
                emitResults()
            }

            let updateObserver = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: metadataQuery,
                queue: .main
            ) { _ in
                emitResults()
            }
            self?.observerTokens = [finishObserver, updateObserver]

            metadataQuery.start()
            self?.query = metadataQuery

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.stopSearch()
                }
            }
        }
    }

    func stopSearch() {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()

        query?.stop()
        query = nil
        continuation?.finish()
        continuation = nil
    }

    private static func makePredicate(queryText: String) -> NSPredicate {
        let namePredicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", queryText)
        guard !AppSettings.searchIncludeSystemLocations else {
            return namePredicate
        }

        let hiddenPredicate = NSPredicate(format: "NOT (kMDItemFSName BEGINSWITH '.')")
        let systemExcludes = systemPathPrefixes.map { prefix in
            NSPredicate(format: "NOT (kMDItemPath BEGINSWITH[cd] %@)", prefix)
        }

        return NSCompoundPredicate(andPredicateWithSubpredicates: [namePredicate, hiddenPredicate] + systemExcludes)
    }

    private func searchScopes(for scope: SearchScope) -> [Any] {
        switch scope {
        case .currentFolder(let url):
            return [url.standardizedFileURL.path]
        case .everywhere:
            if !AppSettings.searchPreferUserFolders {
                if AppSettings.searchIncludeSystemLocations {
                    return [NSMetadataQueryUserHomeScope, NSMetadataQueryLocalComputerScope]
                }
                return [NSMetadataQueryUserHomeScope]
            }

            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            var scopePaths: [String] = [home.path]

            let standardSubfolders = [
                "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"
            ]
            for name in standardSubfolders {
                let url = home.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    scopePaths.append(url.path)
                }
            }

            if let bookmarkData = UserDefaults.standard.data(forKey: "helm.bookmarks"),
               let bookmarkURLs = try? JSONDecoder().decode([URL].self, from: bookmarkData) {
                for url in bookmarkURLs {
                    scopePaths.append(url.standardizedFileURL.path)
                }
            }

            let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsBrowsableKey]
            if let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) {
                for volume in mounted {
                    let values = try? volume.resourceValues(forKeys: Set(keys))
                    if values?.volumeIsRemovable == true, values?.volumeIsBrowsable != false {
                        scopePaths.append(volume.path)
                    }
                }
            }

            if AppSettings.searchIncludeSystemLocations {
                scopePaths.append(NSMetadataQueryLocalComputerScope)
            }

            var dedupedPaths: [String] = []
            var seenPaths: Set<String> = []
            for path in scopePaths {
                let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
                if seenPaths.insert(standardized).inserted {
                    dedupedPaths.append(standardized)
                }
            }
            return dedupedPaths
        }
    }

    private func processResults(
        _ query: NSMetadataQuery,
        queryText: String,
        scope: SearchScope,
        activeDirectoryURL: URL?,
        starredService: StarredFilesService?
    ) -> [FileItem] {
        query.disableUpdates()
        defer { query.enableUpdates() }

        let hardCap = max(AppSettings.searchResultLimit * 3, 450)
        let count = min(query.resultCount, hardCap)

        var rawItems: [FileItem] = []
        rawItems.reserveCapacity(count)
        var seenPaths: Set<String> = []

        for index in 0..<count {
            guard let result = query.result(at: index) as? NSMetadataItem,
                  let path = result.value(forAttribute: NSMetadataItemPathKey) as? String else {
                continue
            }
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seenPaths.insert(normalizedPath).inserted else { continue }

            let url = URL(fileURLWithPath: normalizedPath)
            if let item = try? FileItem.from(url: url, starredService: starredService) {
                rawItems.append(item)
            }
        }

        let activePath = activeDirectoryURL?.standardizedFileURL.path
        return Self.rank(rawItems, queryText: queryText, scope: scope, activeDirectoryPath: activePath)
            .prefix(AppSettings.searchResultLimit)
            .map { $0 }
    }

    nonisolated private static func rank(
        _ items: [FileItem],
        queryText: String,
        scope: SearchScope,
        activeDirectoryPath: String?
    ) -> [FileItem] {
        let normalizedQuery = queryText.lowercased()
        let queryTokens = normalizedQuery
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path.lowercased()
        let preferredRoots = preferredRootPaths(in: homePath)
        let bookmarks = bookmarkPaths()

        let scored = items.map { item in
            (item, score(
                item,
                query: normalizedQuery,
                queryTokens: queryTokens,
                homePath: homePath,
                preferredRoots: preferredRoots,
                bookmarks: bookmarks,
                activeDirectoryPath: activeDirectoryPath,
                scope: scope
            ))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.modificationDate != rhs.0.modificationDate {
                    return lhs.0.modificationDate > rhs.0.modificationDate
                }
                return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    nonisolated private static func preferredRootPaths(in homePath: String) -> [String] {
        let standard: [String] = [
            "documents", "desktop", "downloads", "projects", "work",
            "pictures", "movies", "music", "developer", "sites",
            "code", "coding", "applications", "public"
        ]

        var roots = standard.map { "\(homePath)/\($0)" }

        // Auto-discover custom top-level user directories (non-hidden, non-Library)
        let homeURL = URL(fileURLWithPath: homePath)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: homeURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) {
            let standardNames = Set(standard)
            let excludedNames: Set<String> = ["library", ".trash"]
            for entry in entries {
                let name = entry.lastPathComponent.lowercased()
                guard !standardNames.contains(name),
                      !excludedNames.contains(name),
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }
                roots.append(entry.path.lowercased())
            }
        }

        return roots
    }

    nonisolated private static func bookmarkPaths() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: "helm.bookmarks"),
              let urls = try? JSONDecoder().decode([URL].self, from: data) else {
            return []
        }
        return urls.map { $0.standardizedFileURL.path.lowercased() }
    }

    nonisolated private static func score(
        _ item: FileItem,
        query: String,
        queryTokens: [String],
        homePath: String,
        preferredRoots: [String],
        bookmarks: [String],
        activeDirectoryPath: String?,
        scope: SearchScope
    ) -> Int {
        let lowercaseName = item.name.lowercased()
        let lowercasePath = item.url.path.lowercased()
        var total = 0

        if lowercaseName == query {
            total += 1200
        } else if lowercaseName.hasPrefix(query) {
            total += 800
        } else if lowercaseName.contains(query) {
            total += 500
        }

        for token in queryTokens where lowercaseName.contains(token) {
            total += 100
        }

        let inPreferred = isInPreferredRoots(path: lowercasePath, preferredRoots: preferredRoots)
        if inPreferred {
            total += 380

            // Depth-based scoring: shallower items in preferred roots rank higher.
            let homeComponents = homePath.split(separator: "/").count
            let itemComponents = lowercasePath.split(separator: "/").count
            let relativeDepth = max(0, itemComponents - homeComponents - 1)
            let depthBonus = max(0, 150 - relativeDepth * 30)
            total += depthBonus
        } else if isInUserContent(path: lowercasePath, homePath: homePath) {
            total += 220
        }

        // Boost for files inside bookmarked folders
        if bookmarks.contains(where: { lowercasePath.hasPrefix($0 + "/") || lowercasePath == $0 }) {
            total += 300
        }

        // Boost for files in or near the user's currently browsed directory
        if let activePath = activeDirectoryPath {
            let activePathLower = activePath.lowercased()
            if lowercasePath.hasPrefix(activePathLower + "/") {
                total += 200
            }
        }

        if item.isDirectory {
            total += 80
        }

        if isDocumentLike(item: item) {
            total += 140
        }

        if item.isHidden {
            total -= 280
        }

        if isSystemLike(path: lowercasePath), !AppSettings.searchIncludeSystemLocations {
            total -= 650
        }

        // Favor recent files/folders.
        let age = Date().timeIntervalSince(item.modificationDate)
        if age < 24 * 3600 {
            total += 90
        } else if age < 7 * 24 * 3600 {
            total += 55
        } else if age < 30 * 24 * 3600 {
            total += 25
        }

        // Avoid heavily demoting results when the user explicitly searches inside a folder.
        if case .currentFolder = scope {
            total += 40
        }

        return total
    }

    nonisolated private static func isInPreferredRoots(path: String, preferredRoots: [String]) -> Bool {
        preferredRoots.contains { root in
            path == root || path.hasPrefix("\(root)/")
        }
    }

    nonisolated private static func isInUserContent(path: String, homePath: String) -> Bool {
        guard path == homePath || path.hasPrefix("\(homePath)/") else { return false }
        return !path.hasPrefix("\(homePath)/library/")
    }

    nonisolated private static func isSystemLike(path: String) -> Bool {
        systemPathPrefixes.contains { path.hasPrefix($0) }
    }

    nonisolated private static func isDocumentLike(item: FileItem) -> Bool {
        if let type = item.contentType {
            if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .image) || type.conforms(to: .audiovisualContent) {
                return true
            }
        }

        let ext = item.url.pathExtension.lowercased()
        let commonDocExtensions: Set<String> = [
            "txt", "md", "rtf", "pdf",
            "doc", "docx", "odt", "pages",
            "xls", "xlsx", "numbers",
            "ppt", "pptx", "key",
            "csv", "json", "yaml", "yml", "xml"
        ]
        return commonDocExtensions.contains(ext)
    }

    #if DEBUG
    nonisolated static func debugRank(items: [FileItem], queryText: String, scope: SearchScope, activeDirectoryPath: String? = nil) -> [FileItem] {
        rank(items, queryText: queryText, scope: scope, activeDirectoryPath: activeDirectoryPath)
    }
    #endif
}
