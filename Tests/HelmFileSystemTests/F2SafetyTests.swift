// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
@testable import HelmFileSystem

final class F2FileSystemSafetyTests: XCTestCase {
    func testK29MixedAuthorityPutBackOriginsRefuseInEitherOrder() throws {
        let item = URL(fileURLWithPath: "/trash/item")
        let local = PutBackOrigin(trashedURL: item, originalURL: URL(fileURLWithPath: "/original/item"))
        for raw in ["file://remote/original/item", "https://remote/original/item"] {
            let invalid = PutBackOrigin(trashedURL: item, originalURL: try XCTUnwrap(URL(string: raw)))
            for records in [[local, invalid], [invalid, local]] {
                XCTAssertEqual(PutBackPlanner.plan(item: item, origins: records, parent: .exists), .invalidPath)
            }
        }
    }
    func testK29PutBackValidDuplicatesAndAmbiguityRemainDistinct() {
        let item = URL(fileURLWithPath: "/trash/item"), original = URL(fileURLWithPath: "/original/item")
        let first = PutBackOrigin(trashedURL: item, originalURL: original)
        XCTAssertEqual(PutBackPlanner.plan(item: item, origins: [first, first], parent: .exists),
                       .restore(source: item, destination: original))
        let other = PutBackOrigin(trashedURL: item, originalURL: URL(fileURLWithPath: "/other/item"))
        for records in [[first, other], [other, first]] {
            XCTAssertEqual(PutBackPlanner.plan(item: item, origins: records, parent: .exists), .ambiguousOrigin)
        }
    }
    func testCancellationAfterStartRetainsCompletion() async throws {
        let started = expectation(description: "Native body started")
        let gate = DispatchSemaphore(value: 0)
        let executor = IOExecutor(timeout: 5)
        let task = Task {
            try await executor.run {
                started.fulfill()
                gate.wait()
                return 42
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        gate.signal()
        do { let result = try await task.value; XCTAssertEqual(result, 42) }
        catch { XCTFail("Started operation completion lost: \(error)") }
    }
    func testFailedExclusiveWritePreservesReplacementBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("new.dat")
        let replacement = Data([9, 8, 7])
        XCTAssertThrowsError(try LiveFileSystem.writeExclusively(at: target, contents: Data([1])) { _, _, _ in
            try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("partial"))
            try replacement.write(to: target)
            throw FileSystemError.other("Injected ENOSPC")
        })
        XCTAssertEqual(try Data(contentsOf: target), replacement)
    }
    func testEntryReadFailureCannotProduceSuccessfulListing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("secret"))
        let fs = LiveFileSystem(readMetadata: { _, _, _ in throw FileSystemError.permissionDenied })
        do {
            _ = try await fs.childNames(of: root)
            XCTFail("Incomplete name snapshot accepted")
        } catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
    }
    func testArchiveRootDirectoryMarkers() throws {
        for root in [".", "./"] {
            XCTAssertNoThrow(try ArchiveSafety.validate([
                ArchiveMember(path: root, kind: .directory, expandedBytes: 0, compressedBytes: 0),
                ArchiveMember(path: "./notes.txt", expandedBytes: 1, compressedBytes: 1)
            ]))
        }
    }
    func testArchiveRootMarkerPlanningAndBudgets() throws {
        let root = ArchiveMember(path: "./", kind: .directory, expandedBytes: 0, compressedBytes: 0)
        let member = ArchiveMember(path: "./notes.txt", expandedBytes: 1, compressedBytes: 1)
        let plan = try ArchivePlanner.uncompress(archive: URL(fileURLWithPath: "/input/notes.tar"),
            destinationDirectory: URL(fileURLWithPath: "/output"), stagingDirectory: URL(fileURLWithPath: "/stage"), members: [root, member])
        XCTAssertTrue(plan.command.requiresConfinedExtraction)
        XCTAssertThrowsError(try ArchiveSafety.validate([root, member], limits: ArchiveSafetyLimits(maximumMembers: 1)))
        XCTAssertThrowsError(try ArchiveSafety.validate([ArchiveMember(path: "./", kind: .directory, expandedBytes: 1, compressedBytes: 1)]))
        for path in ["", "/", "../", "a/../"] {
            XCTAssertThrowsError(try ArchiveSafety.validate([ArchiveMember(path: path, kind: .directory, expandedBytes: 0, compressedBytes: 0)]))
        }
    }
    func testArchiveUnsafeRootMarkersRemainRejected() {
        for root in ["", ".", "./", "../", "/"] {
            XCTAssertThrowsError(try ArchiveSafety.validate([ArchiveMember(path: root, expandedBytes: 0, compressedBytes: 0)]))
        }
    }
}
