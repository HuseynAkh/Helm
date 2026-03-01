import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let cache = NSCache<NSString, NSImage>()
    private let generator = QLThumbnailGenerator.shared
    private var inFlightRequests: [String: QLThumbnailGenerator.Request] = [:]

    private init() {
        cache.countLimit = AppSettings.maxCachedThumbnails
    }

    /// UTTypes that benefit from QuickLook thumbnails.
    private static let thumbnailableTypes: [UTType] = [
        .image, .movie, .video, .pdf,
        .presentation, .spreadsheet,
        .html, .svg
    ]

    /// Returns true if the file type should get a QL thumbnail instead of a generic icon.
    func shouldGenerateThumbnail(for item: FileItem) -> Bool {
        guard !item.isDirectory else { return false }
        guard let contentType = item.contentType else { return false }
        return Self.thumbnailableTypes.contains { contentType.conforms(to: $0) }
    }

    /// Synchronously return a cached thumbnail, or nil if not yet generated.
    func cachedThumbnail(for path: String, size: NSSize) -> NSImage? {
        cache.object(forKey: cacheKey(path: path, size: size) as NSString)
    }

    /// Generate a thumbnail asynchronously. Calls completion on the MainActor.
    /// Returns a cancellation key that can be passed to `cancelRequest(for:)`.
    @discardableResult
    func generateThumbnail(
        for url: URL,
        size: NSSize,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) -> String {
        let key = cacheKey(path: url.path, size: size)

        // Return cached result immediately
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return key
        }

        // Avoid duplicate in-flight requests for the same file+size
        if inFlightRequests[key] != nil {
            return key
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size.width * 2, height: size.height * 2), // @2x for Retina
            scale: 2.0,
            representationTypes: .thumbnail
        )

        inFlightRequests[key] = request

        generator.generateRepresentations(for: request) { [weak self] thumbnail, _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlightRequests.removeValue(forKey: key)

                guard let cgImage = thumbnail?.cgImage else {
                    completion(nil)
                    return
                }

                let nsImage = NSImage(cgImage: cgImage, size: size)
                self.cache.setObject(nsImage, forKey: key as NSString)
                completion(nsImage)
            }
        }

        return key
    }

    /// Cancel a pending thumbnail request.
    func cancelRequest(for key: String) {
        if let request = inFlightRequests.removeValue(forKey: key) {
            generator.cancel(request)
        }
    }

    func clearCache() {
        cache.removeAllObjects()
        for (_, request) in inFlightRequests {
            generator.cancel(request)
        }
        inFlightRequests.removeAll()
    }

    private func cacheKey(path: String, size: NSSize) -> String {
        "\(path)#\(Int(size.width))x\(Int(size.height))"
    }
}
