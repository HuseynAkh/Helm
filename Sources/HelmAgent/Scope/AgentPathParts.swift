import Foundation
import HelmCore

/// Paths as lists of parts, compared part by part. A folder whose name only starts like another is never inside
/// it, and two spellings of one accented name match as the disk matches them.
enum AgentPathParts {
    /// A path's parts, with "/" first.
    static func of(_ path: String) -> [String] {
        ["/"] + path.split(separator: "/").map(String.init)
    }

    static func joined(_ parts: [String]) -> String {
        parts.count <= 1 ? "/" : "/" + parts.dropFirst().joined(separator: "/")
    }

    /// Whether `parts` is `prefix` or inside it.
    static func starts(_ parts: [String], with prefix: [String]) -> Bool {
        parts.count >= prefix.count && zip(parts, prefix).allSatisfy { PathSpelling.identity($0) == PathSpelling.identity($1) }
    }

    static func same(_ path: String, _ other: String) -> Bool {
        let parts = of(path), otherParts = of(other)
        return parts.count == otherParts.count && starts(parts, with: otherParts)
    }

    /// Whether `path` is `folder` or inside it.
    static func isAt(_ path: String, orInside folder: String) -> Bool {
        starts(of(path), with: of(folder))
    }

    /// Whether `path` is inside `folder` and not `folder` itself.
    static func isStrictlyInside(_ path: String, _ folder: String) -> Bool {
        let parts = of(path), folderParts = of(folder)
        return parts.count > folderParts.count && starts(parts, with: folderParts)
    }

    /// The path of an item named `name` in `folder`.
    static func child(_ name: String, of folder: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    /// The same path whatever the spelling of the system's temporary folders, for comparing a path the window gave
    /// with one Helm canonicalized. Worked out from the text alone, so nothing is asked of the disk.
    static func comparable(_ path: String) -> [[UInt8]] {
        var parts = of(path)
        if parts.count >= 3, parts[1] == "private", ["tmp", "var", "etc"].contains(parts[2]) { parts.remove(at: 1) }
        return parts.map(PathSpelling.identity)
    }
}
