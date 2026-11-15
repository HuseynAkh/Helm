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

/// The pieces AI mode stands on, in a real window and a real app on a throwaway home, with AI mode off: the services
/// every run gets, Connect to Server through one seam, a search handed to an AI search runner, a command run for an
/// applied plan, the fixture Trash's refusals, ai.json, and the AI tab in Settings.
@MainActor final class AgentWindowHooksTests: XCTestCase {
    private var root: URL!
    private var app: AppController?
    private var controllers: [BrowserWindowController] = []
    private var keep: [AnyObject] = []
    private var messages: [String] = []
    private let home = URL(fileURLWithPath: "/home/hooks", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/Documents", isDirectory: true),
                                                withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for window in app?.allWindows ?? [] { window.window?.close() }
        for controller in controllers { controller.window?.close() }
        app = nil; controllers = []; keep = []; messages = []
        HostEffectRunner.spotlightAnswersForTesting = nil
        HeaderMotion.isDisabledForTesting = false
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: A real app on a throwaway home

    private func composedApp(liveAgent: Bool = false) async -> AppController {
        var options = LaunchOptions()
        options.home = root.appendingPathComponent("home", isDirectory: true)
        options.support = root.appendingPathComponent("support", isDirectory: true)
        options.liveAgent = liveAgent
        let app = AppController(options: options)
        app.staysInBackground = true
        self.app = app
        await app.compose()
        return app
    }

    func testAFixtureRunGetsStandInsWithAIModeOff() async throws {
        let app = await composedApp()
        let agent = try XCTUnwrap(app.agentServicesForTesting)
        XCTAssertFalse(agent.runtime.isOn)
        XCTAssertEqual(agent.runtime.state, .off)
        XCTAssertNotNil(agent.runtime.scriptedClientForTesting, "a fixture run answers from the scripted model")
        XCTAssertEqual(agent.runtime.clientBuildCount, 0)
        XCTAssertTrue(agent.secrets is MemorySecretStore)
        XCTAssertTrue(agent.connector is MemoryServerConnector)
        XCTAssertTrue(agent.storage is MemoryStorageFactsReader)
        XCTAssertTrue(agent.config === app.environment?.aiConfig, "the windows and the app share ai.json's store")
        XCTAssertTrue(app.allWindows.first?.dependencies.agent.runtime === agent.runtime, "every window shares one runtime")
    }

    func testTheSwitchAndAIJsonReachTheRuntime() async throws {
        let app = await composedApp()
        let agent = try XCTUnwrap(app.agentServicesForTesting)
        let environment = try XCTUnwrap(app.environment)
        environment.settings.set(.bool(true), for: .aiModeEnabled)
        XCTAssertTrue(agent.runtime.isOn)
        if case .ready = agent.runtime.state {} else { XCTFail("a scripted runtime is ready as soon as AI mode is on") }
        agent.config.update { $0.provider = "ollama"; $0.ports["ollama"] = 11500 }
        XCTAssertEqual(agent.runtime.config.provider, "ollama")
        XCTAssertEqual(agent.runtime.config.ports["ollama"], 11500)
        environment.settings.set(.bool(false), for: .aiModeEnabled)
        XCTAssertFalse(agent.runtime.isOn)
        XCTAssertEqual(agent.runtime.clientBuildCount, 0, "no live client is ever built in a fixture run")
    }

    func testLiveWiringLeavesTheScriptedModelOut() async throws {
        let app = await composedApp(liveAgent: true)
        let agent = try XCTUnwrap(app.agentServicesForTesting)
        XCTAssertNil(agent.runtime.scriptedClientForTesting)
        app.environment?.settings.set(.bool(true), for: .aiModeEnabled)
        XCTAssertEqual(agent.runtime.state, .notReady, "with no provider chosen nothing is ready")
        XCTAssertEqual(agent.runtime.clientBuildCount, 0)
        XCTAssertTrue(agent.secrets is MemorySecretStore, "keys stay in memory in a fixture run")
        XCTAssertTrue(agent.disk is InjectedAgentDisk)
        XCTAssertTrue(agent.storage is MemoryStorageFactsReader)
        XCTAssertTrue(agent.connector is MemoryServerConnector, "a fixture run never hands an address to macOS")
        // The shipped client factory is in place: a local provider with a model is ready, and still nothing is built
        // until a request needs it.
        agent.config.update { $0.provider = "ollama"; $0.models["ollama"] = "stand-in:latest" }
        if case .ready(_, _, "stand-in:latest", true) = agent.runtime.state {} else {
            XCTFail("the live wiring makes a local provider ready: \(agent.runtime.state)")
        }
        XCTAssertEqual(agent.runtime.clientBuildCount, 0)
        app.environment?.settings.set(.bool(false), for: .aiModeEnabled)
        XCTAssertEqual(agent.runtime.state, .off)
        XCTAssertEqual(agent.runtime.clientBuildCount, 0)
    }

    func testLiveAgentNeedsBothFixtureFolders() {
        XCTAssertEqual(LaunchOptions.parse(["Helm", "--live-agent"])?.liveAgent, true)
        XCTAssertEqual(LaunchOptions.parse(["Helm", "--live-agent"])?.usesLiveAgent, false)
        XCTAssertEqual(LaunchOptions.parse(["Helm", "--home", "/h", "--live-agent"])?.usesLiveAgent, false)
        XCTAssertEqual(LaunchOptions.parse(["Helm", "--home", "/h", "--support", "/s", "--live-agent"])?.usesLiveAgent, true)
        XCTAssertEqual(LaunchOptions.parse(["Helm"])?.liveAgent, false)
    }

    func testAIJsonIsLoadedAndSavedWithTheOtherDocuments() async throws {
        let app = await composedApp()
        let environment = try XCTUnwrap(app.environment)
        environment.aiConfig.update { $0.provider = "claude"; $0.models["claude"] = "claude-opus-5-5" }
        let failures = await environment.flushStores()
        XCTAssertEqual(failures, [])
        let file = root.appendingPathComponent("support/ai.json")
        let text = try String(contentsOfFile: file.path, encoding: .utf8)
        XCTAssertTrue(text.contains("claude-opus-5-5"))

        let directories = AppDirectories(home: root.appendingPathComponent("home", isDirectory: true),
                                         applicationSupport: root.appendingPathComponent("support", isDirectory: true))
        let reloaded = try await AppEnvironment.live(directories: directories, settingsStorage: IsolatedSettings(),
                                                     legacyReader: NoLegacyDefaults(), trash: { _ in nil })
        XCTAssertEqual(reloaded.aiConfig.config.provider, "claude")
        XCTAssertEqual(reloaded.aiConfig.config.models["claude"], "claude-opus-5-5")
        XCTAssertEqual(reloaded.loadFailures, [])
    }

    func testTheFixtureTrashRefusesWhereAScriptSaysThereIsNone() async throws {
        let app = await composedApp()
        let environment = try XCTUnwrap(app.environment)
        let share = root.appendingPathComponent("home/Share", isDirectory: true)
        let beside = root.appendingPathComponent("home/Share 2", isDirectory: true)
        for folder in [share, beside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let inside = share.appendingPathComponent("a.txt"), other = beside.appendingPathComponent("b.txt")
        for file in [inside, other] { FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)) }
        app.fixtureTrashRules.refuse(under: share.path)
        do {
            _ = try await environment.fileSystem.trashItem(at: inside)
            XCTFail("the Trash took an item from a place with none")
        } catch {
            XCTAssertEqual(FileSystemError.mapping(error), .unsupported)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path), "nothing moved")
        let trashed = try await environment.fileSystem.trashItem(at: other)
        XCTAssertNotNil(trashed, "a folder whose name only starts the same still has its Trash")
        app.fixtureTrashRules.clear()
        let nowTrashed = try await environment.fileSystem.trashItem(at: inside)
        XCTAssertNotNil(nowTrashed)
    }

    func testFixtureTrashRulesCompareFolderByFolder() {
        let rules = FixtureTrashRules()
        XCTAssertFalse(rules.refuses("/home/helm/Share/a.txt"))
        rules.refuse(under: "/home/helm/Share")
        XCTAssertTrue(rules.refuses("/home/helm/Share/a.txt"))
        XCTAssertTrue(rules.refuses("/home/helm/Share/Deep/b.txt"))
        XCTAssertTrue(rules.refuses("/home/helm/Share"))
        XCTAssertTrue(rules.refuses("/home/helm/Share/../Share/a.txt"))
        XCTAssertFalse(rules.refuses("/home/helm/Share 2/a.txt"))
        XCTAssertFalse(rules.refuses("/home/helm/Sha"))
        XCTAssertFalse(rules.refuses("/home/helm/Other/a.txt"))
        rules.clear()
        XCTAssertFalse(rules.refuses("/home/helm/Share/a.txt"))
    }

    func testSettingsHasAnAITabAfterGeneral() async throws {
        let app = await composedApp()
        app.makeSettingsWindowIfNeeded()
        let settings = try XCTUnwrap(app.settingsControllerForTesting)
        settings.select(.ai)
        XCTAssertEqual(settings.selectedPane, .ai)
        let tabs = try XCTUnwrap(settings.window?.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["General", "AI", "View", "Appearance", "Sidebar", "Search", "Advanced"])
        let image = try XCTUnwrap(tabs.tabViewItems[1].image, "the AI tab draws the spark")
        XCTAssertTrue(image.isTemplate)
        settings.close()
    }

    // MARK: A window on an in-memory home

    private func window(agent: AgentServices? = nil) async throws -> (BrowserWindowController, InMemoryFileSystem) {
        let env = try await AppEnvironment.test(home: home)
        let memory = try XCTUnwrap(env.fileSystem as? InMemoryFileSystem)
        try await memory.createDirectory(at: documents)
        for name in ["notes.txt", "plan.txt"] {
            try await memory.createFileExclusively(at: documents.appendingPathComponent(name), contents: Data(name.utf8))
        }
        let operations = OperationCoordinator(fileSystem: env.fileSystem, origins: env.trashOrigins, journal: env.journal)
        let volumes = VolumeCenter(isLive: false, home: env.directories.home) { false }
        let dependencies = WindowDependencies(settings: env.settings, bookmarks: env.bookmarks, stars: env.stars,
            recents: env.recents, trashOrigins: env.trashOrigins, viewOptions: env.viewOptions, fileSystem: env.fileSystem,
            operations: operations, home: env.directories.home, volumes: volumes, icons: IconCache(limit: 50, previewLimit: 10),
            clock: env.clock, pasteboard: NSPasteboard(name: .init("helm.agent-hooks.\(UUID().uuidString)")),
            persistsWindowFrames: false, openWith: env.openWith, agent: agent)
        dependencies.settings.set(.bool(false), for: .askOnConflict)
        let host = AgentHooksHost()
        let controller = BrowserWindowController(dependencies: dependencies, host: host, frameName: "agent-hooks", seeds: [], activeIndex: 0)
        keep += [host, operations, volumes]
        controllers.append(controller)
        controller.messageObserver = { [weak self] in self?.messages.append($0) }
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

    func testAWindowBuiltWithoutTheAppGetsStandInsWithAIModeOff() async throws {
        let (controller, _) = try await window()
        let agent = controller.dependencies.agent
        XCTAssertFalse(agent.runtime.isOn)
        XCTAssertTrue(agent.connector is MemoryServerConnector)
        XCTAssertEqual(agent.config.config, AIConfig())
        XCTAssertFalse(controller.isAgentPanelOpen)
        XCTAssertEqual(controller.agentPanelHost.frame.width, 0, "the panel's column takes no room")
        XCTAssertNil(controller.agentPanelModelForTesting)
    }

    func testConnectToServerGoesThroughTheConnector() async throws {
        let (controller, _) = try await window()
        let connector = try XCTUnwrap(controller.dependencies.agent.connector as? MemoryServerConnector)
        let address = try XCTUnwrap(URL(string: "smb://nas.local/Media"))
        controller.connect(to: address)
        XCTAssertEqual(connector.opened, [address], "the address reached the connector, and nothing was opened")
        let location = try XCTUnwrap(ServerLocation("afp://mac.local/Files"))
        XCTAssertTrue(controller.connectAgentServer(location))
        XCTAssertEqual(connector.opened, [address, location.url])
        connector.answer = false
        XCTAssertFalse(controller.connectAgentServer(location))
    }

    func testTheSparkAndTheMenuRowAskForTheAIModeScreenWhileAIModeIsOff() async throws {
        let (controller, _) = try await window()
        let host = try XCTUnwrap(controller.host as? AgentHooksHost)
        controller.clickSparkForTesting()
        controller.perform(.aiPanel)
        XCTAssertEqual(host.aiScreenRequests, 2)
        XCTAssertFalse(controller.isAgentPanelOpen)
        XCTAssertEqual(controller.title(of: .aiPanel).0, AgentText.menuShowPanel)
        XCTAssertTrue(controller.title(of: .aiPanel).1)
        XCTAssertNotEqual(controller.focusOwnerForTesting, "assistant")
    }

    /// Something in the panel's column with the keys: the file commands are off, as Return, Space and Delete are the
    /// panel's, and the window says the assistant has the keys. Back on the files, both are as before.
    func testWhileThePanelHoldsTheKeysTheFileCommandsAreOff() async throws {
        let (controller, _) = try await window()
        let window = try XCTUnwrap(controller.window)
        let notes = try XCTUnwrap(controller.activeTab?.snapshot.sortedEntries.first { $0.name == "notes.txt" })
        controller.store.send(.tab(controller.activeTabID, .setSelection([notes.id], source: .user)))
        controller.focusFilesForTesting()
        XCTAssertEqual(controller.focusOwnerForTesting, "files")
        let fileCommands: [CommandID] = [.open, .trash, .rename, .copy]
        XCTAssertEqual(fileCommands.map { controller.title(of: $0).1 }, [true, true, true, true], "the selection's commands are on")

        // A plain view, not a text field, so it's the panel's hold on the keys that turns them off.
        let inside = AgentHooksKeyView()
        controller.agentPanelHost.addSubview(inside)
        XCTAssertTrue(window.makeFirstResponder(inside))
        XCTAssertEqual(controller.focusOwnerForTesting, "assistant")
        XCTAssertEqual(fileCommands.map { controller.title(of: $0).1 }, [false, false, false, false], "the file commands are off")

        controller.focusFilesForTesting()
        XCTAssertEqual(controller.focusOwnerForTesting, "files")
        XCTAssertEqual(fileCommands.map { controller.title(of: $0).1 }, [true, true, true, true], "back on with the files")
        inside.removeFromSuperview()
    }

    func testAnAISearchGoesToTheRunnerWithTodaysSearchAsItsBaseline() async throws {
        HostEffectRunner.spotlightAnswersForTesting = { _ in AsyncStream { $0.yield([]); $0.finish() } }
        let (controller, _) = try await window()
        let runner = AgentHooksSearchRunner()
        controller.effects.aiSearch = runner

        controller.search("notes", usesAI: true)
        let delivered = await until { runner.delivered.contains { $0.contains("notes.txt") } }
        XCTAssertTrue(delivered, "today's search handed its results to the runner")
        XCTAssertEqual(runner.queries.map(\.text), ["notes"])
        XCTAssertEqual(runner.queries.map(\.usesAI), [true])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.activeTab?.search?.isGathering, true, "nothing reached the store but through the runner")
        XCTAssertEqual(controller.activeTab?.snapshot.rootCount, 0)

        // The runner is the one that sends.
        runner.forward()
        let shown = await until { controller.activeTab?.snapshot.sortedEntries.contains { $0.name == "notes.txt" } == true }
        XCTAssertTrue(shown)

        // A plain search runs as it always has, without the runner.
        controller.search("plan")
        let plain = await until { controller.activeTab?.snapshot.sortedEntries.contains { $0.name == "plan.txt" } == true }
        XCTAssertTrue(plain)
        XCTAssertEqual(runner.queries.count, 1)
    }

    func testWithoutARunnerAnAISearchRunsAsToday() async throws {
        HostEffectRunner.spotlightAnswersForTesting = { _ in AsyncStream { $0.yield([]); $0.finish() } }
        let (controller, _) = try await window()
        controller.search("notes", usesAI: true)
        let shown = await until { controller.activeTab?.snapshot.sortedEntries.contains { $0.name == "notes.txt" } == true }
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.activeTab?.search?.query.usesAI, true)
        XCTAssertNil(controller.aiSearchStatusForTesting)
        XCTAssertFalse(controller.statusTextForTesting.isEmpty, "the status bar keeps its usual words")
    }

    func testRunAwaitingShowsNoMessageAndAnswersWhatHappened() async throws {
        let (controller, memory) = try await window()
        let notes = documents.appendingPathComponent("notes.txt")
        let group = HistoryGroup(name: "Organize “Documents”")
        let moved = await controller.enqueueOperationAwaiting { [weak controller] () -> Bool in
            let outcome = await controller?.runAwaiting(.trash(items: [notes]), group: group, resolver: nil, onFailure: nil,
                                                        downloadsOff: true)
            if case .success(let result)? = outcome { return result.error == nil }
            return false
        }
        XCTAssertTrue(moved)
        let gone = await memory.exists(notes)
        XCTAssertFalse(gone)
        // Nothing left to do: the failure is .cancelled, and the window says nothing.
        let missing = documents.appendingPathComponent("gone.txt")
        let outcome = await controller.enqueueOperationAwaiting { [weak controller] () -> String in
            guard let result = await controller?.runAwaiting(.trash(items: [missing]), group: group, resolver: nil,
                                                             onFailure: nil, downloadsOff: false) else { return "none" }
            switch result {
            case .success: return "success"
            case .failure(let failure): return String(describing: failure)
            }
        }
        XCTAssertNotEqual(outcome, "success")
        XCTAssertEqual(messages, [], "a command run for a plan shows no message")
        await controller.refreshHistoryForTesting()
        XCTAssertEqual(controller.title(of: .undo).0, "Undo Organize “Documents”")
        await controller.dependencies.operations.clearStallIfSettled()
    }

    func testTheStandInServicesStartOff() {
        let services = AgentServices.standIn(home: home, clock: SystemHelmClock())
        XCTAssertFalse(services.runtime.isOn)
        XCTAssertNotNil(services.runtime.scriptedClientForTesting)
        XCTAssertEqual(services.runtime.clientBuildCount, 0)
        XCTAssertTrue(services.connector is MemoryServerConnector)
        XCTAssertTrue(services.disk is MemoryAgentDisk)
        XCTAssertEqual(services.config.config, AIConfig())
        services.runtime.setOn(true)
        if case .ready = services.runtime.state {} else { XCTFail("the scripted model is ready once AI mode is on") }
    }
}

@MainActor private final class AgentHooksHost: BrowserWindowHost {
    var aiScreenRequests = 0
    func openWindow(at location: Location, selecting: [URL]) {}
    func windowDidClose(_ controller: BrowserWindowController) {}
    func windowDidBecomeKey(_ controller: BrowserWindowController) {}
    func showSettings() {}
    func showSettings(pane: SettingsPane) {}
    func requestQuitAnyway() {}
    func showAIModeScreen(from window: BrowserWindowController?) { aiScreenRequests += 1 }
}

/// A view that takes the keys and is no kind of text.
private final class AgentHooksKeyView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Records what it's asked and what the baseline hands it, and sends nothing until told to.
@MainActor private final class AgentHooksSearchRunner: AISearchRunning {
    var queries: [SearchQuery] = []
    var delivered: [[String]] = []
    private var latest: [SearchResult] = []
    private var send: (@Sendable (WindowStoreAction) -> Void)?
    private var generation: Generation?
    private var tab: TabID?
    private var baseline: StoreEffectCancellation?

    func run(_ query: SearchQuery, generation: Generation, tab: TabID,
             baseline: @escaping @MainActor (_ deliver: @escaping @Sendable ([SearchResult]) -> Void) -> StoreEffectCancellation,
             send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation {
        queries.append(query)
        self.send = send; self.generation = generation; self.tab = tab
        self.baseline = baseline { [weak self] results in
            Task { @MainActor in
                self?.latest = results
                self?.delivered.append(results.map(\.entry.name))
            }
        }
        return StoreEffectCancellation { [weak self] in self?.baseline?.cancel() }
    }
    func forward() {
        guard let send, let generation, let tab else { return }
        send(.tab(tab, .searchResults(generation, latest)))
    }
}

#endif
