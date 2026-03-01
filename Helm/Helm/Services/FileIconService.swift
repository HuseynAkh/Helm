import AppKit
import Foundation

@MainActor
final class FileIconService {
    static let shared = FileIconService()

    private let cache = NSCache<NSString, NSImage>()
    private var cachedLimit = 0

    private init() {}

    func icon(for filePath: String, size: NSSize) -> NSImage {
        refreshLimitIfNeeded()
        let sizeKey = "\(Int(size.width))x\(Int(size.height))"
        let cacheKey = "\(filePath)#\(sizeKey)" as NSString

        if let image = cache.object(forKey: cacheKey) {
            return image
        }

        let icon = NSWorkspace.shared.icon(forFile: filePath)
        icon.size = size
        cache.setObject(icon, forKey: cacheKey)
        return icon
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    private func refreshLimitIfNeeded() {
        let newLimit = AppSettings.maxCachedIcons
        guard newLimit != cachedLimit else { return }
        cachedLimit = newLimit
        cache.countLimit = newLimit
    }
}
