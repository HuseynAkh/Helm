import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The path as the file system spells it. Finder also lands on the real folder, so paths never run through a link.
public enum CanonicalPath {
    public static func resolve(_ url: URL) -> URL {
        let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard let real = realPath(url.path) else { return url }
        return URL(fileURLWithPath: real, isDirectory: directory)
    }
    /// An item as the file system spells it: every folder on the way to it as the disk has it, through any link, and
    /// its own name in the disk's case. Unlike `resolve`, a link stays a link, so showing one selects the link itself,
    /// as Finder's reveal does.
    public static func spelling(of url: URL) -> URL {
        #if canImport(Darwin)
        guard let path = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else { return url }
        return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
        #else
        // Only macOS answers with the disk's own spelling, so elsewhere the address stays as it was given.
        return url
        #endif
    }
    /// The one real path of the item at `path`, through every link on the way and the item itself when it is one.
    /// Nil when any part of the path is missing or can't be reached, so an answer always names something on disk.
    public static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// Walks `path` one part at a time without following anything, and answers the target of the first link whose
    /// own path `isAllowed` takes but whose target it doesn't, written as a path and never looked up. A link in an
    /// allowed place that leads under /net is found here, before resolving it would make macOS mount the host.
    /// Links in places that aren't allowed, such as /tmp on the way to a folder, are followed. Nil when no link
    /// leads out, and when a part is missing or there are too many links: resolving the path then answers.
    public static func linkLeaving(_ path: String, isAllowed: (String) -> Bool) -> String? {
        #if canImport(Darwin)
        var resolved: [String] = []
        var pending = Array(parts(of: path).reversed())
        var links = 0
        while let part = pending.popLast() {
            if part == "." { continue }
            if part == ".." { _ = resolved.popLast(); continue }
            let current = joined(resolved + [part])
            var info = stat()
            guard lstat(current, &info) == 0 else { return nil }
            guard info.st_mode & S_IFMT == S_IFLNK else {
                resolved.append(part)
                continue
            }
            links += 1
            guard links <= maximumLinks, let target = linkTarget(current) else { return nil }
            let targetParts = target.hasPrefix("/") ? parts(of: target) : resolved + parts(of: target)
            let targetPath = joined(normalized(targetParts))
            if isAllowed(current), !isAllowed(targetPath) { return targetPath }
            // The target is walked from the top of the disk, before the parts still to come.
            resolved = []
            pending += normalized(targetParts).reversed()
        }
        return nil
        #else
        return nil
        #endif
    }

    private static let maximumLinks = 32

    private static func parts(of path: String) -> [String] { path.split(separator: "/").map(String.init) }
    private static func joined(_ parts: [String]) -> String { "/" + parts.joined(separator: "/") }

    /// Parts with every "." and ".." taken out, as a target is read from the top of the disk.
    private static func normalized(_ parts: [String]) -> [String] {
        var kept: [String] = []
        for part in parts where part != "." {
            if part == ".." { _ = kept.popLast() } else { kept.append(part) }
        }
        return kept
    }

    #if canImport(Darwin)
    private static func linkTarget(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        buffer[count] = 0
        return String(cString: buffer)
    }
    #endif
}
