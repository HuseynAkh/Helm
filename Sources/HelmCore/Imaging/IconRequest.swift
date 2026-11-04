// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// F-047 generic caching avoids the per-visible-cell file icon lookup cost of B-058.
public enum IconCacheIdentity: Hashable, Sendable {
    case contentType(String)
    case pathExtension(String)
    case folder
    case volume(String)
    case genericFile
    case file(ItemID, ChangeToken)
}
/// F-047 file-specific lookup is opt-in for known custom icons, apps and packages.
public enum IconPolicy: Sendable { case generic, fileSpecific }

/// Pure metadata-only F-047 request planning; platform adapters perform any actual icon I/O.
public struct IconRequest: Hashable, Sendable {
    public let identity: IconCacheIdentity
    public let dimensions: ImageDimensions
    public init(entry: FileEntry, dimensions: ImageDimensions, policy: IconPolicy = .generic,
                isVolumeRoot: Bool = false) {
        self.dimensions = dimensions
        if case .fileSpecific = policy {
            identity = .file(entry.id, entry.changeToken)
        } else if isVolumeRoot {
            identity = .volume(entry.volumeIdentifier ?? entry.id.rawValue)
        } else if entry.isDirectoryLike {
            identity = .folder
        } else if let type = entry.contentTypeIdentifier, !type.isEmpty {
            identity = .contentType(type)
        } else {
            let ext = entry.url.pathExtension.lowercased()
            identity = ext.isEmpty ? .genericFile : .pathExtension(ext)
        }
    }
}
