import Foundation

/// The requests a ChatGPT sign-in makes of OpenAI's sign-in host. Each has a fixed path, but a revocation, whose
/// path the host's own discovery document names; the transport takes that path only when it is plain.
public enum AgentSignInRoute: Hashable, Sendable {
    /// Exchanges a code, or a refresh token, for tokens.
    case token
    /// The keys the host signs ID tokens with.
    case keys
    /// The host's discovery document, which names where a refresh token is revoked.
    case discovery
    /// Revokes a refresh token, at the path the discovery document named.
    case revoke(path: String)
}

/// Sends a sign-in's requests to OpenAI's sign-in host and nowhere else. A caller names a route and gives form
/// fields; the address, the headers and the encoding are the transport's.
public protocol AgentSignInTransport: Sendable {
    /// A form-encoded POST. A status outside 200 to 299 is an answer too, with its body, since the host says in it
    /// why a request was refused.
    func post(_ route: AgentSignInRoute, form: [(String, String)]) async throws -> AgentHTTPReply
    /// A GET whose whole reply is wanted.
    func get(_ route: AgentSignInRoute) async throws -> AgentHTTPReply
    func shutdown() async
}

/// Hands a transport the token for its requests, when they are made with a sign-in's token in place of a key. The
/// token is asked for each request, so one that has run out is renewed before it goes.
public protocol AgentBearerSource: Sendable {
    /// The token for the next request. Throws `AgentTransportError.noKey` when there is no sign-in, `.keyDenied` when
    /// macOS refused to hand it over, and `.unreachable` when it ran out and couldn't be renewed just now.
    func bearerToken() async throws -> AgentSecret
    /// The provider turned away the last token handed out. A newer one, saved since, is handed out if there is one;
    /// else the token is renewed. Throws as `bearerToken()` does, and `.noKey` once the sign-in can't be renewed.
    func renewedToken() async throws -> AgentSecret
    /// Lets go of the tokens it holds, as AI mode turns off.
    func forget()
}

/// Listens on this Mac for the one request a browser makes when a sign-in finishes.
public protocol AgentCallbackListening: AnyObject, Sendable {
    /// Starts listening on 127.0.0.1, on a port the system picks, and gives that port. It listens before the browser
    /// opens, so the browser can't arrive first.
    func start() throws -> Int
    /// The query of the first request for `path` whose query `accepts` takes. Every other request is answered and
    /// turned away. Throws `AgentSignInFailure.timedOut` after `timeout` seconds, and `.cancelled` once stopped.
    func callback(path: String, timeout: Double,
                  accepts: @escaping @Sendable ([String: String]) -> Bool) async throws -> [String: String]
    /// Stops listening. A callback still awaited throws `.cancelled`.
    func stop()
}

/// Why a ChatGPT sign-in didn't finish. Each case has one line in `AgentText`.
public enum AgentSignInFailure: String, Error, Sendable, CaseIterable {
    /// The person stopped it.
    case cancelled
    /// Nothing came back from the browser in time.
    case timedOut
    /// The browser couldn't be opened.
    case noBrowser
    /// The person didn't allow it.
    case declined
    /// The sign-in worked, but doesn't allow ChatGPT plan use.
    case planOff
    /// OpenAI's sign-in host couldn't be reached.
    case unreachable
    /// What came back wasn't a sign-in Helm could trust: a callback for another client, a token that failed its
    /// checks, or an answer that couldn't be read.
    case failed
    /// This run of Helm can't sign in: a fixture run, or AI mode is off.
    case unavailable
}

/// Who signed in, as Settings shows it. The email is never sent to a model.
public struct AgentChatGPTAccount: Equatable, Sendable {
    public let email: String?
    public init(email: String?) { self.email = email }
}
