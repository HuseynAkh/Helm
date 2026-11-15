#if os(macOS)
import Foundation

/// Folders whose items the fixture Trash refuses, as a server or a disk with no Trash does, so a scripted run can
/// show what Helm does there. A fixture run's Trash reads it from the operation engine's thread, so it's guarded by
/// a lock.
final class FixtureTrashRules: @unchecked Sendable {
    private let lock = NSLock()
    private var refused: [[String]] = []

    /// Items inside `prefix`, a folder's path, are refused from now on.
    func refuse(under prefix: String) {
        let components = Self.components(prefix)
        lock.lock(); defer { lock.unlock() }
        if !refused.contains(components) { refused.append(components) }
    }
    /// Whether `path` is a refused folder or inside one. A name that only starts the same, such as “Share 2” beside
    /// “Share”, isn't: the paths are compared folder by folder.
    func refuses(_ path: String) -> Bool {
        let components = Self.components(path)
        lock.lock(); defer { lock.unlock() }
        return refused.contains { components.count >= $0.count && Array(components.prefix($0.count)) == $0 }
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        refused.removeAll()
    }

    /// The path's folders as the disk spells them, so /tmp and /private/tmp agree, and its own name as given, so a
    /// link is judged by where it is and not by where it points.
    private static func components(_ path: String) -> [String] {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathComponents.count > 1 else { return url.pathComponents }
        return url.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents + [url.lastPathComponent]
    }
}
#endif
