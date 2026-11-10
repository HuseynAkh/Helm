import Foundation
import HelmCore

/// What a folder's own entry says before it's listed: whether it can be listed and, if not, why. Both the tab's load
/// and the monitor's reload ask here, so a folder reads the same however it's being read.
enum ListingRoot {
    /// A link to an item that's gone, or to itself, leads nowhere. That's no permissions problem.
    static let brokenLink = "The item this link points to can’t be found."

    /// The folder's entry. A folder that can't be found on a disk that's no longer mounted, because it was ejected or
    /// unplugged or its server went away, fails as a disconnected disk: Try Again works once it's back.
    static func entry(at url: URL, fileSystem: any FileSystem) async throws -> FileEntry {
        do {
            return try await fileSystem.entry(at: url)
        } catch let failure where FileSystemError.mapping(failure) == .notFound {
            if let disk = mountPoint(of: url), !(await fileSystem.exists(disk)) { throw LoadError.volumeUnmounted }
            throw failure
        }
    }

    /// Throws why the folder can't be listed.
    static func check(_ root: FileEntry) throws {
        if root.kind == .danglingSymlink { throw FileSystemError.other(brokenLink) }
        guard root.isReadable else { throw FileSystemError.permissionDenied }
        guard root.isDirectoryLike || root.kind == .package else { throw FileSystemError.other("Not a directory") }
    }

    /// Where the disk holding `url` is mounted: disks other than the startup disk, and server shares, are mounted in
    /// /Volumes, and the folder goes with the disk. Nil for anything on the startup disk.
    static func mountPoint(of url: URL) -> URL? {
        let components = URL(fileURLWithPath: PathSpelling.standardPath(url)).pathComponents
        guard components.count > 2, components[1].lowercased() == "volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes", isDirectory: true).appendingPathComponent(components[2], isDirectory: true)
    }
}
