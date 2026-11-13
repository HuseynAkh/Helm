import Foundation

/// A whole reply to a request that isn't streamed.
public struct AgentHTTPReply: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = status; self.body = body
    }
}

/// Every way sending a request can fail before a provider's reply is understood.
public enum AgentTransportError: Error, Equatable, Sendable {
    case http(status: Int, body: Data), redirected, wrongHost, tooLarge, timedOut, unreachable, notRunning,
         proxyAuth, cancelled, noKey, keyDenied, insecure, keyInBody
}

/// Sends requests to the one provider it was made for. A caller names a route and gives a body. It can't give an
/// address or a header, on purpose: where a request goes and which key it carries are decided in one place.
public protocol AgentTransport: Sendable {
    /// A streamed request. Each element is one line of the reply. A status outside 200 to 299 throws `.http`.
    func stream(_ route: AgentRoute, body: Data) -> AsyncThrowingStream<String, Error>
    /// A GET whose whole reply is wanted.
    func fetch(_ route: AgentRoute) async throws -> AgentHTTPReply
    func shutdown() async
}

/// How long a request may take and how much may come back.
public struct AgentTransportLimits: Equatable, Sendable {
    /// Seconds without a byte arriving, and seconds for the whole request.
    public var idleSeconds: Double, totalSeconds: Double
    /// The most bytes in one line, in one reply and in a model list, and how often a request is tried again.
    public var lineBytes: Int, responseBytes: Int, listBytes: Int, retries: Int
    public init(idleSeconds: Double, totalSeconds: Double, lineBytes: Int, responseBytes: Int, listBytes: Int, retries: Int) {
        self.idleSeconds = idleSeconds; self.totalSeconds = totalSeconds; self.lineBytes = lineBytes
        self.responseBytes = responseBytes; self.listBytes = listBytes; self.retries = retries
    }
    /// A provider on the internet.
    public static let cloud = AgentTransportLimits(idleSeconds: 120, totalSeconds: 900, lineBytes: 4_000_000,
                                                   responseBytes: 32_000_000, listBytes: 4_000_000, retries: 2)
    /// A model on this Mac, which can take minutes to load before its first word.
    public static let local = AgentTransportLimits(idleSeconds: 300, totalSeconds: 900, lineBytes: 4_000_000,
                                                   responseBytes: 32_000_000, listBytes: 4_000_000, retries: 2)
}
