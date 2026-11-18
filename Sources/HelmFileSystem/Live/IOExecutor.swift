import Foundation

/// Bounded blocking queues isolate volumes; timeout quarantines a stalled queue (B-107).
/// Kernel calls cannot be interrupted. Timed-out mutations may still finish and require reconciliation.
///
/// A timed-out read that names the folder or item it read shuts only that path, not its lane: a later read of that
/// path or inside it fails at once as timed out, and every other read on the lane carries on. Such a read is most
/// often one macOS holds while one of its privacy questions is unanswered. The whole lane still shuts, as it does for
/// a change, when the disk itself looks stuck: reads stalled in two places at once, neither inside the other; a
/// stalled read that named no path; or stalled reads holding every one of the lane's workers, so that nothing else
/// there could run. A change can't say where it lands, so while any read on a lane is stalled a change there is
/// refused as timed out, as it was when such a read shut the whole lane.
public final class IOExecutor: @unchecked Sendable {
    /// A call waiting for one of its lane's workers. `path` is a read's path as stalls compare it.
    private struct Waiting {
        let path: String?
        let mutation: Bool
        let reject: @Sendable () -> Void
    }
    private let lock = NSLock()
    private var queues: [String: OperationQueue] = [:]
    private var quarantined: Set<String> = []
    private var mutationQuarantine: Set<String> = []
    private var timedOutBodies: [UUID: Set<String>] = [:]
    /// The timed-out reads still out that named a path: the lane each ran on, and that path as `spelling` writes it.
    private var stalledReads: [UUID: (lane: String, path: String)] = [:]
    private var queued: [String: [UUID: Waiting]] = [:]
    private let width: Int
    private let timeout: TimeInterval
    public init(maxConcurrentOperations: Int = 4, timeout: TimeInterval = 30) {
        width = max(1, maxConcurrentOperations)
        self.timeout = max(0.001, timeout.isFinite ? timeout : 30)
    }
    /// A path as stalls compare it: without regard to case, as the Mac's own disk compares names, and with no slash
    /// at the end. Nothing here asks the disk, so the caller settles the spelling first (`PathSpelling.standardPath`).
    static func spelling(_ path: String) -> String {
        var spelled = path.lowercased()
        while spelled.count > 1 && spelled.hasSuffix("/") { spelled.removeLast() }
        return spelled
    }
    /// Whether `path` is `folder` or inside it, folder by folder: a name that only starts the same isn't inside.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? folder : folder + "/")
    }
    // Caller holds the executor lock across registration and quarantine admission.
    private func queue(for volume: String) throws -> OperationQueue {
        guard !quarantined.contains(volume) else { throw FileSystemError.timedOut }
        if let existing = queues[volume] { return existing }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = width; queue.qualityOfService = .utility
        queues[volume] = queue
        return queue
    }
    /// Whether a call may start: none of its lanes is shut, and no read stalled on them holds it up. A stalled read
    /// holds up a read of its path or inside it, and every change. Caller holds the executor lock.
    private func admits(_ volumes: Set<String>, path: String?, mutation: Bool) -> Bool {
        guard quarantined.isDisjoint(with: volumes) else { return false }
        for stall in stalledReads.values where volumes.contains(stall.lane) {
            if mutation { return false }
            if let path, Self.isInside(path, stall.path) { return false }
        }
        return true
    }
    /// How many places reads are stalled in on `lane`. A stall inside another one counts with it, as one place.
    private func stalledPlaces(on lane: String) -> Int {
        let paths = Set(stalledReads.values.filter { $0.lane == lane }.map(\.path))
        return paths.filter { path in !paths.contains { $0 != path && Self.isInside(path, $0) } }.count
    }
    private func register<T>(_ state: IOResultState<T>, id: UUID, volumes: Set<String>, worker: String,
                             path: String?, mutation: Bool) throws -> OperationQueue {
        lock.lock(); defer { lock.unlock() }
        guard admits(volumes, path: path, mutation: mutation) else { throw FileSystemError.timedOut }
        let queue = try queue(for: worker)
        let waiting = Waiting(path: path, mutation: mutation) { state.cancelIfQueued(error: FileSystemError.timedOut) }
        for volume in volumes { queued[volume, default: [:]][id] = waiting }
        return queue
    }
    private func begin<T>(_ state: IOResultState<T>, id: UUID, volumes: Set<String>, path: String?, mutation: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for volume in volumes { queued[volume]?[id] = nil }
        guard admits(volumes, path: path, mutation: mutation) else {
            state.cancelIfQueued(error: FileSystemError.timedOut)
            return false
        }
        return state.begin()
    }
    private func watch<T>(_ state: IOResultState<T>, id: UUID, volumes: Set<String>, path: String?, mutation: Bool) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self, weak state] in
            guard let self, let state else { return }
            self.checkDeadline(state, id: id, volumes: volumes, path: path, mutation: mutation)
        }
    }
    private func checkDeadline<T>(_ state: IOResultState<T>, id: UUID, volumes: Set<String>, path: String?, mutation: Bool) {
        lock.lock(); defer { lock.unlock() }
        let remaining = state.expireIfIdle(timeout: timeout) {
            timedOutBodies[id] = volumes
            if !mutation, let path, volumes.count == 1, let lane = volumes.first {
                stalledReads[id] = (lane, path)
                let held = stalledReads.values.filter { $0.lane == lane }.count
                if stalledPlaces(on: lane) < 2, held < width {
                    // Only this place is stuck. What waits to read in it is turned away, and so is every change.
                    for (waiter, call) in queued[lane] ?? [:]
                    where call.mutation || call.path.map({ Self.isInside($0, path) }) == true {
                        queued[lane]?[waiter] = nil
                        call.reject()
                    }
                    return
                }
            }
            if mutation { mutationQuarantine.formUnion(volumes) }
            quarantined.formUnion(volumes)
            for volume in volumes {
                let waiting = queued.removeValue(forKey: volume) ?? [:]
                for call in waiting.values { call.reject() }
            }
        }
        if let remaining {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining) { [weak self, weak state] in
                guard let self, let state else { return }
                self.checkDeadline(state, id: id, volumes: volumes, path: path, mutation: mutation)
            }
        }
    }
    /// A timed-out body has come back: its own stall clears, and a lane only timed-out reads shut opens once the last
    /// of them is back.
    private func bodyReturned(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        stalledReads[id] = nil
        guard let volumes = timedOutBodies.removeValue(forKey: id) else { return }
        for volume in volumes where !mutationQuarantine.contains(volume) {
            if !timedOutBodies.values.contains(where: { $0.contains(volume) }) { quarantined.remove(volume) }
        }
    }
    /// Reopen a reconciled mutation lane only after every timed-out body has returned (B-107).
    /// The caller must reconcile late filesystem effects before invoking this method.
    @discardableResult public func clearQuarantine(volume: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !timedOutBodies.values.contains(where: { $0.contains(volume) }) else { return false }
        mutationQuarantine.remove(volume); quarantined.remove(volume)
        return true
    }
    /// Reopens every lane a timed-out mutation shut, as `clearQuarantine` does for one. For the moment the person
    /// has acknowledged the stalled change, which is the reconciliation `clearQuarantine` asks for.
    /// Such a lane stays shut while a timed-out call on it is still out, and the answer is then false: ask again
    /// once it returns. True means every lane a mutation shut is open again.
    /// A lane shut only by a timed-out read, or with a read stalled in one folder, is left alone and doesn't make the
    /// answer false, since a read leaves nothing to reconcile. Its stall clears by itself when the read returns, and
    /// until then a change on that lane still fails as timed out, as does every call on a lane that read shut.
    @discardableResult public func reopenAll() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let stillOut = timedOutBodies.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let settled = mutationQuarantine.subtracting(stillOut)
        mutationQuarantine.subtract(settled); quarantined.subtract(settled)
        return mutationQuarantine.isEmpty
    }
    /// Conservative mutation lane: a timeout requires explicit reconciliation (B-107).
    public func run<T: Sendable>(volume: String = "/", _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run(volumes: [volume], body)
    }
    /// Read-only timeouts recover once all timed-out bodies on the volume return (F-035/B-107).
    /// `path` is the folder or item the read is of, spelled as `PathSpelling.standardPath` spells it. With one, a
    /// timeout shuts only that path and what is inside it; with none, it shuts the whole lane.
    public func runRead<T: Sendable>(volume: String = "/", path: String? = nil,
        _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run(volumes: [volume], mutation: false, path: path) { _ in try body() }
    }
    /// Enumeration batches report progress to bound inactivity rather than total listing time (F-035).
    /// `path` is the folder listed, as for `runRead`.
    public func runReadWithProgress<T: Sendable>(volume: String = "/", path: String? = nil,
        _ body: @escaping @Sendable (@Sendable () -> Void) throws -> T) async throws -> T {
        try await run(volumes: [volume], mutation: false, path: path, body)
    }
    /// Copy adapters may reset the inactivity watchdog from native progress callbacks (F-052/B-107).
    public func runWithProgress<T: Sendable>(volumes: [String],
        _ body: @escaping @Sendable (@Sendable () -> Void) throws -> T) async throws -> T {
        try await run(volumes: volumes, mutation: true, body)
    }
    func run<T: Sendable>(volumes: [String], _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run(volumes: volumes, mutation: true) { _ in try body() }
    }
    private func run<T: Sendable>(volumes: [String], mutation: Bool, path: String? = nil,
        _ body: @escaping @Sendable (@Sendable () -> Void) throws -> T) async throws -> T {
        try Task.checkCancellation()
        // "Downloads off" is a mark on the caller's task, which the queue's thread can't see. It is read here and
        // applied to that thread for as long as the body runs.
        let downloadsOff = DatalessGuard.isOff
        let worker = volumes.first ?? "/"
        let footprint = Set(volumes.isEmpty ? [worker] : volumes)
        // Only a read's path counts. An empty one says nothing, so it counts as none.
        let place = mutation ? nil : path.flatMap { $0.isEmpty ? nil : Self.spelling($0) }
        let state = IOResultState<T>()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let queue: OperationQueue
                do { queue = try register(state, id: id, volumes: footprint, worker: worker, path: place, mutation: mutation) }
                catch { state.complete(.failure(error)); return }
                queue.addOperation {
                    guard self.begin(state, id: id, volumes: footprint, path: place, mutation: mutation) else { return }
                    self.watch(state, id: id, volumes: footprint, path: place, mutation: mutation)
                    defer { self.bodyReturned(id: id) }
                    do {
                        let value = downloadsOff ? try DatalessGuard.withDownloadsOff { try body { state.progress() } }
                            : try body { state.progress() }
                        state.complete(.success(value))
                    } catch { state.complete(.failure(error)) }
                }
            }
        } onCancel: { state.cancelIfQueued() }
    }

}
/// Lock covers continuation installation and exactly-once completion, including cancel-before-install.
final class IOResultState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var started = false
    private var lastProgress: UInt64 = 0
    func progress() {
        lock.lock(); defer { lock.unlock() }
        guard result == nil, started else { return }
        lastProgress = DispatchTime.now().uptimeNanoseconds
    }
    // Progress and expiration compete under the same state lock; no stale-deadline race.
    func expireIfIdle(timeout: TimeInterval, onExpiration: () -> Void) -> TimeInterval? {
        lock.lock()
        guard result == nil, started else { lock.unlock(); return nil }
        let remaining = timeout - Double(DispatchTime.now().uptimeNanoseconds - lastProgress) / 1_000_000_000
        if remaining > 0 { lock.unlock(); return remaining }
        let failure: Result<T, Error> = .failure(FileSystemError.timedOut)
        result = failure
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        onExpiration()
        continuation?.resume(with: failure)
        return nil
    }
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return false }
        started = true
        lastProgress = DispatchTime.now().uptimeNanoseconds
        return true
    }
    func cancelIfQueued(error: Error = CancellationError()) {
        lock.lock()
        guard !started, result == nil else { lock.unlock(); return }
        let result: Result<T, Error> = .failure(error)
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    @discardableResult func complete(_ result: Result<T, Error>, onCompletion: () -> Void = {}) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        onCompletion()
        continuation?.resume(with: result)
        return true
    }
}
/// Synchronization only guards the cancellation bit used by synchronous enumeration (B-107).
final class EnumerationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
