import Foundation

/// Parses F-015–F-017 paths without I/O; relative paths use the displayed directory (B-054).
public struct PathEntry: Equatable, Sendable {
    public let directory: URL
    public let prefix: String
    public let resolvedURL: URL
    public let isSlashBrowsing: Bool

    /// Completion text is not trimmed: spaces can belong to filenames. Commit trims separately.
    public init(text: String, currentDirectory: URL, home: URL) {
        let expanded: String
        if let path = TypedLocation.localPath(fromFileURL: text) { expanded = path }
        else if text == "~" { expanded = home.path }
        else if text.hasPrefix("~/") { expanded = home.path + String(text.dropFirst()) }
        else { expanded = text }
        let absolute: String = expanded.hasPrefix("/") ? expanded : (currentDirectory.path as NSString).appendingPathComponent(expanded)
        let resolved: URL = URL(fileURLWithPath: absolute, isDirectory: text.hasSuffix("/")).standardizedFileURL
        self.resolvedURL = resolved
        self.isSlashBrowsing = text.hasSuffix("/")
        if isSlashBrowsing {
            self.directory = resolved
            self.prefix = ""
        } else {
            // Split before normalizing so a literal '.' or '..' remains a completion prefix.
            let raw: NSString = absolute as NSString
            self.directory = URL(fileURLWithPath: raw.deletingLastPathComponent, isDirectory: true).standardizedFileURL
            self.prefix = raw.lastPathComponent
        }
    }

    public static func commitURL(text: String, currentDirectory: URL, home: URL) -> URL? {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\0") else { return nil }
        if trimmed.isEmpty { return home.standardizedFileURL }
        return PathEntry(text: trimmed, currentDirectory: currentDirectory, home: home).resolvedURL
    }

    /// F-020 directory acceptance has exactly one trailing slash, including root (B-110).
    public static func directoryText(_ url: URL) -> String {
        let path: String = url.standardizedFileURL.path
        return path == "/" ? "/" : path + "/"
    }
}
