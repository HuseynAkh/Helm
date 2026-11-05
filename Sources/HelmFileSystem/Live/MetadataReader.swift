// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
#if os(macOS)
import UniformTypeIdentifiers
#endif

/// Maps metadata without traversing links or hydrating file contents (F-035, F-048).
public struct MetadataReader: Sendable {
    public init() {}
    /// Handed to the directory enumerator so the kernel's bulk read serves `read`'s resource values (FB1-15).
    static var listingPrefetchKeys: [URLResourceKey]? {
        #if os(macOS)
        return [.isHiddenKey, .isPackageKey, .isAliasFileKey, .contentTypeKey]
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
            let values = try url.resourceValues(forKeys: [.isHiddenKey, .isPackageKey, .isAliasFileKey, .contentTypeKey])
            hidden = hidden || values.isHidden == true
            if kind == .directory && values.isPackage == true { kind = .package }
            if values.isAliasFile == true && type != .typeSymbolicLink { kind = .alias }
            identifier = values.contentType?.identifier
            description = values.contentType?.localizedDescription
            #endif
            return FileEntry(url: url, kind: kind, isHidden: hidden,
                             isReadable: manager.isReadableFile(atPath: url.path),
                             size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                             modificationDate: attributes[.modificationDate] as? Date ?? .distantPast,
                             creationDate: attributes[.creationDate] as? Date ?? .distantPast,
                             contentTypeIdentifier: identifier, localizedKindDescription: description,
                             volumeIdentifier: volumeIdentifier,
                             cloudAvailability: (try? CloudAvailabilityReader.readMetadata(at: url)) ?? .unknown,
                             objectIdentity: Self.identity(attributes))
        } catch { throw FileSystemError.mapping(error) }
    }
    private static func identity(_ attributes: [FileAttributeKey: Any]) -> FileObjectIdentity? {
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return FileObjectIdentity(scope: "native:" + device.stringValue, object: inode.stringValue)
    }

}
