import Foundation
import HelmCore

/// What AI mode may learn about a disk, read through any `FileSystem`: names and details, never contents.
/// Every method runs with downloads off, so a cloud file is never downloaded and a cloud folder is never loaded to
/// answer; what would need that comes back marked instead. Each answer comes within its time limit or not at all:
/// a call stuck on a server is abandoned, since a call in the kernel can't be stopped.
public struct FileSystemAgentDisk: AgentDisk {
    /// How long a single question may take before it has no answer.
    static let answerSeconds: Double = 2

    private let fileSystem: any FileSystem
    private let storage: any StorageFactsReading
    private let home: String
    private let canonical: @Sendable (String) -> String?
    /// Where `canonical` runs: its own lanes, so the thread it runs on has downloads off and a stuck call is given up on.
    private let lanes = IOExecutor(timeout: FileSystemAgentDisk.answerSeconds)

    /// `canonical` resolves every link in a path, as realpath does; tests over a disk in memory pass their own.
    public init(fileSystem: any FileSystem, storage: any StorageFactsReading, home: String,
                canonical: @escaping @Sendable (String) -> String? = { CanonicalPath.realPath($0) }) {
        self.fileSystem = fileSystem; self.storage = storage; self.home = home; self.canonical = canonical
    }

    /// A link in an allowed place that leads out of the allowed places is not resolved: its target is the answer,
    /// as text, so the scope gate refuses it by its place and nothing under /net is ever asked about.
    public func canonicalPath(_ path: String) async -> String? {
        await DatalessGuard.off {
            let canonical = self.canonical, fileSystem = self.fileSystem, lanes = self.lanes, home = self.home
            let lane = SystemStorageFactsReader.lane(of: path, home: home)
            // One limit for the whole question: resolving the path and then seeing what it names.
            let found = await Self.answer(idleSeconds: Self.answerSeconds) { _ -> String? in
                let answer = try? await lanes.runRead(volume: lane, { () -> Resolution in
                    let homes = [home] + [CanonicalPath.realPath(home)].compactMap { $0 }
                    let leaving = CanonicalPath.linkLeaving(path) { place in
                        homes.contains { AgentItemFilter.area(ofPath: place, home: $0) != .refused }
                    }
                    if let leaving { return .leaves(leaving) }
                    return canonical(path).map(Resolution.resolved) ?? .missing
                })
                switch answer {
                case .leaves(let target)?: return target
                case .resolved(let resolved)?:
                    // The answer names something the file system can see, and nothing else.
                    return await fileSystem.exists(URL(fileURLWithPath: resolved)) ? resolved : nil
                case .missing?, nil: return nil
                }
            }
            return found ?? nil
        }
    }

    /// What resolving a path came to.
    private enum Resolution: Sendable { case resolved(String), leaves(String), missing }

    public func item(at path: String) async -> AgentDiskItem? {
        await DatalessGuard.off {
            let url = URL(fileURLWithPath: path), fileSystem = self.fileSystem
            let found = await Self.answer(idleSeconds: Self.answerSeconds) { _ in await Self.entry(at: url, in: fileSystem) }
            switch found {
            case .success(let entry)?: return Self.item(entry, path: path)
            case .failure(.notDownloaded)?:
                // macOS wouldn't describe it without fetching it: it is in a cloud and not on this Mac.
                return AgentDiskItem(path: path, name: url.lastPathComponent, kind: .other, identity: nil, isDataless: true)
            default: return nil
            }
        }
    }

    public func list(_ folder: String, limit: Int, idleSeconds: Double) async -> AgentDiskListing {
        await DatalessGuard.off {
            let skipped = DatalessGuard.SkippedChildren()
            let listed = await Self.answer(idleSeconds: idleSeconds) { progress in
                await DatalessGuard.$skippedChildren.withValue(skipped) { await self.read(folder, limit: limit, progress: progress) }
            }
            guard var listing = listed else { return AgentDiskListing(items: [], state: .slow) }
            if listing.state == .ok, skipped.count > 0 {
                listing = AgentDiskListing(items: listing.items, more: listing.more, unreadable: skipped.count)
            }
            return listing
        }
    }

    public func storage(of folder: String) async -> StorageFacts {
        await DatalessGuard.off {
            let storage = self.storage
            let facts = await Self.answer(idleSeconds: Self.answerSeconds + 0.5) { _ in
                await storage.facts(for: URL(fileURLWithPath: folder, isDirectory: true))
            }
            return facts ?? StorageClassifier.classify(path: folder, home: home, probe: StorageProbe(timedOut: true))
        }
    }

    // MARK: Listing

    /// The folder's own names, sorted, `limit` at most. A link is never listed through, a folder that isn't loaded is
    /// never listed, and names a model may not see are left out before the limit is applied.
    private func read(_ folder: String, limit: Int, progress: @escaping @Sendable () -> Void) async -> AgentDiskListing {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let own: FileEntry
        switch await Self.entry(at: url, in: fileSystem) {
        case .success(let entry): own = entry
        case .failure(let error): return AgentDiskListing(items: [], state: Self.state(for: error))
        }
        guard own.kind == .directory || own.kind == .package else { return AgentDiskListing(items: [], state: .gone) }
        if own.cloudAvailability == .evicted { return AgentDiskListing(items: [], state: .notLoaded) }
        progress()
        var entries: [FileEntry] = []
        do {
            for try await batch in fileSystem.enumerate(url, options: EnumerationOptions(includeHidden: true, resolveSymlinkTargets: false)) {
                entries.append(contentsOf: batch)
                progress()
            }
        } catch {
            return AgentDiskListing(items: [], state: Self.state(for: FileSystemError.mapping(error)))
        }
        let shown = entries.filter { AgentItemFilter.isListable(name: $0.name, isHidden: $0.isHidden) }
            .sorted { Self.comesFirst($0.name, $1.name) }
        let kept = Array(shown.prefix(max(0, limit)))
        var items: [AgentDiskItem] = []
        var places = ChildPlaces(folder: url, storage: storage, home: home)
        for entry in kept {
            let path = url.appendingPathComponent(entry.name).path
            let place = entry.kind == .directory ? await places.differing(child: path) : nil
            items.append(Self.item(entry, path: path, place: place))
            progress()
        }
        return AgentDiskListing(items: items, more: shown.count - kept.count)
    }

    /// The places of a listing's child folders, read only for the few children that can be somewhere else.
    private struct ChildPlaces {
        let folder: URL
        let storage: any StorageFactsReading
        let home: String
        private var mirrors: [String: String]?
        private var listed: StorageFacts?
        init(folder: URL, storage: any StorageFactsReading, home: String) {
            self.folder = folder; self.storage = storage; self.home = home
        }
        /// The child's facts when its place isn't the listed folder's; nil when it is.
        mutating func differing(child: String) async -> StorageFacts? {
            let mirrors = await currentMirrors()
            guard StorageClassifier.mayDiffer(child: child, home: home, mirrors: mirrors) else { return nil }
            let own = await storage.facts(for: URL(fileURLWithPath: child, isDirectory: true))
            let listed = await listedFacts()
            return own.placeKey == listed.placeKey ? nil : own
        }
        private mutating func currentMirrors() async -> [String: String] {
            if let mirrors { return mirrors }
            let read = await storage.mirrors()
            mirrors = read
            return read
        }
        private mutating func listedFacts() async -> StorageFacts {
            if let listed { return listed }
            let read = await storage.facts(for: folder)
            listed = read
            return read
        }
    }

    // MARK: Reading one item

    /// The item itself. Where a link points is never looked at, so a link into a server that stopped answering, or
    /// into a place macOS mounts on demand, costs nothing.
    private static func entry(at url: URL, in fileSystem: any FileSystem) async -> Result<FileEntry, FileSystemError> {
        do {
            if let unfollowing = fileSystem as? any StorageLinkEntryReading {
                return .success(try await unfollowing.entry(at: url, resolveSymlinkTargets: false))
            }
            return .success(try await fileSystem.entry(at: url))
        } catch { return .failure(FileSystemError.mapping(error)) }
    }

    /// A link reads as a link whatever it points at, as it does in a listing.
    private static func item(_ entry: FileEntry, path: String, place: StorageFacts? = nil) -> AgentDiskItem {
        let isLink = entry.kind == .symlinkToFile || entry.kind == .symlinkToDirectory || entry.kind == .danglingSymlink
        return AgentDiskItem(path: path, name: entry.name, kind: isLink ? .danglingSymlink : entry.kind,
                             identity: entry.objectIdentity, size: entry.size,
                             modified: entry.modificationDate, created: entry.creationDate,
                             typeIdentifier: entry.contentTypeIdentifier,
                             isHidden: entry.isHidden, isDataless: entry.cloudAvailability == .evicted, place: place)
    }

    private static func state(for error: FileSystemError) -> AgentDiskListState {
        switch error {
        case .notFound: return .gone
        case .timedOut: return .slow
        case .notDownloaded: return .notLoaded
        default: return .denied
        }
    }

    /// Names in the order a listing gives them: without regard to case, a run of digits by its value, the same on
    /// every Mac whatever its language.
    private static func comesFirst(_ name: String, _ other: String) -> Bool {
        switch name.compare(other, options: [.caseInsensitive, .numeric], range: nil, locale: nil) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return name < other
        }
    }

    // MARK: Waiting

    /// Runs `work` and waits for it until it finishes, or until it has gone `idleSeconds` without calling the progress
    /// closure it is handed; then the answer is nil and `work` is cancelled and left to finish on its own. The work
    /// runs in a task that carries this task's marks, downloads off included.
    static func answer<T: Sendable>(idleSeconds: Double,
                                    _ work: @escaping @Sendable (@escaping @Sendable () -> Void) async -> T) async -> T? {
        let race = AnswerRace<T>(idleSeconds: idleSeconds)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.wait(continuation)
                let worker = Task { race.finish(await work { race.touch() }) }
                race.watch(worker)
            }
        } onCancel: { race.finish(nil) }
    }

    /// One answer, from the work or from the clock, whichever comes first.
    private final class AnswerRace<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let idleSeconds: Double
        private var continuation: CheckedContinuation<T?, Never>?
        private var result: T??
        private var lastProgress = DispatchTime.now().uptimeNanoseconds
        private var worker: Task<Void, Never>?

        init(idleSeconds: Double) { self.idleSeconds = max(0.001, idleSeconds) }

        func wait(_ continuation: CheckedContinuation<T?, Never>) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(returning: result); return }
            self.continuation = continuation
            lock.unlock()
        }
        func touch() {
            lock.lock(); lastProgress = DispatchTime.now().uptimeNanoseconds; lock.unlock()
        }
        func finish(_ value: T?) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = .some(value)
            let continuation = self.continuation, worker = self.worker
            self.continuation = nil; self.worker = nil
            lock.unlock()
            if value == nil { worker?.cancel() }
            continuation?.resume(returning: value)
        }
        /// Gives up on `worker` once it has been idle too long.
        func watch(_ worker: Task<Void, Never>) {
            lock.lock()
            let done = result != nil
            if !done { self.worker = worker }
            lock.unlock()
            if done { return }
            Task.detached { [self] in
                while let idle = self.idle() {
                    if idle >= self.idleSeconds { self.finish(nil); return }
                    try? await Task.sleep(nanoseconds: UInt64((self.idleSeconds - idle) * 1_000_000_000) + 1_000_000)
                }
            }
        }
        /// Seconds since the last progress, or nil once there is an answer.
        private func idle() -> Double? {
            lock.lock(); defer { lock.unlock() }
            guard result == nil else { return nil }
            return Double(DispatchTime.now().uptimeNanoseconds - lastProgress) / 1_000_000_000
        }
    }
}

/// A file system that can describe the item at a path without looking at where a link there points.
protocol StorageLinkEntryReading: FileSystem {
    func entry(at url: URL, resolveSymlinkTargets: Bool) async throws -> FileEntry
}
