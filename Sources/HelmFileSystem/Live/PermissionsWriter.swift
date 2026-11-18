import Foundation
import HelmCore
#if os(macOS)
import Darwin

/// Changes one item's permissions as `chmod` does, for Properties. Only an item the person owns is changed, as on a
/// Mac without an administrator's password: Helm never asks for one and never runs anything with more rights. It never
/// follows a link and never goes inside a folder. Every change is checked against the item and the mode it was asked
/// about, and the item is read again afterwards, so what's reported is what the disk keeps.
public enum PermissionsWriter {
    /// The item's mode and identity, read without following a link, and what would stand in the way of a change.
    public static func target(at url: URL) -> Result<PermissionTarget, PermissionRefusal> {
        var info = stat()
        let read = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            return lstat(path, &info) == 0 ? 0 : errno
        }
        guard read == 0 else { return .failure(read == ENOENT || read == ENOTDIR ? .missing : .failed(describe(read))) }
        let mode = UInt16(info.st_mode & 0o7777)
        let identity = FileObjectIdentity(scope: "native:\(info.st_dev)", object: "\(info.st_ino)")
        return .success(PermissionTarget(mode: mode, identity: identity, refusal: refusal(for: info, at: url)))
    }

    /// Changes the item's mode from `expected` to `mode`, provided it's still the item with `identity`, it has
    /// `expected`, and nothing in `target(at:)` stands in the way. Answers the mode the disk keeps afterwards.
    public static func change(_ url: URL, identity: FileObjectIdentity, from expected: UInt16, to mode: UInt16) -> Result<UInt16, PermissionRefusal> {
        let before: PermissionTarget
        switch target(at: url) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): before = value
        }
        guard before.identity == identity, before.mode == expected & 0o7777 else { return .failure(.changed) }
        if let refusal = before.refusal { return .failure(refusal) }
        // No link is followed: had the item been swapped for one since it was read, the link itself would be changed,
        // never what it points to.
        let code = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            return fchmodat(AT_FDCWD, path, mode_t(mode & 0o7777), AT_SYMLINK_NOFOLLOW) == 0 ? 0 : errno
        }
        switch code {
        case 0: break
        case ENOENT, ENOTDIR: return .failure(.missing)
        case EPERM, EACCES: return .failure(.notPermitted)
        case EROFS: return .failure(.readOnlyVolume)
        case ENOTSUP, EOPNOTSUPP: return .failure(.notKept)
        default: return .failure(.failed(describe(code)))
        }
        // The change was made. If the item can't be read again, what was asked for stands.
        guard case .success(let after) = target(at: url), after.identity == identity else { return .success(mode & 0o7777) }
        // Some disks take the change without an error and keep nothing of it.
        if after.mode == before.mode, before.mode != mode & 0o7777 { return .failure(.notKept) }
        return .success(after.mode)
    }

    /// Why the item's permissions can't be changed here, if they can't.
    private static func refusal(for info: stat, at url: URL) -> PermissionRefusal? {
        if info.st_mode & S_IFMT == S_IFLNK { return .link }
        if info.st_uid != getuid() { return .notOwner }
        if info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { return .locked }
        var volume = statfs()
        let found = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return statfs(path, &volume) == 0
        }
        guard found else { return nil }
        if volume.f_flags & UInt32(MNT_RDONLY) != 0 { return .readOnlyVolume }
        let type = withUnsafeBytes(of: volume.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return withoutPermissions.contains(type) ? .notKept : nil
    }
    /// File systems that keep no owner or permissions of their own: macOS makes them up for every item.
    private static let withoutPermissions: Set<String> = ["msdos", "exfat"]

    private static func describe(_ code: Int32) -> String { String(cString: strerror(code)) }
}
#endif
