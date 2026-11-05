// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Bounded blocking queues isolate volumes; timeout quarantines a stalled queue (B-107).
/// Kernel calls cannot be interrupted. Timed-out mutations may still finish and require reconciliation.
public final class IOExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: OperationQueue] = [:]
    private var quarantined: Set<String> = []
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
    private func expire<T>(_ state: IOResultState<T>, volumes: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        // Admission checks and timeout quarantine share one lock across the whole footprint.
        state.complete(.failure(FileSystemError.timedOut), onCompletion: {
            quarantined.formUnion(volumes)
            for volume in volumes {
                let waiting = queued.removeValue(forKey: volume) ?? [:]
                for reject in waiting.values { reject() }
            }
        })
    }
    /// The caller supplies a mount identity when known; unrelated queues survive a blocked mount.
    public func run<T: Sendable>(volume: String = "/", _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run(volumes: [volume], body)
    }
    // Native multi-path calls register every touched volume, independently of worker selection.
    func run<T: Sendable>(volumes: [String], _ body: @escaping @Sendable () throws -> T) async throws -> T {
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
                    do { state.complete(.success(try body())) }
                    catch { state.complete(.failure(error)) }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self, weak state] in
                    if let state { self?.expire(state, volumes: footprint) }
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
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return false }
        started = true
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
