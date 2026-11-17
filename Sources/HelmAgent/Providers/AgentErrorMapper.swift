import Foundation
import HelmCore

/// Turns what went wrong into one of the fixed `AgentFailure` cases. A provider's error body is read only for the
/// codes and fixed phrases below, never kept and never shown: the person sees Helm's own line for the case.
public enum AgentErrorMapper {
    /// A reply whose status wasn't a success, from the provider `provider`.
    public static func failure(status: Int, body: Data, provider: AgentProviderID) -> AgentFailure {
        let words = AgentErrorWords(body: body)
        // Gemini also answers 400 when a project needs billing before it can be used.
        if provider == .gemini, status == 400, words.hasToken("failed_precondition") { return .outOfCredit }
        return failure(status: status, words: words)
    }

    /// A request that failed before a reply could be read.
    public static func failure(_ error: AgentTransportError, provider: AgentProviderID) -> AgentFailure {
        let isLocal = provider == .ollama || provider == .lmStudio
        switch error {
        case .http(let status, let body): return failure(status: status, body: body, provider: provider)
        // A local server that refuses the connection isn't running. Nothing else is listening on its port.
        case .notRunning: return isLocal ? .notRunning : .unreachable
        case .unreachable: return isLocal ? .notRunning : .unreachable
        // A proxy that wants a password is a network that can't reach the provider, as far as the person can act.
        case .proxyAuth, .redirected, .wrongHost, .insecure: return .unreachable
        case .timedOut: return .timedOut
        case .tooLarge, .keyInBody: return .unreadable
        case .cancelled: return .cancelled
        case .noKey: return .noKey
        case .keyDenied: return .keyDenied
        }
    }

    /// Anything a request threw, as one case: an `AgentFailure` stays as it is, a transport error is mapped, and a
    /// stopped task is `cancelled`.
    static func failure(of error: Error, provider: AgentProviderID) -> AgentFailure {
        if let failure = error as? AgentFailure { return failure }
        if let transport = error as? AgentTransportError { return failure(transport, provider: provider) }
        if error is CancellationError { return .cancelled }
        return .unreachable
    }

    /// A reply whose status wasn't a success, where only the shape of the wire is known.
    static func failure(status: Int, body: Data) -> AgentFailure {
        let words = AgentErrorWords(body: body)
        // Gemini's billing answer reads the same here as it does when the provider is known.
        if status == 400, words.hasToken("failed_precondition") { return .outOfCredit }
        return failure(status: status, words: words)
    }

    /// An error that arrived inside a stream after the reply had started: Claude's `error` event, a Responses
    /// `error` event or failed response, or a Chat Completions chunk with an `error` member. It is mapped as the
    /// reply of the same kind would have been. One that names nothing Helm knows is a provider that is struggling.
    static func failure(streamError value: AgentJSON) -> AgentFailure {
        let error = value["error"].flatMap { $0.objectValue == nil ? nil : $0 } ?? value
        let body = error.data()
        if let code = AgentWireParts.integer(error["code"] ?? error["status"]), (400...599).contains(code) {
            return failure(status: code, body: body)
        }
        let words = AgentErrorWords(body: body)
        for (token, status) in streamStatuses where words.hasToken(token) { return failure(status: status, words: words) }
        if words.hasAny([], noPicturePhrases) { return .badRequest }
        return .overloaded
    }

    // MARK: A ChatGPT plan

    /// A reply from OpenAI to a request billed to the person's ChatGPT plan. The plan's own codes come first: its
    /// usage limit is `outOfCredit`, a plan that can't check its usage now is `overloaded`, a request the plan doesn't
    /// cover (an account, workspace or policy that can't use it, a route or a feature it doesn't take) is
    /// `noSuchModel`, and a sign-in OpenAI couldn't verify is `noKey`, which asks the person to sign in again. The
    /// panel names the plan for each, through the provider name "ChatGPT".
    public static func chatGPTFailure(status: Int, body: Data) -> AgentFailure {
        let words = AgentErrorWords(body: body)
        if let failure = chatGPTCode(words) { return failure }
        switch status {
        case 401: return .noKey
        case 403, 404: return .noSuchModel
        default: return failure(status: status, body: body, provider: .openAI)
        }
    }

    /// Anything a request billed to a ChatGPT plan threw, as one case.
    static func chatGPTFailure(of error: Error) -> AgentFailure {
        if case .http(let status, let body)? = error as? AgentTransportError { return chatGPTFailure(status: status, body: body) }
        return failure(of: error, provider: .openAI)
    }

    /// An error inside the stream of a request billed to a ChatGPT plan, such as a usage limit reached as the answer
    /// began.
    static func chatGPTFailure(streamError value: AgentJSON) -> AgentFailure {
        let error = value["error"].flatMap { $0.objectValue == nil ? nil : $0 } ?? value
        return chatGPTCode(AgentErrorWords(body: error.data())) ?? failure(streamError: value)
    }

    /// The plan's codes, from OpenAI's errors-and-recovery guide for ChatGPT plan use.
    private static func chatGPTCode(_ words: AgentErrorWords) -> AgentFailure? {
        if words.hasToken("subscription_sharing_usage_limit_exceeded") { return .outOfCredit }
        if words.hasAny(["subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable"], []) {
            return .overloaded
        }
        if words.hasToken("subscription_sharing_invalid_user") { return .noKey }
        if words.hasAny(["subscription_sharing_user_not_eligible", "subscription_sharing_route_not_supported",
                         "subscription_sharing_unsupported_capability", "chatpass_v2_scope_not_authorized",
                         "chatpass_v2_invalid_authorization_context"], []) {
            return .noSuchModel
        }
        return nil
    }

    // MARK: Statuses

    /// The status each error code or type stands for, when an error arrives without one. A code says more than a
    /// type, so the codes come first.
    private static let streamStatuses: [(String, Int)] = [
        ("context_length_exceeded", 400), ("invalid_api_key", 401), ("model_not_found", 404), ("insufficient_quota", 429),
        ("rate_limit_exceeded", 429), ("server_is_overloaded", 503),
        ("invalid_request_error", 400), ("authentication_error", 401), ("billing_error", 402), ("permission_error", 403),
        ("not_found_error", 404), ("request_too_large", 413), ("rate_limit_error", 429), ("api_error", 500),
        ("server_error", 500), ("timeout_error", 504), ("overloaded_error", 529)
    ]

    /// Codes that mean the account can't pay for more, whatever status they come with. Retrying won't help.
    private static let creditTokens: Set<String> = [
        "enforced_spend_limit_reached", "credit_balance_exhausted", "organization_spend_limit_exceeded",
        "project_spend_limit_exceeded", "organization_usage_limit_exceeded", "insufficient_quota", "billing_error"
    ]
    private static let creditPhrases = ["spend limit", "credit balance"]
    /// Google's answer to a key it doesn't know, which comes with status 400.
    private static let badKeyTokens: Set<String> = ["api_key_invalid"]
    private static let badKeyPhrases = ["api key not valid"]
    /// A local model that has no way to call tools.
    private static let noToolPhrases = ["does not support tools", "does not support tool", "tools are not supported",
                                        "tool calling is not supported", "tool use is not supported",
                                        "function calling is not supported"]
    /// A model that can't take pictures, as the servers that say so word it: Ollama answers status 500 with the
    /// first phrase, LM Studio with "Model does not support images", OpenAI with a 400 that says image input "is only
    /// supported by certain models". Each is a request the model can't take, which Helm sends again without pictures.
    private static let noPicturePhrases = ["missing data required for image input", "does not support image",
                                           "doesn't support image", "do not support image", "does not support vision",
                                           "image input is not supported", "image inputs are not supported",
                                           "images are not supported", "vision is not supported",
                                           "is only supported by certain models"]
    private static let tooLargeTokens: Set<String> = ["context_length_exceeded", "request_too_large"]
    private static let tooLargePhrases = ["prompt is too long", "maximum context length", "context window"]

    private static func failure(status: Int, words: AgentErrorWords) -> AgentFailure {
        if words.hasAny(creditTokens, creditPhrases), status == 400 || status == 402 || status == 403 || status == 429 {
            return .outOfCredit
        }
        switch status {
        case 400:
            if words.hasAny(badKeyTokens, badKeyPhrases) { return .wrongKey }
            if words.hasAny([], noToolPhrases) { return .noTools }
            if words.hasAny([], noPicturePhrases) { return .badRequest }
            if words.hasAny(tooLargeTokens, tooLargePhrases) { return .tooLarge }
            return .badRequest
        case 401, 403: return .wrongKey
        case 402: return .outOfCredit
        case 404: return .noSuchModel
        case 408, 504: return .timedOut
        case 413: return .tooLarge
        case 429: return .rateLimited
        case 500...599: return words.hasAny([], noPicturePhrases) ? .badRequest : .overloaded
        case 405...499: return .badRequest
        default: return .unreadable
        }
    }
}

/// The words of an error body, lower-cased: every string in it, whole as tokens and joined as one text for phrases.
/// A body that isn't JSON is taken as text. Only the start of a body is read.
struct AgentErrorWords {
    private static let bodyBytes = 16_384
    private static let mostStrings = 200

    private(set) var tokens: Set<String> = []
    private(set) var text = ""

    init(body: Data) {
        let head = body.prefix(Self.bodyBytes)
        if let value = try? AgentJSON(data: head) {
            var strings: [String] = []
            Self.collect(value, into: &strings)
            tokens = Set(strings.map { $0.lowercased() })
            text = strings.joined(separator: "\n").lowercased()
        } else {
            text = String(decoding: head, as: UTF8.self).lowercased()
        }
    }

    func hasToken(_ token: String) -> Bool { tokens.contains(token) }

    func hasAny(_ tokens: Set<String>, _ phrases: [String]) -> Bool {
        !self.tokens.isDisjoint(with: tokens) || phrases.contains { text.contains($0) }
    }

    private static func collect(_ value: AgentJSON, into strings: inout [String]) {
        guard strings.count < mostStrings else { return }
        switch value {
        case .string(let text): strings.append(text)
        case .array(let values): for member in values { collect(member, into: &strings) }
        case .object(let members): for key in members.keys.sorted() { if let member = members[key] { collect(member, into: &strings) } }
        case .null, .bool, .number: break
        }
    }
}
