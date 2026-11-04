// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmTestKit

private actor ImageProducerProbe {
    private var pending: [Int: CheckedContinuation<ThumbnailImage<String>, Error>] = [:]
    private let onCancel: @Sendable () -> Void
    init(onCancel: @escaping @Sendable () -> Void = {}) { self.onCancel = onCancel }
    private var starts: Int = 0
    private var cancelled: Set<Int> = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancelWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func produce(_ key: ThumbnailKey) async throws -> ThumbnailImage<String> {
        starts += 1
        let number = starts
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[number] = continuation
                let ready = startWaiters.filter { $0.0 <= starts }
                startWaiters.removeAll { $0.0 <= starts }
                ready.forEach { $0.1.resume() }
            }
        } onCancel: { Task { await self.markCancelled(number) } }
    }
    private func markCancelled(_ number: Int) {
        cancelled.insert(number)
        onCancel()
        let ready = cancelWaiters.filter { $0.0 == number }
        cancelWaiters.removeAll { $0.0 == number }
        ready.forEach { $0.1.resume() }
    }
    func waitForStart(_ number: Int) async {
        if starts >= number { return }
        await withCheckedContinuation { startWaiters.append((number, $0)) }
    }
    func waitForCancel(_ number: Int) async {
        if cancelled.contains(number) { return }
        await withCheckedContinuation { cancelWaiters.append((number, $0)) }
    }
    func finish(_ number: Int, _ result: Result<ThumbnailImage<String>, Error>) {
        pending.removeValue(forKey: number)?.resume(with: result)
    }
    func counts() -> (Int, Int) { (starts, cancelled.count) }
}

final class ThumbnailCoordinatorTests: XCTestCase {
    private func key(_ path: String = "/a", size: Int64 = 1) -> ThumbnailKey {
        ThumbnailKey(itemID: ItemID(rawValue: path), modificationDate: .distantPast, fileSize: size,
                     dimensions: ImageDimensions(widthPoints: 96, heightPoints: 96, backingScale: 2))
    }
    private func delivery(_ subscription: ThumbnailSubscription<String>) async -> ThumbnailDelivery<String>? {
        var iterator = subscription.deliveries.makeAsyncIterator()
        return await iterator.next()
    }
    func testF3OwnerReleaseCancelsProducerAndFinishesStream() async {
        let cancelled = expectation(description: "producer cancelled")
        let probe = ImageProducerProbe(onCancel: { cancelled.fulfill() })
        var coordinator: ThumbnailCoordinator<String>? = ThumbnailCoordinator(costLimitBytes: 10) { try await probe.produce($0) }
        let subscription = await coordinator?.subscribe(to: key())
        await probe.waitForStart(1)
        weak var weakCoordinator = coordinator
        coordinator = nil
        XCTAssertNil(weakCoordinator)
        let ended = expectation(description: "subscriber finished")
        let consumer = Task { if let subscription { for await _ in subscription.deliveries {} }; ended.fulfill() }
        await fulfillment(of: [cancelled, ended], timeout: 1)
        consumer.cancel()
        await probe.finish(1, .failure(CancellationError()))
    }
    func testCoalescingAndIndependentCancellation() async {
        let probe = ImageProducerProbe()
        let coordinator = ThumbnailCoordinator<String>(costLimitBytes: 100) { try await probe.produce($0) }
        let first = await coordinator.subscribe(to: key())
        let second = await coordinator.subscribe(to: key())
        await probe.waitForStart(1)
        await coordinator.cancel(first.token)
        let counts = await probe.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0)
        await probe.finish(1, .success(ThumbnailImage(image: "image", costBytes: 10)))
        let cancelled = await delivery(first)
        let result = await delivery(second)
        XCTAssertNil(cancelled)
        XCTAssertEqual(result?.image(ifCurrent: second.token), "image")
        XCTAssertNil(result?.image(ifCurrent: first.token))
        XCTAssertNil(result?.image(ifCurrent: nil))
    }
    func testBothSubscribersReceiveAndCacheHit() async {
        let probe = ImageProducerProbe()
        let coordinator = ThumbnailCoordinator<String>(costLimitBytes: 100) { try await probe.produce($0) }
        let first = await coordinator.subscribe(to: key())
        let second = await coordinator.subscribe(to: key())
        await probe.waitForStart(1)
        await probe.finish(1, .success(ThumbnailImage(image: "both", costBytes: 10)))
        let a = await delivery(first); let b = await delivery(second)
        XCTAssertEqual(a?.image(ifCurrent: first.token), "both")
        XCTAssertEqual(b?.image(ifCurrent: second.token), "both")
        let cached = await coordinator.subscribe(to: key())
        let c = await delivery(cached)
        XCTAssertEqual(c?.image(ifCurrent: cached.token), "both")
        XCTAssertNil(a?.image(ifCurrent: cached.token))
        let counts = await probe.counts(); XCTAssertEqual(counts.0, 1)
    }
    func testLastCancellationAndLateProducerCannotReplaceNewFlight() async {
        let probe = ImageProducerProbe()
        let coordinator = ThumbnailCoordinator<String>(costLimitBytes: 100) { try await probe.produce($0) }
        let old = await coordinator.subscribe(to: key())
        await probe.waitForStart(1)
        await coordinator.cancel(old.token)
        await probe.waitForCancel(1)
        let fresh = await coordinator.subscribe(to: key())
        await probe.waitForStart(2)
        await probe.finish(1, .success(ThumbnailImage(image: "stale", costBytes: 10)))
        await probe.finish(2, .success(ThumbnailImage(image: "fresh", costBytes: 10)))
        let result = await delivery(fresh)
        XCTAssertEqual(result?.image(ifCurrent: fresh.token), "fresh")
        let ended = await delivery(old); XCTAssertNil(ended)
    }
    func testLRUAndLiveCostLimitAndOversizedImage() async {
        let probe = ImageProducerProbe()
        let coordinator = ThumbnailCoordinator<String>(costLimitBytes: 20) { try await probe.produce($0) }
        for (index, path) in ["/a", "/b"].enumerated() {
            let sub = await coordinator.subscribe(to: key(path))
            await probe.waitForStart(index + 1)
            await probe.finish(index + 1, .success(ThumbnailImage(image: path, costBytes: 10)))
            _ = await delivery(sub)
        }
        let touch = await coordinator.subscribe(to: key("/a")); _ = await delivery(touch)
        let third = await coordinator.subscribe(to: key("/c"))
        await probe.waitForStart(3)
        await probe.finish(3, .success(ThumbnailImage(image: "c", costBytes: 10)))
        _ = await delivery(third)
        let a = await coordinator.subscribe(to: key("/a")); _ = await delivery(a)
        let b = await coordinator.subscribe(to: key("/b"))
        await probe.waitForStart(4) // b, rather than recently accessed a, was evicted.
        await probe.finish(4, .success(ThumbnailImage(image: "huge", costBytes: Int.max)))
        let huge = await delivery(b); XCTAssertEqual(huge?.image(ifCurrent: b.token), "huge")
        let cost = await coordinator.cachedCostBytes; XCTAssertEqual(cost, 20)
        await coordinator.setCostLimitBytes(10)
        let count = await coordinator.cachedEntryCount; XCTAssertEqual(count, 1)
        await coordinator.setCostLimitBytes(-1)
        let zero = await coordinator.cachedCostBytes; XCTAssertEqual(zero, 0)
    }
    func testFailureExpiryAndInvalidation() async {
        let clock = FakeClock()
        let probe = ImageProducerProbe()
        let coordinator = ThumbnailCoordinator<String>(costLimitBytes: 10, failureTTL: 5, now: { clock.now() }) {
            try await probe.produce($0)
        }
        let first = await coordinator.subscribe(to: key())
        await probe.waitForStart(1)
        await probe.finish(1, .failure(ThumbnailFailure.unavailable))
        let failed = await delivery(first)
        if case .failure(.unavailable)? = failed?.result {} else { XCTFail("Expected unavailable") }
        let cached = await coordinator.subscribe(to: key()); _ = await delivery(cached)
        let counts = await probe.counts(); XCTAssertEqual(counts.0, 1)
        clock.advance(by: 5)
        let retry = await coordinator.subscribe(to: key())
        await probe.waitForStart(2)
        await coordinator.invalidate(key().itemID)
        await probe.waitForCancel(2)
        await probe.finish(2, .failure(CancellationError()))
        let ended = await delivery(retry); XCTAssertNil(ended)
        let count = await coordinator.cachedEntryCount; XCTAssertEqual(count, 0)
    }
    func testConsumerTaskCancellationCancelsLastProducer() async {
        let probe = ImageProducerProbe()
        let coordinator = ThumbnailCoordinator<String>(costLimitBytes: 10) { try await probe.produce($0) }
        let subscription = await coordinator.subscribe(to: key())
        await probe.waitForStart(1)
        let consumer = Task { for await _ in subscription.deliveries {} }
        consumer.cancel()
        await consumer.value
        await probe.waitForCancel(1)
        await probe.finish(1, .failure(CancellationError()))
        let count = await coordinator.cachedEntryCount
        XCTAssertEqual(count, 0)
    }
    func testCancellationErrorsAreNotCachedAndCompletedImagesInvalidate() async {
        let probe = ImageProducerProbe()
        let coordinator = ThumbnailCoordinator<String>(costLimitBytes: 10) { try await probe.produce($0) }
        let subscription = await coordinator.subscribe(to: key())
        await probe.waitForStart(1)
        await probe.finish(1, .failure(CancellationError()))
        let cancelled = await delivery(subscription)
        if case .failure(.cancelled)? = cancelled?.result {} else { XCTFail("Expected cancellation") }
        let retry = await coordinator.subscribe(to: key())
        await probe.waitForStart(2)
        await probe.finish(2, .success(ThumbnailImage(image: "retry", costBytes: 5)))
        _ = await delivery(retry)
        await coordinator.invalidate(key().itemID)
        let count = await coordinator.cachedEntryCount
        XCTAssertEqual(count, 0)
    }
    func testFailureCacheIsBoundedAndCanBeDisabled() async {
        let coordinator = ThumbnailCoordinator<String>(costLimitBytes: 2) { _ in
            throw CocoaError(.fileReadUnknown)
        }
        for path in ["/a", "/b", "/c"] {
            let subscription = await coordinator.subscribe(to: key(path))
            _ = await delivery(subscription)
        }
        let count = await coordinator.cachedEntryCount
        let cost = await coordinator.cachedCostBytes
        XCTAssertEqual(count, 2); XCTAssertEqual(cost, 2)
        let disabled = ThumbnailCoordinator<String>(costLimitBytes: 100, failureTTL: 0) { _ in
            throw CocoaError(.fileReadUnknown)
        }
        let subscription = await disabled.subscribe(to: key())
        _ = await delivery(subscription)
        let disabledCount = await disabled.cachedEntryCount
        XCTAssertEqual(disabledCount, 0)
    }
    func testKeyContentAndDimensions() {
        XCTAssertNotEqual(key(), key(size: 2))
        XCTAssertNotEqual(key(), ThumbnailKey(itemID: key().itemID, modificationDate: Date(), fileSize: 1, dimensions: key().dimensions))
        XCTAssertEqual(key().dimensions.pixelWidth, 192)
        XCTAssertEqual(key().dimensions.pixelHeight, 192)
        let invalid = ImageDimensions(widthPoints: .nan, heightPoints: -1, backingScale: .infinity)
        XCTAssertEqual(invalid.pixelWidth, 1); XCTAssertEqual(invalid.pixelHeight, 1)
        XCTAssertNotEqual(key().dimensions, ImageDimensions(widthPoints: 96, heightPoints: 96, backingScale: 1))
        XCTAssertEqual(ThumbnailImage(image: "x", costBytes: -1).costBytes, 1)
    }
}
