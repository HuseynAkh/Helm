// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmFileSystem

final class ExecutorAndRegistryTests: XCTestCase {
    func testExecutorCancellationTimeoutAndIsolation() async throws {
        let executor = IOExecutor(maxConcurrentOperations: 1, timeout: 1)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        do {
            let _: Int = try await executor.run(volume: "slow") { gate.wait(); return 1 }
            XCTFail("Timeout ignored")
        } catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        do { let _: Int = try await executor.run(volume: "slow") { 2 }; XCTFail("Quarantine ignored") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        let value = try await executor.run(volume: "other") { 3 }
        XCTAssertEqual(value, 3)
        let task = Task {
            // Cancel before admission deterministically; parent scheduling must not
            // accidentally turn this into cancellation of an admitted native call.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.run(volume: "cancel") {
                XCTFail("Precancelled body entered")
                return 4
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }
    func testRegistryFanoutAndFinalSubscriberTeardown() async throws {
        let monitor = InMemoryMonitor()
        let registry = MonitorRegistry { _ in monitor }
        let root = URL(fileURLWithPath: "/root")
        let first = await registry.subscribe(path: root)
        let second = await registry.subscribe(path: root)
        let observed = await registry.observedDirectoryCount
        XCTAssertEqual(observed, 1)
        try await monitor.start()
        let received = expectation(description: "Both subscribers receive")
        received.expectedFulfillmentCount = 2
        let firstTask = Task {
            for await event in first {
                if event == .rescan { received.fulfill() }
            }
        }
        let secondTask = Task {
            for await event in second {
                if event == .rescan { received.fulfill() }
            }
        }
        await monitor.emit(.rescan)
        await fulfillment(of: [received], timeout: 2)
        firstTask.cancel()
        await firstTask.value
        // Actor termination handler executes asynchronously; second subscriber must keep the watch.
        for _ in 0..<10 { await Task.yield() }
        let remaining = await registry.observedDirectoryCount
        XCTAssertEqual(remaining, 1)
        await registry.stopAll()
        await secondTask.value
        let ended = await registry.observedDirectoryCount
        XCTAssertEqual(ended, 0)
    }
    func testErrorMappingAndPortableVolumeReader() async throws {
        XCTAssertEqual(FileSystemError.mapping(NSError(domain: NSPOSIXErrorDomain, code: 13)), .permissionDenied)
        XCTAssertEqual(FileSystemError.mapping(NSError(domain: NSCocoaErrorDomain, code: 260)), .notFound)
        let values = try await VolumeReader().volumes()
        XCTAssertFalse(values.isEmpty)
    }
}
