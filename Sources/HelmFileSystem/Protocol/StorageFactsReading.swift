import Foundation
import HelmCore

/// Answers what kind of place a folder is in: this Mac, iCloud Drive, a provider's cloud folder, a server or an
/// external disk. The answer is the folder's own, since one root can hold several places.
public protocol StorageFactsReading: Sendable {
    /// The facts of this folder itself, not of the root or the disk it was reached through.
    func facts(for folder: URL) async -> StorageFacts
    /// The folders a cloud provider mirrors to, by canonical path, each with the name of that provider's folder in
    /// the home's CloudStorage folder.
    func mirrors() async -> [String: String]
}

public extension StorageFactsReading {
    /// A reader that knows of no mirrored folder.
    func mirrors() async -> [String: String] { [:] }
}

/// A reader for tests and fixture runs. It reads nothing from the disk: `StorageClassifier`'s path rules are applied
/// to the home it is given, so a folder in that home's CloudStorage folder is a cloud folder with nothing set.
/// What a path can't say (a server, an external disk, a read-only place, a missing Trash, a place that doesn't
/// answer) is set by path prefix. Paths are compared as they are given, so they should be canonical.
public final class MemoryStorageFactsReader: StorageFactsReading, @unchecked Sendable {
    private let lock = NSLock()
    private let home: String
    private var probes: [(prefix: [String], probe: StorageProbe)] = []
    private var mirrorTargets: [String: String] = [:]
    private var askedPaths: [String] = []

    /// The path rules apply to this home, and every folder starts with an empty probe.
    public init(home: URL) { self.home = home.path }

    /// Folders at or inside `prefix` answer from `probe`. Where several prefixes hold a folder, the longest wins.
    /// Setting a prefix again replaces its probe.
    public func set(_ probe: StorageProbe, under prefix: String) {
        let parts = Self.parts(of: prefix)
        lock.lock(); defer { lock.unlock() }
        probes.removeAll { Self.same($0.prefix, parts) }
        probes.append((parts, probe))
    }

    /// Makes `target` a folder that the provider with the CloudStorage folder `cloudFolder` mirrors to.
    public func setMirror(target: String, cloudFolder: String) {
        lock.lock(); defer { lock.unlock() }
        mirrorTargets[target] = cloudFolder
    }

    /// Forgets every probe, every mirror and what was asked. The home stays.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        probes.removeAll(); mirrorTargets.removeAll(); askedPaths.removeAll()
    }

    /// The path of every folder whose facts were asked for, in order, so a test can show how often a folder was read.
    public var asked: [String] {
        lock.lock(); defer { lock.unlock() }
        return askedPaths
    }

    public func facts(for folder: URL) async -> StorageFacts {
        let path = folder.path
        let (probe, mirrors) = recordAsking(for: path)
        return StorageClassifier.classify(path: path, home: home, probe: probe, mirrors: mirrors)
    }

    public func mirrors() async -> [String: String] { currentMirrors }

    /// Records that `path` was asked for, and answers the probe that applies to it and the mirrors as they are now.
    private func recordAsking(for path: String) -> (probe: StorageProbe, mirrors: [String: String]) {
        let parts = Self.parts(of: path)
        lock.lock(); defer { lock.unlock() }
        askedPaths.append(path)
        let held = probes.filter { Self.starts(parts, with: $0.prefix) }.max { $0.prefix.count < $1.prefix.count }
        return (held?.probe ?? StorageProbe(), mirrorTargets)
    }
    private var currentMirrors: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return mirrorTargets
    }

    // Paths are compared part by part, as the classifier does, so a folder whose name only starts like a prefix's
    // last part isn't inside it, and a name matches whatever form its accents are written in.
    private static func parts(of path: String) -> [String] { path.split(separator: "/").map(String.init) }
    private static func starts(_ parts: [String], with prefix: [String]) -> Bool {
        parts.count >= prefix.count && zip(parts, prefix).allSatisfy { PathSpelling.identity($0) == PathSpelling.identity($1) }
    }
    private static func same(_ parts: [String], _ other: [String]) -> Bool {
        parts.count == other.count && starts(parts, with: other)
    }
}
