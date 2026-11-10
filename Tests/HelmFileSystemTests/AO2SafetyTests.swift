// DRAFT: pending review, 2026-11-04
import XCTest
import Foundation
import HelmCore
@testable import HelmFileSystem

final class AO2FileSystemSafetyTests: XCTestCase {
    func testVanishedChildDoesNotFailListing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("gone"))
        try Data().write(to: root.appendingPathComponent("kept"))
        let fs = LiveFileSystem(readMetadata: { url, resolve, volume in
            if url.lastPathComponent == "gone" { throw FileSystemError.notFound }
            return try MetadataReader().read(url, resolveSymlinkTargets: resolve, volumeIdentifier: volume)
        })
        let names = try await fs.childNames(of: root)
        XCTAssertEqual(names, ["kept"])
    }

    func testQueueWaitDoesNotConsumeBodyTimeout() async throws {
        let executor = IOExecutor(maxConcurrentOperations: 1, timeout: 0.8)
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        let firstGate = DispatchSemaphore(value: 0), secondGate = DispatchSemaphore(value: 0)
        defer { firstGate.signal(); secondGate.signal() }
        let first = Task { try await executor.run { firstStarted.fulfill(); firstGate.wait(); return 1 } }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { try await executor.run { secondStarted.fulfill(); secondGate.wait(); return 2 } }
        // Both bodies stay under their own deadline; the third waits longer than one deadline.
        try await Task.sleep(nanoseconds: 100_000_000)
        let third = Task { try await executor.run { 3 } }
        try await Task.sleep(nanoseconds: 450_000_000)
        firstGate.signal()
        await fulfillment(of: [secondStarted], timeout: 2)
        try await Task.sleep(nanoseconds: 450_000_000)
        secondGate.signal()
        let values = try await [first.value, second.value, third.value]
        XCTAssertEqual(values, [1, 2, 3])
        let subsequent = try await executor.run { 4 }
        XCTAssertEqual(subsequent, 4)
    }

    func testCancelledQueuedLiveCreatesReportNoMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [false, true] {
            let executor = IOExecutor(maxConcurrentOperations: 1, timeout: 5)
            let fs = LiveFileSystem(executor: executor)
            let started = expectation(description: "blocker started")
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let blocker = Task { try await executor.run { started.fulfill(); gate.wait() } }
            await fulfillment(of: [started], timeout: 2)
            let output = root.appendingPathComponent(directory ? "folder" : "file")
            let create = Task {
                if directory { try await fs.createDirectory(at: output) }
                else { try await fs.createFileExclusively(at: output, contents: Data([1])) }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            create.cancel()
            do { try await create.value; XCTFail("Cancelled queued create succeeded") }
            catch { XCTAssertEqual(error as? ConditionalMutationError, .cancelledBeforeMutation) }
            gate.signal()
            try await blocker.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            try await fs.createFileExclusively(at: output, contents: Data([2]))
        }
    }

    func testPrecancelledFakeCreatesRefuseWithoutMutation() async throws {
        for directory in [false, true] {
            let fs = InMemoryFileSystem(), output = URL(fileURLWithPath: "/new")
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                if directory { try await fs.createDirectory(at: output) }
                else { try await fs.createFileExclusively(at: output, contents: Data()) }
            }
            do { try await task.value; XCTFail("Cancelled fake create succeeded") }
            catch { XCTAssertEqual(error as? ConditionalMutationError, .cancelledBeforeMutation) }
            let exists = await fs.exists(output)
            XCTAssertFalse(exists)
        }
    }
}
