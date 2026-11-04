import Foundation

/// Metadata-only F-016 candidate. Providers must resolve directory symlink targets (F-015).
public struct CompletionCandidate: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let isDirectory: Bool
    public let isHidden: Bool
    public let symlinkTargetIsDirectory: Bool
    public init(name: String, url: URL, isDirectory: Bool, isHidden: Bool = false,
                symlinkTargetIsDirectory: Bool = false) {
        self.name = name; self.url = url; self.isDirectory = isDirectory
        self.isHidden = isHidden; self.symlinkTargetIsDirectory = symlinkTargetIsDirectory
    }
}

/// F-016/F-017 enumeration seam; implementations do I/O off the UI actor (B-050).
public protocol DirectoryListing: Sendable {
    func children(of url: URL, includeHidden: Bool) async throws -> [CompletionCandidate]
}

/// F-018 popup value, with normalized absolute paths and no images (B-050, B-110).
public struct CompletionRow: Hashable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isParentLink: Bool
    public init(name: String, path: String, isDirectory: Bool, isParentLink: Bool = false) {
        self.name = name
        self.path = URL(fileURLWithPath: path, isDirectory: isDirectory).standardizedFileURL.path
        self.isDirectory = isDirectory; self.isParentLink = isParentLink
    }
    public var completionText: String {
        isDirectory ? PathEntry.directoryText(URL(fileURLWithPath: path, isDirectory: true)) : path
    }
}
