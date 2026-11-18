#if os(macOS)
import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import HelmCore
import HelmFileSystem

/// Reads what Properties shows about one item beyond its row in the folder: owner, group and what each can do,
/// Locked, an access list, when it was last opened, its disk's free space, where a link points and a picture's size.
/// It reads only the item's own attributes and a picture's header, never a file kept in a cloud and not on this Mac,
/// which it leaves unread rather than download. Nothing it reads leaves the Mac.
enum PropertiesReader {
    static func read(_ entry: FileEntry) async -> PropertiesSupplement {
        await Task.detached(priority: .userInitiated) {
            DatalessGuard.withDownloadsOff { read(url: entry.url, kind: entry.kind, type: entry.contentTypeIdentifier) }
        }.value
    }

    private static func read(url: URL, kind: FileEntryKind, type: String?) -> PropertiesSupplement {
        var supplement = PropertiesSupplement()
        var info = stat()
        if lstat(url.path, &info) == 0 {
            supplement.posixMode = UInt16(info.st_mode & 0o7777)
            // Helm reads no account's name: your own items say "You", the system's say root, which is always account
            // 0, and any other is shown by its number.
            supplement.ownerIsYou = info.st_uid == getuid()
            if !supplement.ownerIsYou { supplement.owner = info.st_uid == 0 ? "root" : "Another account (ID \(info.st_uid))" }
            supplement.group = name(ofGroup: info.st_gid)
            supplement.locked = info.st_flags & UInt32(UF_IMMUTABLE) != 0
        }
        supplement.hasAccessList = hasAccessList(url.path)
        if let values = try? url.resourceValues(forKeys: [.contentAccessDateKey, .volumeLocalizedNameKey]) {
            supplement.accessed = values.contentAccessDate
            supplement.volumeName = values.volumeLocalizedName
        }
        // The same free space the status bar shows.
        if let disk = try? FileManager.default.attributesOfFileSystem(forPath: url.path) {
            supplement.volumeFree = (disk[.systemFreeSize] as? NSNumber)?.int64Value
            supplement.volumeTotal = (disk[.systemSize] as? NSNumber)?.int64Value
        }
        switch kind {
        case .symlinkToDirectory, .symlinkToFile, .danglingSymlink:
            supplement.linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        case .alias:
            // Without asking for a disk to be mounted or showing anything.
            supplement.linkTarget = (try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]))?.path
        default: break
        }
        if let type, let uti = UTType(type) {
            supplement.mimeType = uti.preferredMIMEType
            if kind == .regular, uti.conforms(to: .image) { supplement.imageDimensions = dimensions(of: url) }
        }
        return supplement
    }

    private static func name(ofGroup id: gid_t) -> String? {
        guard let entry = getgrgid(id), let name = entry.pointee.gr_name else { return nil }
        return String(cString: name)
    }
    /// Whether the item has an access control list with at least one rule, without following a link.
    private static func hasAccessList(_ path: String) -> Bool {
        guard let list = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(list)) }
        var entry: acl_entry_t?
        return acl_get_entry(list, ACL_FIRST_ENTRY.rawValue, &entry) == 0
    }
    /// A picture's size from its header, without decoding it. Nil when it can't be read here, which includes one kept
    /// in a cloud only, since downloads are off.
    private static func dimensions(of url: URL) -> String? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }
}
#endif
