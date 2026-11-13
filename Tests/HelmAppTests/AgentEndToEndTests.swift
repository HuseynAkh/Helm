#if os(macOS)
import AppKit
import XCTest
import HelmAgent
import HelmCore
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmApp
@testable import HelmUI

/// AI mode from the spark to Undo with every piece real but the model: the app's own wiring in a fixture run, the
/// real conversation, folder rules, tools and plan checks, and Apply and Undo through the window's file commands.
@MainActor final class AgentEndToEndTests: XCTestCase {
    private var root: URL!
    private var app: AppController?
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var mess: URL { home.appendingPathComponent("AgentMess", isDirectory: true) }

    /// Photos into a new Images folder and text files into a new Notes folder.
    private static let organizeScript = """
        {"rules": [
          {"when": "organize", "turns": [
            {"calls": [{"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]},
            {"text": "Photos and notes get folders of their own.", "calls": [{"name": "propose_changes", "args": {
              "new_folders": [{"key": "n1", "parent": "@root", "name": "Images"}, {"key": "n2", "parent": "@root", "name": "Notes"}],
              "moves": [{"items": ["@name:photo-1.png", "@name:photo-2.jpg"], "all_in": "", "to": "n1"},
                        {"items": ["@name:memo.txt", "@name:todo.txt"], "all_in": "", "to": "n2"}],
              "copies": [], "renames": [], "trash": []}}]}]},
          {"when": "*", "turns": [{"text": "I can organize, move and copy files in these folders."}]}]}
        """

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mess, withIntermediateDirectories: true)
        for name in ["photo-1.png", "photo-2.jpg", "memo.txt", "todo.txt"] {
            try Data(name.utf8).write(to: mess.appendingPathComponent(name))
        }
        try Data(Self.organizeScript.utf8).write(to: root.appendingPathComponent(AppController.fixtureScriptName))
    }

    override func tearDownWithError() throws {
        for window in app?.allWindows ?? [] { window.window?.close() }
        for controller in controllers { controller.window?.close() }
        app = nil; controllers = []; keep = []
        HeaderMotion.isDisabledForTesting = false
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: Building

    /// A fixture-mode app on the throwaway home, as the host smoke launches one.
    private func composedApp() async -> AppController {
        var options = LaunchOptions()
        options.home = home
        options.support = root.appendingPathComponent("support", isDirectory: true)
        let app = AppController(options: options)
        app.staysInBackground = true
        self.app = app
        await app.compose()
        return app
    }

    /// The app's window on AgentMess, with AI mode on and the panel opened by its spark.
    private func openedOnMess(_ app: AppController) async throws -> (BrowserWindowController, AgentPanelModel) {
        app.environment?.settings.set(.bool(true), for: .aiModeEnabled)
        let window = try XCTUnwrap(app.allWindows.first)
        window.navigate(to: .directory(mess))
        let arrived = await until { window.activeTab?.location == .directory(self.mess) && window.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "AgentMess never opened")
        window.clickSparkForTesting()
        XCTAssertTrue(window.isAgentPanelOpen, "the spark opens the panel once a model is ready")
        let model = try XCTUnwrap(window.agentPanelModelForTesting)
        let ready = await until { model.chipsForTesting == ["AgentMess:thisMac"] && !model.isWaitingForTesting }
        XCTAssertTrue(ready, "the panel never took AgentMess: \(model.chipsForTesting)")
        return (window, model)
    }

    private func until(_ timeout: TimeInterval = 30, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    private func settle(_ window: BrowserWindowController, _ model: AgentPanelModel) async {
        _ = await until { !model.isWaitingForTesting && !window.isRunningOperationsForTesting && window.activeTab?.isLoading == false }
        await window.refreshHistoryForTesting()
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: The whole flow

    func testAFixtureRunOrganizesAppliesAndUndoesWithoutEverBuildingAClient() async throws {
        let app = await composedApp()
        let agent = try XCTUnwrap(app.agentServicesForTesting)
        XCTAssertTrue(agent.disk is InjectedAgentDisk, "a fixture run reads the fixture home through the real agent disk")
        let (window, model) = try await openedOnMess(app)
        XCTAssertTrue(model.sessionForTesting is AgentSession, "the panel talks to the real conversation")
        XCTAssertEqual(model.suggestionsForTesting, [AgentText.suggestOrganize(4), AgentText.suggestMoveAll, AgentText.suggestCopyAll])

        model.press(AgentText.suggestOrganize(4))
        await settle(window, model)
        XCTAssertEqual(model.phaseForTesting, "plan")
        XCTAssertEqual(model.planCountsForTesting, "4 moves · 2 new folders")
        XCTAssertEqual(model.groupsForTesting.sorted(), ["Move 2 items to “Images”:on", "Move 2 items to “Notes”:on"])
        XCTAssertEqual(names(in: mess), ["memo.txt", "photo-1.png", "photo-2.jpg", "todo.txt"], "nothing moves before Apply")

        model.press(AgentText.apply)
        await settle(window, model)
        XCTAssertEqual(model.phaseForTesting, "result")
        XCTAssertEqual(names(in: mess), ["Images", "Notes"])
        XCTAssertEqual(names(in: mess.appendingPathComponent("Images")), ["photo-1.png", "photo-2.jpg"])
        XCTAssertEqual(names(in: mess.appendingPathComponent("Notes")), ["memo.txt", "todo.txt"])
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.resultOrganized(items: 4, folders: 2)))
        window.focusFilesForTesting()
        XCTAssertEqual(window.undoTitleForTesting, "Organize “AgentMess”", "one Undo, named after the plan")

        // Command-Z takes the whole plan back in one step, and nothing of it can be redone.
        window.perform(.undo)
        let back = await until { self.names(in: self.mess) == ["memo.txt", "photo-1.png", "photo-2.jpg", "todo.txt"] }
        XCTAssertTrue(back, "everything is back: \(names(in: mess))")
        await settle(window, model)
        window.focusFilesForTesting()
        XCTAssertFalse(window.title(of: .redo).1, "an undone plan can't be redone")
        XCTAssertNotEqual(window.undoTitleForTesting, "Organize “AgentMess”")

        XCTAssertEqual(agent.runtime.clientBuildCount, 0, "a fixture run never builds a live client")
        let sent = try XCTUnwrap(agent.runtime.scriptedClientForTesting).allSentText()
        XCTAssertTrue(sent.contains("photo-1.png"), "the names went to the model")
        XCTAssertFalse(sent.contains(home.path), "the home's path never did")
        XCTAssertFalse(sent.contains(root.lastPathComponent), "nor any part of the path above the folder")
    }

    func testTurningAIModeOffShutsThePanelAndEndsItsConversation() async throws {
        let app = await composedApp()
        let agent = try XCTUnwrap(app.agentServicesForTesting)
        let (window, model) = try await openedOnMess(app)
        let session = try XCTUnwrap(model.sessionForTesting as? AgentSession)

        app.environment?.settings.set(.bool(false), for: .aiModeEnabled)
        XCTAssertFalse(window.isAgentPanelOpen, "the panel shuts")
        XCTAssertNil(window.agentPanelModelForTesting, "and its conversation goes with it")
        XCTAssertFalse(agent.runtime.isOn)
        XCTAssertEqual(agent.runtime.state, .off)
        XCTAssertNil(agent.runtime.makeSession(), "no conversation can be made while AI mode is off")
        // The conversation the panel had can't reach a model any more.
        var failures: [AgentFailure] = []
        for await event in session.send(AgentPersonInput(typedByPerson: "organize", selectedPaths: [])) {
            if case .failed(let failure) = event { failures.append(failure) }
        }
        XCTAssertEqual(failures, [.off])
        XCTAssertEqual(agent.runtime.scriptedClientForTesting?.sentTurns.count, 0, "nothing was sent")
        XCTAssertEqual(agent.runtime.clientBuildCount, 0)

        window.clickSparkForTesting()
        XCTAssertFalse(window.isAgentPanelOpen, "with AI mode off the spark asks for the AI mode screen instead")
    }

    func testALiveRuntimeNeverCallsItsClientFactoryWhileAIModeIsOff() async throws {
        let record = AgentEndToEndFactoryRecord()
        let secrets = MemorySecretStore()
        let profile = AgentProviderProfile(id: .claude, endpoint: try AgentEndpoint(fixed: .claude))
        try secrets.save(try XCTUnwrap(AgentSecret(pasted: "test-key-end-to-end-0001")), for: profile.secretID)
        let parts = AgentRuntimeParts(secrets: secrets, disk: MemoryAgentDisk(), home: "/home/helm",
                                      supportFolder: "/home/helm/.helm-support", clock: SystemHelmClock(), buildStamp: "",
                                      makeClient: { _, _, _ in record.made() }, makeSession: AgentLiveParts.makeSession)
        let runtime = AgentRuntime(parts: parts)
        let config = AIConfig(provider: "claude", models: ["claude": "claude-opus-5-5"])
        runtime.configure(config)

        XCTAssertEqual(runtime.state, .off)
        guard case .failure(.off) = runtime.client() else { return XCTFail("no client while off") }
        let checked = await runtime.check(config)
        XCTAssertEqual(checked, .off, "nothing is asked while off")
        XCTAssertNil(runtime.makeSession())
        XCTAssertEqual(record.count, 0, "the factory is never called while AI mode is off")
        XCTAssertEqual(runtime.clientBuildCount, 0)

        // On: still nothing until a request needs the client, and then one is built once.
        runtime.setOn(true)
        guard case .ready = runtime.state else { return XCTFail("a provider with a model and a key is ready") }
        let session = try XCTUnwrap(runtime.makeSession())
        XCTAssertTrue(session is AgentSession)
        XCTAssertEqual(record.count, 0, "a conversation alone builds no client")
        guard case .success = runtime.client() else { return XCTFail("the client is built on first use") }
        guard case .success = runtime.client() else { return XCTFail("and kept") }
        XCTAssertEqual(record.count, 1)
        XCTAssertEqual(runtime.clientBuildCount, 1)

        runtime.setOn(false)
        let shut = await until(10) { record.shutDowns == 1 }
        XCTAssertTrue(shut, "turning AI mode off shuts the client down")
        guard case .failure(.off) = runtime.client() else { return XCTFail("no client once off again") }
        XCTAssertEqual(record.count, 1)
    }

    func testACopyOfAnItemNoLongerDownloadedIsOneSkippedItemAndNothingIsRead() async throws {
        let memory = InMemoryFileSystem()
        let memoryHome = URL(fileURLWithPath: "/home/e2e", isDirectory: true)
        let cloud = memoryHome.appendingPathComponent("Cloud", isDirectory: true)
        let backup = cloud.appendingPathComponent("Backup", isDirectory: true)
        let clip = cloud.appendingPathComponent("clip.mov")
        for folder in [URL(fileURLWithPath: "/home", isDirectory: true), memoryHome, cloud, backup] {
            try await memory.createDirectory(at: folder)
        }
        try await memory.createFileExclusively(at: clip, contents: Data("frames".utf8))

        let scripted = ScriptedModelClient()
        try scripted.load(Data("""
            {"rules": [{"when": "copy", "turns": [
              {"calls": [{"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]},
              {"calls": [{"name": "propose_changes", "args": {"new_folders": [], "moves": [],
                "copies": [{"items": ["@name:clip.mov"], "all_in": "", "to": "@name:Backup"}], "renames": [], "trash": []}}]}]}]}
            """.utf8))
        // The window's commands see the clip go back to the cloud just before it is copied: after the conversation
        // checked the plan again, and as the window reads the clip for the last time.
        let evicting = AgentEndToEndEvictingFileSystem(inner: memory, evicting: clip)
        let (window, model) = try await memoryWindow(memory, commands: evicting, home: memoryHome, scripted: scripted, showing: cloud)
        model.type("copy the clip to Backup")
        model.send()
        await settle(window, model)
        XCTAssertEqual(model.phaseForTesting, "plan")
        XCTAssertEqual(model.planCountsForTesting, "1 copy")

        model.press(AgentText.apply)
        await settle(window, model)
        XCTAssertEqual(model.phaseForTesting, "result")
        XCTAssertTrue(model.threadTextForTesting.contains(AgentText.resultPartial(done: 0, total: 1, skipped: 1)),
                      model.threadTextForTesting)
        let reads = await memory.reads
        XCTAssertFalse(reads.contains(clip.path), "nothing was read to copy it: \(reads)")
        let copied = await memory.exists(backup.appendingPathComponent("clip.mov"))
        XCTAssertFalse(copied)
    }

    /// A window over a file system in memory, whose conversation is the real one over that file system.
    private func memoryWindow(_ memory: InMemoryFileSystem, commands: any FileSystem, home memoryHome: URL, scripted: ScriptedModelClient,
                              showing folder: URL) async throws -> (BrowserWindowController, AgentPanelModel) {
        let directories = AppDirectories(home: home, applicationSupport: root.appendingPathComponent("support", isDirectory: true))
        let env = try await AppEnvironment.live(directories: directories, settingsStorage: IsolatedSettings(),
                                                legacyReader: NoLegacyDefaults(), trash: { _ in nil })
        let storage = MemoryStorageFactsReader(home: memoryHome)
        let disk = FileSystemAgentDisk(fileSystem: memory, storage: storage, home: memoryHome.path, canonical: { $0 })
        let secrets = MemorySecretStore()
        let parts = AgentRuntimeParts(secrets: secrets, disk: disk, home: memoryHome.path,
                                      supportFolder: memoryHome.appendingPathComponent(".helm-support").path, clock: env.clock,
                                      buildStamp: "", scripted: scripted, makeSession: AgentLiveParts.makeSession)
        let runtime = AgentRuntime(parts: parts)
        runtime.setOn(true)
        let agent = AgentServices(runtime: runtime, config: AIConfigStore(), secrets: secrets, disk: disk, storage: storage,
                                  connector: MemoryServerConnector())
        let operations = OperationCoordinator(fileSystem: commands, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: memoryHome) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: commands,
            operations: operations, home: memoryHome, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.agent-e2e.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith, agent: agent)
        dependencies.settings.set(.bool(false), for: .askOnConflict)
        let host = PanelWindowHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "agent-e2e", seeds: [], activeIndex: 0)
        keep += [host, operations, volumes, env.settings]
        controllers.append(controller)
        controller.navigate(to: .directory(folder))
        let arrived = await until { controller.activeTab?.location == .directory(folder) && controller.activeTab?.isLoading == false }
        XCTAssertTrue(arrived, "the folder never opened")
        controller.clickSparkForTesting()
        let model = try XCTUnwrap(controller.agentPanelModelForTesting)
        let ready = await until { model.chipsForTesting == ["Cloud:thisMac"] && !model.isWaitingForTesting }
        XCTAssertTrue(ready, "the panel never took the folder: \(model.chipsForTesting)")
        return (controller, model)
    }
}

/// Forwards everything to a file system in memory, and marks one item as not downloaded the first time a command
/// reads it before changing anything.
private struct AgentEndToEndEvictingFileSystem: FileSystem {
    let inner: InMemoryFileSystem
    let evicting: URL
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        inner.enumerate(directory, options: options)
    }
    func entry(at url: URL) async throws -> FileEntry { try await inner.entry(at: url) }
    func exists(_ url: URL) async -> Bool { await inner.exists(url) }
    func isDirectory(_ url: URL, resolvingSymlinks: Bool) async -> Bool { await inner.isDirectory(url, resolvingSymlinks: resolvingSymlinks) }
    func childNames(of directory: URL) async throws -> Set<String> { try await inner.childNames(of: directory) }
    func mutationPrecondition(at source: URL) async throws -> FileMutationPrecondition {
        if source.standardizedFileURL.path == evicting.standardizedFileURL.path { await inner.setCloudAvailability(.evicted, at: source) }
        return try await inner.mutationPrecondition(at: source)
    }
    func mutate(_ mutation: ConditionalFileMutation, source: URL, requiring precondition: FileMutationPrecondition) async throws -> URL? {
        try await inner.mutate(mutation, source: source, requiring: precondition)
    }
    func copyItem(at source: URL, to destination: URL) async throws { try await inner.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) async throws { try await inner.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws {
        try await inner.replaceItem(at: destination, with: temporary, backup: backup)
    }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws {
        try await inner.applyDirectoryMetadata(from: source, to: destination)
    }
    func trashItem(at url: URL) async throws -> URL? { try await inner.trashItem(at: url) }
    func removeItem(at url: URL) async throws { try await inner.removeItem(at: url) }
    func createDirectory(at url: URL) async throws { try await inner.createDirectory(at: url) }
    func createFileExclusively(at url: URL, contents: Data) async throws { try await inner.createFileExclusively(at: url, contents: contents) }
    func createSymbolicLink(at url: URL, destination: URL) async throws { try await inner.createSymbolicLink(at: url, destination: destination) }
    func createAlias(for url: URL, at destination: URL) async throws { try await inner.createAlias(for: url, at: destination) }
    func isCaseSensitive(at url: URL) async throws -> Bool { try await inner.isCaseSensitive(at: url) }
    func volumeIdentifier(for url: URL) async throws -> String { try await inner.volumeIdentifier(for: url) }
    func availableCapacity(of url: URL) async throws -> Int64 { try await inner.availableCapacity(of: url) }
    func sizeOfTree(at url: URL) -> AsyncThrowingStream<Int64, Error> { inner.sizeOfTree(at: url) }
    func makeMonitor(for directory: URL) -> any DirectoryMonitor { inner.makeMonitor(for: directory) }
    func reopenAfterStall() async -> Bool { await inner.reopenAfterStall() }
}

/// Counts the live clients a runtime asks for, and their shutdowns. It makes no client that can connect.
final class AgentEndToEndFactoryRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var built = 0
    private var shut = 0
    var count: Int { lock.withLock { built } }
    var shutDowns: Int { lock.withLock { shut } }
    func made() -> any AgentLiveClient {
        lock.withLock { built += 1 }
        return AgentEndToEndLiveClient(record: self)
    }
    fileprivate func shutDown() { lock.withLock { shut += 1 } }
}

/// A live client that answers nothing and only notes that it was shut down.
private final class AgentEndToEndLiveClient: AgentLiveClient, @unchecked Sendable {
    let providerName = "Claude", destination = "Claude", isLocal = false
    private let record: AgentEndToEndFactoryRecord
    init(record: AgentEndToEndFactoryRecord) { self.record = record }
    func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentFailure.unreachable) }
    }
    func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] { [] }
    func structured(_ ask: AgentStructuredAsk) async throws -> Data { throw AgentFailure.unreachable }
    func models() async throws -> [AgentModelInfo] { [] }
    func shutdown() async { record.shutDown() }
}
#endif
