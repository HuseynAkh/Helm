// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

/// F-052/F-059, B-038/B-041: admission is atomic and refusal preserves both endpoints.
final class T3ConditionalMutationTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/source")
    private let destination = URL(fileURLWithPath: "/destination")
    private func fixture() async throws -> (InMemoryFileSystem, FileMutationPrecondition) {
        let fs = InMemoryFileSystem()
        try await fs.createFileExclusively(at: source, contents: Data([1, 2, 3]))
        return (fs, try await fs.mutationPrecondition(at: source))
    }
    private func cancelled(_ mutation: ConditionalFileMutation) async throws {
        let (fs, evidence) = try await fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fs.mutate(mutation, source: source, requiring: evidence)
        }
        do { _ = try await task.value; XCTFail("Cancelled admission must refuse") }
        catch { XCTAssertEqual(error as? ConditionalMutationError, .cancelledBeforeMutation) }
        let retained = try await fs.mutationPrecondition(at: source)
        let created = await fs.exists(destination)
        XCTAssertEqual(retained, evidence); XCTAssertFalse(created)
    }
    func testCancelledCopy() async throws { try await cancelled(.copy(to: destination)) }
    func testCancelledMove() async throws { try await cancelled(.move(to: destination)) }
    func testCancelledTrash() async throws { try await cancelled(.trash) }
    private func stale(_ mutation: ConditionalFileMutation) async throws {
        let (fs, evidence) = try await fixture()
        try await fs.removeItem(at: source)
        try await fs.createFileExclusively(at: source, contents: Data([1, 2, 3]))
        let replacement = try await fs.mutationPrecondition(at: source)
        do { _ = try await fs.mutate(mutation, source: source, requiring: evidence); XCTFail("ABA must refuse") }
        catch { XCTAssertEqual(error as? ConditionalMutationError, .sourceChanged) }
        let after = try await fs.mutationPrecondition(at: source)
        let created = await fs.exists(destination)
        XCTAssertEqual(after, replacement); XCTAssertFalse(created)
    }
    func testABACopy() async throws { try await stale(.copy(to: destination)) }
    func testABAMove() async throws { try await stale(.move(to: destination)) }
    func testABATrash() async throws { try await stale(.trash) }
    func testWrongKindEvidenceRefuses() async throws {
        let (fs, evidence) = try await fixture()
        let forged = FileMutationPrecondition(identity: evidence.identity, changeToken: evidence.changeToken, kind: .directory)
        do { _ = try await fs.mutate(.trash, source: source, requiring: forged); XCTFail("Kind mismatch must refuse") }
        catch { XCTAssertEqual(error as? ConditionalMutationError, .sourceChanged) }
        let retained = try await fs.mutationPrecondition(at: source)
        XCTAssertEqual(retained, evidence)
    }
    func testWrongTokenEvidenceRefuses() async throws {
        let (fs, evidence) = try await fixture()
        let forged = FileMutationPrecondition(identity: evidence.identity, changeToken: ChangeToken(modificationDate: .distantPast, size: 3), kind: evidence.kind)
        do { _ = try await fs.mutate(.trash, source: source, requiring: forged); XCTFail("Token mismatch must refuse") }
        catch { XCTAssertEqual(error as? ConditionalMutationError, .sourceChanged) }
        let retained = try await fs.mutationPrecondition(at: source)
        XCTAssertEqual(retained, evidence)
    }
    func testConcurrentExclusiveCopiesHaveExactlyOneWinner() async throws {
        let (fs, evidence) = try await fixture()
        let source = self.source, destination = self.destination
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    do {
                        _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence)
                        return true
                    } catch {
                        XCTAssertEqual(error as? FileSystemError, .collision(noMutation: true))
                        return false
                    }
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        let retained = try await fs.mutationPrecondition(at: source)
        let copied = try await fs.mutationPrecondition(at: destination)
        XCTAssertEqual(retained, evidence)
        XCTAssertNotEqual(copied.identity, evidence.identity)
        XCTAssertEqual(copied.changeToken.size, 3)
    }
    func testMoveAwayAndBackPreservesObjectEvidence() async throws {
        let (fs, evidence) = try await fixture()
        _ = try await fs.mutate(.move(to: destination), source: source, requiring: evidence)
        let moved = try await fs.mutationPrecondition(at: destination)
        _ = try await fs.mutate(.move(to: source), source: destination, requiring: moved)
        let returned = try await fs.mutationPrecondition(at: source)
        XCTAssertEqual(returned, evidence)
        _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence)
        let copied = try await fs.mutationPrecondition(at: destination)
        XCTAssertNotEqual(copied.identity, evidence.identity)
    }
}
