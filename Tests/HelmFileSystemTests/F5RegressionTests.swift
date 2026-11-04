// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

final class F5RegressionTests: XCTestCase {
    func testQuarantineRejectsQueuedAndFreshWorkButNotOtherVolumes() async throws {
        let executor = IOExecutor(maxConcurrentOperations: 1, timeout: 0.8)
        let entered = expectation(description: "First body entered")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let first = Task { try await executor.run(volume: "blocked") { entered.fulfill(); gate.wait(); return 1 } }
        await fulfillment(of: [entered], timeout: 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        let calls = F5CallCount()
        let queued = Task { try await executor.run(volume: "blocked") { calls.increment(); return 2 } }
        do { _ = try await first.value; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        do { _ = try await executor.run(volume: "blocked") { calls.increment() }; XCTFail("Expected quarantine") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        let other = try await executor.run(volume: "other") { 3 }
        XCTAssertEqual(other, 3)
        gate.signal()
        do { _ = try await queued.value; XCTFail("Queued work must fail") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        XCTAssertEqual(calls.value, 0)
    }

    func testCancellationBeforeContinuationInstallationIsRetained() async {
        let state = IOResultState<Int>()
        state.cancelIfQueued()
        do {
            let _: Int = try await withCheckedThrowingContinuation { state.install($0) }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(state.begin())
        XCTAssertFalse(state.complete(.success(1)))
    }

    func testStartedStateCannotBeCancelledAsQueued() async throws {
        let state = IOResultState<Int>()
        XCTAssertTrue(state.begin())
        state.cancelIfQueued()
        XCTAssertTrue(state.complete(.success(7)))
        let value: Int = try await withCheckedThrowingContinuation { state.install($0) }
        XCTAssertEqual(value, 7)
        XCTAssertFalse(state.complete(.success(8)))
    }

    func testSuccessfulPrimaryWriteSurvivesCancellation() async throws {
        let fallback = F5TagSpy()
        let task = Task {
            try await CompositeTagStorage(primary: F5CancellingSuccess(), fallback: fallback)
                .apply(.add(FinderTag(rawValue: "red")), to: ItemID(rawValue: "/a"))
        }
        try await task.value
        let calls = await fallback.calls
        XCTAssertEqual(calls, 0)
    }

    func testCancelledUnsupportedPrimaryDoesNotStartFallback() async throws {
        let primary = F5SuspendedTags()
        let fallback = F5TagSpy()
        let composite = CompositeTagStorage(primary: primary, fallback: fallback)
        let task = Task { await TagBulkApplier(storage: composite).apply(.add(FinderTag(rawValue: "red")), to: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]) }
        await primary.waitUntilEntered()
        task.cancel()
        await primary.release()
        let result = await task.value
        XCTAssertTrue(result.outcomes.allSatisfy { $0.failure != nil })
        let calls = await fallback.calls
        XCTAssertEqual(calls, 0)
    }

    func testPrecancelledCompositeDoesNotStartPrimary() async {
        let primary = F5TagSpy()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await CompositeTagStorage(primary: primary).apply(.add(FinderTag(rawValue: "red")), to: ItemID(rawValue: "/a")); XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        let calls = await primary.calls
        XCTAssertEqual(calls, 0)
    }
}

private final class F5CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private actor F5TagSpy: TagStorage {
    var calls = 0
    func tags(for item: ItemID) -> TagSet { TagSet(tags: []) }
    func apply(_ edit: TagEdit, to item: ItemID) { calls += 1 }
}
private actor F5SuspendedTags: TagStorage {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    func tags(for item: ItemID) -> TagSet { TagSet(tags: []) }
    func apply(_ edit: TagEdit, to item: ItemID) async throws {
        entered = true
        await withCheckedContinuation { continuation in
            gate = continuation
            waiter?.resume(); waiter = nil
        }
        throw TagAdapterError.unsupportedFilesystem
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { gate?.resume(); gate = nil }
}

private struct F5CancellingSuccess: TagStorage {
    func tags(for item: ItemID) -> TagSet { TagSet() }
    func apply(_ edit: TagEdit, to item: ItemID) {
        withUnsafeCurrentTask { $0?.cancel() }
    }
}
