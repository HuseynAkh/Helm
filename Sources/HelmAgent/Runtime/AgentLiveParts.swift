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
    public static let makeClient: @Sendable (AgentProviderProfile, String, any AgentSecretStoring) -> any AgentLiveClient = {
        profile, model, secrets in
        let transport = HTTPTransport(liveProfile: profile, secrets: secrets, limits: limits(for: profile))
        return LiveModelClient(profile: profile, model: model, transport: transport)
    }

    /// A new conversation over the runtime's parts.
    public static let makeSession: @Sendable (AgentSessionParts) -> any AgentConversing = { parts in
        AgentSession(parts: parts, validator: AgentPlanValidator())
    }

    /// The transport's limits for a provider: a local model may take minutes to load before its first word.
    static func limits(for profile: AgentProviderProfile) -> AgentTransportLimits {
        profile.isLocal ? .local : .cloud
    }
}
