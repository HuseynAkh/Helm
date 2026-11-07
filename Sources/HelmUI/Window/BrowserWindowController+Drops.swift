#if os(macOS)
import AppKit
import HelmCore
import UniformTypeIdentifiers

/// Where a drop lands. Every drop target in the window (files, sidebar, path, tabs) resolves to one of these,
/// so the cursor badge and what actually happens always agree.
enum WindowDropTarget: Equatable {
    case folder(URL)
    /// Files dropped on an app open in it, as in Finder.
    case application(URL)
    case trash
}

enum FileDrag {
    /// Everything a drop target registers for: files, and files that will be written when dropped (file promises).
    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }
}

extension FileEntry {
    /// An app, which opens what's dropped on it instead of taking it in.
    var isApplicationBundle: Bool {
        guard kind == .package else { return false }
        if let identifier = contentTypeIdentifier, let type = UTType(identifier) { return type.conforms(to: .application) }
        return url.pathExtension == "app"
    }
    /// Folders take files in and apps open them. A document hands the drop to the folder it's in.
    var takesDrops: Bool { isDirectoryLike || isApplicationBundle }
}

extension BrowserWindowController {
    // MARK: Deciding

    /// The operation a drop would do, which is also the badge the pointer shows.
    /// Finder's rules: Option copies, Cmd moves, Option and Cmd make an alias; otherwise copy across volumes and
    /// move within one (Q5). A folder can't go inside itself, and moving something to where it already is isn't offered.
    func dropOperation(_ info: NSDraggingInfo, into destination: WindowDropTarget) -> NSDragOperation {
        let urls = Self.fileURLs(info)
        switch destination {
        case .trash:
            return urls.isEmpty ? [] : .delete
        case .application(let app):
            guard !urls.isEmpty, !urls.contains(where: { Self.isSameOrInside(app, $0) }) else { return [] }
            return applicationOpens(urls, app: app, session: info.draggingSequenceNumber) ? .generic : []
        case .folder(let folder):
            if urls.isEmpty { return Self.filePromises(info).isEmpty ? [] : .copy }
            return dragOperation(from: urls, into: folder)
        }
    }

    func dragOperation(from urls: [URL], into target: URL) -> NSDragOperation {
        if urls.contains(where: { Self.isSameOrInside(target, $0) }) { return [] }
        let flags = NSEvent.modifierFlags
        let operation: NSDragOperation
        if flags.contains(.option), flags.contains(.command) { operation = .link }
        else if flags.contains(.option) { operation = .copy }
        else if flags.contains(.command) { operation = .move }
        else {
            // Decided from paths, so it can't block on a stalled disk.
            let same = urls.allSatisfy { Self.volumeKey($0) == Self.volumeKey(target) }
            operation = same || dependencies.settings.snapshot.string(.crossVolumeDragDefault) == "move" ? .move : .copy
        }
        if operation == .move, urls.allSatisfy({ Self.isSame($0.deletingLastPathComponent(), target) }) { return [] }
        return operation
    }

    // MARK: Doing

    func performDrop(_ info: NSDraggingInfo, into destination: WindowDropTarget) -> Bool {
        springs.cancel()
        let urls = Self.fileURLs(info)
        switch destination {
        case .trash:
            guard !urls.isEmpty else { return false }
            trash(urls); return true
        case .application(let app):
            guard dropOperation(info, into: destination) != [] else { return false }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in self?.show(message: error.localizedDescription) }
            }
            return true
        case .folder(let folder):
            if urls.isEmpty { return receivePromises(Self.filePromises(info), into: folder) }
            return acceptDrop(urls, into: folder)
        }
    }

    func acceptDrop(_ urls: [URL], into target: URL) -> Bool {
        let operation = dragOperation(from: urls, into: target)
        let sources = urls.filter { !Self.isSame($0.deletingLastPathComponent(), target) || operation != .move }
        guard operation != [], !sources.isEmpty else { return false }
        switch operation {
        case .link: makeAliases(of: sources, in: target)
        case .copy: run(.copy(sources: sources, destinationDirectory: target))
        default: run(.move(sources: sources, destinationDirectory: target))
        }
        return true
    }

    /// Option-Cmd drags leave aliases, named as Finder names them.
    private func makeAliases(of urls: [URL], in folder: URL) {
        let fileSystem = dependencies.fileSystem
        Task { @MainActor in
            var made: Set<ItemID> = []
            for url in urls {
                do {
                    let names = try await fileSystem.childNames(of: folder)
                    let name = try UniqueNamer.name(for: url.lastPathComponent + " alias", existingNames: names)
                    let target = folder.appendingPathComponent(name.value)
                    try await fileSystem.createAlias(for: url, at: target)
                    made.insert(ItemID(url: target))
                } catch { show(message: OperationText.describe(error)) }
            }
            if activeTab?.mutationTarget.map({ Self.isSame($0, folder) }) == true {
                store.send(.tab(activeTabID, .refreshSelecting(made)))
            }
        }
    }

    // MARK: File promises: pictures from Photos, attachments from Mail, images from Safari

    /// Promised files are written into a private folder on the destination's volume, then copied in through the
    /// normal operations, so a name that's taken asks first and Undo removes them. The private folder is removed after.
    func receivePromises(_ receivers: [NSFilePromiseReceiver], into folder: URL) -> Bool {
        guard !receivers.isEmpty else { return false }
        let staging: URL
        do {
            staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        } catch {
            show(message: "Couldn’t receive the dropped items: \(error.localizedDescription)"); return false
        }
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileTypes.count) }
        let collector = PromiseCollector(expected: expected) { [weak self] received, failures in
            guard let self else { try? FileManager.default.removeItem(at: staging); return }
            if let failure = failures.first { self.show(message: "Couldn’t receive a dropped item: \(failure.localizedDescription)") }
            guard !received.isEmpty else { try? FileManager.default.removeItem(at: staging); return }
            self.run(.copy(sources: received, destinationDirectory: folder)) { _ in
                try? FileManager.default.removeItem(at: staging)
            }
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: Self.promiseQueue) { url, error in
                collector.add(url, error)
            }
        }
        return true
    }
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "helm.file-promises"; queue.qualityOfService = .userInitiated
        return queue
    }()

    // MARK: Reading the drag

    static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    static func filePromises(_ info: NSDraggingInfo) -> [NSFilePromiseReceiver] {
        info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    /// Whether `app` can open every dropped item, worked out once per drag rather than on every pointer move.
    private func applicationOpens(_ urls: [URL], app: URL, session: Int) -> Bool {
        let key = "\(session)|\(app.path)"
        if let known = appDropAnswers[key] { return known }
        let opens = NSEvent.modifierFlags.contains([.command, .option])
            || urls.allSatisfy { NSWorkspace.shared.urlsForApplications(toOpen: $0).contains { Self.isSame($0, app) } }
        if appDropAnswers.count > 32 { appDropAnswers.removeAll() }
        appDropAnswers[key] = opens
        return opens
    }

    // MARK: Paths

    static func volumeKey(_ url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? "/Volumes/" + parts[2] : "/"
    }
    static func isSame(_ a: URL, _ b: URL) -> Bool { components(a) == components(b) }
    /// Whether `target` is `source` or somewhere inside it.
    static func isSameOrInside(_ target: URL, _ source: URL) -> Bool {
        let inner = components(target), outer = components(source)
        return inner.count >= outer.count && Array(inner.prefix(outer.count)) == outer
    }
    private static func components(_ url: URL) -> [[UInt8]] {
        URL(fileURLWithPath: PathSpelling.standardPath(url)).pathComponents.map(PathSpelling.identity)
    }
}

/// Gathers promised files as they arrive on the promise queue and reports once, on the main actor.
private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var received: [URL] = []
    private var failures: [Error] = []
    private let done: @MainActor ([URL], [Error]) -> Void
    init(expected: Int, done: @escaping @MainActor ([URL], [Error]) -> Void) { remaining = expected; self.done = done }
    func add(_ url: URL, _ error: Error?) {
        lock.lock()
        if let error { failures.append(error) } else { received.append(url) }
        remaining -= 1
        let finished = remaining == 0
        let urls = received, errors = failures
        lock.unlock()
        guard finished else { return }
        let done = self.done
        Task { @MainActor in done(urls, errors) }
    }
}

/// Spring-loaded folders: hold a drag over a folder and it opens, as in Finder and Nautilus.
/// It honours the system's spring-loading switch and delay (System Settings › Accessibility › Pointer Control).
@MainActor final class SpringLoader {
    private var target: AnyHashable?
    private var timer: Timer?
    var open: ((URL) -> Void)?

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "com.apple.springing.enabled") as? Bool ?? true }
    static var delay: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "com.apple.springing.delay")
        return value > 0 ? value : 0.7
    }

    /// Called as the pointer moves over folders. Hovering somewhere new restarts the wait; nil stops it.
    func hover(_ url: URL?) {
        hover(url) { [weak self] in if let url { self?.open?(url) } }
    }
    /// The same wait for anything else that springs open, such as a tab.
    func hover(_ key: AnyHashable?, then action: @escaping () -> Void) {
        guard key != target else { return }
        cancel()
        guard let key, Self.isEnabled else { return }
        target = key
        timer = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.target != nil else { return }
                self.target = nil; self.timer = nil
                action()
            }
        }
    }
    func cancel() {
        timer?.invalidate(); timer = nil; target = nil
    }
}
#endif
