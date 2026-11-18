#if os(macOS)
import Darwin
import Foundation
import XCTest
import HelmCore
import HelmApp
import HelmFileSystem
import HelmOperations
import HelmTestKit
@testable import HelmUI

/// A change Properties makes to a temporary file's or folder's permissions, through the app's operation coordinator
/// and a window's history: Undo puts the exact mode back, Redo makes the change again, and a refusal changes nothing
/// and records nothing. Every change is said to whoever follows them.
@MainActor final class PermissionChangeFlowTests: XCTestCase {
    private var temp: TempDirectory!
    override func setUpWithError() throws { temp = try TempDirectory() }
    override func tearDownWithError() throws { try temp.remove() }

    private func coordinator() async throws -> OperationCoordinator {
        let env = try await AppEnvironment.test()
        return OperationCoordinator(fileSystem: InMemoryFileSystem(), origins: env.trashOrigins, journal: env.journal)
    }
    private func file(_ name: String, mode: mode_t) throws -> URL {
        let url = temp.url.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, mode), 0)
        return url
    }
    private func mode(_ url: URL) -> UInt16 {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return UInt16(info.st_mode & 0o7777)
    }
    private func identity(_ url: URL) throws -> FileObjectIdentity { try PermissionsWriter.target(at: url).get().identity }

    func testUndoPutsTheExactModeBackAndRedoMakesTheChangeAgain() async throws {
        let operations = try await coordinator()
        let history = WindowOperationHistory()
        var events: [PermissionEvent] = []
        let token = operations.permissionEvents.subscribe { events.append($0) }
        defer { operations.permissionEvents.cancel(token) }
        let url = try file("notes.txt", mode: 0o644)
        let id = try identity(url)

        let first = await operations.changePermissions(of: url, identity: id, from: 0o644, to: 0o604, history: history)
        XCTAssertEqual(try first.get(), 0o604)
        let second = await operations.changePermissions(of: url, identity: id, from: 0o604, to: 0o705, history: history)
        XCTAssertEqual(try second.get(), 0o705)
        XCTAssertEqual(mode(url), 0o705)
        var state = await history.snapshot()
        XCTAssertEqual(state.undoEntries.map(\.name), ["Change Permissions", "Change Permissions"])

        // Undo, one change at a time, latest first.
        guard case .success = await operations.undo(history: history) else { return XCTFail("first Undo") }
        XCTAssertEqual(mode(url), 0o604)
        guard case .success = await operations.undo(history: history) else { return XCTFail("second Undo") }
        XCTAssertEqual(mode(url), 0o644)
        state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .empty)

        // Redo makes the first change again.
        guard case .success = await operations.redo(history: history, resolver: nil) else { return XCTFail("Redo") }
        XCTAssertEqual(mode(url), 0o604)
        state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .available("Change Permissions"))
        XCTAssertEqual(events, Array(repeating: PermissionEvent(item: url), count: 5))
    }

    /// A folder's sticky bit, and every bit a change isn't about, come back as they were.
    func testAFoldersModeComesBackWhole() async throws {
        let operations = try await coordinator()
        let history = WindowOperationHistory()
        let url = temp.url.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(url.path, 0o1755), 0)
        let changed = PermissionEdit.mode(0o1755, setting: .noAccess, for: .everyone, folder: true)
        let outcome = await operations.changePermissions(of: url, identity: try identity(url), from: 0o1755, to: changed, history: history)
        XCTAssertEqual(try outcome.get(), 0o1750)
        guard case .success = await operations.undo(history: history) else { return XCTFail("Undo") }
        XCTAssertEqual(mode(url), 0o1755)
    }

    /// Changed on the disk since the change was made: its Undo changes nothing, says why, and stays for Undo.
    func testUndoOfAnItemChangedSinceIsRefused() async throws {
        let operations = try await coordinator()
        let history = WindowOperationHistory()
        var events: [PermissionEvent] = []
        let token = operations.permissionEvents.subscribe { events.append($0) }
        defer { operations.permissionEvents.cancel(token) }
        let url = try file("notes.txt", mode: 0o644)
        _ = await operations.changePermissions(of: url, identity: try identity(url), from: 0o644, to: 0o600, history: history)
        XCTAssertEqual(chmod(url.path, 0o640), 0)
        let refused = await operations.undo(history: history)
        let expected = "“notes.txt” has changed since, so its permissions can’t be put back."
        XCTAssertEqual(refused.failureMessage, expected)
        XCTAssertEqual(mode(url), 0o640)
        XCTAssertEqual(events.last, PermissionEvent(item: url, message: expected))
        let state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .available("Change Permissions"))
        // Back as the change left it, the Undo goes through.
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        guard case .success = await operations.undo(history: history) else { return XCTFail("Undo") }
        XCTAssertEqual(mode(url), 0o644)
    }

    /// A change asked about a mode the item no longer has, or about root's item, changes nothing and records nothing.
    func testARefusedChangeRecordsNothing() async throws {
        let operations = try await coordinator()
        let history = WindowOperationHistory()
        let url = try file("notes.txt", mode: 0o644)
        let stale = await operations.changePermissions(of: url, identity: try identity(url), from: 0o600, to: 0o604, history: history)
        XCTAssertEqual(stale.failureMessage, PermissionRefusal.changed.message)
        XCTAssertEqual(mode(url), 0o644)
        if getuid() != 0 {
            let system = URL(fileURLWithPath: "/usr/bin/true")
            let target = try PermissionsWriter.target(at: system).get()
            let theirs = await operations.changePermissions(of: system, identity: target.identity, from: target.mode,
                                                            to: target.mode & ~UInt16(0o001), history: history)
            XCTAssertEqual(theirs.failureMessage, PermissionRefusal.notOwner.message)
        }
        let state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .empty)
        XCTAssertNil(state.pending)
    }

    /// While the window's history is reserved, a change is turned away as busy, and nothing is changed.
    func testAChangeWhileTheHistoryIsBusyIsTurnedAway() async throws {
        let operations = try await coordinator()
        let history = WindowOperationHistory()
        let url = try file("notes.txt", mode: 0o644)
        let reserved = await history.beginForward(.trash(items: [url]))
        XCTAssertNotNil(reserved)
        let outcome = await operations.changePermissions(of: url, identity: try identity(url), from: 0o644, to: 0o600, history: history)
        guard case .failure(.busy) = outcome else { return XCTFail("not turned away: \(outcome)") }
        XCTAssertEqual(mode(url), 0o644)
    }
}

private extension Result where Failure == OperationCoordinator.Failure {
    var failureMessage: String? {
        if case .failure(.message(let message)) = self { return message }
        return nil
    }
}
#endif
