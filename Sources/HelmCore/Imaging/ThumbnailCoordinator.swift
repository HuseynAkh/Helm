// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Portable F-048 fan-out, cancellation and bounded LRU caching fix B-055/B-056.
/// Producer adapters must propagate task cancellation into their platform generator.
public actor ThumbnailCoordinator<Image: Sendable> {
    public typealias Producer = @Sendable (ThumbnailKey) async throws -> ThumbnailImage<Image>
    private typealias Continuation = AsyncStream<ThumbnailDelivery<Image>>.Continuation
    private struct Flight {
        let generation: UUID
        let task: Task<Void, Never>
        var subscribers: [ThumbnailRequestToken: Continuation]
    }
    private struct Cached {
        let result: Result<ThumbnailImage<Image>, ThumbnailFailure>
        let cost: Int
        let expires: Date?
    }
    private let producer: Producer
    private let now: @Sendable () -> Date
    private let failureTTL: TimeInterval
    private var costLimit: Int
    private var cache: [ThumbnailKey: Cached] = [:]
    private var recency: [ThumbnailKey] = [] // oldest first; bounded by cache cost (minimum one byte).
    private var totalCost: Int = 0
    private var flights: [ThumbnailKey: Flight] = [:]

    public init(costLimitBytes: Int, failureTTL: TimeInterval = 5,
                now: @escaping @Sendable () -> Date = { Date() }, producer: @escaping Producer) {
        self.costLimit = max(0, costLimitBytes)
        self.failureTTL = failureTTL.isFinite ? max(0, failureTTL) : 0
        self.now = now; self.producer = producer
    }

    deinit {
        // No asynchronous self capture: cancellation and stream termination are synchronous.
        for flight in flights.values {
            flight.task.cancel()
            for continuation in flight.subscribers.values { continuation.finish() }
        }
    }

    public func subscribe(to key: ThumbnailKey) -> ThumbnailSubscription<Image> {
        let token = ThumbnailRequestToken()
        let pair = AsyncStream<ThumbnailDelivery<Image>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel(token) }
        }
        if let hit = cachedResult(for: key) {
            pair.continuation.yield(ThumbnailDelivery(token: token, result: hit))
            pair.continuation.finish()
        } else if var flight = flights[key] {
            flight.subscribers[token] = pair.continuation
            flights[key] = flight
        } else {
            let generation = UUID()
            let producer = self.producer
            let task = Task { [weak self] in
                let result: Result<ThumbnailImage<Image>, ThumbnailFailure>
                do {
                    let image = try await producer(key)
                    result = Task.isCancelled ? .failure(.cancelled) : .success(image)
                } catch {
                    result = (error is CancellationError || Task.isCancelled) ? .failure(.cancelled) : .failure(.unavailable)
                }
                await self?.complete(key, generation: generation, result: result)
            }
            flights[key] = Flight(generation: generation, task: task, subscribers: [token: pair.continuation])
        }
        return ThumbnailSubscription(token: token, deliveries: pair.stream)
    }

    public func cancel(_ token: ThumbnailRequestToken) {
        for (key, var flight) in flights {
            guard let subscriber = flight.subscribers.removeValue(forKey: token) else { continue }
            if flight.subscribers.isEmpty {
                flights.removeValue(forKey: key)
                flight.task.cancel()
            } else { flights[key] = flight }
            subscriber.finish()
            return
        }
    }

    /// Monitor changes drop cached content and cancel existing subscribers; callers request fresh keys.
    public func invalidate(_ itemID: ItemID) {
        for key in Array(cache.keys) where key.itemID == itemID { removeCached(key) }
        for key in Array(flights.keys) where key.itemID == itemID {
            guard let flight = flights.removeValue(forKey: key) else { continue }
            flight.task.cancel()
            for subscriber in flight.subscribers.values { subscriber.finish() }
        }
    }

    public func setCostLimitBytes(_ limit: Int) {
        costLimit = max(0, limit)
        evict(toFit: 0)
    }
    public var cachedCostBytes: Int { totalCost }
    public var cachedEntryCount: Int { cache.count }

    private func cachedResult(for key: ThumbnailKey) -> Result<ThumbnailImage<Image>, ThumbnailFailure>? {
        guard let cached = cache[key] else { return nil }
        if let expiry = cached.expires, now() >= expiry { removeCached(key); return nil }
        recency.removeAll { $0 == key }; recency.append(key)
        return cached.result
    }
    private func complete(_ key: ThumbnailKey, generation: UUID,
                          result: Result<ThumbnailImage<Image>, ThumbnailFailure>) {
        guard let flight = flights[key], flight.generation == generation else { return }
        flights.removeValue(forKey: key)
        let cached: Cached?
        switch result {
        case .success(let image): cached = Cached(result: result, cost: image.costBytes, expires: nil)
        case .failure(.unavailable) where failureTTL > 0:
            cached = Cached(result: result, cost: 1, expires: now().addingTimeInterval(failureTTL))
        default: cached = nil
        }
        if let cached, cached.cost <= costLimit {
            removeCached(key)
            evict(toFit: cached.cost)
            cache[key] = cached; recency.append(key); totalCost += cached.cost
        }
        for (token, subscriber) in flight.subscribers {
            subscriber.yield(ThumbnailDelivery(token: token, result: result)); subscriber.finish()
        }
    }
    private func evict(toFit cost: Int) {
        while totalCost > costLimit - cost, let oldest = recency.first { removeCached(oldest) }
    }
    private func removeCached(_ key: ThumbnailKey) {
        if let old = cache.removeValue(forKey: key) { totalCost -= old.cost }
        recency.removeAll { $0 == key }
    }
}
