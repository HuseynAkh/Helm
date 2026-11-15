import Foundation

/// The official pages that say how to connect each provider, opened in the person's browser from the help beside the
/// provider menu, and ChatGPT's usage page. They are pages for the browser: Helm itself never fetches one, and its
/// transport can't reach them. The privacy checks list each address, so another can't arrive unseen.
public enum AgentHelpLinks {
    static let chatGPTPlan = "https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites"
    static let chatGPTUsage = "https://chatgpt.com/settings/usage"
    static let openAIKey = "https://developers.openai.com/api/docs/quickstart"
    static let claudeKey = "https://platform.claude.com/docs/en/manage-claude/authentication#api-keys"
    static let geminiKey = "https://aistudio.google.com/docs/api-key"
    static let grokKey = "https://docs.x.ai/docs/quickstart"
    static let ollamaStart = "https://docs.ollama.com/quickstart"
    static let lmStudioServer = "https://lmstudio.ai/docs/developer/core/server"

    /// The page on connecting `provider`: ChatGPT's help on using a plan in other apps, or the provider's page on
    /// making a key or starting its local server. Nil for Other, which has no page of its own.
    public static func howToConnect(_ provider: AgentProviderID, usesChatGPT: Bool) -> URL? {
        switch provider {
        case .claude: return URL(string: claudeKey)
        case .openAI: return URL(string: usesChatGPT ? chatGPTPlan : openAIKey)
        case .gemini: return URL(string: geminiKey)
        case .grok: return URL(string: grokKey)
        case .ollama: return URL(string: ollamaStart)
        case .lmStudio: return URL(string: lmStudioServer)
        case .other: return nil
        }
    }

    /// ChatGPT's usage settings, where the person sees and limits what Helm uses of their plan.
    public static var manageUsage: URL? { URL(string: chatGPTUsage) }

    /// Every address here, for the checks that hold the app to its list.
    static let all = [chatGPTPlan, chatGPTUsage, openAIKey, claudeKey, geminiKey, grokKey, ollamaStart, lmStudioServer]
}
