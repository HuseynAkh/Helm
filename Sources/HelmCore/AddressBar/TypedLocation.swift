import Foundation

/// What can be typed into the location bar beyond a plain path (docs/rebuild/03-finder-nautilus-balance.md).
public enum TypedLocation {
    /// Schemes macOS can mount, handed to the system like Finder's Connect to Server.
    static let serverSchemes: Set<String> = ["smb", "cifs", "afp", "nfs", "ftp", "webdav", "webdavs", "vnc"]

    /// `smb://nas/share` and friends. Nothing else is treated as remote, so a file named `a:b` stays a path.
    public static func serverURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "://"),
              serverSchemes.contains(trimmed[trimmed.startIndex..<range.lowerBound].lowercased()),
              let url = URL(string: trimmed), url.host?.isEmpty == false else { return nil }
        return url
    }

    /// `file:///Users/me/My%20Files` becomes `/Users/me/My Files`. Other hosts aren't local, so they aren't paths.
    public static func localPath(fromFileURL text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
        let path = url.path
        return text.hasSuffix("/") && path != "/" ? path + "/" : path
    }
}
