// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmFileSystem

final class F7AdmissionTests: XCTestCase {
    func testTimeoutQuarantinesBothVolumesAndLeavesThirdAvailable() async throws {
        let executor = IOExecutor(timeout: 0.2)
        let entered = expectation(description: "Native operation entered")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let operation = Task { try await executor.run(volumes: ["A", "B"]) { entered.fulfill(); gate.wait() } }
        await fulfillment(of: [entered], timeout: 2)
        do { try await operation.value; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        for volume in ["A", "B"] {
            do { try await executor.run(volume: volume) { XCTFail("Quarantined body entered") }; XCTFail("Expected refusal") }
            catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        }
        let third = try await executor.run(volume: "C") { 3 }
        XCTAssertEqual(third, 3)
        do { try await executor.run(volumes: ["C", "B"]) { XCTFail("Copy into quarantined destination entered") }; XCTFail("Expected refusal") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
    }
    func testLiveCopyRefusesQuarantinedDestination() async throws {
        let executor = IOExecutor(timeout: 0.2)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        do { try await executor.run(volume: "/Volumes/B") { gate.wait() }; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        let fs = LiveFileSystem(executor: executor)
        do {
            try await fs.copyItem(at: URL(fileURLWithPath: "/Volumes/A/missing"), to: URL(fileURLWithPath: "/Volumes/B/new"))
            XCTFail("Expected quarantine before native entry")
        } catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
    }
}

extension F7AdmissionTests {
    func testLiveMultiPathMutationsCheckEveryVolume() async throws {
        let executor = IOExecutor(timeout: 0.1)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        do { try await executor.run(volume: "/Volumes/B") { gate.wait() }; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        let fs = LiveFileSystem(executor: executor)
        let a = URL(fileURLWithPath: "/Volumes/A/missing"), b = URL(fileURLWithPath: "/Volumes/B/missing")
        do { try await fs.moveItem(at: a, to: b); XCTFail("Expected quarantine") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        do { try await fs.replaceItem(at: a, with: a.appendingPathExtension("stage"), backup: b); XCTFail("Expected quarantine") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        do { try await fs.applyDirectoryMetadata(from: b, to: a); XCTFail("Expected quarantine") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
    }
}
