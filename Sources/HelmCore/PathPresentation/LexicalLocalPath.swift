// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

// Scoped F-012/F-063/F-067 admission: decode once, never resolve symlinks or parents.
// Byte keys deliberately avoid Swift String's canonical Unicode equivalence.
struct LexicalLocalPath {
    let components: [String]
    var key: [[UInt8]] { components.map { Array($0.utf8) } }
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
