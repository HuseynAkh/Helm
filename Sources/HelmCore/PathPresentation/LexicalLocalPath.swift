// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// How two spellings of one path component compare (docs/rebuild/03-finder-nautilus-balance.md).
/// macOS file systems treat canonically equivalent names as one file, and Foundation's URLs already
/// decompose them, so identity follows suit. Elsewhere a byte difference can be a different file.
public enum PathSpelling {
    public static func identity(_ component: String) -> [UInt8] {
        #if canImport(Darwin)
        return Array(component.decomposedStringWithCanonicalMapping.utf8)
        #else
        return Array(component.utf8)
        #endif
    }

    /// One path per item. `standardizedFileURL` asks the disk before it drops `/private`, so on its own the same
    /// path comes out differently before and after a file exists. This settles it without depending on the disk.
    public static func standardPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        #if canImport(Darwin)
        for root in ["/private/tmp", "/private/var", "/private/etc"] where path == root || path.hasPrefix(root + "/") {
            return String(path.dropFirst("/private".count))
        }
        #endif
        return path
    }
}

// Scoped F-012/F-063/F-067 admission: decode once, never resolve symlinks or parents.
struct LexicalLocalPath {
    let components: [String]
    var key: [[UInt8]] { components.map(PathSpelling.identity) }
    var path: String { "/" + components.dropFirst().joined(separator: "/") }
    var hasParent: Bool { components.contains("..") }

    init?(_ url: URL) {
        guard url.isFileURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              parts.host == nil || parts.host == "" || parts.host?.lowercased() == "localhost",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.hasPrefix("/") else { return nil }
        var decoded: [String] = ["/"]
        for encoded in parts.percentEncodedPath.split(separator: "/") {
            guard let component = String(encoded).removingPercentEncoding,
                  !component.utf8.contains(0), !component.utf8.contains(47) else { return nil }
            if component != "." { decoded.append(component) }
        }
        components = decoded
    }
}
