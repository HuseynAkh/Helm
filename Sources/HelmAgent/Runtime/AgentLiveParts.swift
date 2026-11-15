import Foundation
import HelmCore

/// The real pieces behind AI mode, as the app hands them to `AgentRuntimeParts`. This is the one place that makes the
/// transport, so a request can only ever go out through a client the runtime asked for, which it does only while AI
/// mode is on and a provider is chosen.
///
/// A conversation is always the real loop: its folders go through `AgentScope`, its tools through `AgentToolRunner`,
/// and every plan through `AgentPlanValidator` before a card shows it. Which model answers is the runtime's choice,
/// so a fixture run's scripted model goes through exactly the same loop as a provider would.
public enum AgentLiveParts {
    /// The client for one provider and model: that provider's wire over its own transport, with the limits for a
    /// model on this Mac when the provider is local and the limits for one on the internet otherwise. The key store
    /// is read only when a request needs the key, never here.
    ///
    /// OpenAI with a ChatGPT sign-in gets its token from the sign-in, renewed through a transport of its own to
    /// OpenAI's sign-in host, in place of a key.
    public static let makeClient: @Sendable (AgentProviderProfile, String, any AgentSecretStoring) -> any AgentLiveClient = {
        profile, model, secrets in
        var bearer: (any AgentBearerSource)?
        if profile.usesChatGPT, let signIn = try? AgentProviderCatalog.signInProfile() {
            bearer = AgentChatGPTBearer(store: secrets,
                                        transport: HTTPTransport(liveProfile: signIn, secrets: secrets, limits: signInLimits))
        }
        let transport = HTTPTransport(liveProfile: profile, secrets: secrets, limits: limits(for: profile), bearer: bearer)
        return LiveModelClient(profile: profile, model: model, transport: transport)
    }

    /// A ChatGPT sign-in: a transport to OpenAI's sign-in host, and a listener on 127.0.0.1 made for each sign-in.
    public static let makeSignIn: @Sendable (any AgentSecretStoring) -> AgentChatGPTSignIn = { secrets in
        let transport: any AgentSignInTransport = (try? AgentProviderCatalog.signInProfile()).map {
            HTTPTransport(liveProfile: $0, secrets: secrets, limits: signInLimits)
        } ?? AgentNoSignInTransport()
        return AgentChatGPTSignIn(store: secrets, transport: transport, makeListener: { AgentLoopbackListener() })
    }

    /// A sign-in's requests are small, and a code or a refresh token works once, so none is tried again.
    static let signInLimits = AgentTransportLimits(idleSeconds: 60, totalSeconds: 120, lineBytes: 1_000_000,
                                                   responseBytes: 1_000_000, listBytes: 1_000_000, retries: 0)

    /// A new conversation over the runtime's parts.
    public static let makeSession: @Sendable (AgentSessionParts) -> any AgentConversing = { parts in
        AgentSession(parts: parts, validator: AgentPlanValidator())
    }

    /// The transport's limits for a provider: a local model may take minutes to load before its first word.
    static func limits(for profile: AgentProviderProfile) -> AgentTransportLimits {
        profile.isLocal ? .local : .cloud
    }
}

/// The sign-in transport when OpenAI's sign-in address couldn't be read, which only a broken build would see: every
/// request fails as if the host couldn't be reached.
struct AgentNoSignInTransport: AgentSignInTransport {
    func post(_ route: AgentSignInRoute, form: [(String, String)]) async throws -> AgentHTTPReply { throw AgentTransportError.unreachable }
    func get(_ route: AgentSignInRoute) async throws -> AgentHTTPReply { throw AgentTransportError.unreachable }
    func shutdown() async {}
}
