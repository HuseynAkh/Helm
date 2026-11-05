// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmUI

final class K34BatchRenameWorkerTests: XCTestCase {
    @MainActor func testLatestPendingReplacesIntermediateAndReturnsSuccess() async {
        let worker = BatchRenameWorker(), gate = F18WorkerGate()
        let started = expectation(description: "A running")
        let admitted = expectation(description: "B admitted on main actor")
        let replaced = expectation(description: "B cancelled")
        let completed = expectation(description: "C completed")
        let firstCompleted = expectation(description: "A cancelled")
        let latest = BatchRenameEvaluation(revision: UUID(), plan: nil, messages: ["C"])
        defer { gate.release(); worker.cancelAll() }
        _ = Task {
            do {
                _ = try await worker.evaluate {
                    started.fulfill()
                    try gate.wait()
                    // Deliberately ignore cancellation: the worker must reject late success.
                    return BatchRenameEvaluation(revision: UUID(), plan: nil, messages: ["A"])
                }
                XCTFail("Late A success published")
            } catch { XCTAssertTrue(error is CancellationError) }
            firstCompleted.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        _ = Task {
            admitted.fulfill()
            do {
                _ = try await worker.evaluate {
                    XCTFail("Replaced pending B executed")
                    return latest
                }
                XCTFail("B succeeded")
            } catch { XCTAssertTrue(error is CancellationError) }
            replaced.fulfill()
        }
        await fulfillment(of: [admitted], timeout: 3)
        _ = Task {
            do {
                let result = try await worker.evaluate {
                    XCTAssertTrue(gate.hasExited, "C overlapped A")
                    return latest
                }
                XCTAssertEqual(result.revision, latest.revision)
                XCTAssertEqual(result.messages, ["C"])
            } catch { XCTFail("C failed: \(error)") }
            completed.fulfill()
        }
        await fulfillment(of: [replaced], timeout: 3)
        gate.release()
        await fulfillment(of: [firstCompleted, completed], timeout: 3)
    }

    @MainActor func testDismissalCancelsActiveWork() async {
        let worker = BatchRenameWorker(), gate = F18WorkerGate()
        let started = expectation(description: "active before dismissal")
        let completed = expectation(description: "dismissed caller finished")
        defer { gate.release(); worker.cancelAll() }
        _ = Task {
            do {
                _ = try await worker.evaluate {
                    started.fulfill(); try gate.wait(); try Task.checkCancellation()
                    return BatchRenameEvaluation(revision: UUID(), plan: nil, messages: [])
                }
                XCTFail("Dismissed work succeeded")
            } catch { XCTAssertTrue(error is CancellationError) }
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        worker.cancelAll(); gate.release()
        await fulfillment(of: [completed], timeout: 3)
    }

    @MainActor func testOuterCancellationAndWorkerReuse() async {
        let worker = BatchRenameWorker(), gate = F18WorkerGate()
        let started = expectation(description: "work started")
        let finished = expectation(description: "caller finished")
        defer { gate.release(); worker.cancelAll() }
        let caller = Task {
            do {
                _ = try await worker.evaluate {
                    started.fulfill(); try gate.wait(); try Task.checkCancellation()
                    return BatchRenameEvaluation(revision: UUID(), plan: nil, messages: [])
                }
                XCTFail("Outer cancellation ignored")
            } catch { XCTAssertTrue(error is CancellationError) }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        caller.cancel()
        gate.release()
        await fulfillment(of: [finished], timeout: 3)
        do {
            let result = try await worker.evaluate { BatchRenameEvaluation(revision: UUID(), plan: nil, messages: ["reused"]) }
            XCTAssertEqual(result.messages, ["reused"])
        } catch { XCTFail("Reuse failed: \(error)") }
    }

    @MainActor func testSuccessfulWorkerEvaluationFillsAndReusesCache() async throws {
        let model = BatchRenameViewModel(items: [URL(fileURLWithPath: "/a")], existingNames: [:],
                                        caseSensitive: true, date: Date(timeIntervalSince1970: 0), timeZone: .gmt)
        let worker = BatchRenameWorker()
        let first = try await worker.evaluate { try model.cancellableEvaluation() }
        let second = try await worker.evaluate { try model.cancellableEvaluation() }
        XCTAssertEqual(first.revision, second.revision)
        XCTAssertEqual(first.preview, second.preview)
        XCTAssertEqual(model.evaluationCount, 1)
    }

    func testCancelledEvaluationDoesNotFillCache() async {
        let model = BatchRenameViewModel(items: [URL(fileURLWithPath: "/a")], existingNames: [:],
                                        caseSensitive: true, date: Date(timeIntervalSince1970: 0), timeZone: .gmt)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try model.cancellableEvaluation()
        }
        if case .success = await task.result { XCTFail("Expected cancellation") }
        XCTAssertEqual(model.evaluationCount, 0)
    }
}

private final class F18WorkerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var exited = false
    var hasExited: Bool { condition.lock(); defer { condition.unlock() }; return exited }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func wait() throws {
        condition.lock(); defer { exited = true; condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !released {
            if !condition.wait(until: deadline) { throw NSError(domain: "F18 watchdog", code: 1) }
        }
    }
}
