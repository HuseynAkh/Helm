import Foundation
import HelmCore
#if canImport(Darwin)
import Darwin
#endif

/// Tells what kind of place a folder is in from what macOS says about it: its volume, its own keys, whether its
/// volume has a Trash, the names of its extended attributes, and whether iCloud shares it or a folder above it.
/// Every read runs on a lane of its own with a 2-second limit and with downloads off, so a server that stopped
/// answering costs two seconds and a cloud folder is never loaded to answer. A folder that didn't answer in time is a
/// server that isn't responding.
public struct SystemStorageFactsReader: StorageFactsReading {
    /// What is read from the disk, one closure each, so tests can watch the reads or stand in for what a test Mac
    /// can't hold. Every closure runs on the reader's lane, with downloads off.
    struct Reads: Sendable {
        /// The path with every link in it resolved; nil when a part is missing.
        var canonical: @Sendable (String) -> String?
        /// The volume's keys and the folder's own cloud key, without the facts the other closures read.
        var volume: @Sendable (URL) throws -> StorageProbe
        /// Whether the volume the folder is on has a Trash, looked up without making one.
        var hasTrash: @Sendable (URL) -> Bool?
        /// The names of the folder's own extended attributes. Only names are ever read.
        var attributeNames: @Sendable (String) -> [String]
        /// iCloud's answer to whether this one folder is shared; nil when it gives none.
        var isShared: @Sendable (URL) -> Bool?
        /// The names in a folder, or nil when it can't be listed (with downloads off, a folder that isn't loaded).
        var names: @Sendable (String) -> [String]?
        /// Where the link at a path points, as written in the link; nil when the item isn't a link.
        var linkTarget: @Sendable (String) -> String?
    }

    /// How long one folder's facts may take before it counts as not responding.
    static let answerSeconds: TimeInterval = 2
    /// How many folders above a folder are asked whether iCloud shares them, at most.
    private static let chainLimit = 32

    private let home: String
    private let reads: Reads
    private let executor: IOExecutor
    private let mirrorCache = MirrorCache()

    /// Its own lane with a 2-second limit; every read with downloads off. `home` is the folder whose Library holds
    /// iCloud's and the providers' folders.
    public init(home: URL) { self.init(home: home, reads: .system) }

    init(home: URL, reads: Reads, executor: IOExecutor = IOExecutor(timeout: SystemStorageFactsReader.answerSeconds)) {
        self.home = home.standardizedFileURL.path; self.reads = reads; self.executor = executor
    }

    public func facts(for folder: URL) async -> StorageFacts {
        let mirrors = await mirrors()
        let path = folder.standardizedFileURL.path, home = self.home, reads = self.reads
        do {
            let found = try await DatalessGuard.off {
                try await executor.runRead(volume: Self.lane(of: path, home: home)) {
                    Self.probe(path, home: home, mirrors: mirrors, reads: reads)
                }
            }
            return StorageClassifier.classify(path: found.path, home: found.home, probe: found.probe, mirrors: mirrors)
        } catch {
            // The lane gave up waiting, or a stall before this one has it shut until the late call returns.
            return StorageClassifier.classify(path: path, home: home, probe: StorageProbe(timedOut: true), mirrors: mirrors)
        }
    }

    /// The folders a provider mirrors to: where the links one and two levels inside each folder of the home's
    /// `Library/CloudStorage` point, by canonical path, each with the name of the provider's folder. Google leaves such
    /// a link when My Drive is mirrored to an ordinary folder. Read on first use and again whenever the list of
    /// providers' folders, or the names in one of them, changes; a folder that isn't loaded is passed over, never
    /// loaded. The read has a lane of its own, so a provider that stopped answering holds up no folder's facts.
    public func mirrors() async -> [String: String] {
        let home = self.home, reads = self.reads, cache = mirrorCache
        let found = try? await DatalessGuard.off {
            try await executor.runRead(volume: home + "/Library/CloudStorage") { () -> [String: String] in
                let realHome = reads.canonical(home) ?? home
                let storage = realHome + "/Library/CloudStorage"
                let folders = (reads.names(storage) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                // A shortcut can appear in a provider's folder that was already there, as when Google Drive is
                // switched from streaming to mirroring, so each folder's own names are part of what was read.
                let listed = folders.map { [$0] + (reads.names(storage + "/" + $0) ?? []).sorted() }
                if let known = cache.mirrors(for: listed) { return known }
                let mirrors = Self.readMirrors(in: storage, listed: listed, home: realHome, reads: reads)
                cache.store(mirrors, for: listed)
                return mirrors
            }
        }
        return found ?? mirrorCache.last ?? [:]
    }

    // MARK: Reading

    private struct Found: Sendable {
        let path: String, home: String
        let probe: StorageProbe
    }

    /// Everything about one folder, read on the lane. The folder is named by its canonical path, so a folder reached
    /// through a link answers as the folder it is.
    private static func probe(_ path: String, home: String, mirrors: [String: String], reads: Reads) -> Found {
        let canonical = reads.canonical(path) ?? path
        let realHome = reads.canonical(home) ?? home
        let url = URL(fileURLWithPath: canonical, isDirectory: true)
        var probe = (try? reads.volume(url)) ?? StorageProbe()
        probe.hasTrash = reads.hasTrash(url)
        let names = reads.attributeNames(canonical)
        probe.hasSyncAttribute = names.contains { name in StorageClassifier.syncAttributePrefixes.contains { name.hasPrefix($0) } }
        probe.isShared = sharing(of: canonical, home: realHome, mirrors: mirrors, ubiquitous: probe.isUbiquitous == true, reads: reads)
        return Found(path: canonical, home: realHome, probe: probe)
    }

    /// Whether iCloud shares the folder, or any folder above it up to its place's root: a folder inside a shared
    /// folder is seen by the same people. Nil when no folder answered.
    private static func sharing(of path: String, home: String, mirrors: [String: String], ubiquitous: Bool,
                                reads: Reads) -> Bool? {
        let root = StorageClassifier.cloudRoot(of: path, home: home, mirrors: mirrors)
            ?? (ubiquitous ? ["Desktop", "Documents"].map { home + "/" + $0 }.first { isAt(path, orInside: $0) } : nil)
            ?? path
        var answer: Bool?
        var folder = path
        for _ in 0..<chainLimit {
            switch reads.isShared(URL(fileURLWithPath: folder, isDirectory: true)) {
            case true?: return true
            case false?: answer = answer ?? false
            case nil: break
            }
            guard folder != root, isAt(folder, orInside: root), folder != "/" else { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return answer
    }

    /// The targets of the links one and two levels inside each provider's folder. A target inside the providers'
    /// folders is already a cloud place, and one at or above the home can't be a mirror, so neither counts.
    /// `listed` holds each provider's folder name followed by the names in it.
    private static func readMirrors(in storage: String, listed: [[String]], home: String, reads: Reads) -> [String: String] {
        var mirrors: [String: String] = [:]
        func follow(_ link: String, from folder: String, provider: String) -> Bool {
            guard let written = reads.linkTarget(link) else { return false }
            let absolute = written.hasPrefix("/") ? written : folder + "/" + written
            if let target = reads.canonical(absolute), !isAt(target, orInside: storage), !isAt(home, orInside: target) {
                mirrors[target] = mirrors[target] ?? provider
            }
            return true
        }
        for names in listed {
            guard let provider = names.first else { continue }
            let top = storage + "/" + provider
            for first in names.dropFirst() {
                let level = top + "/" + first
                if follow(level, from: top, provider: provider) { continue }
                for second in reads.names(level) ?? [] { _ = follow(level + "/" + second, from: level, provider: provider) }
            }
        }
        return mirrors
    }

    /// The lane a folder's reads wait in. A disk in the Volumes folder, each provider's folder in the home's
    /// `Library/CloudStorage` and the home's `Library/Mobile Documents` have one each, so a server or a provider that
    /// stopped answering holds up only itself; the rest of the startup disk shares one.
    static func lane(of path: String, home: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2 && parts[0] == "Volumes" { return "/Volumes/" + parts[1] }
        let homeParts = home.split(separator: "/").map(String.init), library = homeParts.count
        guard parts.count >= library + 2, Array(parts.prefix(library)) == homeParts, parts[library] == "Library" else { return "/" }
        if parts[library + 1] == "Mobile Documents" { return "/" + parts.prefix(library + 2).joined(separator: "/") }
        if parts[library + 1] == "CloudStorage", parts.count >= library + 3 {
            return "/" + parts.prefix(library + 3).joined(separator: "/")
        }
        return "/"
    }

    /// Whether `path` is `prefix` or inside it, folder by folder.
    private static func isAt(_ path: String, orInside prefix: String) -> Bool {
        prefix == "/" || path == prefix || path.hasPrefix(prefix + "/")
    }

    /// The mirrors last read and the providers' folders, with the names in each, they were read from.
    private final class MirrorCache: @unchecked Sendable {
        private let lock = NSLock()
        private var folders: [[String]]?
        private var known: [String: String]?
        func mirrors(for folders: [[String]]) -> [String: String]? {
            lock.lock(); defer { lock.unlock() }
            return self.folders == folders ? known : nil
        }
        func store(_ mirrors: [String: String], for folders: [[String]]) {
            lock.lock(); defer { lock.unlock() }
            self.folders = folders; known = mirrors
        }
        var last: [String: String]? {
            lock.lock(); defer { lock.unlock() }
            return known
        }
    }
}

extension SystemStorageFactsReader.Reads {
    /// What macOS says, read through Foundation and the system calls that read names and flags only.
    static let system = SystemStorageFactsReader.Reads(
        canonical: { CanonicalPath.realPath($0) },
        volume: { url in
            #if os(macOS)
            let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey,
                                             .volumeIsEjectableKey, .volumeIsReadOnlyKey, .volumeURLKey, .isUbiquitousItemKey]
            let values = try url.resourceValues(forKeys: keys)
            let mount = values.volume?.standardizedFileURL.path
            return StorageProbe(isLocal: values.volumeIsLocal, isInternal: values.volumeIsInternal,
                                isRemovable: values.volumeIsRemovable, isEjectable: values.volumeIsEjectable,
                                isReadOnly: values.volumeIsReadOnly, isUbiquitous: values.isUbiquitousItem,
                                volumeRoot: mount == "/" ? nil : mount)
            #else
            return StorageProbe(isLocal: true, isInternal: true)
            #endif
        },
        hasTrash: { url in
            #if os(macOS)
            return (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url,
                                                 create: false)) != nil
            #else
            return nil
            #endif
        },
        attributeNames: { path in
            #if canImport(Darwin)
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: size)
            let filled = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
            guard filled > 0 else { return [] }
            return buffer[0..<filled].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            #else
            return []
            #endif
        },
        isShared: { url in
            #if os(macOS)
            return try? url.resourceValues(forKeys: [.ubiquitousItemIsSharedKey]).ubiquitousItemIsShared
            #else
            return nil
            #endif
        },
        names: { try? FileManager.default.contentsOfDirectory(atPath: $0) },
        linkTarget: { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) }
    )
}
