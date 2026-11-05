import Foundation
import HelmCore

/// Explicitly driven monitor fixture preserves start/stop semantics (B-072).
public actor InMemoryMonitor: DirectoryMonitor {
    public nonisolated let events: AsyncStream<MonitorEvent>
    private let continuation: AsyncStream<MonitorEvent>.Continuation
    private var active = false
    public init() {
        let pair = AsyncStream<MonitorEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
    }
    public func start() async throws { active = true }
    public func stop() async { active = false; continuation.finish() }
    public func emit(_ event: MonitorEvent) { if active { continuation.yield(event) } }
    deinit { continuation.finish() }
}
