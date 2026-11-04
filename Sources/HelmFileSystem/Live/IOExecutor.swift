// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Bounded blocking queues isolate volumes; timeout quarantines a stalled queue (B-107).
/// Kernel calls cannot be interrupted. Timed-out mutations may still finish and require reconciliation.
public final class IOExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: OperationQueue] = [:]
    private var quarantined: Set<String> = []
    private let width: Int
    private let timeout: TimeInterval
    public init(maxConcurrentOperations: Int = 4, timeout: TimeInterval = 30) {
        width = max(1, maxConcurrentOperations)
        self.timeout = max(0.001, timeout.isFinite ? timeout : 30)
    }
    private func queue(for volume: String) throws -> OperationQueue {
        lock.lock(); defer { lock.unlock() }
        guard !quarantined.contains(volume) else { throw FileSystemError.timedOut }
        if let existing = queues[volume] { return existing }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = width; queue.qualityOfService = .utility
        queues[volume] = queue
        return queue
    }
    private func quarantine(_ volume: String) {
        lock.lock(); quarantined.insert(volume); lock.unlock()
    }
    /// The caller supplies a mount identity when known; unrelated queues survive a blocked mount.
    public func run<T: Sendable>(volume: String = "/", _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let queue = try queue(for: volume)
        let state = IOResultState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                queue.addOperation {
                    guard state.begin() else { return }
                    do { state.complete(.success(try body())) }
                    catch { state.complete(.failure(error)) }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self, weak state] in
                    state?.complete(.failure(FileSystemError.timedOut), onCompletion: { self?.quarantine(volume) })
                }
            }
        } onCancel: { state.cancelIfQueued() }
    }
}
/// Lock covers continuation installation and exactly-once completion, including cancel-before-install.
private final class IOResultState<T: Sendable>: @unchecked Sendable {
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
    func cancelIfQueued() {
        lock.lock()
        guard !started, result == nil else { lock.unlock(); return }
        let result: Result<T, Error> = .failure(CancellationError())
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
