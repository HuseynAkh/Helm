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
}
