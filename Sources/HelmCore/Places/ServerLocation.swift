import Foundation

/// A server address the person typed for AI mode to hand to macOS: a file share and nothing else.
/// This is the one parser for such an address. A value can only hold a file-sharing scheme, a plain host, a share and
/// up to two folders, so nothing made from it can carry a web address, an account, a password or a command.
/// Text that doesn't parse is ordinary text.
public struct ServerLocation: Hashable, Sendable {
    /// "smb", "afp" or "nfs". "cifs" is another name for SMB, and is read as "smb".
    public let scheme: String
    /// Lower case and ASCII: letters, digits, dots, hyphens and underscores. Never a port, a name or a password.
    public let host: String
    public let share: String
    /// The folders below the share, at most two.
    public let folders: [String]
    /// The address as macOS is given it, built from the parts above and from nothing else.
    public let url: URL

    /// The longest address read, in characters.
    static let maximumLength = 255
    /// The most folders below the share.
    static let maximumFolders = 2
    static let schemes: [String: String] = ["smb": "smb", "cifs": "smb", "afp": "afp", "nfs": "nfs"]

    /// Nil for any other scheme, a name or a password, a port, a query or a fragment, more than 255 characters, no
    /// share, more than two folders below it, or a hidden or control character anywhere.
    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.count <= Self.maximumLength, AgentTextEscaper.isClean(text),
              let separator = text.range(of: "://"),
              let scheme = Self.schemes[text[..<separator.lowerBound].lowercased()] else { return nil }
        let rest = text[separator.upperBound...]
        // A query or a fragment could carry options to whatever mounts the share.
        guard !rest.contains("?"), !rest.contains("#") else { return nil }
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let host = rest[..<slash].lowercased()
        guard Self.isHost(host) else { return nil }
        var parts = rest[slash...].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // One "/" before the share and at most one after the last folder; an empty part anywhere else is a mistake.
        guard parts.first == "" else { return nil }
        parts.removeFirst()
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        var names: [String] = []
        for part in parts {
            guard let name = part.removingPercentEncoding, Self.isPathPart(name) else { return nil }
            names.append(name)
        }
        guard let share = names.first, names.count <= 1 + Self.maximumFolders else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + names.joined(separator: "/")
        guard let url = components.url else { return nil }
        self.scheme = scheme; self.host = host; self.share = share
        self.folders = Array(names.dropFirst()); self.url = url
    }

    /// A host name or an IPv4 address. Anything with an "@" (a name or a password), a ":" (a port or an IPv6
    /// address) or a character outside ASCII isn't one.
    private static func isHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        let allowed = host.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
        }
        return allowed && !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
    }

    /// One name of the path, after its percent escapes are read: not empty, not "." or "..", and holding no slash and
    /// nothing hidden, which an escape could otherwise bring in.
    private static func isPathPart(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && AgentTextEscaper.isClean(name)
    }
}
