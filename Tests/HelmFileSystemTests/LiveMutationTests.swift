import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmFileSystem

/// The live bounded-race contract on a real volume, in temp folders only (O1-1).
final class LiveMutationTests: XCTestCase {
    private var root: URL!
    private var fs: LiveFileSystem!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("helm-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fs = LiveFileSystem(trash: fixtureTrash(in: root.appendingPathComponent("trash")))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ name: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func stageFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".helm-copy") }
    }

    func testCopyKeepsDatesAndExtendedAttributes() async throws {
        let source = try write("a.txt", "hello")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        XCTAssertEqual(setxattr(source.path, "com.example.keep", "yes", 3, 0, 0), 0)
        let destination = root.appendingPathComponent("b.txt")
        let evidence = try await fs.mutationPrecondition(at: source)
        _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "hello")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date, date)
        XCTAssertEqual(getxattr(destination.path, "com.example.keep", nil, 0, 0, 0), 3)
        XCTAssertEqual(try stageFiles(), [])
    }

    func testCopyOfFolderKeepsTreeAndLinks() async throws {
        let inner = try write("tree/sub/file.txt", "deep")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("tree/link").path, withDestinationPath: inner.path)
        let source = root.appendingPathComponent("tree"), destination = root.appendingPathComponent("copy")
        let evidence = try await fs.mutationPrecondition(at: source)
        _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("sub/file.txt"), encoding: .utf8), "deep")
        let kind = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("link").path)[.type] as? FileAttributeType
        XCTAssertEqual(kind, .typeSymbolicLink)
        XCTAssertEqual(try stageFiles(), [])
    }

    func testCopyOfLinkCopiesTheLinkItself() async throws {
        let target = try write("target.txt")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let destination = root.appendingPathComponent("link copy")
        let evidence = try await fs.mutationPrecondition(at: link)
        _ = try await fs.mutate(.copy(to: destination), source: link, requiring: evidence)
        let kind = try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
        XCTAssertEqual(kind, .typeSymbolicLink)
    }

    func testOccupiedDestinationIsNeverOverwrittenAndLeavesNoStage() async throws {
        let source = try write("a.txt", "new"), destination = try write("b.txt", "old")
        let evidence = try await fs.mutationPrecondition(at: source)
        do { _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence); XCTFail("Overwrote") }
        catch { XCTAssertEqual(error as? FileSystemError, .collision(noMutation: true)) }
        do { _ = try await fs.mutate(.move(to: destination), source: source, requiring: evidence); XCTFail("Overwrote") }
        catch { XCTAssertEqual(error as? FileSystemError, .collision(noMutation: true)) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new")
        XCTAssertEqual(try stageFiles(), [])
    }

    func testBothUnicodeSpellingsCollideOnMacOSVolumes() async throws {
        let source = try write("a.txt"), existing = try write("caf\u{00E9}.txt", "old")
        let evidence = try await fs.mutationPrecondition(at: source)
        do { _ = try await fs.mutate(.move(to: root.appendingPathComponent("cafe\u{0301}.txt")), source: source, requiring: evidence); XCTFail("Overwrote") }
        catch { XCTAssertEqual(error as? FileSystemError, .collision(noMutation: true)) }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
    }

    func testMoveKeepsTheSameObject() async throws {
        let source = try write("a.txt"), destination = root.appendingPathComponent("b.txt")
        let before = try await fs.entry(at: source)
        let evidence = try await fs.mutationPrecondition(at: source)
        _ = try await fs.mutate(.move(to: destination), source: source, requiring: evidence)
        let after = try await fs.entry(at: destination)
        XCTAssertEqual(after.objectIdentity, before.objectIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testChangedSourceIsRefusedWithNothingDone() async throws {
        let source = try write("a.txt", "one"), destination = root.appendingPathComponent("b.txt")
        let evidence = try await fs.mutationPrecondition(at: source)
        try Data("three".utf8).write(to: source)
        for mutation in [ConditionalFileMutation.copy(to: destination), .move(to: destination), .trash] {
            do { _ = try await fs.mutate(mutation, source: source, requiring: evidence); XCTFail("Must refuse") }
            catch { XCTAssertEqual(error as? ConditionalMutationError, .sourceChanged) }
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "three")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testReplacedSourceIsRefusedEvenWithSameSizeAndDate() async throws {
        let source = try write("a.txt", "one"), destination = root.appendingPathComponent("b.txt")
        let date = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        let evidence = try await fs.mutationPrecondition(at: source)
        try FileManager.default.removeItem(at: source)
        try Data("two".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: date as Any], ofItemAtPath: source.path)
        do { _ = try await fs.mutate(.move(to: destination), source: source, requiring: evidence); XCTFail("Must refuse") }
        catch { XCTAssertEqual(error as? ConditionalMutationError, .sourceChanged) }
    }

    func testTrashReturnsWhereTheItemWent() async throws {
        let source = try write("a.txt", "keep")
        let evidence = try await fs.mutationPrecondition(at: source)
        let trashed = try await fs.mutate(.trash, source: source, requiring: evidence)
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(trashed), encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testCancelledCopyLeavesNothingBehind() async throws {
        let source = try write("big.bin")
        try Data(count: 4_000_000).write(to: source)
        let destination = root.appendingPathComponent("copy.bin")
        let evidence = try await fs.mutationPrecondition(at: source)
        let fs = fs!
        let task = Task { try await fs.mutate(.copy(to: destination), source: source, requiring: evidence) }
        task.cancel()
        do {
            _ = try await task.value
            // A clone can finish before the cancellation lands, and then the copy is simply complete.
            XCTAssertEqual(try Data(contentsOf: destination).count, 4_000_000)
        } catch {
            XCTAssertEqual(error as? ConditionalMutationError, .cancelledBeforeMutation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        XCTAssertEqual(try stageFiles(), [])
    }
}
