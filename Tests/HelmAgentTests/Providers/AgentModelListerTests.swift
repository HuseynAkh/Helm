import XCTest
import HelmCore
@testable import HelmAgent

/// Model lists in each provider's own shape: which ids are kept, in which order, and the caps.
final class AgentModelListerTests: XCTestCase {
    private func ids(_ fixture: String, _ provider: AgentProviderID) throws -> [String] {
        try AgentModelLister.models(from: ProviderFixtures.data("models/\(fixture).json"), provider: provider).map(\.id)
    }

    func testClaudeKeepsItsOwnOrderAndDropsARepeat() throws {
        XCTAssertEqual(try ids("claude", .claude), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"])
    }

    func testOpenAIPutsItsChatModelsFirst() throws {
        XCTAssertEqual(try ids("openai", .openAI),
                       ["gpt-6-astra", "gpt-6-luna", "gpt-6.1-sol", "dall-e-4", "text-embedding-4", "whisper-2"])
    }

    func testGrokReadsTheLanguageModelList() throws {
        XCTAssertEqual(try ids("grok", .grok), ["grok-4.7", "grok-4.7-mini"])
    }

    func testGeminiLosesItsPrefixAndModelsThatCantChat() throws {
        XCTAssertEqual(try ids("gemini", .gemini), ["gemini-4-hydrogen", "gemini-4-carbon", "gemini-3.5-flash-lite"])
    }

    func testGeminiCompatibleListIsReadToo() throws {
        let body = Data(#"{"object":"list","data":[{"id":"models/gemini-4-hydrogen","object":"model"}]}"#.utf8)
        XCTAssertEqual(try AgentModelLister.models(from: body, provider: .gemini).map(\.id), ["gemini-4-hydrogen"])
    }

    func testOllamaLeavesOutModelsThatRunOnItsServersAndNamesWithASpace() throws {
        XCTAssertEqual(try ids("ollama", .ollama), ["qwen3:8b", "llama3.2:latest"])
    }

    func testLMStudioLeavesOutEmbeddingModels() throws {
        XCTAssertEqual(try ids("lmstudio", .lmStudio), ["qwen2.5-7b-instruct", "lmstudio-community/llama-3.2-3b-instruct"])
    }

    func testOtherKeepsSlashAndColonIDs() throws {
        XCTAssertEqual(try ids("other", .other), ["anthropic/claude-opus-5-5", "openai/gpt-6-astra", "meta-llama/llama-5:free"])
    }

    func testAListOf600IsCutTo500() throws {
        let entries = (0..<600).map { #"{"id":"model-\#($0)"}"# }.joined(separator: ",")
        let models = try AgentModelLister.models(from: Data(#"{"data":[\#(entries)]}"#.utf8), provider: .other)
        XCTAssertEqual(models.count, 500)
        XCTAssertEqual(models.first?.id, "model-0")
        XCTAssertEqual(models.last?.id, "model-499")
    }

    func testAnIDOf129CharactersOrWithASpaceIsDropped() throws {
        let longest = String(repeating: "a", count: 128), tooLong = String(repeating: "b", count: 129)
        let body = Data(#"{"data":[{"id":"\#(longest)"},{"id":"\#(tooLong)"},{"id":"has space"},{"id":"bad\u0007bell"},{"id":"ok-1"}]}"#.utf8)
        XCTAssertEqual(try AgentModelLister.models(from: body, provider: .other).map(\.id), [longest, "ok-1"])
    }

    func testAReplyThatIsNotAListIsUnreadable() {
        for body in ["<html>Not found</html>", #"{"error":"nope"}"#, "[1,2]"] {
            XCTAssertThrowsError(try AgentModelLister.models(from: Data(body.utf8), provider: .other), body) {
                XCTAssertEqual($0 as? AgentFailure, .unreadable)
            }
        }
    }

    func testTheProvidersOwnModelIsPreselectedWhenListed() throws {
        let claude = try AgentModelLister.models(from: ProviderFixtures.data("models/claude.json"), provider: .claude)
        XCTAssertEqual(AgentModelLister.preselected(claude, provider: .claude), "claude-opus-5-5")
        let openAI = try AgentModelLister.models(from: ProviderFixtures.data("models/openai.json"), provider: .openAI)
        XCTAssertEqual(AgentModelLister.preselected(openAI, provider: .openAI), "gpt-6-astra")
    }

    func testALocalProviderPreselectsTheFirstListedAndATypedAddressNothing() throws {
        let ollama = try AgentModelLister.models(from: ProviderFixtures.data("models/ollama.json"), provider: .ollama)
        XCTAssertEqual(AgentModelLister.preselected(ollama, provider: .ollama), "qwen3:8b")
        let other = try AgentModelLister.models(from: ProviderFixtures.data("models/other.json"), provider: .other)
        XCTAssertNil(AgentModelLister.preselected(other, provider: .other))
        XCTAssertNil(AgentModelLister.preselected([], provider: .lmStudio))
    }
}
