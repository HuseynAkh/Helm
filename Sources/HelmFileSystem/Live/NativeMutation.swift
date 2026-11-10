import Foundation
import HelmCore
#if os(macOS)
import Darwin

/// Finder-like primitives for the bounded-race contract (O1-1, docs/handoff/OWNER_RULINGS.md).
/// Each one admits its destination exclusively: a name that appears after planning is never overwritten.
/// macOS has no atomic compare-identity-and-rename, so a small window remains between the caller's
/// evidence check and these calls. That window is disclosed, not hidden.
enum NativeMutation {
    /// Copies beside the destination and publishes with an exclusive rename, so a failed or cancelled
    /// copy never leaves a partial item under the final name.
    static func copy(from source: URL, to destination: URL, cancellation: EnumerationCancellation,
                     progress: @escaping @Sendable () -> Void) throws {
        try cancellation.check()
        let stage = destination.deletingLastPathComponent()
            .appendingPathComponent(".helm-copy-\(UUID().uuidString)")
        do {
            try cloneOrCopy(from: source, to: stage, cancellation: cancellation, progress: progress)
            try publish(stage, as: destination)
        } catch {
            // The stage name is unique to this call, so removing it can't touch anyone else's file.
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    /// EEXIST means the rename did nothing, which is what lets the executor retry with a new name.
    static func publish(_ source: URL, as destination: URL) throws {
        let code = source.withUnsafeFileSystemRepresentation { from -> Int32 in
            destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return EINVAL }
                return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        switch code {
        case 0: return
        case EEXIST: throw FileSystemError.collision(noMutation: true)
        // Some network and third-party file systems have no exclusive rename. Finder still works
        // there, so check first and accept the race these volumes leave no way to close.
        case ENOTSUP, EINVAL, ENOSYS: try publishWithoutExclusiveRename(source, as: destination)
        default: throw FileSystemError.mapping(NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
        }
    }

    private static func publishWithoutExclusiveRename(_ source: URL, as destination: URL) throws {
        var status = Darwin.stat()
        let exists = destination.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &status) == 0
        }
        if exists { throw FileSystemError.collision(noMutation: true) }
        do { try FileManager.default.moveItem(at: source, to: destination) }
        catch { throw FileSystemError.mapping(error) }
    }

    private static func cloneOrCopy(from source: URL, to stage: URL, cancellation: EnumerationCancellation,
                                    progress: @escaping @Sendable () -> Void) throws {
        let context = CopyContext(cancellation: cancellation, progress: progress)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { _, stage, _, _, _, context -> Int32 in
            guard let context else { return COPYFILE_CONTINUE }
            let value = Unmanaged<CopyContext>.fromOpaque(context).takeUnretainedValue()
            if stage == COPYFILE_ERR { return COPYFILE_QUIT }
            if value.isCancelled { return COPYFILE_QUIT }
            value.progress()
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        let retained = Unmanaged.passUnretained(context).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), retained)
        // Clones on APFS; otherwise copies data, metadata, extended attributes and ACLs. Links stay links.
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_CLONE)
        let result = source.withUnsafeFileSystemRepresentation { from -> Int32 in
            stage.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { errno = EINVAL; return -1 }
                return copyfile(from, to, state, flags)
            }
        }
        let code = errno
        withExtendedLifetime(context) {}
        if context.isCancelled { throw ConditionalMutationError.cancelledBeforeMutation }
        guard result == 0 else { throw FileSystemError.mapping(NSError(domain: NSPOSIXErrorDomain, code: Int(code))) }
    }

    private final class CopyContext {
        let cancellation: EnumerationCancellation
        let progress: @Sendable () -> Void
        init(cancellation: EnumerationCancellation, progress: @escaping @Sendable () -> Void) {
            self.cancellation = cancellation; self.progress = progress
        }
        var isCancelled: Bool {
            do { try cancellation.check(); return false } catch { return true }
        }
    }
}
#endif
