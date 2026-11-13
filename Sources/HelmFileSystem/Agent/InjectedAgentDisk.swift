import Foundation
import HelmCore

/// For fixture runs only: a disk that answers as `base` does, plus what a fixture folder can't hold. A file can be
/// marked as not downloaded, a folder as not loaded, and a place as slow to answer. Marks are honoured only at or
/// inside `allowedPrefix`, so a run can't make a folder outside its fixture home look any different.
public final class InjectedAgentDisk: AgentDisk, @unchecked Sendable {
    /// A path's folders, each as the disk compares names, whatever form its accents are written in.
    private typealias Parts = [[UInt8]]

    private let base: any AgentDisk
    private let allowed: Parts
    private let lock = NSLock()
    private var cloudOnly: [Parts] = []
    private var notLoaded: [Parts] = []
    private var delays: [(prefix: Parts, seconds: Double)] = []

    /// A mark or delay outside `allowedPrefix` is ignored.
    public init(base: any AgentDisk, allowedPrefix: String) {
        self.base = base
        allowed = Self.parts(Self.spelled(allowedPrefix))
    }

    /// Marks the file at `path` as kept in a cloud and not downloaded.
    public func markCloudOnly(_ path: String) {
        guard let parts = allowedParts(path) else { return }
        locked { if !cloudOnly.contains(parts) { cloudOnly.append(parts) } }
    }

    /// Marks the folder at `path` as one whose names aren't loaded: listing it answers `notLoaded`.
    public func markNotLoaded(_ path: String) {
        guard let parts = allowedParts(path) else { return }
        locked { if !notLoaded.contains(parts) { notLoaded.append(parts) } }
    }

    /// Makes every question about a path at or inside `prefix` take this long. One that would take longer than its
    /// limit waits out the limit and gets no answer, as a place that stopped responding gives none. Zero takes it away.
    public func setDelay(_ seconds: Double, under prefix: String) {
        guard let parts = allowedParts(prefix) else { return }
        locked {
            delays.removeAll { $0.prefix == parts }
            if seconds > 0 { delays.append((parts, seconds)) }
        }
    }

    /// Forgets every mark and delay.
    public func clear() {
        locked { cloudOnly.removeAll(); notLoaded.removeAll(); delays.removeAll() }
    }

    // MARK: AgentDisk

    public func canonicalPath(_ path: String) async -> String? {
        guard await answers(path, within: FileSystemAgentDisk.answerSeconds) else { return nil }
        return await base.canonicalPath(path)
    }

    public func item(at path: String) async -> AgentDiskItem? {
        guard await answers(path, within: FileSystemAgentDisk.answerSeconds) else { return nil }
        return await base.item(at: path).map(marked)
    }

    public func list(_ folder: String, limit: Int, idleSeconds: Double) async -> AgentDiskListing {
        guard await answers(folder, within: idleSeconds) else { return AgentDiskListing(items: [], state: .slow) }
        let parts = Self.parts(Self.spelled(folder))
        if locked({ notLoaded.contains(parts) }) { return AgentDiskListing(items: [], state: .notLoaded) }
        let listing = await base.list(folder, limit: limit, idleSeconds: idleSeconds)
        return AgentDiskListing(items: listing.items.map(marked), more: listing.more, unreadable: listing.unreadable,
                                state: listing.state)
    }

    public func storage(of folder: String) async -> StorageFacts {
        guard await answers(folder, within: FileSystemAgentDisk.answerSeconds) else {
            return StorageClassifier.classify(path: folder, home: "/", probe: StorageProbe(timedOut: true))
        }
        return await base.storage(of: folder)
    }

    // MARK: Marks

    /// The item as the marks say it is: a marked file isn't downloaded and a marked folder isn't loaded.
    private func marked(_ item: AgentDiskItem) -> AgentDiskItem {
        let parts = Self.parts(Self.spelled(item.path))
        guard !item.isDataless, locked({ cloudOnly.contains(parts) || notLoaded.contains(parts) }) else { return item }
        return AgentDiskItem(path: item.path, name: item.name, kind: item.kind, identity: item.identity, size: item.size,
                             modified: item.modified, created: item.created, typeIdentifier: item.typeIdentifier,
                             isHidden: item.isHidden, isDataless: true, place: item.place)
    }

    /// Waits as long as the path's place takes to answer, and says whether it answered within `limit` seconds.
    private func answers(_ path: String, within limit: Double) async -> Bool {
        let parts = Self.parts(Self.spelled(path))
        let delay = locked { delays.filter { Self.isAt(parts, orInside: $0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.seconds ?? 0 }
        let wait = min(delay, limit)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        return delay <= limit
    }

    /// The parts of a path a mark may be set on, or nil when it lies outside the allowed prefix.
    private func allowedParts(_ path: String) -> Parts? {
        let parts = Self.parts(Self.spelled(CanonicalPath.realPath(path) ?? path))
        return Self.isAt(parts, orInside: allowed) ? parts : nil
    }

    // MARK: Paths, by part

    /// The path as the disk spells it, without reading the disk: "." and ".." worked out, and the folders macOS keeps
    /// under /private named there, so /tmp and /private/tmp are one place.
    private static func spelled(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        let first = standard.split(separator: "/").first.map(String.init)
        return ["tmp", "var", "etc"].contains(first ?? "") ? "/private" + standard : standard
    }

    private static func parts(_ path: String) -> Parts {
        path.split(separator: "/").map { PathSpelling.identity(String($0)) }
    }

    private static func isAt(_ parts: Parts, orInside prefix: Parts) -> Bool {
        parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix
    }

    @discardableResult private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
