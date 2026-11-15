import Foundation
import HelmCore

/// Signs the person in with ChatGPT, so OpenAI's requests are billed to their ChatGPT plan with no key to paste
/// ("Sign in with ChatGPT" for apps that run on the person's own computer).
///
/// One sign-in, start to end:
/// 1. This Mac's host ID is made and saved before the first sign-in, and reused afterwards.
/// 2. A fresh state, nonce and PKCE verifier are made, and the listener starts on 127.0.0.1 before the browser opens.
/// 3. The browser opens OpenAI's authorize page with the issued client, or the registration client the first time.
/// 4. The one request back to `/auth/callback` with this sign-in's state is taken; any other is turned away.
/// 5. The code is exchanged for tokens with the verifier and no client secret.
/// 6. The ID token's signature is checked against OpenAI's published keys, then its issuer, audience, times and nonce.
/// 7. The granted scopes must include ChatGPT plan use.
/// 8. The client and the tokens are saved in the keychain, the tokens with the account's email as their note.
///
/// Nothing here opens the browser itself: the caller hands it an opener, which is the app's and is a stand-in in
/// tests. The state, the nonce and the verifier live only for the sign-in that made them. One value signs in or out
/// once: its transport is shut down when that is done.
public final class AgentChatGPTSignIn: @unchecked Sendable {
    /// The client a first sign-in registers with. It is never saved: the client OpenAI issues in its place is.
    static let registrationClient = "dynamic_agent_client"
    /// The name OpenAI shows the person when Helm registers.
    static let agentName = "Helm"
    /// Identity, a refresh token, and ChatGPT plan use.
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    /// Where the browser comes back to on this Mac.
    static let callbackPath = "/auth/callback"
    /// How long the browser has to come back.
    static let waitSeconds: Double = 300

    private let store: any AgentSecretStoring
    private let transport: any AgentSignInTransport
    private let makeListener: @Sendable () -> any AgentCallbackListening
    private let now: @Sendable () -> Date

    /// `makeListener` makes a new listener for each sign-in.
    public init(store: any AgentSecretStoring, transport: any AgentSignInTransport,
                makeListener: @escaping @Sendable () -> any AgentCallbackListening,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.transport = transport; self.makeListener = makeListener; self.now = now
    }

    // MARK: Signing in

    /// Runs one sign-in. `openInBrowser` hands the authorize address to the browser and says whether it went. `asksConsent`
    /// asks the person to agree again, after a sign-in they declined or one that didn't allow plan use. Stopping the
    /// task that runs this stops the listener, and the sign-in throws `.cancelled`.
    public func run(asksConsent: Bool = false,
                    openInBrowser: @escaping @Sendable (URL) async -> Bool) async throws -> AgentChatGPTAccount {
        let listener = makeListener(), transport = self.transport
        do {
            let account = try await withTaskCancellationHandler {
                try await signIn(openInBrowser: openInBrowser, listener: listener, asksConsent: asksConsent)
            } onCancel: {
                listener.stop()
            }
            await transport.shutdown()
            return account
        } catch {
            await transport.shutdown()
            throw Task.isCancelled ? AgentSignInFailure.cancelled : error
        }
    }

    private func signIn(openInBrowser: @escaping @Sendable (URL) async -> Bool, listener: any AgentCallbackListening,
                        asksConsent: Bool) async throws -> AgentChatGPTAccount {
        var registration = try loadRegistration()
        let pkce = AgentPKCE(), state = AgentSignInRandom.text(), nonce = AgentSignInRandom.text()
        let port: Int
        do { port = try listener.start() } catch { throw AgentSignInFailure.unavailable }
        defer { listener.stop() }
        let redirect = Self.redirect(port: port)
        let retained = (try? store.signInData(.chatGPTTokens)).flatMap(AgentChatGPTTokens.init(data:))
        guard let address = Self.authorizeAddress(registration: registration, redirect: redirect, state: state, nonce: nonce,
                                                  challenge: pkce.challenge, idTokenHint: retained?.idToken,
                                                  asksConsent: asksConsent) else {
            throw AgentSignInFailure.failed
        }
        try Task.checkCancellation()
        guard await openInBrowser(address) else { throw AgentSignInFailure.noBrowser }
        let query = try await listener.callback(path: Self.callbackPath, timeout: Self.waitSeconds) { $0["state"] == state }
        let clientID = try Self.client(from: query, registration: registration)
        guard let code = query["code"], !code.isEmpty else { throw AgentSignInFailure.failed }

        let reply = try await exchange(code: code, clientID: clientID, verifier: pkce.verifier, redirect: redirect)
        guard let idToken = reply.idToken, let refreshToken = reply.refreshToken else { throw AgentSignInFailure.failed }
        let claims = try await checked(idToken, clientID: clientID, nonce: nonce)

        // The client is this registration's from now on, whatever the scopes say.
        if registration.clientID != clientID {
            registration.clientID = clientID
            try save(registration.encoded(), note: nil, for: .chatGPTRegistration)
        }
        let scopes = reply.scopes ?? query["scope"].map { $0.split(separator: " ").map(String.init) } ?? []
        let tokens = AgentChatGPTTokens(clientID: clientID, accessToken: reply.accessToken, refreshToken: refreshToken,
                                        idToken: idToken, expiresAt: now().addingTimeInterval(reply.expiresIn), scopes: scopes)
        guard tokens.allowsPlan else { throw AgentSignInFailure.planOff }
        try save(tokens.encoded(), note: claims.email, for: .chatGPTTokens)
        return AgentChatGPTAccount(email: claims.email)
    }

    /// The registration, made and saved the first time, so the host ID is the same for every sign-in from this Mac.
    private func loadRegistration() throws -> AgentChatGPTRegistration {
        do {
            if let data = try store.signInData(.chatGPTRegistration), let saved = AgentChatGPTRegistration(data: data) {
                return saved
            }
        } catch AgentSecretError.denied {
            throw AgentSignInFailure.failed
        }
        let made = AgentChatGPTRegistration.newHost()
        try save(made.encoded(), note: nil, for: .chatGPTRegistration)
        return made
    }

    private func save(_ data: Data, note: String?, for item: AgentSignInItem) throws {
        do { try store.saveSignIn(data, note: note, for: item) } catch { throw AgentSignInFailure.failed }
    }

    /// Trades the code for tokens. No client secret: the verifier is the proof.
    private func exchange(code: String, clientID: String, verifier: String, redirect: String) async throws -> AgentTokenReply {
        let reply: AgentHTTPReply
        do {
            reply = try await transport.post(.token, form: Self.exchangeForm(code: code, clientID: clientID, verifier: verifier,
                                                                            redirect: redirect))
        } catch {
            throw Self.failure(of: error)
        }
        guard (200...299).contains(reply.status), let tokens = AgentTokenReply(data: reply.body) else {
            throw AgentSignInFailure.failed
        }
        return tokens
    }

    /// The ID token, checked against the keys OpenAI publishes.
    private func checked(_ idToken: String, clientID: String, nonce: String) async throws -> AgentIDClaims {
        let reply: AgentHTTPReply
        do { reply = try await transport.get(.keys) } catch { throw Self.failure(of: error) }
        guard (200...299).contains(reply.status) else { throw AgentSignInFailure.unreachable }
        do {
            return try AgentIDToken.check(idToken, keys: AgentSigningKey.keys(from: reply.body), clientID: clientID,
                                          nonce: nonce, now: now())
        } catch {
            throw AgentSignInFailure.failed
        }
    }

    // MARK: Signing out

    /// Signs out: the refresh token is revoked at OpenAI when the sign-in host's discovery document names where, and the
    /// tokens are removed from the keychain whatever happens. The registration stays. Answers whether OpenAI confirmed
    /// the revocation; when it didn't, the person can disconnect Helm in ChatGPT's settings.
    public func signOut() async -> Bool {
        let tokens = (try? store.signInData(.chatGPTTokens)).flatMap(AgentChatGPTTokens.init(data:))
        try? store.removeSignIn(.chatGPTTokens)
        let transport = self.transport
        defer { Task { await transport.shutdown() } }
        guard let tokens else { return true }
        guard let discovery = try? await transport.get(.discovery), (200...299).contains(discovery.status),
              let path = Self.revocationPath(in: discovery.body),
              let reply = try? await transport.post(.revoke(path: path), form: [
                ("token", tokens.refreshToken), ("token_type_hint", "refresh_token"), ("client_id", tokens.clientID)
              ]) else { return false }
        return (200...299).contains(reply.status)
    }

    // MARK: The parts, each tested by itself

    /// The address the browser opens. The registration client and Helm's name go only with a first sign-in; a returning
    /// one sends its own client and, when it has one, the ID token it kept, so OpenAI can skip asking which account.
    static func authorizeAddress(registration: AgentChatGPTRegistration, redirect: String, state: String, nonce: String,
                                 challenge: String, idTokenHint: String?, asksConsent: Bool) -> URL? {
        guard let host = try? AgentEndpoint.openAISignIn() else { return nil }
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: registration.clientID ?? registrationClient),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "resource", value: AgentProviderCatalog.openAIBase),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: AgentPKCE.method),
            URLQueryItem(name: "ext_agent_host_id", value: registration.hostID)
        ]
        if registration.clientID == nil {
            items.append(URLQueryItem(name: "agent_name_hint", value: agentName))
        } else if let idTokenHint {
            items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint))
        }
        if asksConsent { items.append(URLQueryItem(name: "prompt", value: "consent")) }
        var parts = URLComponents()
        parts.scheme = AgentProviderCatalog.secureScheme
        parts.host = host.host
        parts.path = AgentProviderCatalog.authorizePath
        // Every value is written with only letters, digits and `-._~` left as they are, so a `+` or a `:` can't be read
        // differently by the host.
        parts.percentEncodedQuery = items.map { AgentFormBody.escape($0.name) + "=" + AgentFormBody.escape($0.value ?? "") }
            .joined(separator: "&")
        return parts.url
    }

    /// Plain http to 127.0.0.1, the port, then `/auth/callback`: this Mac by number, never "localhost", and only the
    /// port varies.
    static func redirect(port: Int) -> String {
        var parts = URLComponents()
        parts.scheme = plainScheme
        parts.host = AgentProviderCatalog.loopbackHost
        parts.port = port
        parts.path = callbackPath
        return parts.string ?? ""
    }
    private static let plainScheme = "http"

    /// The client the code was issued to, from a callback whose state already matched. A refusal is `.declined` when the
    /// person said no and `.failed` otherwise. A returning sign-in takes no other client than its own; a first one must
    /// name the client OpenAI issued.
    static func client(from query: [String: String], registration: AgentChatGPTRegistration) throws -> String {
        if let error = query["error"] {
            throw error == "access_denied" ? AgentSignInFailure.declined : AgentSignInFailure.failed
        }
        if let saved = registration.clientID {
            if let named = query["client_id"], named != saved { throw AgentSignInFailure.failed }
            return saved
        }
        guard let issued = query["client_id"], AgentChatGPTRegistration.isClientID(issued) else { throw AgentSignInFailure.failed }
        return issued
    }

    /// The code exchange: an `authorization_code` grant with the issued client, the verifier, the same redirect and the
    /// same resource. No client secret.
    static func exchangeForm(code: String, clientID: String, verifier: String, redirect: String) -> [(String, String)] {
        [("grant_type", "authorization_code"), ("client_id", clientID), ("code", code), ("code_verifier", verifier),
         ("redirect_uri", redirect), ("resource", AgentProviderCatalog.openAIBase)]
    }

    /// A refresh: a `refresh_token` grant with the client the tokens were issued to, and no scope, so the grant stays as
    /// it was.
    static func refreshForm(_ tokens: AgentChatGPTTokens) -> [(String, String)] {
        [("grant_type", "refresh_token"), ("client_id", tokens.clientID), ("refresh_token", tokens.refreshToken),
         ("resource", AgentProviderCatalog.openAIBase)]
    }

    /// Where the discovery document says a refresh token is revoked: a path on the sign-in host itself, and only then.
    static func revocationPath(in body: Data) -> String? {
        guard let document = try? AgentJSON(data: body), let text = document["revocation_endpoint"]?.stringValue,
              let parts = URLComponents(string: text), parts.scheme == AgentProviderCatalog.secureScheme,
              let host = try? AgentEndpoint.openAISignIn(), parts.host?.lowercased() == host.host,
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, AgentProviderCatalog.isPlainPath(parts.percentEncodedPath) else {
            return nil
        }
        return parts.percentEncodedPath
    }

    /// What a transport's error means for a sign-in.
    static func failure(of error: Error) -> AgentSignInFailure {
        if let failure = error as? AgentSignInFailure { return failure }
        if error is CancellationError || (error as? AgentTransportError) == .cancelled { return .cancelled }
        return .unreachable
    }
}
