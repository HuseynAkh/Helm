#if os(macOS)
import AppKit
import XCTest
import HelmAgent
import HelmCore
@testable import HelmUI

/// The model menu under the composer: which providers it offers, in what order, with which models ticked, and what
/// choosing a row does. Everything comes from a config value and a stand-in answer about saved keys.
@MainActor final class AgentModelMenuTests: XCTestCase {
    private let claude = "claude|api.anthropic.com:443"
    private let lmStudio = "lmStudio|127.0.0.1:1234", ollama = "ollama|127.0.0.1:11434"

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func menu(_ config: AIConfig, keys: Set<AgentProviderID> = [.claude]) -> AgentModelMenu {
        AgentModelMenu.make(config: config, hasKey: { keys.contains($0.provider) })
    }

    func testEveryConnectedProviderIsOfferedInTheCatalogsOrderWithTheCurrentModelTicked() {
        let config = AIConfig(provider: "lmStudio", models: ["lmStudio": "qwen-9b", "claude": "claude-haiku-5"],
                              modelLists: [lmStudio: ["llama-5-8b", "qwen-9b"], claude: ["claude-opus-5-5", "claude-haiku-5"],
                                           ollama: ["gemma-4"]])
        let offered = menu(config)
        XCTAssertEqual(offered.providers.map(\.name), ["Claude", "Ollama", "LM Studio"])
        XCTAssertEqual(offered.current, AgentModelMenu.Choice(provider: .lmStudio, model: "qwen-9b"))
        XCTAssertEqual(offered.summaryForTesting, "Claude: claude-opus-5-5,claude-haiku-5 | Ollama: gemma-4 | LM Studio: llama-5-8b,*qwen-9b")
        XCTAssertEqual(offered.modelCount, 5)
        XCTAssertTrue(offered.isMenu)
    }

    func testACloudProviderWhoseKeyWentIsLeftOut() {
        let config = AIConfig(provider: "lmStudio", models: ["lmStudio": "qwen-9b"],
                              modelLists: [lmStudio: ["qwen-9b"], claude: ["claude-opus-5-5"], "openAI|api.openai.com:443": ["gpt-6-astra"]])
        XCTAssertEqual(menu(config, keys: []).summaryForTesting, "LM Studio: *qwen-9b")
        XCTAssertFalse(menu(config, keys: []).isMenu, "one model alone stays a plain name")
        XCTAssertEqual(menu(config, keys: [.openAI]).summaryForTesting, "OpenAI: gpt-6-astra | LM Studio: *qwen-9b")
    }

    func testAListIsOnlyOfferedForTheAddressThatGaveIt() {
        // LM Studio moved to another port since its list was kept, and Other to another host.
        let config = AIConfig(provider: "claude", ports: ["lmStudio": 1240], otherAddress: "models.example.org",
                              modelLists: [lmStudio: ["qwen-9b"], "other|models.example.com:443": ["m-1"],
                                           "other|models.example.org:443": ["m-2", "m-3"]])
        let offered = menu(config)
        XCTAssertEqual(offered.summaryForTesting, "Claude: *claude-opus-5-5 | models.example.org: m-2,m-3",
                       "a typed address is named by its host")
    }

    func testEachProviderLeadsWithItsChosenModelSoThereIsAWayBack() {
        // Claude's chosen model isn't in what it listed last; LM Studio, in use, has its own in its list.
        let config = AIConfig(provider: "lmStudio", models: ["lmStudio": "qwen-9b"],
                              modelLists: [lmStudio: ["qwen-9b"], claude: ["claude-haiku-5"]])
        XCTAssertEqual(menu(config).summaryForTesting, "Claude: claude-opus-5-5,claude-haiku-5 | LM Studio: *qwen-9b")
        // A provider with no list isn't offered for its chosen model alone.
        XCTAssertEqual(menu(AIConfig(provider: "lmStudio", models: ["lmStudio": "qwen-9b"], modelLists: [lmStudio: ["qwen-9b"]])).summaryForTesting,
                       "LM Studio: *qwen-9b")
    }

    func testTheModelInUseHasARowEvenWithoutAList() {
        let config = AIConfig(provider: "claude", models: ["claude": "claude-haiku-5"], modelLists: [claude: ["claude-opus-5-5"]])
        XCTAssertEqual(menu(config).summaryForTesting, "Claude: *claude-haiku-5,claude-opus-5-5")
        // With nothing kept, only the model in use: a plain name that opens Settings.
        let alone = menu(AIConfig(provider: "claude"))
        XCTAssertEqual(alone.summaryForTesting, "Claude: *claude-opus-5-5")
        XCTAssertFalse(alone.isMenu)
        XCTAssertEqual(menu(AIConfig()).providers, [], "no provider chosen and nothing kept")
        XCTAssertNil(menu(AIConfig()).current)
    }

    func testNamesNoProviderCouldListAreLeftOutAndRepeatsCountOnce() {
        let config = AIConfig(provider: "ollama", models: ["ollama": "gemma-4"],
                              modelLists: [ollama: ["gemma-4", "gemma-4", "bad name", "", "a\u{202E}b", String(repeating: "x", count: 200), "llama/5"]])
        XCTAssertEqual(menu(config).summaryForTesting, "Ollama: *gemma-4,llama/5")
    }

    // MARK: In the composer

    private func panel(_ offered: AgentModelMenu, chosen: @escaping (AgentModelMenu.Choice) -> Void,
                       settings: @escaping () -> Void = {}) -> (AgentPanelModel, AgentComposerView) {
        var actions = AgentPanelModel.Actions()
        actions.chooseModel = chosen
        actions.openSettings = settings
        let model = AgentPanelModel(session: StandInConversation(), home: "/home/helm",
                                    provider: AgentPanelModel.Provider(name: "LM Studio", destination: "LM Studio on this Mac",
                                                                       model: offered.current?.model ?? ""),
                                    actions: actions)
        model.modelMenuChanged(offered)
        let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 340, height: 80))
        composer.attach(model, dropTarget: AgentPanelHost())
        return (model, composer)
    }

    private func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    func testTheNameBecomesACompactMenuOfEveryModelThenAISettings() async throws {
        let config = AIConfig(provider: "lmStudio", models: ["lmStudio": "qwen-9b"],
                              modelLists: [lmStudio: ["llama-5-8b", "qwen-9b"], claude: ["claude-opus-5-5"]])
        var chosen: [AgentModelMenu.Choice] = []
        var settings = 0
        let (model, composer) = panel(menu(config), chosen: { chosen.append($0) }, settings: { settings += 1 })
        let shown = await until { composer.modelNameIsMenuForTesting }
        XCTAssertTrue(shown, "the name shows it's a menu")
        XCTAssertEqual(composer.modelNameForTesting, "qwen-9b")
        let built = try XCTUnwrap(composer.makeModelMenu())
        let rows = built.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(rows.map(\.title), ["Claude", "claude-opus-5-5", "LM Studio", "llama-5-8b", "qwen-9b", AgentText.modelMenuSettings])
        XCTAssertEqual(rows.filter(\.isSectionHeader).map(\.title), ["Claude", "LM Studio"])
        XCTAssertEqual(rows.filter { $0.state == .on }.map(\.title), ["qwen-9b"], "the model in use is ticked")
        XCTAssertEqual(built.items.last?.title, AgentText.modelMenuSettings)

        XCTAssertTrue(composer.pickModelMenuRowForTesting("claude-opus-5-5"))
        XCTAssertEqual(chosen, [AgentModelMenu.Choice(provider: .claude, model: "claude-opus-5-5")])
        // The model already in use changes nothing.
        XCTAssertTrue(composer.pickModelMenuRowForTesting("qwen-9b", under: "LM Studio"))
        XCTAssertEqual(chosen.count, 1)
        XCTAssertTrue(composer.pickModelMenuRowForTesting(AgentText.modelMenuSettings))
        XCTAssertEqual(settings, 1)
        _ = model
    }

    func testOneModelAloneStaysAPlainNameThatOpensSettings() async throws {
        var settings = 0
        let (model, composer) = panel(menu(AIConfig(provider: "lmStudio", models: ["lmStudio": "qwen-9b"], modelLists: [lmStudio: ["qwen-9b"]])),
                                      chosen: { _ in XCTFail("nothing to choose") }, settings: { settings += 1 })
        XCTAssertFalse(composer.modelNameIsMenuForTesting)
        XCTAssertNil(composer.makeModelMenu())
        composer.pressModelNameForTesting()
        XCTAssertEqual(settings, 1, "pressing the name opens Settings › AI")
        // A second model arrives, as when a check answers: the name turns into the menu.
        model.modelMenuChanged(menu(AIConfig(provider: "lmStudio", models: ["lmStudio": "qwen-9b"], modelLists: [lmStudio: ["qwen-9b", "llama-5-8b"]])))
        let shown = await until { composer.modelNameIsMenuForTesting }
        XCTAssertTrue(shown)
        XCTAssertEqual(model.modelMenuForTesting, "LM Studio: *qwen-9b,llama-5-8b")
    }

    func testModelNamesAreShownEscaped() throws {
        // A name only ever arrives already checked, but the menu draws it as the composer draws the name: escaped.
        let offered = AgentModelMenu(providers: [AgentModelMenu.ProviderModels(provider: .other, name: "models.example.com",
                                                                                 models: ["m-1", "m-2"])],
                                     current: nil)
        let (model, composer) = panel(offered, chosen: { _ in })
        let titles = try XCTUnwrap(composer.makeModelMenu()).items.map(\.title)
        XCTAssertEqual(titles.filter { !$0.isEmpty }, ["models.example.com", "m-1", "m-2", AgentText.modelMenuSettings])
        XCTAssertEqual(model.modelMenuForTesting, "models.example.com: m-1,m-2")
    }
}
#endif
