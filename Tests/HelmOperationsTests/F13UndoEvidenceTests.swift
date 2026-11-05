// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmFileSystem
import HelmOperations

final class F13UndoEvidenceTests: XCTestCase {
    func testCreateCopyAndMoveSubstitutionsBeforePlanningAndExecution() async throws {
        for kind in [PlannedStep.Kind.createFile, .copy, .move] {
            for beforePlanning in [true, false] {
                let fs = InMemoryFileSystem(), executor = OperationExecutor(fileSystem: fs)
                let source = URL(fileURLWithPath: "/source"), output = URL(fileURLWithPath: "/output")
                try await fs.createFileExclusively(at: source, contents: Data([1]))
                let result = await executor.execute(OperationPlan(command: .recovery,
                    steps: [PlannedStep(kind: kind, source: kind == .createFile ? nil : source, destination: output, contents: Data([1]))]))
                XCTAssertNil(result.error)
                let stored = await executor.journal.entry(result.id)
                let entry = try XCTUnwrap(stored)
                if beforePlanning { try await substitute(output, in: fs) }
                let inverse = UndoPlanner.inverse(of: entry, recordedOrigins: [:])
                if !beforePlanning { try await substitute(output, in: fs) }
                let undo = await executor.execute(inverse)
                XCTAssertEqual(undo.error, .sourceChanged(output))
                XCTAssertEqual(undo.succeededCount, 0)
                let exists = await fs.exists(output)
                XCTAssertTrue(exists)
            }
        }
    }

    func testReplaceInstalledAndBackupSubstitutionsRefuseAllUndoSteps() async throws {
        for replaceBackup in [true, false] {
            for beforePlanning in [true, false] {
                let fs = InMemoryFileSystem(), executor = OperationExecutor(fileSystem: fs)
                let source = URL(fileURLWithPath: "/new"), output = URL(fileURLWithPath: "/output")
                let backup = URL(fileURLWithPath: "/backup"), stage = URL(fileURLWithPath: "/stage")
                try await fs.createFileExclusively(at: source, contents: Data([1]))
                try await fs.createFileExclusively(at: output, contents: Data([2]))
                let plan = OperationPlan(command: .recovery, steps: [
                    PlannedStep(kind: .copy, source: source, destination: stage),
                    PlannedStep(kind: .move, source: output, destination: backup),
                    PlannedStep(kind: .move, source: stage, destination: output)])
                let result = await executor.execute(plan)
                XCTAssertNil(result.error)
                let stored = await executor.journal.entry(result.id)
                let entry = try XCTUnwrap(stored), replaced = replaceBackup ? backup : output
                if beforePlanning { try await substitute(replaced, in: fs) }
                let inverse = UndoPlanner.inverse(of: entry, recordedOrigins: [:])
                if !beforePlanning { try await substitute(replaced, in: fs) }
                let undo = await executor.execute(inverse)
                XCTAssertEqual(undo.error, .sourceChanged(replaced))
                XCTAssertEqual(undo.succeededCount, 0)
                let outputExists = await fs.exists(output), backupExists = await fs.exists(backup)
                XCTAssertTrue(outputExists); XCTAssertTrue(backupExists)
            }
        }
    }

    func testValidMultiStepMovesRemapIdentityAndUndoSuccessfully() async throws {
        let fs = InMemoryFileSystem(), executor = OperationExecutor(fileSystem: fs)
        let source = URL(fileURLWithPath: "/source"), stage = URL(fileURLWithPath: "/stage")
        let output = URL(fileURLWithPath: "/output")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let original = try await fs.mutationPrecondition(at: source)
        let result = await executor.execute(OperationPlan(command: .recovery, steps: [
            PlannedStep(kind: .move, source: source, destination: stage),
            PlannedStep(kind: .move, source: stage, destination: output)]))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.outcomes.map { $0.destinationEvidence?.identity }, [original.identity, original.identity])
        let stored = await executor.journal.entry(result.id)
        let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
        XCTAssertEqual(inverse.expectedEvidence.keys.map(\.path), [output.path])
        let undo = await executor.execute(inverse)
        XCTAssertNil(undo.error); XCTAssertEqual(undo.succeededCount, 2)
        let restored = try await fs.mutationPrecondition(at: source)
        XCTAssertEqual(restored.identity, original.identity)
    }

    func testTrashIdentitySurvivesRestore() async throws {
        let fs = InMemoryFileSystem(), origins = InMemoryTrashOrigins()
        let executor = OperationExecutor(fileSystem: fs, origins: origins)
        let source = URL(fileURLWithPath: "/source")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let original = try await fs.mutationPrecondition(at: source)
        let result = await executor.execute(OperationPlan(command: .recovery,
            steps: [PlannedStep(kind: .trash, source: source)]))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.outcomes.first?.destinationEvidence?.identity, original.identity)
        let stored = await executor.journal.entry(result.id)
        let inverse = await UndoPlanner.inverse(of: try XCTUnwrap(stored), origins: origins)
        let undo = await executor.execute(inverse)
        XCTAssertNil(undo.error)
        let restored = try await fs.mutationPrecondition(at: source)
        XCTAssertEqual(restored.identity, original.identity)
    }

    func testMissingJournalIdentityCannotAdoptCurrentLeaf() async throws {
        let fs = InMemoryFileSystem(), output = URL(fileURLWithPath: "/output")
        try await fs.createFileExclusively(at: output, contents: Data([1]))
        let metadata = try await fs.entry(at: output)
        let step = PlannedStep(kind: .createFile, destination: output), id = OperationID()
        let plan = OperationPlan(command: .recovery, steps: [step])
        let outcome = ItemOutcome(step: step, destination: output, result: .success(metadata.changeToken), destinationKind: metadata.kind)
        let entry = JournalEntry(id: id, plan: plan, result: OperationResult(id: id, command: .recovery, outcomes: [outcome]))
        let inverse = UndoPlanner.inverse(of: entry, recordedOrigins: [:])
        let result = await OperationExecutor(fileSystem: fs).execute(inverse)
        XCTAssertEqual(result.error, .verificationUnavailable); XCTAssertEqual(result.succeededCount, 0)
        let exists = await fs.exists(output)
        XCTAssertTrue(exists)
    }

    private func substitute(_ url: URL, in fs: InMemoryFileSystem) async throws {
        let saved = URL(fileURLWithPath: "/saved-metadata")
        let original = try await fs.entry(at: url)
        try await fs.createFileExclusively(at: saved, contents: Data([9]))
        try await fs.applyDirectoryMetadata(from: url, to: saved)
        try await fs.removeItem(at: url)
        try await fs.createFileExclusively(at: url, contents: Data([9]))
        try await fs.applyDirectoryMetadata(from: saved, to: url)
        let replacement = try await fs.entry(at: url)
        XCTAssertEqual(replacement.changeToken, original.changeToken)
        XCTAssertNotEqual(replacement.objectIdentity, original.objectIdentity)
    }
}
