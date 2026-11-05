// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

// Shared scoped policy: never collapse parent components across a possible symlink.
// Explicit directory hints avoid Foundation existence inference during construction.
enum LexicalLocalPath {
    static func isLocal(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
            && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil && url.path.hasPrefix("/")
    }
    static func components(_ url: URL) -> [String] {
        ["/"] + url.path.split(separator: "/").filter { $0 != "." }.map(String.init)
    }
    static func key(_ url: URL) -> String {
        "/" + components(url).dropFirst().joined(separator: "/")
    }
    static func hasParent(_ url: URL) -> Bool { components(url).contains("..") }
}
