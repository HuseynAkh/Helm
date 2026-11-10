// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
#if os(macOS)
import UniformTypeIdentifiers
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Maps metadata without traversing links or hydrating file contents (F-035, F-048).
public struct MetadataReader: Sendable {
    /// 0 when a path can be read, otherwise the error code that refused it. Tests stand in for macOS refusals here.
    private let readCheck: @Sendable (String) -> Int32
    public init() { readCheck = MetadataReader.systemReadCheck }
    init(readCheck: @escaping @Sendable (String) -> Int32) { self.readCheck = readCheck }
    /// errno is read straight after access(2), before anything else can change it.
    static let systemReadCheck: @Sendable (String) -> Int32 = { path in access(path, R_OK) == 0 ? 0 : errno }
    /// Handed to the directory enumerator so the kernel's bulk read serves `read`'s resource values (FB1-15).
    static var listingPrefetchKeys: [URLResourceKey]? {
        #if os(macOS)
        return [.isHiddenKey, .isPackageKey, .isAliasFileKey, .contentTypeKey, .localizedTypeDescriptionKey]
        #else
        return nil
        #endif
    }
    public func read(_ url: URL, resolveSymlinkTargets: Bool = true, volumeIdentifier: String? = nil) throws -> FileEntry {
        do {
            let manager = FileManager.default
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            var kind: FileEntryKind = type == .typeDirectory ? .directory : (type == .typeRegular ? .regular : .other)
            if type == .typeSymbolicLink {
                kind = .danglingSymlink
                if resolveSymlinkTargets {
                    // FileManager follows a bounded OS link resolution; cycles remain dangling.
                    var directory: ObjCBool = false
                    if manager.fileExists(atPath: url.path, isDirectory: &directory) {
                        kind = directory.boolValue ? .symlinkToDirectory : .symlinkToFile
                    }
                }
            }
            var hidden = url.lastPathComponent.hasPrefix(".")
            var identifier: String?
            var description: String?
            #if os(macOS)
            let values = try url.resourceValues(forKeys: [.isHiddenKey, .isPackageKey, .isAliasFileKey, .contentTypeKey,
                                                          .localizedTypeDescriptionKey])
            hidden = hidden || values.isHidden == true
            if kind == .directory && values.isPackage == true { kind = .package }
            if values.isAliasFile == true && type != .typeSymbolicLink { kind = .alias }
            identifier = values.contentType?.identifier
            // Finder's Kind words, such as "Plain Text Document" and "Folder". The type's own description reads
            // "text" and "folder".
            description = values.localizedTypeDescription ?? values.contentType?.localizedDescription
            #endif
            let (readable, privacyProtected) = Self.readAccess(refusedWith: readCheck(url.path))
            return FileEntry(url: url, kind: kind, isHidden: hidden,
                             isReadable: readable,
                             size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                             modificationDate: attributes[.modificationDate] as? Date ?? .distantPast,
                             creationDate: attributes[.creationDate] as? Date ?? .distantPast,
                             contentTypeIdentifier: identifier, localizedKindDescription: description,
                             volumeIdentifier: volumeIdentifier,
                             cloudAvailability: (try? CloudAvailabilityReader.readMetadata(at: url)) ?? .unknown,
                             objectIdentity: Self.identity(attributes), isPrivacyProtected: privacyProtected)
        } catch { throw FileSystemError.mapping(error) }
    }
    /// Whether the item can be read, and whether macOS privacy protection is what stops it. A refused read
    /// fails with EACCES for ownership, mode bits or an ACL, and with EPERM when macOS privacy protection
    /// refuses, as for `~/Movies/TV` without media access. Readability comes from access(2), not the
    /// enumerator's prefetched readable key, which reports those folders as readable.
    static func readAccess(_ path: String) -> (readable: Bool, privacyProtected: Bool) {
        readAccess(refusedWith: systemReadCheck(path))
    }
    /// What a read check's result means: 0 is readable, EPERM is macOS privacy, anything else ordinary permissions.
    static func readAccess(refusedWith code: Int32) -> (readable: Bool, privacyProtected: Bool) {
        code == 0 ? (true, false) : (false, code == EPERM)
    }
    private static func identity(_ attributes: [FileAttributeKey: Any]) -> FileObjectIdentity? {
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return FileObjectIdentity(scope: "native:" + device.stringValue, object: inode.stringValue)
    }

}
