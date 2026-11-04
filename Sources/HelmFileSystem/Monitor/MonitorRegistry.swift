import Foundation
import HelmCore

/// One underlying watcher fans out into independent subscriber streams (B-104).
public actor MonitorRegistry {
    private struct Subscription {
        let monitor: any DirectoryMonitor
        var listeners: [UUID: AsyncStream<MonitorEvent>.Continuation]
        let generation: UInt64
        var task: Task<Void, Never>?
    }
    private let factory: @Sendable (URL) -> any DirectoryMonitor
    private var subscriptions: [String: Subscription] = [:]
    private var generation: UInt64 = 0
    public init(factory: @escaping @Sendable (URL) -> any DirectoryMonitor) { self.factory = factory }
    public func subscribe(path: URL) -> AsyncStream<MonitorEvent> {
        let key = path.standardizedFileURL.path
        let id = UUID()
        let pair = AsyncStream<MonitorEvent>.makeStream()
        if subscriptions[key] == nil {
            generation &+= 1
            let token = generation
            let monitor = factory(path)
            subscriptions[key] = Subscription(monitor: monitor, listeners: [:], generation: token)
            let task = Task { [weak self] in
                do {
                    try await monitor.start()
                    for await event in monitor.events {
                        await self?.broadcast(event, key: key, generation: token)
                    }
                } catch { await self?.broadcast(.unavailable(.unavailable), key: key, generation: token) }
            }
            subscriptions[key]?.task = task
        }
        guard let token = subscriptions[key]?.generation else { pair.continuation.finish(); return pair.stream }
        subscriptions[key]?.listeners[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(key: key, id: id, generation: token) }
        }
        return pair.stream
    }
    private func broadcast(_ event: MonitorEvent, key: String, generation: UInt64) {
        guard let subscription = subscriptions[key], subscription.generation == generation else { return }
        for listener in subscription.listeners.values { listener.yield(event) }
    }
    private func unsubscribe(key: String, id: UUID, generation: UInt64) async {
        guard var subscription = subscriptions[key], subscription.generation == generation else { return }
        subscription.listeners.removeValue(forKey: id)
        if subscription.listeners.isEmpty {
            subscriptions.removeValue(forKey: key)
            subscription.task?.cancel()
            await subscription.monitor.stop()
        } else { subscriptions[key] = subscription }
    }
    public func volumeUnmounted(at root: URL) {
        let path = root.standardizedFileURL.path
        for (key, subscription) in subscriptions where key == path || key.hasPrefix(path == "/" ? "/" : path + "/") {
            broadcast(.volumeUnmounted, key: key, generation: subscription.generation)
        }
    }
    public func stopAll() async {
        let old = subscriptions
        subscriptions.removeAll()
        for subscription in old.values {
            subscription.task?.cancel()
            for listener in subscription.listeners.values { listener.finish() }
            await subscription.monitor.stop()
        }
    }
    public var observedDirectoryCount: Int { subscriptions.count }
    deinit {
        for subscription in subscriptions.values {
            subscription.task?.cancel()
            for listener in subscription.listeners.values { listener.finish() }
            let monitor = subscription.monitor
            Task { await monitor.stop() }
        }
    }
}
