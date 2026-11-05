// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

final class K34ConditionalMutationTests: XCTestCase {
    func testSubstitutionRefusesWithoutMutation() async throws {
        let fs = InMemoryFileSystem()
        let source = URL(fileURLWithPath: "/a"), destination = URL(fileURLWithPath: "/b")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let evidence = try await fs.mutationPrecondition(at: source)
        try await fs.removeItem(at: source)
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        do {
            _ = try await fs.mutate(.move(to: destination), source: source, requiring: evidence)
            XCTFail("Substituted source must be retained")
        } catch { XCTAssertEqual(error as? ConditionalMutationError, .sourceChanged) }
        let present = await fs.exists(source), absent = await fs.exists(destination)
        XCTAssertTrue(present); XCTAssertFalse(absent)
    }
    func testMovePreservesIdentityAndCollisionIsNoMutation() async throws {
        let fs = InMemoryFileSystem()
        let source = URL(fileURLWithPath: "/a"), destination = URL(fileURLWithPath: "/b")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let before = try await fs.mutationPrecondition(at: source)
        _ = try await fs.mutate(.move(to: destination), source: source, requiring: before)
        let after = try await fs.mutationPrecondition(at: destination)
        XCTAssertEqual(after.identity, before.identity)
        try await fs.createFileExclusively(at: source, contents: Data([2]))
        do {
            _ = try await fs.mutate(.move(to: source), source: destination, requiring: after)
            XCTFail("Occupied destination must be refused")
        } catch { XCTAssertEqual(error as? FileSystemError, .collision(noMutation: true)) }
        let retained = try await fs.mutationPrecondition(at: destination)
        XCTAssertEqual(retained, after)
    }
    func testLiveAtomicMutationRefusesAndRetainsSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("a")
        let fs = LiveFileSystem()
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let evidence = try await fs.mutationPrecondition(at: source)
        do {
            _ = try await fs.mutate(.trash, source: source, requiring: evidence)
            XCTFail("Native compare-and-mutate is unavailable")
        } catch { XCTAssertEqual(error as? ConditionalMutationError, .unsupported) }
        let retained = await fs.exists(source)
        XCTAssertTrue(retained)
    }
}

extension K34ConditionalMutationTests {
    func testCopyCreatesNewIdentityAndForeignProviderEvidenceRefuses() async throws {
        let fs = InMemoryFileSystem(), foreign = InMemoryFileSystem()
        let source = URL(fileURLWithPath: "/a"), destination = URL(fileURLWithPath: "/b")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        try await foreign.createFileExclusively(at: source, contents: Data([1]))
        let before = try await fs.mutationPrecondition(at: source)
        let wrong = try await foreign.mutationPrecondition(at: source)
        do {
            _ = try await fs.mutate(.copy(to: destination), source: source, requiring: wrong)
            XCTFail("Foreign evidence must refuse")
        } catch { XCTAssertEqual(error as? ConditionalMutationError, .sourceChanged) }
        _ = try await fs.mutate(.copy(to: destination), source: source, requiring: before)
        let copied = try await fs.mutationPrecondition(at: destination)
        XCTAssertNotEqual(copied.identity, before.identity)
        let unchanged = try await fs.mutationPrecondition(at: source)
        XCTAssertEqual(unchanged, before)
    }
    func testChangedRootMetadataRefusesAndSymlinkIdentityIsNoFollow() async throws {
        let fs = InMemoryFileSystem(), root = URL(fileURLWithPath: "/tree")
        try await fs.createDirectory(at: root)
        let before = try await fs.mutationPrecondition(at: root)
        let child = root.appendingPathComponent("child")
        try await fs.createFileExclusively(at: child, contents: Data())
        do {
            _ = try await fs.mutate(.trash, source: root, requiring: before)
            XCTFail("Changed root evidence must refuse")
        } catch { XCTAssertEqual(error as? ConditionalMutationError, .sourceChanged) }
        let link = URL(fileURLWithPath: "/link")
        try await fs.createSymbolicLink(at: link, destination: child)
        let linkEvidence = try await fs.mutationPrecondition(at: link)
        let targetEvidence = try await fs.mutationPrecondition(at: child)
        XCTAssertNotEqual(linkEvidence.identity, targetEvidence.identity)
        _ = try await fs.mutate(.trash, source: link, requiring: linkEvidence)
        let retained = await fs.exists(child)
        XCTAssertTrue(retained)
    }
}
