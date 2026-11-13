// The transport to the chosen model provider: the only file in Helm that may make a network connection.
import Foundation

/// Sends requests to one provider. Where a request goes is the profile's endpoint and the route's fixed path; a
/// caller gives a route and a body, and never an address or a header. The key is looked up in `secrets` under the
/// profile's own account when a request is sent.
///
/// The first label of the initializers is `liveProfile`, and the privacy check lets one file write it, so a
/// transport can't be made anywhere else.
///
/// This file makes no connection: every request answers `unreachable`.
public final class HTTPTransport: AgentTransport, @unchecked Sendable {
    private let profile: AgentProviderProfile
    private let secrets: any AgentSecretStoring
    private let limits: AgentTransportLimits
    /// Loader classes a test puts in front of the network. Empty outside tests.
    private let testProtocols: [AnyClass]

    public init(liveProfile profile: AgentProviderProfile, secrets: any AgentSecretStoring, limits: AgentTransportLimits) {
        self.profile = profile; self.secrets = secrets; self.limits = limits; self.testProtocols = []
    }

    /// For tests, which stand loaders of their own in for the network.
    init(liveProfile profile: AgentProviderProfile, secrets: any AgentSecretStoring, limits: AgentTransportLimits,
         testProtocols: [AnyClass]) {
        self.profile = profile; self.secrets = secrets; self.limits = limits; self.testProtocols = testProtocols
    }

    public func stream(_ route: AgentRoute, body: Data) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentTransportError.unreachable) }
    }

    public func fetch(_ route: AgentRoute) async throws -> AgentHTTPReply {
        throw AgentTransportError.unreachable
    }

    public func shutdown() async {}
}
