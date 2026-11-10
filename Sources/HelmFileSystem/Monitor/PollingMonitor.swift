import Foundation
import HelmCore

/// Portable fallback compares child identities as well as metadata, detecting same-count renames (B-015).
public actor PollingMonitor: DirectoryMonitor {
    public nonisolated let events: AsyncStream<MonitorEvent>
    private let continuation: AsyncStream<MonitorEvent>.Continuation
    private let directory: URL
    private let fileSystem: any FileSystem
    private let interval: UInt64
    private var baseline: [String: ChangeToken]?
    private var lastFailure: FileSystemError?
    private var task: Task<Void, Never>?
    private var stopped = false
    public init(directory: URL, fileSystem: any FileSystem, interval: TimeInterval = 3) {
        self.directory = directory; self.fileSystem = fileSystem
        self.interval = UInt64(min(max(interval.isFinite ? interval : 3, 0.01), 86_400) * 1_000_000_000)
        let pair = AsyncStream<MonitorEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    private func read() async throws -> [String: ChangeToken] {
        var result: [String: ChangeToken] = [:]
        for try await batch in fileSystem.enumerate(directory, options: EnumerationOptions(includeHidden: true)) {
            for entry in batch { result[entry.id.rawValue] = entry.changeToken }
        }
        return result
    }
    public func start() async throws {
        guard task == nil && !stopped else { return }
        baseline = try await read()
        guard !stopped && task == nil else { return }
        let interval = self.interval
        task = Task { [weak self] in
            var delay = interval
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                let began = DispatchTime.now().uptimeNanoseconds
                await self?.poll()
                delay = PollingMonitor.nextDelay(interval: interval, lastRead: DispatchTime.now().uptimeNanoseconds &- began)
            }
        }
    }
    /// Keeps reads to about a fifth of wall time, so a large folder on a slow share is not listed nonstop (FB1-10).
    static func nextDelay(interval: UInt64, lastRead: UInt64) -> UInt64 {
        let scaled = lastRead.multipliedReportingOverflow(by: 4)
        return scaled.overflow ? UInt64.max : max(interval, scaled.partialValue)
    }
    /// Deterministic tick for tests; production calls this at the configured interval.
    public func poll() async {
        guard !stopped else { return }
        do {
            let next = try await read()
            guard !stopped else { return }
            if lastFailure != nil {
                // Recovery requires one full validation even when metadata did not change.
                continuation.yield(.rescan)
            } else if let previous = baseline {
                let changed = Set(previous.keys).union(next.keys).filter { previous[$0] != next[$0] }
                if !changed.isEmpty { continuation.yield(.changed(paths: Set(changed))) }
            }
            baseline = next
            lastFailure = nil
        } catch {
            guard !stopped else { return }
            let failure = FileSystemError.mapping(error)
            guard lastFailure != failure else { return }
            lastFailure = failure
            if failure == .notFound { continuation.yield(.rootChanged) }
            else { continuation.yield(.unavailable(failure == .permissionDenied ? .permissionDenied : .unavailable)) }
        }
    }
    public func stop() async { stopped = true; task?.cancel(); task = nil; continuation.finish() }
    deinit { task?.cancel(); continuation.finish() }
}
