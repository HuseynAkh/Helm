import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// "Downloads off" for a piece of work. A file or folder kept in a cloud can be on this Mac in name only, and macOS
/// fetches it the moment something reads it. Work marked here is refused that read instead: it fails at once with
/// `FileSystemError.notDownloaded`, and nothing is fetched.
///
/// The mark belongs to a task, while macOS keeps its switch per thread, so there are two halves. `off` marks the
/// task. `IOExecutor` reads the mark where it hands a body to its queue and runs that body inside
/// `withDownloadsOff`, which turns the switch off on the queue's thread and puts it back afterwards.
public enum DatalessGuard {
    /// Whether the current task runs with downloads off. False unless inside `off`.
    @TaskLocal public static var isOff: Bool = false

    /// Runs `work` with downloads off. Tasks that `work` starts are marked too, apart from detached ones.
    /// A listing or a size stream (`enumerate`, `sizeOfTree`) must be made inside `work`. Its reads run on a task
    /// that starts when the stream is made, so it carries the mark of the task that made it, not of the one that
    /// reads it: a stream made outside and read inside runs with downloads on.
    public static func off<T>(_ work: () async throws -> T) async rethrows -> T {
        try await $isOff.withValue(true) { try await work() }
    }

    /// Runs `work` with downloads off when `wanted`. Otherwise `work` runs as the caller does, so inside another
    /// `off` it stays off.
    public static func off<T>(if wanted: Bool, _ work: () async throws -> T) async rethrows -> T {
        if wanted { return try await off(work) }
        return try await work()
    }

    /// Runs `body` on the calling thread with downloads off: a read that would fetch a file, or load a folder's
    /// names, from a cloud is refused by macOS and nothing is fetched. The thread's own setting is put back when
    /// `body` returns or throws, so a queue thread that is used again starts as it was.
    /// The switch can only fail to turn on a macOS older than the ones Helm runs on; `body` then runs as it is.
    public static func withDownloadsOff<T>(_ body: () throws -> T) rethrows -> T {
        #if canImport(Darwin)
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, scope = IOPOL_SCOPE_THREAD
        let before = getiopolicy_np(policy, scope)
        // Already off: an outer call owns the switch and will put it back.
        guard before != IOPOL_MATERIALIZE_DATALESS_FILES_OFF,
              setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return try body() }
        defer { _ = setiopolicy_np(policy, scope, before < 0 ? IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT : before) }
        return try body()
        #else
        // Only macOS keeps files in name only, so elsewhere there is nothing to switch off.
        return try body()
        #endif
    }

    /// Whether the calling thread has downloads off right now. For tests that show the switch is on inside a marked
    /// body and back afterwards.
    public static var threadPolicyIsOffForTesting: Bool {
        #if canImport(Darwin)
        return getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            == IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        #else
        return false
        #endif
    }
}
