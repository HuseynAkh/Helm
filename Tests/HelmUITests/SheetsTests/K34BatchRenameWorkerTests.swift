// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmUI

final class K34BatchRenameWorkerTests: XCTestCase {
    @MainActor func testReplacementAndDismissalCancelWithoutOverlapOrPublication() async throws {
        let worker = BatchRenameWorker(), probe = K34WorkerProbe()
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        let first = Task { try await worker.evaluate { try probe.run(started: firstStarted) } }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { try await worker.evaluate { try probe.run(started: secondStarted) } }
        await fulfillment(of: [secondStarted], timeout: 2)
        worker.cancelAll()
        for result in [await first.result, await second.result] {
            switch result {
            case .success: XCTFail("Cancelled worker must never publish")
            case .failure(let error): XCTAssertTrue(error is CancellationError)
            }
        }
        XCTAssertEqual(probe.maximum, 1)
        XCTAssertEqual(probe.cancelled, 2)
    }
    func testCancelledEvaluationDoesNotFillCache() async {
        let model = BatchRenameViewModel(items: [URL(fileURLWithPath: "/a")], existingNames: [:],
                                        caseSensitive: true, date: Date(), timeZone: .current)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try model.cancellableEvaluation()
        }
        let result = await task.result
        if case .success = result { XCTFail("Expected cancellation") }
        XCTAssertEqual(model.evaluationCount, 0)
    }
}
private final class K34WorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var cancellations = 0
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var cancelled: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    func run(started: XCTestExpectation) throws -> BatchRenameEvaluation {
        lock.lock(); active += 1; peak = max(peak, active); lock.unlock()
        defer { lock.lock(); active -= 1; cancellations += 1; lock.unlock() }
        started.fulfill()
        let deadline = Date().addingTimeInterval(3)
        while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        try Task.checkCancellation()
        throw NSError(domain: "Worker did not receive cancellation", code: 1)
    }
}
