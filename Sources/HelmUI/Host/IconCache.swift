#if os(macOS)
import AppKit
import HelmCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Icons without disk work on the main thread (F-035). A type icon shows at once, then the file's real
/// icon or thumbnail replaces it. At most four loads run together, newest first (OK1-12).
@MainActor public final class IconCache {
    private struct Key: Hashable { let path: String; let stamp: Date; let size: Int64; let pixels: Int }
    private let images = NSCache<NSString, NSImage>()
    private var inFlight: [Key: [(NSImage) -> Void]] = [:]
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "helm.icons"; queue.maxConcurrentOperationCount = 4; queue.qualityOfService = .userInitiated
        return queue
    }()
    private var typeIcons: [String: NSImage] = [:]

    public init(limit: Int = 2000) { images.countLimit = limit }

    /// The immediate image, needing no disk access.
    public func placeholder(for entry: FileEntry) -> NSImage {
        let key: String
        switch entry.kind {
        case .directory, .symlinkToDirectory: key = "public.folder"
        default: key = entry.contentTypeIdentifier ?? "public.data"
        }
        if let cached = typeIcons[key] { return cached }
        let type = UTType(key) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        typeIcons[key] = image
        return image
    }

    /// Calls `deliver` with the file's own icon, or a thumbnail if `thumbnails` is on, unless it's already the image.
    public func load(for entry: FileEntry, pixels: Int, thumbnails: Bool, deliver: @escaping (NSImage) -> Void) {
        let key = Key(path: entry.url.path, stamp: entry.modificationDate, size: entry.size, pixels: pixels)
        let cacheKey = "\(key.path)|\(key.stamp.timeIntervalSince1970)|\(key.size)|\(key.pixels)" as NSString
        if let cached = images.object(forKey: cacheKey) { deliver(cached); return }
        if inFlight[key] != nil { inFlight[key]?.append(deliver); return }
        inFlight[key] = [deliver]
        let url = entry.url
        queue.addOperation { [weak self] in
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: pixels, height: pixels)
            Task { @MainActor [weak self] in self?.finish(key, cacheKey: cacheKey, image: icon) }
        }
        guard thumbnails, Self.wantsThumbnail(entry) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixels, height: pixels), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor [weak self] in self?.replace(cacheKey: cacheKey, image: image, deliver: deliver) }
        }
    }

    private func finish(_ key: Key, cacheKey: NSString, image: NSImage) {
        if images.object(forKey: cacheKey) == nil { images.setObject(image, forKey: cacheKey) }
        let waiting = inFlight.removeValue(forKey: key) ?? []
        let chosen = images.object(forKey: cacheKey) ?? image
        for deliver in waiting { deliver(chosen) }
    }
    private func replace(cacheKey: NSString, image: NSImage, deliver: @escaping (NSImage) -> Void) {
        images.setObject(image, forKey: cacheKey)
        deliver(image)
    }

    private static func wantsThumbnail(_ entry: FileEntry) -> Bool {
        guard entry.kind == .regular, entry.cloudAvailability != .evicted,
              let identifier = entry.contentTypeIdentifier, let type = UTType(identifier) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }
}
#endif
