import Foundation
import UniformTypeIdentifiers

actor FileSystemService {

    private let fileManager = FileManager.default
    private struct DirectoryCacheKey: Hashable {
        let path: String
        let showHidden: Bool
    }
    private struct DirectoryCacheEntry {
        let timestamp: Date
        let items: [FileItem]
    }
    private var directoryCache: [DirectoryCacheKey: DirectoryCacheEntry] = [:]

    func contentsOfDirectory(
        at url: URL,
        showHidden: Bool = false,
        starredService: StarredFilesService? = nil,
        useCache: Bool = true
    ) async throws -> [FileItem] {
        let standardizedURL = url.standardizedFileURL
        let cacheKey = DirectoryCacheKey(path: standardizedURL.path, showHidden: showHidden)
        if useCache,
           AppSettings.directoryCacheEnabled,
           let entry = directoryCache[cacheKey],
           Date().timeIntervalSince(entry.timestamp) <= AppSettings.directoryCacheTTL {
            return applyStarState(entry.items, starredService: starredService)
        }

        let resourceKeys = Array(FileItem.prefetchKeys)

        let urls = try fileManager.contentsOfDirectory(
            at: standardizedURL,
            includingPropertiesForKeys: resourceKeys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)

        for fileURL in urls {
            do {
                let item = try FileItem.from(url: fileURL, starredService: starredService)
                items.append(item)
            } catch {
                // Skip files we can't read (permission denied, etc.)
                continue
            }
        }

        if AppSettings.directoryCacheEnabled {
            directoryCache[cacheKey] = DirectoryCacheEntry(timestamp: Date(), items: items)
            pruneCacheIfNeeded()
        }

        return applyStarState(items, starredService: starredService)
    }

    func fileItem(at url: URL, starredService: StarredFilesService? = nil) async throws -> FileItem {
        try FileItem.from(url: url, starredService: starredService)
    }

    func exists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func parentDirectory(of url: URL) -> URL {
        url.deletingLastPathComponent()
    }

    func invalidateDirectoryCache(at url: URL) {
        let path = url.standardizedFileURL.path
        directoryCache = directoryCache.filter { key, _ in
            key.path != path
        }
    }

    func clearCache() {
        directoryCache.removeAll()
    }

    func volumeInfo(for url: URL) throws -> (totalCapacity: Int64, availableCapacity: Int64) {
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        return (total, available)
    }

    private func applyStarState(_ items: [FileItem], starredService: StarredFilesService?) -> [FileItem] {
        guard let starredService else { return items }
        return items.map { item in
            var updated = item
            updated.isStarred = starredService.isStarred(url: item.url)
            return updated
        }
    }

    private func pruneCacheIfNeeded() {
        let maxEntries = 80
        guard directoryCache.count > maxEntries else { return }
        let sorted = directoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
        let overflow = directoryCache.count - maxEntries
        for index in 0..<overflow {
            directoryCache.removeValue(forKey: sorted[index].key)
        }
    }
}
