// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
@testable import HelmFileSystem

final class AO3QuarantineTests: XCTestCase {
    func testReadQuarantineWaitsForEveryTimedOutBody() async throws {
        let executor = IOExecutor(maxConcurrentOperations: 2, timeout: 0.04)
        let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let a = Task { try await executor.runRead(volume: "v") { entered.signal(); first.wait(); return 1 } }
        let b = Task { try await executor.runRead(volume: "v") { entered.signal(); second.wait(); return 2 } }
        entered.wait(); entered.wait()
        for task in [a, b] {
            do { _ = try await task.value; XCTFail("Must time out") }
            catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        }
        XCTAssertFalse(executor.clearQuarantine(volume: "v"))
        first.signal()
        try await Task.sleep(nanoseconds: 20_000_000)
        do { _ = try await executor.runRead(volume: "v") { 3 }; XCTFail("Second body still alive") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        second.signal()
        try await Task.sleep(nanoseconds: 20_000_000)
        let recovered = try await executor.runRead(volume: "v") { 4 }
        XCTAssertEqual(recovered, 4)
    }

    func testMutationRequiresExplicitClearAfterBodyReturns() async throws {
        let executor = IOExecutor(timeout: 0.02), gate = DispatchSemaphore(value: 0)
        let task = Task { try await executor.run(volume: "v") { gate.wait(); return 1 } }
        do { _ = try await task.value; XCTFail("Must time out") } catch { }
        XCTAssertFalse(executor.clearQuarantine(volume: "v"))
        gate.signal()
        try await Task.sleep(nanoseconds: 20_000_000)
        do { _ = try await executor.runRead(volume: "v") { 2 }; XCTFail("Needs reconciliation") } catch { }
        XCTAssertTrue(executor.clearQuarantine(volume: "v"))
        let value = try await executor.runRead(volume: "v") { 3 }
        XCTAssertEqual(value, 3)
    }

    func testProgressResetsWatchdog() async throws {
        // Margins are wide: a 25 ms sleep at this queue's utility QoS was measured taking 180 ms on macOS.
        let executor = IOExecutor(timeout: 1)
        let value = try await executor.runReadWithProgress(volume: "v") { progress in
            for _ in 0..<7 { Thread.sleep(forTimeInterval: 0.2); progress() }
            return 7
        }
        XCTAssertEqual(value, 7)
    }
}
