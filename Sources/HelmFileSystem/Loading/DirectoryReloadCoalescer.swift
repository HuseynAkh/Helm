// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Coalesces directory notifications before reducer refresh effects (F-008/B-016/B-073).
/// The injected clock decides deadlines; flush() permits deterministic fake-clock driving.
public actor DirectoryReloadCoalescer {
    private var coalescer: EventCoalescer
    private let generation: Generation
    private let output: AsyncStream<TabAction>.Continuation
    public nonisolated let actions: AsyncStream<TabAction>
    private var revalidation: MonitorEvent?
    private var stopped = false
    private var pendingChanges = false

    public init(generation: Generation, clock: any HelmClock = SystemHelmClock(),
                quietInterval: TimeInterval = 0.25, maximumInterval: TimeInterval = 1) {
        self.generation = generation
        self.coalescer = EventCoalescer(clock: clock, quietInterval: quietInterval, maximumInterval: maximumInterval)
        let pair = AsyncStream<TabAction>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.actions = pair.stream; self.output = pair.continuation
    }

    public func receive(_ event: MonitorEvent) {
        guard !stopped else { return }
        // Revalidation cannot be overwritten by an ordinary changed event in a slow consumer's buffer.
        if case .changed = event { pendingChanges = true }
        switch event {
        case .rootChanged, .volumeUnmounted: revalidation = event
        default: break
        }
        publish(coalescer.receive(event))
    }
    public func flush() {
        guard !stopped else { return }
        publish(coalescer.flushIfDue())
    }
    /// Call after consuming root validation and successfully validating this watch's root.
    /// Until acknowledgement, root invalidation survives newest-buffer replacement (F-008/B-014).
    public func acknowledgeRootValidation() {
        guard !stopped else { return }
        revalidation = nil
    }
    public func finish() { stopped = true; output.finish() }

    /// Runs until cancelled or the source ends. The caller owns/cancels this task with its monitor lane.
    /// The timer only wakes the coalescer; elapsed time is always measured by the injected HelmClock.
    public func consume(_ events: AsyncStream<MonitorEvent>,
                        sleep: @escaping @Sendable () async throws -> Void = {
                            try await Task.sleep(nanoseconds: 25_000_000)
                        }) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await self.receive(event)
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    do { try await sleep() } catch { break }
                    await self.flush()
                }
            }
            await group.next()
            group.cancelAll()
        }
        // A finite event source must not lose a final pending change inside the quiet window.
        if !Task.isCancelled && pendingChanges { publish([.rescan]) }
        finish()
    }

    private func publish(_ events: [MonitorEvent]) {
        for event in events {
            pendingChanges = false
            // Full refreshes safely subsume dropped changed-path sets in the newest-only buffer.
            let safeEvent: MonitorEvent
            if let revalidation { safeEvent = revalidation }
            else if case .changed = event { safeEvent = .rescan }
            else { safeEvent = event }
            output.yield(.monitorEvent(generation, safeEvent))
        }
    }
}
