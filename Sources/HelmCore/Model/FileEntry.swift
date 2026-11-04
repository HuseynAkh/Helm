import Foundation

/// Files, packages and links remain distinct for activation and traversal (F-035, F-048).
public enum FileEntryKind: String, Hashable, Sendable, Codable {
    case regular, directory, package, symlinkToDirectory, symlinkToFile, danglingSymlink, alias, other
}
/// Metadata identity for refresh and undo checks, including directory children (B-041).
public struct ChangeToken: Hashable, Sendable, Codable {
    public let modificationDate: Date
    public let size: Int64
    public let childCount: Int?
    public init(modificationDate: Date, size: Int64, childCount: Int? = nil) {
        self.modificationDate = modificationDate; self.size = size; self.childCount = childCount
    }
}
/// Immutable listing metadata with value equality (F-035, B-009); localized kind comes from the reader.
public struct FileEntry: Hashable, Sendable, Identifiable, Codable {
    public let id: ItemID
    public let url: URL
    public let name: String
    public let kind: FileEntryKind
    public let isHidden: Bool
    public let isReadable: Bool
    public let size: Int64
    public let modificationDate: Date
    public let creationDate: Date
    public let contentTypeIdentifier: String?
    public let localizedKindDescription: String?
    public let volumeIdentifier: String?
    public let childCount: Int?
    public var isStarred: Bool
    public init(url: URL, name: String? = nil, kind: FileEntryKind = .regular,
                isHidden: Bool = false, isReadable: Bool = true, size: Int64 = 0,
                modificationDate: Date = .distantPast, creationDate: Date = .distantPast,
                contentTypeIdentifier: String? = nil, localizedKindDescription: String? = nil,
                volumeIdentifier: String? = nil, childCount: Int? = nil, isStarred: Bool = false) {
        self.id = ItemID(url: url); self.url = url; self.name = name ?? url.lastPathComponent
        self.kind = kind; self.isHidden = isHidden; self.isReadable = isReadable; self.size = size
        self.modificationDate = modificationDate; self.creationDate = creationDate
        self.contentTypeIdentifier = contentTypeIdentifier; self.localizedKindDescription = localizedKindDescription
        self.volumeIdentifier = volumeIdentifier; self.childCount = childCount; self.isStarred = isStarred
    }
    public var isDirectoryLike: Bool { kind == .directory || kind == .symlinkToDirectory }
    public var changeToken: ChangeToken { ChangeToken(modificationDate: modificationDate, size: size, childCount: childCount) }
}
