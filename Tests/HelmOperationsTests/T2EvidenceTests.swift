// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem
@testable import HelmOperations

// F-053/F-059/B-041: forward evidence and inverse steps must preserve ownership and spelling.
final class T2EvidenceTests: XCTestCase {
    func testMoveRetiresSourceEvidence() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source"), destination = URL(fileURLWithPath: "/destination")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        var evidence = await ForwardEvidence.capture(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .move, source: source)]), fileSystem: fs)
        try await evidence.validate(source, fileSystem: fs)
        evidence.completed(PlannedStep(kind: .move, source: source, destination: destination), destination: destination, entry: nil)
        XCTAssertTrue(evidence.isMissing(source)); XCTAssertTrue(evidence.isMissing(destination))
        do { try await evidence.validate(source, fileSystem: fs); XCTFail("Retired source adopted") }
        catch { XCTAssertEqual(error as? OperationError, .verificationUnavailable) }
    }
    func testTrashRetiresSourceEvidence() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source"), destination = URL(fileURLWithPath: "/destination")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        var evidence = await ForwardEvidence.capture(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .trash, source: source)]), fileSystem: fs)
        try await evidence.validate(source, fileSystem: fs)
        evidence.completed(PlannedStep(kind: .trash, source: source, destination: destination), destination: destination, entry: nil)
        XCTAssertTrue(evidence.isMissing(source)); XCTAssertTrue(evidence.isMissing(destination))
        do { try await evidence.validate(source, fileSystem: fs); XCTFail("Retired source adopted") }
        catch { XCTAssertEqual(error as? OperationError, .verificationUnavailable) }
    }
    func testCopyKeepsSourceEvidence() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        var evidence = await ForwardEvidence.capture(OperationPlan(command: .recovery, steps: []), fileSystem: fs)
        evidence.record(source, entry: try await fs.entry(at: source))
        evidence.completed(PlannedStep(kind: .copy, source: source), destination: nil, entry: nil)
        XCTAssertFalse(evidence.isMissing(source)); try await evidence.validate(source, fileSystem: fs)
        try await fs.moveItem(at: source, to: URL(fileURLWithPath: "/saved"))
        try await fs.createFileExclusively(at: source, contents: Data([2, 3]))
        do { try await evidence.validate(source, fileSystem: fs); XCTFail("Substituted source adopted") }
        catch { XCTAssertEqual(error as? OperationError, .sourceChanged(source)) }
    }
    func testVerifyCannotRepairMissingEvidence() async throws {
        let fs = InMemoryFileSystem(), stage = URL(fileURLWithPath: "/stage")
        try await fs.createFileExclusively(at: stage, contents: Data([1]))
        var evidence = await ForwardEvidence.capture(OperationPlan(command: .recovery, steps: []), fileSystem: fs)
        evidence.record(stage, entry: nil)
        evidence.completed(PlannedStep(kind: .verifyCopy, destination: stage), destination: stage, entry: try await fs.entry(at: stage))
        XCTAssertTrue(evidence.isMissing(stage))
        do { try await evidence.validate(stage, fileSystem: fs); XCTFail("Missing evidence repaired by verification") }
        catch { XCTAssertEqual(error as? OperationError, .verificationUnavailable) }
    }
    func testReplacementUndoUppercase() async throws {
        let fs = InMemoryFileSystem(caseSensitive: false)
        let parent = URL(fileURLWithPath: "/dest"), input = URL(fileURLWithPath: "/src")
        try await fs.createDirectory(at: parent); try await fs.createDirectory(at: input)
        let source = input.appendingPathComponent("report.txt"), original = parent.appendingPathComponent("REPORT.TXT")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        try await fs.createFileExclusively(at: original, contents: Data([9, 8, 7]))
        let origins = InMemoryTrashOrigins(), executor = OperationExecutor(fileSystem: fs, origins: origins)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent], policy: ConflictPolicy(defaultResolution: .replace))
        let result = await executor.execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context))
        XCTAssertNil(result.error)
        let stored = await executor.journal.entry(result.id)
        let inverse = await UndoPlanner.inverse(of: try XCTUnwrap(stored), origins: origins)
        let undone = await executor.execute(inverse)
        XCTAssertNil(undone.error)
        let names = try await fs.childNames(of: parent)
        XCTAssertEqual(names.count, 1); XCTAssertEqual(Array(try XCTUnwrap(names.first).utf8), Array("REPORT.TXT".utf8))
        let bytes = try await fs.storedContents(at: original); XCTAssertEqual(bytes, Data([9, 8, 7]))
        let sourceBytes = try await fs.storedContents(at: source); XCTAssertEqual(sourceBytes, Data([1]))
    }
    func testReplacementUndoMixedcase() async throws {
        let fs = InMemoryFileSystem(caseSensitive: false)
        let parent = URL(fileURLWithPath: "/dest"), input = URL(fileURLWithPath: "/src")
        try await fs.createDirectory(at: parent); try await fs.createDirectory(at: input)
        let source = input.appendingPathComponent("report.txt"), original = parent.appendingPathComponent("RePoRt.TxT")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        try await fs.createFileExclusively(at: original, contents: Data([9, 8, 7]))
        let origins = InMemoryTrashOrigins(), executor = OperationExecutor(fileSystem: fs, origins: origins)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent], policy: ConflictPolicy(defaultResolution: .replace))
        let result = await executor.execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context))
        XCTAssertNil(result.error)
        let stored = await executor.journal.entry(result.id)
        let inverse = await UndoPlanner.inverse(of: try XCTUnwrap(stored), origins: origins)
        let undone = await executor.execute(inverse)
        XCTAssertNil(undone.error)
        let names = try await fs.childNames(of: parent)
        XCTAssertEqual(names.count, 1); XCTAssertEqual(Array(try XCTUnwrap(names.first).utf8), Array("RePoRt.TxT".utf8))
        let bytes = try await fs.storedContents(at: original); XCTAssertEqual(bytes, Data([9, 8, 7]))
        let sourceBytes = try await fs.storedContents(at: source); XCTAssertEqual(sourceBytes, Data([1]))
    }
    func testReplacementUndoUnicode() async throws {
        let fs = InMemoryFileSystem(caseSensitive: false)
        let parent = URL(fileURLWithPath: "/dest"), input = URL(fileURLWithPath: "/src")
        try await fs.createDirectory(at: parent); try await fs.createDirectory(at: input)
        let source = input.appendingPathComponent("café.txt"), original = parent.appendingPathComponent("cafe\u{301}.txt")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        try await fs.createFileExclusively(at: original, contents: Data([9, 8, 7]))
        let origins = InMemoryTrashOrigins(), executor = OperationExecutor(fileSystem: fs, origins: origins)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent], policy: ConflictPolicy(defaultResolution: .replace))
        let result = await executor.execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context))
        XCTAssertNil(result.error)
        let stored = await executor.journal.entry(result.id)
        let inverse = await UndoPlanner.inverse(of: try XCTUnwrap(stored), origins: origins)
        let undone = await executor.execute(inverse)
        XCTAssertNil(undone.error)
        let names = try await fs.childNames(of: parent)
        XCTAssertEqual(names.count, 1); XCTAssertEqual(Array(try XCTUnwrap(names.first).utf8), Array("cafe\u{301}.txt".utf8))
        let bytes = try await fs.storedContents(at: original); XCTAssertEqual(bytes, Data([9, 8, 7]))
        let sourceBytes = try await fs.storedContents(at: source); XCTAssertEqual(sourceBytes, Data([1]))
    }
}
