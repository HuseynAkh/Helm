// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
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
    /// macOS privacy protection, not ownership or permissions, is what refuses reading this item: the read
    /// failed with EPERM rather than EACCES. `~/Movies/TV` without media access is one (P-268).
    public let isPrivacyProtected: Bool
    public let size: Int64
    public let modificationDate: Date
    public let creationDate: Date
    public let contentTypeIdentifier: String?
    public let localizedKindDescription: String?
    public let volumeIdentifier: String?
    public let childCount: Int?
    public let objectIdentity: FileObjectIdentity?
    public let cloudAvailability: CloudAvailability
    public var isStarred: Bool
    /// When Helm last opened it. Only Recent knows this; it's nil everywhere else.
    public var lastOpenedDate: Date? = nil
    public init(url: URL, name: String? = nil, kind: FileEntryKind = .regular,
                isHidden: Bool = false, isReadable: Bool = true, size: Int64 = 0,
                modificationDate: Date = .distantPast, creationDate: Date = .distantPast,
                contentTypeIdentifier: String? = nil, localizedKindDescription: String? = nil,
                volumeIdentifier: String? = nil, childCount: Int? = nil, isStarred: Bool = false,
                cloudAvailability: CloudAvailability = .unknown, objectIdentity: FileObjectIdentity? = nil,
                isPrivacyProtected: Bool = false) {
        self.objectIdentity = objectIdentity
        self.isPrivacyProtected = isPrivacyProtected
        self.cloudAvailability = cloudAvailability
        self.id = ItemID(url: url); self.url = url; self.name = name ?? url.lastPathComponent
        self.kind = kind; self.isHidden = isHidden; self.isReadable = isReadable; self.size = size
        self.modificationDate = modificationDate; self.creationDate = creationDate
        self.contentTypeIdentifier = contentTypeIdentifier; self.localizedKindDescription = localizedKindDescription
        self.volumeIdentifier = volumeIdentifier; self.childCount = childCount; self.isStarred = isStarred
    }
    /// Older metadata payloads predate cloud inspection and decode as unknown (F-035).
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.objectIdentity = try values.decodeIfPresent(FileObjectIdentity.self, forKey: .objectIdentity)
        self.id = try values.decode(ItemID.self, forKey: .id)
        self.url = try values.decode(URL.self, forKey: .url)
        self.name = try values.decode(String.self, forKey: .name)
        self.kind = try values.decode(FileEntryKind.self, forKey: .kind)
        self.isHidden = try values.decode(Bool.self, forKey: .isHidden)
        self.isReadable = try values.decode(Bool.self, forKey: .isReadable)
        self.isPrivacyProtected = try values.decodeIfPresent(Bool.self, forKey: .isPrivacyProtected) ?? false
        self.size = try values.decode(Int64.self, forKey: .size)
        self.modificationDate = try values.decode(Date.self, forKey: .modificationDate)
        self.creationDate = try values.decode(Date.self, forKey: .creationDate)
        self.contentTypeIdentifier = try values.decodeIfPresent(String.self, forKey: .contentTypeIdentifier)
        self.localizedKindDescription = try values.decodeIfPresent(String.self, forKey: .localizedKindDescription)
        self.volumeIdentifier = try values.decodeIfPresent(String.self, forKey: .volumeIdentifier)
        self.childCount = try values.decodeIfPresent(Int.self, forKey: .childCount)
        self.isStarred = try values.decode(Bool.self, forKey: .isStarred)
        self.cloudAvailability = try values.decodeIfPresent(CloudAvailability.self, forKey: .cloudAvailability) ?? .unknown
        self.lastOpenedDate = try values.decodeIfPresent(Date.self, forKey: .lastOpenedDate)
    }
    public var isDirectoryLike: Bool { kind == .directory || kind == .symlinkToDirectory }
    public var changeToken: ChangeToken { ChangeToken(modificationDate: modificationDate, size: size, childCount: childCount) }
}
