import Foundation

/// What one class of user may do with an item, in the words of Finder's Get Info pop-up.
public enum FinderAccess: String, CaseIterable, Sendable {
    case readWrite, readOnly, noAccess

    public var title: String {
        switch self {
        case .readWrite: return "Read & Write"
        case .readOnly: return "Read only"
        case .noAccess: return "No access"
        }
    }

    /// The choice a class's three bits match, or nil for a mix that none of the three describes, which Finder shows as
    /// Custom. A folder's choices include execute, since a folder can't be opened without it: rwx, r-x and ---. A
    /// file's are about reading and writing only: whether it runs is its own checkbox, so its execute bit plays no part.
    public init?(bits: UInt16, folder: Bool) {
        let bits = bits & 7
        if folder {
            switch bits {
            case 7: self = .readWrite
            case 5: self = .readOnly
            case 0: self = .noAccess
            default: return nil
            }
        } else {
            switch bits & 6 {
            case 6: self = .readWrite
            case 4: self = .readOnly
            case 0: self = .noAccess
            default: return nil
            }
        }
    }

    /// A class's three bits for this choice. A folder gets rwx, r-x or ---, as in Finder. A file gets rw-, r-- or ---
    /// with the execute bit it had in `current` kept.
    public func bits(folder: Bool, keepingExecuteOf current: UInt16) -> UInt16 {
        let read: UInt16
        switch self {
        case .readWrite: read = 6
        case .readOnly: read = 4
        case .noAccess: read = 0
        }
        if folder { return read == 0 ? 0 : read | 1 }
        return read | (current & 1)
    }
}

/// Changes to a mode, one control at a time, as Properties makes them. Each keeps every bit it isn't about as it was,
/// set-user-ID, set-group-ID and sticky included.
public enum PermissionEdit {
    /// `mode` with `subject`'s access set to `access`.
    public static func mode(_ mode: UInt16, setting access: FinderAccess, for subject: PermissionSubject, folder: Bool) -> UInt16 {
        let shift = UInt16(subject.rawValue)
        let current = (mode >> shift) & 7
        return (mode & ~(UInt16(7) << shift)) | (access.bits(folder: folder, keepingExecuteOf: current) << shift)
    }

    /// Whether Nautilus's "Allow executing file as program" is on for a file: some class of user may run it.
    public static func allowsExecuting(_ mode: UInt16) -> Bool { mode & 0o111 != 0 }

    /// `mode` with "Allow executing file as program" turned on, which lets every class that can read the file run it,
    /// or off, which lets nobody run it.
    public static func mode(_ mode: UInt16, allowingExecution: Bool) -> UInt16 {
        guard allowingExecution else { return mode & ~UInt16(0o111) }
        var result = mode
        for subject in PermissionSubject.allCases {
            let shift = UInt16(subject.rawValue)
            if (mode >> shift) & 4 != 0 { result |= 1 << shift }
        }
        return result
    }
}

/// Why Helm left an item's permissions as they were. Nothing changed for any of these.
public enum PermissionRefusal: Error, Equatable, Sendable {
    /// Another account or root owns it. Only the owner may change its permissions without an administrator's
    /// password, and Helm never asks for one.
    case notOwner
    /// Finder's Locked is on.
    case locked
    case readOnlyVolume
    /// Its disk keeps no permissions, as FAT and exFAT disks don't, or it didn't keep the change.
    case notKept
    /// It's a symbolic link, whose own permissions macOS doesn't use: its original's apply.
    case link
    /// It isn't the item the change was asked about any more, or its permissions have changed since they were read.
    case changed
    case missing
    case notPermitted
    case failed(String)

    /// What the Properties window says about it, under the permissions.
    public var message: String {
        switch self {
        case .notOwner: return "Only the owner can change these."
        case .locked: return "It’s locked, so its permissions can’t be changed."
        case .readOnlyVolume: return "Its disk is read-only, so its permissions can’t be changed."
        case .notKept: return "Its disk doesn’t keep permissions, so they can’t be changed."
        case .link: return "A symbolic link uses its original’s permissions."
        case .changed: return "Its permissions changed meanwhile, so nothing was changed. They’re shown as they are now."
        case .missing: return "It’s no longer there, so nothing was changed."
        case .notPermitted: return "You don’t have permission to change them."
        case .failed(let reason): return "Its permissions couldn’t be changed: \(reason)."
        }
    }
}

/// What decides whether an item's permissions can be changed: its mode and identity, read without following a link,
/// and what stands in the way of a change.
public struct PermissionTarget: Equatable, Sendable {
    /// The permission bits, set-user-ID, set-group-ID and sticky included.
    public let mode: UInt16
    public let identity: FileObjectIdentity
    /// Why a change would be refused now, or nil when one can be made.
    public let refusal: PermissionRefusal?
    public init(mode: UInt16, identity: FileObjectIdentity, refusal: PermissionRefusal? = nil) {
        self.mode = mode; self.identity = identity; self.refusal = refusal
    }
}
