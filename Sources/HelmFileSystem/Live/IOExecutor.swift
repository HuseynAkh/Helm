// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Bounded blocking queues isolate volumes; timeout quarantines a stalled queue (B-107).
/// Kernel calls cannot be interrupted. Timed-out mutations may still finish and require reconciliation.
public final class IOExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: OperationQueue] = [:]
    private var quarantined: Set<String> = []
    private var mutationQuarantine: Set<String> = []
    private var timedOutBodies: [UUID: Set<String>] = [:]
    private var queued: [String: [UUID: @Sendable () -> Void]] = [:]
    private let width: Int
    private let timeout: TimeInterval
    public init(maxConcurrentOperations: Int = 4, timeout: TimeInterval = 30) {
        width = max(1, maxConcurrentOperations)
        self.timeout = max(0.001, timeout.isFinite ? timeout : 30)
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
    private func register<T>(_ state: IOResultState<T>, id: UUID, volumes: Set<String>, worker: String) throws -> OperationQueue {
        lock.lock(); defer { lock.unlock() }
        guard quarantined.isDisjoint(with: volumes) else { throw FileSystemError.timedOut }
        let queue = try queue(for: worker)
        for volume in volumes {
            queued[volume, default: [:]][id] = { state.cancelIfQueued(error: FileSystemError.timedOut) }
        }
        return queue
    }
    private func begin<T>(_ state: IOResultState<T>, id: UUID, volumes: Set<String>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for volume in volumes { queued[volume]?[id] = nil }
        guard quarantined.isDisjoint(with: volumes) else {
            state.cancelIfQueued(error: FileSystemError.timedOut)
            return false
        }
        return state.begin()
    }
    private func watch<T>(_ state: IOResultState<T>, id: UUID, volumes: Set<String>, mutation: Bool) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self, weak state] in
            guard let self, let state else { return }
            self.checkDeadline(state, id: id, volumes: volumes, mutation: mutation)
        }
    }
    private func checkDeadline<T>(_ state: IOResultState<T>, id: UUID, volumes: Set<String>, mutation: Bool) {
        lock.lock(); defer { lock.unlock() }
        let remaining = state.expireIfIdle(timeout: timeout) {
            timedOutBodies[id] = volumes
            if mutation { mutationQuarantine.formUnion(volumes) }
            quarantined.formUnion(volumes)
            for volume in volumes {
                let waiting = queued.removeValue(forKey: volume) ?? [:]
                for reject in waiting.values { reject() }
            }
        }
        if let remaining {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining) { [weak self, weak state] in
                guard let self, let state else { return }
                self.checkDeadline(state, id: id, volumes: volumes, mutation: mutation)
            }
        }
    }
    private func bodyReturned(id: UUID) {
        lock.lock(); defer { lock.unlock() }
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
    /// Conservative mutation lane: a timeout requires explicit reconciliation (B-107).
    public func run<T: Sendable>(volume: String = "/", _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run(volumes: [volume], body)
    }
    /// Read-only timeouts recover once all timed-out bodies on the volume return (F-035/B-107).
    public func runRead<T: Sendable>(volume: String = "/", _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run(volumes: [volume], mutation: false) { _ in try body() }
    }
    /// Enumeration batches report progress to bound inactivity rather than total listing time (F-035).
    public func runReadWithProgress<T: Sendable>(volume: String = "/",
        _ body: @escaping @Sendable (@Sendable () -> Void) throws -> T) async throws -> T {
        try await run(volumes: [volume], mutation: false, body)
    }
    /// Copy adapters may reset the inactivity watchdog from native progress callbacks (F-052/B-107).
    public func runWithProgress<T: Sendable>(volumes: [String],
        _ body: @escaping @Sendable (@Sendable () -> Void) throws -> T) async throws -> T {
        try await run(volumes: volumes, mutation: true, body)
    }
    func run<T: Sendable>(volumes: [String], _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run(volumes: volumes, mutation: true) { _ in try body() }
    }
    private func run<T: Sendable>(volumes: [String], mutation: Bool,
        _ body: @escaping @Sendable (@Sendable () -> Void) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = volumes.first ?? "/"
        let footprint = Set(volumes.isEmpty ? [worker] : volumes)
        let state = IOResultState<T>()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let queue: OperationQueue
                do { queue = try register(state, id: id, volumes: footprint, worker: worker) }
                catch { state.complete(.failure(error)); return }
                queue.addOperation {
                    guard self.begin(state, id: id, volumes: footprint) else { return }
                    self.watch(state, id: id, volumes: footprint, mutation: mutation)
                    defer { self.bodyReturned(id: id) }
                    do { state.complete(.success(try body { state.progress() })) }
                    catch { state.complete(.failure(error)) }
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
