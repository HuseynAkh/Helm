import Foundation
import HelmCore

/// The real pieces behind AI mode, as the app hands them to `AgentRuntimeParts`. A conversation is always the real
/// loop: its folders go through `AgentScope`, its tools through `AgentToolRunner`, and every plan through
/// `AgentPlanValidator` before a card shows it. Which model answers is the runtime's choice, so a fixture run's
/// scripted model goes through exactly the same loop as a provider would.
public enum AgentLiveParts {
    /// A new conversation over the runtime's parts.
    public static let makeSession: @Sendable (AgentSessionParts) -> any AgentConversing = { parts in
        AgentSession(parts: parts, validator: AgentPlanValidator())
    }
}
