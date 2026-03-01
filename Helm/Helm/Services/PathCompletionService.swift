import Foundation
import AppKit

/// A single path completion suggestion.
struct PathCompletionItem {
    let name: String
    let fullPath: String
    let isDirectory: Bool
    let icon: NSImage
}

/// Async actor for lightweight directory enumeration with caching,
/// used by BreadcrumbBar's predictive typing feature.
actor PathCompletionService {

    struct CompletionResult {
        let items: [PathCompletionItem]
        let parentPath: String
        let prefix: String
    }

    private struct CacheEntry {
        let timestamp: Date
        let entries: [(name: String, isDirectory: Bool, path: String)]
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 3.0
    private let maxCacheEntries = 30
    private let maxResults = 50

    // MARK: - Public API

    func completions(for partialPath: String, showHidden: Bool = false) async -> CompletionResult {
        let expanded = NSString(string: partialPath).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expanded)

        let parent: URL
        let prefix: String

        if expanded.hasSuffix("/") {
            parent = fileURL
            prefix = ""
        } else {
            parent = fileURL.deletingLastPathComponent()
            prefix = fileURL.lastPathComponent
        }

        let parentPath = parent.path
        let cacheKey = "\(parentPath)|\(showHidden)"

        // Check cache
        let directoryEntries: [(name: String, isDirectory: Bool, path: String)]
        if let cached = cache[cacheKey], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            directoryEntries = cached.entries
        } else {
            directoryEntries = enumerateDirectory(at: parent, showHidden: showHidden)
            cache[cacheKey] = CacheEntry(timestamp: Date(), entries: directoryEntries)
            pruneCache()
        }

        guard !Task.isCancelled else {
            return CompletionResult(items: [], parentPath: parentPath, prefix: prefix)
        }

        // Filter by prefix
        let filtered: [(name: String, isDirectory: Bool, path: String)]
        if prefix.isEmpty {
            filtered = directoryEntries
        } else {
            filtered = directoryEntries.filter { entry in
                entry.name.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
            }
        }

        // Sort: directories first, then alphabetical
        let sorted = filtered.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        // Cap results
        let capped = Array(sorted.prefix(maxResults))

        // Build items — icons must be created on main thread, use generic ones here
        let items = await MainActor.run {
            capped.map { entry in
                let icon: NSImage
                if entry.isDirectory {
                    icon = NSWorkspace.shared.icon(forFile: entry.path)
                } else {
                    icon = NSWorkspace.shared.icon(forFile: entry.path)
                }
                icon.size = NSSize(width: 16, height: 16)
                return PathCompletionItem(
                    name: entry.name,
                    fullPath: entry.isDirectory ? "\(entry.path)/" : entry.path,
                    isDirectory: entry.isDirectory,
                    icon: icon
                )
            }
        }

        return CompletionResult(items: items, parentPath: parentPath, prefix: prefix)
    }

    func invalidateCache(for directoryPath: String) {
        cache = cache.filter { !$0.key.hasPrefix(directoryPath) }
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func enumerateDirectory(
        at url: URL,
        showHidden: Bool
    ) -> [(name: String, isDirectory: Bool, path: String)] {
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHidden {
            options.insert(.skipsHiddenFiles)
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ) else {
            return []
        }

        return contents.compactMap { fileURL in
            let name = fileURL.lastPathComponent
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return (name: name, isDirectory: isDir, path: fileURL.path)
        }
    }

    private func pruneCache() {
        guard cache.count > maxCacheEntries else { return }
        let sorted = cache.sorted { $0.value.timestamp < $1.value.timestamp }
        let toRemove = sorted.prefix(cache.count - maxCacheEntries)
        for (key, _) in toRemove {
            cache.removeValue(forKey: key)
        }
    }
}
