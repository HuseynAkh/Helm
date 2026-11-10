#if os(macOS)
import AppKit
import HelmCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One step of a file's preview: Quick Look's quick one, its full one (nil when it can't make one), or word that
/// the request was stopped first, which says nothing about the file.
enum PreviewStep { case quick(NSImage?), full(NSImage?), stopped }

/// Where previews come from: Quick Look in the app, a stand-in in tests.
@MainActor protocol PreviewSource: AnyObject {
    /// Starts on one file's previews at `size` points and `scale` pixels to the point. `update` hears each step on
    /// the main actor. What's returned stops the request.
    func start(_ url: URL, size: NSSize, scale: CGFloat, iconMode: Bool,
               update: @escaping @MainActor (PreviewStep) -> Void) -> () -> Void
}

/// Quick Look's quick preview, then its full one.
@MainActor final class QuickLookPreviews: PreviewSource {
    func start(_ url: URL, size: NSSize, scale: CGFloat, iconMode: Bool,
               update: @escaping @MainActor (PreviewStep) -> Void) -> () -> Void {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale,
                                                   representationTypes: [.lowQualityThumbnail, .thumbnail])
        request.iconMode = iconMode
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { representation, type, error in
            let image = representation?.nsImage
            // A stopped request answers once more, as a full preview with no image and this error.
            let stopped = (error as? QLThumbnailError)?.code == .requestCancelled
            let step: PreviewStep = stopped ? .stopped : type == .thumbnail ? .full(image) : .quick(image)
            Task { @MainActor in update(step) }
        }
        return { QLThumbnailGenerator.shared.cancel(request) }
    }
}

/// Icons and previews without disk work on the main thread (F-035).
///
/// A type icon shows at once, then the file's own icon, then Quick Look's quick preview, then its full preview,
/// each at the size shown and the screen's real pixel density. A better image is never replaced by a worse one,
/// and a size already in memory stands in while a new size loads, so zooming doesn't flash generic icons.
/// File icons load four at a time (OK1-12). A cell that scrolls away cancels what it asked for. Once no cell wants a
/// file, its preview stops at the end of that turn of the run loop, so a reload that only moves the file to another
/// cell keeps the preview going instead of starting it again.
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
    /// One load in progress, shared by every cell showing that file at that size. What it starts reports back with
    /// its number, so a load that was given up can't finish the one that took its place.
    private final class Load {
        let number: Int
        var waiters: [UUID: (NSImage) -> Void] = [:]
        var iconDone = false
        var previewDone = true
        var stopPreview: (() -> Void)?
        /// Whether this file can have a preview at all. If it can, an icon is only final once Quick Look answered.
        var canPreview = false
        /// Whether Quick Look gave its answer, a preview or none. A request stopped first gave no answer.
        var answered = false
        init(number: Int) { self.number = number }
        var finished: Bool { iconDone && previewDone }
        var conclusive: Bool { finished && (answered || !canPreview) }
    }
    /// What a cell holds so it can cancel when it's reused.
    struct Ticket: Hashable { fileprivate let key: Key; fileprivate let id: UUID }

    private let icons = NSCache<NSString, Stored>()
    private let previews = NSCache<NSString, Stored>()
    private var loads: [Key: Load] = [:]
    private var loadsStarted = 0
    /// The newest cached key for each file version, used as a stand-in at other sizes.
    private var latest: [String: Key] = [:]
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "helm.icons"; queue.maxConcurrentOperationCount = 4; queue.qualityOfService = .userInitiated
        return queue
    }()
    private var typeIcons: [String: NSImage] = [:]
    private let previewSource: PreviewSource

    /// `limit` caps file icons in memory and `previewLimit` caps previews (`helm.maxCachedIcons`, `helm.maxCachedThumbnails`).
    public convenience init(limit: Int = 2000, previewLimit: Int = 400) {
        self.init(limit: limit, previewLimit: previewLimit, previewSource: QuickLookPreviews())
    }
    /// Tests pass a stand-in for Quick Look.
    init(limit: Int, previewLimit: Int, previewSource: PreviewSource) {
        icons.countLimit = limit; previews.countLimit = previewLimit
        self.previewSource = previewSource
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

    /// A folder macOS keeps private, such as `~/Movies/TV` without media access, still reports that it can be
    /// written and searched, so the system draws it as a write-only drop box: a blank page over a folder.
    /// Finder can read it and shows a plain folder, and so does Helm. Ordinary write-only and locked folders keep
    /// the system's drop-box and no-entry badges.
    static func showsPlainFolder(_ entry: FileEntry) -> Bool { entry.kind == .directory && entry.isPrivacyProtected }

    /// The icon for one item, for Get Info and the Open With chooser, which show a single large image.
    public func icon(for entry: FileEntry) -> NSImage {
        Self.showsPlainFolder(entry) ? placeholder(for: entry) : NSWorkspace.shared.icon(forFile: entry.url.path)
    }

    /// Calls `deliver` each time a better image arrives: the file's icon, then its previews if `previews` is on.
    /// `points` is the size shown and `scale` the window's backing scale factor.
    @discardableResult
    func load(for entry: FileEntry, points: CGFloat, scale: CGFloat, previews wantsPreview: Bool,
                     deliver: @escaping (NSImage) -> Void) -> Ticket? {
        // The cell already shows the plain folder as its placeholder, so there's nothing better to fetch.
        if Self.showsPlainFolder(entry) { return nil }
        let key = Self.key(entry, points: points, scale: scale)
        let preview = wantsPreview && Self.wantsPreview(entry, points: points)
        if let stored = best(for: key) {
            deliver(stored.image)
            if stored.final || (!preview && stored.quality >= .fileIcon) { return nil }
        }
        let id = UUID()
        if let load = loads[key] {
            load.waiters[id] = deliver
            return Ticket(key: key, id: id)
        }
        loadsStarted += 1
        let load = Load(number: loadsStarted)
        load.waiters[id] = deliver
        load.canPreview = Self.wantsPreview(entry, points: points)
        loads[key] = load
        let url = entry.url, size = NSSize(width: key.points, height: key.points), number = load.number
        if best(for: key) != nil { load.iconDone = true } else {
            queue.addOperation { [weak self] in
                // The icon carries every resolution; setting its size in points lets the view pick the sharp one.
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = size
                Task { @MainActor [weak self] in self?.receive(icon, .fileIcon, for: key, from: number, iconDone: true) }
            }
        }
        if preview {
            load.previewDone = false
            // Documents get the page look Finder gives them; pictures and films show edge to edge.
            load.stopPreview = previewSource.start(url, size: size, scale: CGFloat(key.scale) / 100,
                                                   iconMode: !Self.isPicture(entry)) { [weak self] step in
                self?.receive(step, for: key, from: number)
            }
        }
        return Ticket(key: key, id: id)
    }

    /// Stops delivering to a cell that's now showing something else. Once no cell wants the file, its preview is
    /// stopped at the end of this turn of the run loop. A reload puts every file back in a cell within one turn, so
    /// a file that only moved to another cell keeps its preview going.
    func cancel(_ ticket: Ticket?) {
        guard let ticket, let load = loads[ticket.key] else { return }
        load.waiters[ticket.id] = nil
        guard load.waiters.isEmpty else { return }
        let number = load.number
        DispatchQueue.main.async { [weak self] in self?.drop(ticket.key, ifUnwanted: number) }
    }

    /// Ends a load that no cell has asked for again, and stops its preview.
    private func drop(_ key: Key, ifUnwanted number: Int) {
        guard let load = loads[key], load.number == number, load.waiters.isEmpty else { return }
        loads[key] = nil
        if !load.previewDone { load.stopPreview?() }
    }

    private func receive(_ step: PreviewStep, for key: Key, from number: Int) {
        switch step {
        case .quick(let image): if let image { receive(image, .quickPreview, for: key, from: number) }
        case .full(let image): receive(image, .preview, for: key, from: number, previewDone: true, answered: true)
        // A stopped request says nothing about the file, so it doesn't make what's cached final.
        case .stopped: receive(nil, .preview, for: key, from: number, previewDone: true)
        }
    }

    /// What load `number` brought back. A better image is kept and goes to every cell waiting for this file at this
    /// size, whichever load is under way for it now; only load `number` itself is finished by it.
    private func receive(_ image: NSImage?, _ quality: Quality, for key: Key, from number: Int,
                         iconDone: Bool = false, previewDone: Bool = false, answered: Bool = false) {
        let current = loads[key]
        let load = current?.number == number ? current : nil
        if iconDone { load?.iconDone = true }
        if previewDone { load?.previewDone = true }
        if answered { load?.answered = true }
        let conclusive = load?.conclusive ?? false
        if let image, quality > (best(for: key)?.quality ?? .fileIcon) || best(for: key) == nil {
            let stored = Stored(image, quality, final: conclusive || quality == .preview)
            if quality == .fileIcon { icons.setObject(stored, forKey: key.name) } else { previews.setObject(stored, forKey: key.name) }
            latest[key.file] = key
            for deliver in (current?.waiters.values).map(Array.init) ?? [] { deliver(image) }
        } else if conclusive, let cached = best(for: key), !cached.final {
            // Nothing better is coming, so what's cached is the answer.
            let stored = Stored(cached.image, cached.quality, final: true)
            if cached.quality == .fileIcon { icons.setObject(stored, forKey: key.name) } else { previews.setObject(stored, forKey: key.name) }
        }
        if let load, load.finished { loads[key] = nil }
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
    /// Below this size a page of text can't be read, so a text file's preview is just a white rectangle.
    /// List rows show such files with their type's icon instead, as Finder's list does; pictures still preview.
    static let smallestTextPreview: CGFloat = 40

    static func wantsPreview(_ entry: FileEntry, points: CGFloat) -> Bool {
        // Quick Look can't read what Helm can't, so an unreadable item keeps its icon.
        guard entry.isReadable, entry.kind == .regular || entry.kind == .package, entry.cloudAvailability != .evicted else { return false }
        if points < smallestTextPreview, let identifier = entry.contentTypeIdentifier, let type = UTType(identifier),
           type.conforms(to: .text) {
            return false
        }
        if entry.kind == .package {
            // Document packages such as Keynote and Pages files have previews; apps and bundles don't.
            guard let identifier = entry.contentTypeIdentifier, let type = UTType(identifier) else { return false }
            return !type.conforms(to: .application) && (type.conforms(to: .content) || !type.conforms(to: .bundle))
        }
        return true
    }
    static func isPicture(_ entry: FileEntry) -> Bool {
        guard let identifier = entry.contentTypeIdentifier, let type = UTType(identifier) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// What `image` is for this file at this size, for tests and scripted runs: "thumbnail" for its full preview,
    /// or "quick preview", "file icon", "type icon", "another image" or "no image".
    func describe(_ image: NSImage?, for entry: FileEntry, points: CGFloat, scale: CGFloat) -> String {
        guard let image else { return "no image" }
        let key = Self.key(entry, points: points, scale: scale)
        if let stored = previews.object(forKey: key.name), stored.image === image {
            return stored.quality == .preview ? "thumbnail" : "quick preview"
        }
        if icons.object(forKey: key.name)?.image === image { return "file icon" }
        return typeIcons.values.contains { $0 === image } ? "type icon" : "another image"
    }
    /// For tests: how many files are loading now.
    var loadsForTesting: Int { loads.count }
}
#endif
