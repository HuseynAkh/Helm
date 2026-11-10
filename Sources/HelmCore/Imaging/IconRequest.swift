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
/// F-047 apps, packages and links retain per-file icons; custom folder icons remain host policy.
public enum IconPolicy: Sendable {
    case generic, fileSpecific

    public static func recommended(for entry: FileEntry) -> IconPolicy {
        switch entry.kind {
        case .package, .alias, .symlinkToDirectory, .symlinkToFile, .danglingSymlink:
            return .fileSpecific
        case .regular, .directory, .other:
            return .generic
        }
    }
}

/// Pure metadata-only F-047 request planning; platform adapters perform any actual icon I/O.
public struct IconRequest: Hashable, Sendable {
    public let identity: IconCacheIdentity
    public let dimensions: ImageDimensions
    public init(entry: FileEntry, dimensions: ImageDimensions, policy: IconPolicy? = nil,
                isVolumeRoot: Bool = false) {
        self.dimensions = dimensions
        if case .fileSpecific = policy ?? IconPolicy.recommended(for: entry) {
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
