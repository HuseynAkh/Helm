#if os(macOS)
import AppKit
import HelmCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Icons and previews without disk work on the main thread (F-035).
///
/// A type icon shows at once, then the file's own icon, then Quick Look's quick preview, then its full preview,
/// each at the size shown and the screen's real pixel density. A better image is never replaced by a worse one,
/// and a size already in memory stands in while a new size loads, so zooming doesn't flash generic icons.
/// File icons load four at a time (OK1-12). A cell that scrolls away cancels what it asked for.
@MainActor public final class IconCache {
    /// What's asked for: one file, one size in points, one pixel density.
    fileprivate struct Key: Hashable {
        let path: String; let stamp: Date; let size: Int64; let points: Int; let scale: Int
        var name: NSString { "\(path)|\(stamp.timeIntervalSince1970)|\(size)|\(points)@\(scale)" as NSString }
        /// The same file version at any size.
        var file: String { "\(path)|\(stamp.timeIntervalSince1970)|\(size)" }
    }
    private enum Quality: Int, Comparable {
        case fileIcon = 1, quickPreview, preview
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }
    /// A cached image and how good it is. `final` means nothing better can come for it. Boxed for `NSCache`.
    private final class Stored {
        let image: NSImage; let quality: Quality; let final: Bool
        init(_ image: NSImage, _ quality: Quality, final: Bool) { self.image = image; self.quality = quality; self.final = final }
    }
    /// One load in progress, shared by every cell showing that file at that size.
    private final class Load {
        var waiters: [UUID: (NSImage) -> Void] = [:]
        var iconDone = false
        var previewDone = true
        var request: QLThumbnailGenerator.Request?
        /// Whether this file can have a preview at all. If it can, an icon is only final once a preview was tried.
        var canPreview = false
        var finished: Bool { iconDone && previewDone }
        var conclusive: Bool { finished && (request != nil || !canPreview) }
    }
    /// What a cell holds so it can cancel when it's reused.
    struct Ticket: Hashable { fileprivate let key: Key; fileprivate let id: UUID }

    private let icons = NSCache<NSString, Stored>()
    private let previews = NSCache<NSString, Stored>()
    private var loads: [Key: Load] = [:]
    /// The newest cached key for each file version, used as a stand-in at other sizes.
    private var latest: [String: Key] = [:]
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "helm.icons"; queue.maxConcurrentOperationCount = 4; queue.qualityOfService = .userInitiated
        return queue
    }()
    private var typeIcons: [String: NSImage] = [:]

    /// `limit` caps file icons in memory and `previewLimit` caps previews (`helm.maxCachedIcons`, `helm.maxCachedThumbnails`).
    public init(limit: Int = 2000, previewLimit: Int = 400) {
        icons.countLimit = limit; previews.countLimit = previewLimit
    }

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

    /// The best image already in memory for this file at any size, so a cell never starts from a generic icon
    /// when something better is known.
    public func cachedImage(for entry: FileEntry, points: CGFloat, scale: CGFloat) -> NSImage? {
        let key = Self.key(entry, points: points, scale: scale)
        if let stored = best(for: key) { return stored.image }
        if let other = latest[key.file], let stored = best(for: other) { return stored.image }
        return nil
    }

    /// Calls `deliver` each time a better image arrives: the file's icon, then its previews if `previews` is on.
    /// `points` is the size shown and `scale` the window's backing scale factor.
    @discardableResult
    func load(for entry: FileEntry, points: CGFloat, scale: CGFloat, previews wantsPreview: Bool,
                     deliver: @escaping (NSImage) -> Void) -> Ticket? {
        let key = Self.key(entry, points: points, scale: scale)
        let preview = wantsPreview && Self.wantsPreview(entry)
        if let stored = best(for: key) {
            deliver(stored.image)
            if stored.final || (!preview && stored.quality >= .fileIcon) { return nil }
        }
        let id = UUID()
        if let load = loads[key] {
            load.waiters[id] = deliver
            return Ticket(key: key, id: id)
        }
        let load = Load()
        load.waiters[id] = deliver
        load.canPreview = Self.wantsPreview(entry)
        loads[key] = load
        let url = entry.url, size = NSSize(width: key.points, height: key.points)
        if best(for: key) != nil { load.iconDone = true } else {
            queue.addOperation { [weak self] in
                // The icon carries every resolution; setting its size in points lets the view pick the sharp one.
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = size
                Task { @MainActor [weak self] in self?.receive(icon, .fileIcon, for: key, iconDone: true) }
            }
        }
        if preview {
            load.previewDone = false
            let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: CGFloat(key.scale) / 100,
                                                       representationTypes: [.lowQualityThumbnail, .thumbnail])
            // Documents get the page look Finder gives them; pictures and films show edge to edge.
            request.iconMode = !Self.isPicture(entry)
            load.request = request
            QLThumbnailGenerator.shared.generateRepresentations(for: request) { [weak self] representation, type, _ in
                let image = representation?.nsImage
                let done = type == .thumbnail
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let image { self.receive(image, done ? .preview : .quickPreview, for: key, previewDone: done) }
                    else if done { self.receive(nil, .preview, for: key, previewDone: true) }
                }
            }
        }
        return Ticket(key: key, id: id)
    }

    /// Stops delivering to a cell that's now showing something else. The last one out cancels the preview.
    func cancel(_ ticket: Ticket?) {
        guard let ticket, let load = loads[ticket.key] else { return }
        load.waiters[ticket.id] = nil
        guard load.waiters.isEmpty else { return }
        if let request = load.request, !load.previewDone { QLThumbnailGenerator.shared.cancel(request) }
        loads[ticket.key] = nil
    }

    private func receive(_ image: NSImage?, _ quality: Quality, for key: Key, iconDone: Bool = false, previewDone: Bool = false) {
        let load = loads[key]
        if iconDone { load?.iconDone = true }
        if previewDone { load?.previewDone = true }
        let finished = load?.finished ?? true
        let conclusive = load?.conclusive ?? false
        if let image, quality > (best(for: key)?.quality ?? .fileIcon) || best(for: key) == nil {
            let stored = Stored(image, quality, final: conclusive || quality == .preview)
            if quality == .fileIcon { icons.setObject(stored, forKey: key.name) } else { previews.setObject(stored, forKey: key.name) }
            latest[key.file] = key
            for deliver in (load?.waiters.values).map(Array.init) ?? [] { deliver(image) }
        } else if conclusive, let current = best(for: key), !current.final {
            // Nothing better is coming, so what's cached is the answer.
            let stored = Stored(current.image, current.quality, final: true)
            if current.quality == .fileIcon { icons.setObject(stored, forKey: key.name) } else { previews.setObject(stored, forKey: key.name) }
        }
        if finished { loads[key] = nil }
    }

    private func best(for key: Key) -> Stored? {
        let preview = previews.object(forKey: key.name), icon = icons.object(forKey: key.name)
        guard let preview else { return icon }
        guard let icon else { return preview }
        return preview.quality >= icon.quality ? preview : icon
    }

    private static func key(_ entry: FileEntry, points: CGFloat, scale: CGFloat) -> Key {
        Key(path: entry.url.path, stamp: entry.modificationDate, size: entry.size,
            points: max(1, Int(points.rounded())), scale: max(100, Int((scale * 100).rounded())))
    }

    /// Every file with content gets a preview: pictures, films, PDFs, text, office and iWork documents, fonts, 3D.
    /// Folders and apps keep their icons, and a cloud file that isn't downloaded isn't fetched just to preview it.
    private static func wantsPreview(_ entry: FileEntry) -> Bool {
        guard entry.kind == .regular || entry.kind == .package, entry.cloudAvailability != .evicted else { return false }
        if entry.kind == .package {
            // Document packages such as Keynote and Pages files have previews; apps and bundles don't.
            guard let identifier = entry.contentTypeIdentifier, let type = UTType(identifier) else { return false }
            return !type.conforms(to: .application) && (type.conforms(to: .content) || !type.conforms(to: .bundle))
        }
        return true
    }
    private static func isPicture(_ entry: FileEntry) -> Bool {
        guard let identifier = entry.contentTypeIdentifier, let type = UTType(identifier) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }
}
#endif
