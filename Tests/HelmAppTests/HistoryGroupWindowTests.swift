#if os(macOS)
import AppKit
import XCTest
import HelmCore
import HelmApp
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmUI

/// One applied plan is one Undo. Several commands run under one history group, as an applied plan runs them, are
/// undone together, by the plan's own Undo and by Command-Z alike. A change made before them stays, and a step that
/// fails ends the group there. A grouped change that was undone can't be redone. A grouped change, and the Undo of
/// it, run with downloads off, while a plain change and its Undo run as they always have.
@MainActor final class HistoryGroupWindowTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/group", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var sorted: URL { documents.appendingPathComponent("Sorted", isDirectory: true) }
    private var kept: URL { home.appendingPathComponent("Kept", isDirectory: true) }
    private let names = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []
    private var messages: [String] = []
    /// Whether downloads were off for each call the window's file system was asked to make.
    private var marks = DownloadsMarkLog()

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }
    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers = []
        keep = []
        messages = []
        marks = DownloadsMarkLog()
        super.tearDown()
    }

    /// A window that is never shown, on Documents, holding five files, a Sorted folder and one more file, plain.txt.
    private func window() async throws -> (BrowserWindowController, InMemoryFileSystem) {
        let env = try await AppEnvironment.test(home: home)
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        for folder in [documents, sorted, kept] { try await memory.createDirectory(at: folder) }
        for name in names + ["plain.txt"] {
            try await memory.createFileExclusively(at: documents.appendingPathComponent(name), contents: Data(name.utf8))
        }
        let fileSystem = DownloadsMarkRecorder(inner: memory, log: marks)
        let operations = OperationCoordinator(fileSystem: fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.history-group.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith)
        dependencies.settings.set(.bool(false), for: .askOnConflict)
        let host = HistoryGroupQuietHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "history-group", seeds: [], activeIndex: 0)
        keep += [host, operations, volumes]
        controllers.append(controller)
        controller.messageObserver = { [weak self] in self?.messages.append($0) }
        controller.confirmsForTesting = true
        controller.navigate(to: .directory(documents))
        let arrived = await until { controller.activeTab?.location == .directory(self.documents) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "Documents never opened")
        return (controller, memory)
    }

    /// Waits for `condition`. The limit is generous since a busy Mac runs file operations slowly; a wait that is met
    /// ends at once.
    private func until(_ timeout: TimeInterval = 30, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
    private func settle(_ controller: BrowserWindowController) async {
        _ = await until { !controller.isRunningOperations && controller.activeTab?.isLoading == false }
        await controller.refreshHistoryForTesting()
    }
    private func present(in folder: URL, _ memory: InMemoryFileSystem) async -> [String] {
        var found: [String] = []
        for name in names + ["plain.txt"] where await memory.exists(folder.appendingPathComponent(name)) { found.append(name) }
        return found
    }

    /// plain.txt moves to Kept on its own, as any change does. Then each of the five files moves into Sorted with a
    /// command of its own, all under one group, in one of the window's turns, as an applied plan runs them.
    private func applyGroup(_ controller: BrowserWindowController, _ memory: InMemoryFileSystem) async throws -> HistoryGroup {
        controller.run(.move(sources: [documents.appendingPathComponent("plain.txt")], destinationDirectory: kept))
        await settle(controller)
        let group = HistoryGroup(name: "Organize “Documents”")
        let documents = documents, sorted = sorted, names = names
        let outcomes = await controller.enqueueOperationAwaiting { [weak controller] () -> [Bool] in
            var succeeded: [Bool] = []
            for name in names {
                let outcome = await controller?.runAwaiting(.move(sources: [documents.appendingPathComponent(name)], destinationDirectory: sorted),
                                                            group: group, resolver: nil, onFailure: nil, downloadsOff: true)
                if case .success(let result)? = outcome, result.error == nil { succeeded.append(true) } else { succeeded.append(false) }
            }
            return succeeded
        }
        XCTAssertEqual(outcomes, [true, true, true, true, true])
        await settle(controller)
        let inSorted = await present(in: sorted, memory)
        XCTAssertEqual(inSorted, names, "the five files moved")
        XCTAssertEqual(messages, [], "a grouped command shows no message")
        let undo = controller.title(of: .undo)
        XCTAssertEqual(undo.0, "Undo Organize “Documents”", "Edit reads the group's name once, not Undo Move")
        XCTAssertTrue(undo.1)
        return group
    }

    func testOneUndoAgentPlanUndoesTheWholeGroupAndNothingBelowIt() async throws {
        let (controller, memory) = try await window()
        let group = try await applyGroup(controller, memory)

        let undone = await controller.undoAgentPlan(group.id)
        XCTAssertTrue(undone)
        await settle(controller)
        let back = await present(in: documents, memory)
        XCTAssertEqual(back, names, "every file of the group came back, and only those")
        let stillSorted = await present(in: sorted, memory)
        XCTAssertEqual(stillSorted, [])
        let stillKept = await present(in: kept, memory)
        XCTAssertEqual(stillKept, ["plain.txt"], "the change made before the group is untouched")
        XCTAssertEqual(controller.title(of: .undo).0, "Undo Move", "the change before the group is next")
        XCTAssertFalse(controller.title(of: .redo).1, "an undone plan can't be redone")
        for name in names {
            XCTAssertEqual(marks.changes(of: sorted.appendingPathComponent(name)), [true], "\(name) came back with downloads off")
        }

        // Asked again for the same group, nothing of it is at the top any more: nothing else is undone.
        let again = await controller.undoAgentPlan(group.id)
        XCTAssertFalse(again)
        await settle(controller)
        let keptAfter = await present(in: kept, memory)
        XCTAssertEqual(keptAfter, ["plain.txt"])
    }

    func testOneCommandZUndoesTheWholeGroupAndNothingBelowIt() async throws {
        let (controller, memory) = try await window()
        _ = try await applyGroup(controller, memory)

        controller.perform(.undo)
        let done = await until { await self.present(in: self.documents, memory) == self.names }
        XCTAssertTrue(done, "one Command-Z brought back every file of the group")
        await settle(controller)
        let stillKept = await present(in: kept, memory)
        XCTAssertEqual(stillKept, ["plain.txt"], "the change made before the group is untouched")
        XCTAssertEqual(controller.title(of: .undo).0, "Undo Move")
        XCTAssertFalse(controller.title(of: .redo).1, "an undone plan can't be redone")

        // The next Command-Z undoes the change before the group, on its own.
        controller.perform(.undo)
        let plainBack = await until { await memory.exists(self.documents.appendingPathComponent("plain.txt")) }
        XCTAssertTrue(plainBack)
        await settle(controller)
        let documentsAfter = await present(in: documents, memory)
        XCTAssertEqual(documentsAfter, names + ["plain.txt"])
    }

    func testAGroupAndItsUndoRunWithDownloadsOffWhereverTheUndoWasAskedFor() async throws {
        let (controller, memory) = try await window()
        _ = try await applyGroup(controller, memory)
        // Planning reads each destination's case rule: Kept for the plain move, Sorted for the group's.
        XCTAssertEqual(marks.planned(in: kept), [false], "a plain change plans with downloads on")
        XCTAssertEqual(Set(marks.planned(in: sorted)), [true], "a grouped change plans with downloads off")
        XCTAssertEqual(marks.changes(of: documents.appendingPathComponent("plain.txt")), [false])
        for name in names {
            XCTAssertEqual(marks.changes(of: documents.appendingPathComponent(name)), [true], "\(name) moved with downloads off")
        }

        // Command-Z undoes the group as the plan's own Undo does: with downloads off.
        controller.perform(.undo)
        let back = await until { await self.present(in: self.documents, memory) == self.names }
        XCTAssertTrue(back)
        await settle(controller)
        for name in names {
            XCTAssertEqual(marks.changes(of: sorted.appendingPathComponent(name)), [true], "\(name) came back with downloads off")
        }

        // The plain change below it is undone as any Undo is.
        controller.perform(.undo)
        let plainBack = await until { await memory.exists(self.documents.appendingPathComponent("plain.txt")) }
        XCTAssertTrue(plainBack)
        await settle(controller)
        XCTAssertEqual(marks.changes(of: kept.appendingPathComponent("plain.txt")), [false])
    }

    func testAnUndoPlanForAnotherGroupUndoesNothing() async throws {
        let (controller, memory) = try await window()
        _ = try await applyGroup(controller, memory)
        let undone = await controller.undoAgentPlan(UUID())
        XCTAssertFalse(undone)
        await settle(controller)
        let stillSorted = await present(in: sorted, memory)
        XCTAssertEqual(stillSorted, names, "nothing was undone")
        XCTAssertEqual(controller.title(of: .undo).0, "Undo Organize “Documents”")
    }

    func testAFailedStepStopsTheGroupThere() async throws {
        let (controller, memory) = try await window()
        let group = try await applyGroup(controller, memory)
        // The group is undone from its last command back: e, d, then c, which is no longer there to bring back.
        try await memory.removeItem(at: sorted.appendingPathComponent("c.txt"))

        let undone = await controller.undoAgentPlan(group.id)
        XCTAssertFalse(undone, "a step failed")
        await settle(controller)
        let back = await present(in: documents, memory)
        XCTAssertEqual(back, ["d.txt", "e.txt"], "the steps before the failure were undone")
        let stillSorted = await present(in: sorted, memory)
        XCTAssertEqual(stillSorted, ["a.txt", "b.txt"], "nothing after the failure was undone")
        let stillKept = await present(in: kept, memory)
        XCTAssertEqual(stillKept, ["plain.txt"])
        XCTAssertFalse(messages.isEmpty, "the failure was shown, as one Undo shows it")
    }
}

/// What a file system was asked to do and whether downloads were off for it: the case rule planning reads for a
/// destination folder, and each change made to an item, by the item it started from.
private final class DownloadsMarkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var planning: [(String, Bool)] = []
    private var mutations: [(String, Bool)] = []
    func plan(_ url: URL) { lock.withLock { planning.append((url.standardizedFileURL.path, DatalessGuard.isOff)) } }
    func change(_ url: URL) { lock.withLock { mutations.append((url.standardizedFileURL.path, DatalessGuard.isOff)) } }
    func planned(in folder: URL) -> [Bool] {
        lock.withLock { planning.filter { $0.0 == folder.standardizedFileURL.path }.map(\.1) }
    }
    func changes(of item: URL) -> [Bool] {
        lock.withLock { mutations.filter { $0.0 == item.standardizedFileURL.path }.map(\.1) }
    }
}

/// An in-memory file system that notes whether downloads were off for the calls only file operations make.
private struct DownloadsMarkRecorder: FileSystem {
    let inner: InMemoryFileSystem
    let log: DownloadsMarkLog
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        inner.enumerate(directory, options: options)
    }
    func entry(at url: URL) async throws -> FileEntry { try await inner.entry(at: url) }
    func exists(_ url: URL) async -> Bool { await inner.exists(url) }
    func isDirectory(_ url: URL, resolvingSymlinks: Bool) async -> Bool { await inner.isDirectory(url, resolvingSymlinks: resolvingSymlinks) }
    func childNames(of directory: URL) async throws -> Set<String> { try await inner.childNames(of: directory) }
    func mutationPrecondition(at source: URL) async throws -> FileMutationPrecondition { try await inner.mutationPrecondition(at: source) }
    func mutate(_ mutation: ConditionalFileMutation, source: URL, requiring precondition: FileMutationPrecondition) async throws -> URL? {
        log.change(source)
        return try await inner.mutate(mutation, source: source, requiring: precondition)
    }
    func copyItem(at source: URL, to destination: URL) async throws { log.change(source); try await inner.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) async throws { log.change(source); try await inner.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws {
        try await inner.replaceItem(at: destination, with: temporary, backup: backup)
    }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws {
        try await inner.applyDirectoryMetadata(from: source, to: destination)
    }
    func trashItem(at url: URL) async throws -> URL? { log.change(url); return try await inner.trashItem(at: url) }
    func removeItem(at url: URL) async throws { try await inner.removeItem(at: url) }
    func createDirectory(at url: URL) async throws { try await inner.createDirectory(at: url) }
    func createFileExclusively(at url: URL, contents: Data) async throws { try await inner.createFileExclusively(at: url, contents: contents) }
    func createSymbolicLink(at url: URL, destination: URL) async throws { try await inner.createSymbolicLink(at: url, destination: destination) }
    func createAlias(for url: URL, at destination: URL) async throws { try await inner.createAlias(for: url, at: destination) }
    func isCaseSensitive(at url: URL) async throws -> Bool { log.plan(url); return try await inner.isCaseSensitive(at: url) }
    func volumeIdentifier(for url: URL) async throws -> String { try await inner.volumeIdentifier(for: url) }
    func availableCapacity(of url: URL) async throws -> Int64 { try await inner.availableCapacity(of: url) }
    func sizeOfTree(at url: URL) -> AsyncThrowingStream<Int64, Error> { inner.sizeOfTree(at: url) }
    func makeMonitor(for directory: URL) -> any DirectoryMonitor { inner.makeMonitor(for: directory) }
    func reopenAfterStall() async -> Bool { await inner.reopenAfterStall() }
}

@MainActor private final class HistoryGroupQuietHost: BrowserWindowHost {
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
}
#endif
