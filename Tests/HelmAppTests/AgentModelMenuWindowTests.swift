#if os(macOS)
import AppKit
import XCTest
import HelmAgent
import HelmCore
import HelmPersistence
@testable import HelmApp
@testable import HelmUI

/// The model menu under the composer in a whole app on a throwaway home, wired as a launch wires it, with the scripted
/// model standing in for every provider: what checks keep for it, what it offers, and what choosing from it changes.
@MainActor final class AgentModelMenuWindowTests: XCTestCase {
    private var root: URL!
    private var app: AppController?
    private let claude = "claude|api.anthropic.com:443", lmStudio = "lmStudio|127.0.0.1:1234"

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        HeaderMotion.isDisabledForTesting = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("model-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/Documents", isDirectory: true),
                                                withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for window in app?.allWindows ?? [] { window.window?.close() }
        app = nil
        HeaderMotion.isDisabledForTesting = false
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func composedApp() async throws -> (AppController, AgentServices) {
        var options = LaunchOptions()
        options.home = root.appendingPathComponent("home", isDirectory: true)
        options.support = root.appendingPathComponent("support", isDirectory: true)
        let app = AppController(options: options)
        app.staysInBackground = true
        self.app = app
        await app.compose()
        let services = try XCTUnwrap(app.agentServicesForTesting)
        app.setting(.aiModeEnabled, to: true)
        return (app, services)
    }

    private func until(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    func testChecksKeepTheirListsAndAFailedCheckTakesItAway() async throws {
        let (_, services) = try await composedApp()
        _ = await services.runtime.check(AIConfig(provider: "lmStudio"))
        XCTAssertEqual(services.config.config.modelLists[lmStudio], ["scripted-1"])
        let scripted = try XCTUnwrap(services.runtime.scriptedClientForTesting)
        scripted.modelsFailure = .notRunning
        _ = await services.runtime.check(AIConfig(provider: "lmStudio"))
        XCTAssertNil(services.config.config.modelLists[lmStudio])
        scripted.modelsFailure = nil
    }

    func testChoosingAnotherProvidersModelSwitchesTheNextRequestAndStartsANewThread() async throws {
        let (app, services) = try await composedApp()
        try services.secrets.save(try XCTUnwrap(AgentSecret(pasted: "stand-in-for-tests")),
                                  for: AgentSecretID(provider: .claude, host: "api.anthropic.com", port: 443))
        _ = await services.runtime.check(AIConfig(provider: "claude"))
        _ = await services.runtime.check(AIConfig(provider: "lmStudio"))
        services.config.update { $0.provider = "claude" }
        let window = try XCTUnwrap(app.frontmost())
        window.toggleAgentPanel()
        XCTAssertTrue(window.isAgentPanelOpen)
        let model = try XCTUnwrap(window.agentPanelModelForTesting)
        let offered = await until { model.modelMenuForTesting == "Claude: *claude-opus-5-5,scripted-1 | LM Studio: scripted-1" }
        XCTAssertTrue(offered, model.modelMenuForTesting)
        let named = await until { window.agentModelNameForTesting == "claude-opus-5-5 menu" }
        XCTAssertTrue(named, window.agentModelNameForTesting)
        XCTAssertEqual(window.agentModelMenuTitlesForTesting,
                       ["Claude", "claude-opus-5-5", "scripted-1", "LM Studio", "scripted-1", AgentText.modelMenuSettings])

        // Another model of the same provider: the thread stays.
        XCTAssertTrue(window.pickAgentModelMenuRowForTesting("scripted-1", under: "Claude"))
        XCTAssertEqual(services.config.config.provider, "claude")
        XCTAssertEqual(services.config.config.models["claude"], "scripted-1")
        let renamed = await until { window.agentModelNameForTesting == "scripted-1 menu" }
        XCTAssertTrue(renamed, window.agentModelNameForTesting)
        XCTAssertFalse(model.threadTextForTesting.contains(AgentText.noticeStartedOver))

        // Another provider: requests go there from the next one, and the thread starts over.
        XCTAssertTrue(window.pickAgentModelMenuRowForTesting("scripted-1", under: "LM Studio"))
        XCTAssertEqual(services.config.config.provider, "lmStudio")
        XCTAssertEqual(services.config.config.models["lmStudio"], "scripted-1")
        XCTAssertEqual(services.runtime.config.provider, "lmStudio", "the runtime follows at once")
        let startedOver = await until { model.threadTextForTesting.contains(AgentText.noticeStartedOver) }
        XCTAssertTrue(startedOver, model.threadTextForTesting)
        let ticked = await until { model.modelMenuForTesting == "Claude: scripted-1 | LM Studio: *scripted-1" }
        XCTAssertTrue(ticked, model.modelMenuForTesting)
        XCTAssertTrue(window.isAgentPanelOpen, "the panel stays open")
        XCTAssertTrue(window.agentPanelModelForTesting === model, "with the same panel")
    }

    func testOpeningThePanelAsksLocalProvidersForWhatTheyHaveNowAndNoCloudProvider() async throws {
        let (app, services) = try await composedApp()
        services.config.update {
            $0.provider = "lmStudio"
            $0.models["lmStudio"] = "old-model"
            $0.modelLists = [self.lmStudio: ["old-model", "gone-model"], self.claude: ["claude-opus-5-5", "claude-haiku-5"]]
        }
        let scripted = try XCTUnwrap(services.runtime.scriptedClientForTesting)
        let asked = scripted.sentTurns.count
        let window = try XCTUnwrap(app.frontmost())
        window.toggleAgentPanel()
        let model = try XCTUnwrap(window.agentPanelModelForTesting)
        // LM Studio's server now lists only what the scripted model has; the model in use keeps its row.
        let fresh = await until { services.config.config.modelLists[self.lmStudio] == ["scripted-1"] }
        XCTAssertTrue(fresh, "\(services.config.config.modelLists)")
        let offered = await until { model.modelMenuForTesting == "LM Studio: *old-model,scripted-1" }
        XCTAssertTrue(offered, model.modelMenuForTesting)
        XCTAssertEqual(services.config.config.modelLists[claude], ["claude-opus-5-5", "claude-haiku-5"],
                       "a cloud provider's list stands, and with no key saved it isn't offered")
        XCTAssertEqual(scripted.sentTurns.count, asked, "no request went to a model")
        XCTAssertEqual(services.runtime.clientBuildCount, 0)
    }
}
#endif
