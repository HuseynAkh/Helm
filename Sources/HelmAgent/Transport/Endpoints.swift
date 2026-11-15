import Foundation
import HelmCore

/// What is fixed about each provider: its name, the shapes it speaks, where it is and which paths Helm asks for.
/// The five addresses below are the only web addresses Helm connects to: the four providers with a fixed address, and
/// OpenAI's sign-in host for a ChatGPT sign-in. The privacy checks list them one by one, so another can't arrive
/// unseen. The help pages a person may open in their browser are listed apart, in `AgentHelpLinks`.
public enum AgentProviderCatalog {
    static let claudeBase = "https://api.anthropic.com"
    static let openAIBase = "https://api.openai.com/v1"
    static let geminiBase = "https://generativelanguage.googleapis.com/v1beta"
    static let grokBase = "https://api.x.ai/v1"
    static let openAISignInBase = "https://auth.openai.com"

    /// OpenAI's name for its plan, which Helm uses for OpenAI reached with a ChatGPT sign-in.
    public static let chatGPTName = "ChatGPT"

    /// The only scheme a typed or fixed address may have.
    static let secureScheme = "https"
    /// This Mac, by number, so no name has to be looked up to reach a local model server.
    static let loopbackHost = "127.0.0.1"
    /// The version of Claude's API that requests are written for.
    static let claudeVersion = "2026-10-21"

    /// The address of a provider that has one of its own. Nil for a local provider and for a typed one.
    static func fixedBase(_ id: AgentProviderID) -> String? {
        switch id {
        case .claude: return claudeBase
        case .openAI: return openAIBase
        case .gemini: return geminiBase
        case .grok: return grokBase
        case .ollama, .lmStudio, .other: return nil
        }
    }

    /// The provider's name, as the provider menu lists it.
    public static func name(_ id: AgentProviderID) -> String {
        switch id {
        case .claude: return "Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .other: return "Other"
        }
    }

    public static func wire(_ id: AgentProviderID) -> AgentWire {
        switch id {
        case .claude: return .anthropicMessages
        case .openAI, .grok: return .openAIResponses
        case .gemini, .ollama, .lmStudio, .other: return .chatCompletions
        }
    }

    /// The model picked for the person until they pick one. A local provider and a typed one have none: theirs is
    /// whatever the server lists.
    public static func defaultModel(_ id: AgentProviderID) -> String? {
        switch id {
        case .claude: return "claude-opus-5-5"
        case .openAI: return "gpt-6-astra"
        case .gemini: return "gemini-4-hydrogen"
        case .grok: return "grok-4.7"
        case .ollama, .lmStudio, .other: return nil
        }
    }

    /// The port a local model server listens on unless the person changed it.
    public static func defaultPort(_ id: AgentProviderID) -> Int? {
        switch id {
        case .ollama: return 11434
        case .lmStudio: return 1234
        case .claude, .openAI, .gemini, .grok, .other: return nil
        }
    }

    /// The provider `config` chooses and where it is reached. A config with no provider, or with one this build
    /// doesn't know, has no address.
    public static func profile(for config: AIConfig) -> Result<AgentProviderProfile, AgentEndpointRefusal> {
        guard let id = config.provider.flatMap(AgentProviderID.init(rawValue:)) else { return .failure(.notAnAddress) }
        do {
            let endpoint: AgentEndpoint
            switch id {
            case .openAI:
                return .success(AgentProviderProfile(id: id, endpoint: try AgentEndpoint(fixed: id),
                                                     usesChatGPT: !config.openAIUsesKey))
            case .claude, .gemini, .grok:
                endpoint = try AgentEndpoint(fixed: id)
            case .ollama, .lmStudio:
                guard let port = config.ports[id.rawValue] ?? defaultPort(id) else { return .failure(.badPort) }
                endpoint = try AgentEndpoint(localPort: port)
            case .other:
                guard let address = config.otherAddress else { return .failure(.notAnAddress) }
                endpoint = try AgentEndpoint(typed: address)
            }
            return .success(AgentProviderProfile(id: id, endpoint: endpoint))
        } catch let refusal as AgentEndpointRefusal {
            return .failure(refusal)
        } catch {
            return .failure(.notAnAddress)
        }
    }

    /// The method, path, fixed query and key header of one request. Nil where a provider has no such request.
    /// A bearer route of a provider that needs no key is sent without the header when no key is saved.
    public static func route(_ route: AgentRoute, for profile: AgentProviderProfile) -> AgentRouteSpec? {
        switch (profile.id, route) {
        case (.claude, .chat): return AgentRouteSpec(method: "POST", path: "/v1/messages", auth: .xAPIKey)
        case (.claude, .models): return AgentRouteSpec(method: "GET", path: "/v1/models", query: ["limit": "1000"], auth: .xAPIKey)
        case (.openAI, .chat), (.grok, .chat): return AgentRouteSpec(method: "POST", path: "/responses", auth: .bearer)
        case (.openAI, .models): return AgentRouteSpec(method: "GET", path: "/models", auth: .bearer)
        case (.grok, .models): return AgentRouteSpec(method: "GET", path: "/language-models", auth: .bearer)
        case (.gemini, .chat): return AgentRouteSpec(method: "POST", path: "/openai/chat/completions", auth: .bearer)
        case (.gemini, .models): return AgentRouteSpec(method: "GET", path: "/models", query: ["pageSize": "1000"], auth: .googAPIKey)
        case (.ollama, .chat): return AgentRouteSpec(method: "POST", path: "/v1/chat/completions", auth: AgentAuthStyle.none)
        case (.ollama, .models): return AgentRouteSpec(method: "GET", path: "/api/tags", auth: AgentAuthStyle.none)
        case (.lmStudio, .chat): return AgentRouteSpec(method: "POST", path: "/v1/chat/completions", auth: .bearer)
        case (.lmStudio, .models): return AgentRouteSpec(method: "GET", path: "/v1/models", auth: .bearer)
        case (.other, .chat): return AgentRouteSpec(method: "POST", path: "/chat/completions", auth: .bearer)
        case (.other, .models): return AgentRouteSpec(method: "GET", path: "/models", auth: .bearer)
        case (.other, .modelsAlternate): return AgentRouteSpec(method: "GET", path: "/v1/models", auth: .bearer)
        case (.claude, .modelsAlternate), (.openAI, .modelsAlternate), (.grok, .modelsAlternate), (.gemini, .modelsAlternate),
             (.ollama, .modelsAlternate), (.lmStudio, .modelsAlternate):
            return nil
        }
    }

    // MARK: The sign-in host

    /// The paths of a ChatGPT sign-in on OpenAI's sign-in host.
    static let authorizePath = "/api/accounts/authorize"
    static let tokenPath = "/api/accounts/oauth/token"
    static let signingKeysPath = "/.well-known/jwks.json"
    static let discoveryPath = "/.well-known/openid-configuration"
    /// The longest revocation path taken from the discovery document.
    static let longestRevokePath = 256

    /// The profile a sign-in transport is made for: OpenAI, at its sign-in host.
    public static func signInProfile() throws -> AgentProviderProfile {
        AgentProviderProfile(id: .openAI, endpoint: try AgentEndpoint.openAISignIn())
    }

    /// The method and path of a sign-in request. Nil for a revocation path that isn't plain: one that doesn't start
    /// with a slash, climbs, has an empty part or a character other than letters, digits, `.`, `_` and `-`.
    static func route(_ route: AgentSignInRoute) -> AgentRouteSpec? {
        switch route {
        case .token: return AgentRouteSpec(method: "POST", path: tokenPath, auth: .none)
        case .keys: return AgentRouteSpec(method: "GET", path: signingKeysPath, auth: .none)
        case .discovery: return AgentRouteSpec(method: "GET", path: discoveryPath, auth: .none)
        case .revoke(let path):
            guard isPlainPath(path) else { return nil }
            return AgentRouteSpec(method: "POST", path: path, auth: .none)
        }
    }

    static func isPlainPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= longestRevokePath else { return false }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                    || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0) }
        }
    }

    /// Headers a provider wants on every request, apart from its key.
    public static func fixedHeaders(for profile: AgentProviderProfile) -> [String: String] {
        profile.id == .claude ? ["anthropic-version": claudeVersion] : [:]
    }

    /// The model `config` chooses: the one saved for its provider, else that provider's preselected one. Nil with no
    /// provider, with none chosen for a provider that preselects nothing, and for a name no provider could have listed.
    public static func model(for config: AIConfig) -> String? {
        guard let id = config.provider.flatMap(AgentProviderID.init(rawValue:)),
              let model = config.models[id.rawValue] ?? defaultModel(id) else { return nil }
        return AgentModelInfo(id: model)?.id
    }
}
