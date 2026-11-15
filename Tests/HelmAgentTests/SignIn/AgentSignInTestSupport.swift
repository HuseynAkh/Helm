import Foundation
import Security
@testable import HelmAgent

/// Keys made in memory for a test, never saved in a keychain, and ID tokens signed with them.
final class AgentTestSigner: @unchecked Sendable {
    enum Kind { case rsa, p256 }

    let kind: Kind
    let keyID: String
    private let privateKey: SecKey
    let publicKey: SecKey

    init(_ kind: Kind = .rsa, keyID: String = "test-key-1", bits: Int = 2048) {
        self.kind = kind; self.keyID = keyID
        let type = kind == .rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom
        let attributes: [String: Any] = [kSecAttrKeyType as String: type,
                                         kSecAttrKeySizeInBits as String: kind == .rsa ? bits : 256,
                                         kSecAttrIsPermanent as String: false]
        var error: Unmanaged<CFError>?
        guard let made = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let published = SecKeyCopyPublicKey(made) else {
            preconditionFailure("a test key could be made")
        }
        privateKey = made
        publicKey = published
    }

    /// One key made for all the tests that need one: an RSA key takes a moment to make.
    static let shared = AgentTestSigner()

    /// The public key as a sign-in host lists it.
    var signingKey: AgentSigningKey {
        let external = SecKeyCopyExternalRepresentation(publicKey, nil).map { $0 as Data } ?? Data()
        switch kind {
        case .rsa:
            let (modulus, exponent) = Self.integers(inSequence: external)
            return AgentSigningKey(id: keyID, kind: .rsa(modulus: modulus, exponent: exponent))
        case .p256:
            return AgentSigningKey(id: keyID, kind: .p256(x: external.dropFirst().prefix(32), y: external.suffix(32)))
        }
    }

    /// The JSON list a sign-in host publishes, holding this key.
    var keyList: Data {
        var entry: [String: AgentJSON] = ["kid": .string(keyID), "use": .string("sig")]
        switch signingKey.kind {
        case .rsa(let modulus, let exponent):
            entry["kty"] = .string("RSA"); entry["alg"] = .string("RS256")
            entry["n"] = .string(AgentBase64URL.encode(modulus)); entry["e"] = .string(AgentBase64URL.encode(exponent))
        case .p256(let x, let y):
            entry["kty"] = .string("EC"); entry["crv"] = .string("P-256")
            entry["x"] = .string(AgentBase64URL.encode(x)); entry["y"] = .string(AgentBase64URL.encode(y))
        }
        return AgentJSON.object(["keys": .array([.object(entry)])]).data()
    }

    var algorithm: String { kind == .rsa ? "RS256" : "ES256" }

    /// A signed token with these claims. `header` adds to or replaces the usual header.
    func token(_ claims: [String: AgentJSON], header extra: [String: AgentJSON] = [:]) -> String {
        var header: [String: AgentJSON] = ["alg": .string(algorithm), "kid": .string(keyID), "typ": .string("JWT")]
        header.merge(extra) { $1 }
        let input = AgentBase64URL.encode(AgentJSON.object(header).data()) + "." + AgentBase64URL.encode(AgentJSON.object(claims).data())
        return input + "." + AgentBase64URL.encode(signature(over: Data(input.utf8)))
    }

    func signature(over data: Data) -> Data {
        let algorithm: SecKeyAlgorithm = kind == .rsa ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256
        guard let signed = SecKeyCreateSignature(privateKey, algorithm, data as CFData, nil) as Data? else {
            preconditionFailure("a test key signs")
        }
        return kind == .rsa ? signed : Self.raw(fromDER: signed)
    }

    /// The claims of a good ID token for `clientID` and `nonce`.
    static func claims(clientID: String, nonce: String, now: Date = Date(), email: String = "person@example.com") -> [String: AgentJSON] {
        ["iss": .string("https://auth.openai.com"), "aud": .string(clientID), "sub": .string("user-test-subject"),
         "exp": .number(now.timeIntervalSince1970.rounded() + 3_600), "iat": .number(now.timeIntervalSince1970.rounded()),
         "nonce": .string(nonce), "email": .string(email)]
    }

    // MARK: DER

    /// The two integers of a DER sequence, as an RSA public key is written.
    private static func integers(inSequence der: Data) -> (Data, Data) {
        var bytes = Array(der), index = 0
        func length() -> Int {
            let first = Int(bytes[index]); index += 1
            guard first & 0x80 != 0 else { return first }
            var value = 0
            for _ in 0..<(first & 0x7F) { value = value << 8 | Int(bytes[index]); index += 1 }
            return value
        }
        func integer() -> Data {
            index += 1 // the INTEGER tag
            let count = length()
            defer { index += count }
            return Data(bytes[index..<index + count])
        }
        index += 1 // the SEQUENCE tag
        _ = length()
        let modulus = integer(), exponent = integer()
        bytes = []
        return (modulus, exponent)
    }

    /// An ECDSA signature as JSON Web Tokens write it, 32 bytes of r and 32 of s, from DER.
    private static func raw(fromDER der: Data) -> Data {
        let bytes = Array(der)
        var index = 2
        if bytes[1] & 0x80 != 0 { index += Int(bytes[1] & 0x7F) }
        func integer() -> Data {
            index += 1
            let count = Int(bytes[index]); index += 1
            defer { index += count }
            let value = Data(bytes[index..<index + count].drop { $0 == 0 })
            return Data(repeating: 0, count: max(0, 32 - value.count)) + value
        }
        return integer() + integer()
    }
}

/// OpenAI's sign-in, played in the test process: the browser that opens the authorize page and comes back to the
/// callback, and the sign-in host that exchanges the code, publishes its key and revokes. It checks what a real host
/// would: the PKCE verifier against the challenge, the client, the redirect. Nothing leaves the process.
final class AgentStubOpenAI: AgentSignInTransport, @unchecked Sendable {
    private let lock = NSLock()
    let signer: AgentTestSigner
    /// The client OpenAI issues at a first sign-in.
    var issuedClient = "oaiapp_test_client"
    /// The scopes the token endpoint grants.
    var grantedScope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    /// What the browser sends back, from the authorize page's parameters. Each is tried in turn by the listener.
    var callbacks: ([String: String]) -> [[String: String]] = { _ in [] }
    /// The ID token's claims, from the client and the nonce of the sign-in.
    var idClaims: (String, String) -> [String: AgentJSON] = { AgentTestSigner.claims(clientID: $0, nonce: $1) }
    /// Answers for the routes, in place of the usual ones.
    var overrides: [String: Result<AgentHTTPReply, Error>] = [:]
    var opens = true
    var revocationEndpoint = "https://auth.openai.com/oauth/revoke"

    private(set) var opened: [URL] = []
    private(set) var posts: [(route: String, form: [String: String])] = []
    private(set) var gets: [String] = []
    private(set) var shutdowns = 0
    /// What the listener was started with before the browser opened, in order.
    private(set) var events: [String] = []

    init(signer: AgentTestSigner = .shared) { self.signer = signer }

    func note(_ event: String) { held { events.append(event) } }

    /// The opener the sign-in is handed, standing in for the default browser.
    var opener: @Sendable (URL) async -> Bool {
        { [self] address in
            held {
                opened.append(address)
                events.append("open")
            }
            return opens
        }
    }

    /// The authorize page's parameters, from the last address opened.
    var authorizeParameters: [String: String] {
        guard let address = held({ opened.last }), let parts = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return [:] }
        return Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    /// What the browser comes back with, for the listener.
    var browserCallbacks: [[String: String]] { callbacks(authorizeParameters) }

    func post(_ route: AgentSignInRoute, form: [(String, String)]) async throws -> AgentHTTPReply {
        let name = Self.name(route)
        let fields = Dictionary(form) { first, _ in first }
        let override: Result<AgentHTTPReply, Error>? = held {
            posts.append((name, fields))
            return overrides[name]
        }
        if let override { return try override.get() }
        switch route {
        case .token: return tokenReply(fields)
        case .revoke: return AgentHTTPReply(status: 200, body: Data())
        case .keys, .discovery: return AgentHTTPReply(status: 405, body: Data())
        }
    }

    func get(_ route: AgentSignInRoute) async throws -> AgentHTTPReply {
        let name = Self.name(route)
        let override: Result<AgentHTTPReply, Error>? = held {
            gets.append(name)
            return overrides[name]
        }
        if let override { return try override.get() }
        switch route {
        case .keys: return AgentHTTPReply(status: 200, body: signer.keyList)
        case .discovery:
            let document = AgentJSON.object(["issuer": .string("https://auth.openai.com"),
                                             "revocation_endpoint": .string(revocationEndpoint)])
            return AgentHTTPReply(status: 200, body: document.data())
        case .token, .revoke: return AgentHTTPReply(status: 405, body: Data())
        }
    }

    func shutdown() async { held { shutdowns += 1 } }

    /// A code exchange is answered only when its verifier hashes to the challenge the browser saw, its client is the one
    /// issued, and its redirect and resource are the ones the browser was given.
    private func tokenReply(_ fields: [String: String]) -> AgentHTTPReply {
        let page = authorizeParameters
        switch fields["grant_type"] {
        case "authorization_code":
            guard let verifier = fields["code_verifier"], AgentPKCE(verifier: verifier).challenge == page["code_challenge"],
                  fields["client_id"] == expectedClient(page), fields["redirect_uri"] == page["redirect_uri"],
                  fields["resource"] == "https://api.openai.com/v1", fields["code"] == "test-code" else {
                return AgentHTTPReply(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            let client = expectedClient(page)
            let reply: [String: AgentJSON] = [
                "access_token": .string("test-access-token-0001"), "refresh_token": .string("test-refresh-token-0001"),
                "id_token": .string(signer.token(idClaims(client, page["nonce"] ?? ""))), "token_type": .string("Bearer"),
                "expires_in": .number(3_600), "scope": .string(grantedScope)
            ]
            return AgentHTTPReply(status: 200, body: AgentJSON.object(reply).data())
        default:
            return AgentHTTPReply(status: 400, body: Data(#"{"error":"unsupported_grant_type"}"#.utf8))
        }
    }

    private func expectedClient(_ page: [String: String]) -> String {
        page["client_id"] == "dynamic_agent_client" ? issuedClient : (page["client_id"] ?? "")
    }

    static func name(_ route: AgentSignInRoute) -> String {
        switch route {
        case .token: return "token"
        case .keys: return "keys"
        case .discovery: return "discovery"
        case .revoke(let path): return "revoke:" + path
        }
    }

    private func held<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A listener that hands back what the stub browser sent, as the real one does: only a callback the sign-in accepts
/// ends the wait, and the rest are turned away and counted.
final class AgentStubListener: AgentCallbackListening, @unchecked Sendable {
    private let lock = NSLock()
    private let openAI: AgentStubOpenAI
    var port = 54321
    var failure: AgentSignInFailure?
    private(set) var turnedAway: [[String: String]] = []
    private(set) var stops = 0
    private(set) var waitedPath: String?
    private(set) var waitedSeconds: Double?

    init(openAI: AgentStubOpenAI) { self.openAI = openAI }

    func start() throws -> Int {
        openAI.note("listen")
        return port
    }

    func callback(path: String, timeout: Double,
                  accepts: @escaping @Sendable ([String: String]) -> Bool) async throws -> [String: String] {
        lock.lock(); waitedPath = path; waitedSeconds = timeout; lock.unlock()
        if let failure { throw failure }
        for query in openAI.browserCallbacks {
            if accepts(query) { return query }
            lock.lock(); turnedAway.append(query); lock.unlock()
        }
        throw AgentSignInFailure.timedOut
    }

    func stop() {
        lock.lock(); stops += 1; lock.unlock()
        openAI.note("stop")
    }
}

/// A sign-in over a memory store, the stub OpenAI and its listener, at a fixed time.
struct AgentSignInRig {
    let store = MemorySecretStore()
    let openAI: AgentStubOpenAI
    let listener: AgentStubListener
    let signIn: AgentChatGPTSignIn
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    init(signer: AgentTestSigner = .shared) {
        openAI = AgentStubOpenAI(signer: signer)
        let listener = AgentStubListener(openAI: openAI)
        self.listener = listener
        signIn = AgentChatGPTSignIn(store: store, transport: openAI, makeListener: { listener }, now: { Date() })
        // The browser comes back with the code, this sign-in's state and, the first time, the client OpenAI issued.
        let issued = openAI.issuedClient
        openAI.callbacks = { page in
            var query = ["code": "test-code", "state": page["state"] ?? "", "scope": page["scope"] ?? ""]
            if page["client_id"] == "dynamic_agent_client" { query["client_id"] = issued }
            return [query]
        }
    }

    /// Saved tokens for a signed-in person, running out `expiresIn` seconds after `now`.
    func saveTokens(access: String = "test-access-token-0001", refresh: String = "test-refresh-token-0001",
                    expiresIn: TimeInterval = 3_600, scopes: [String]? = nil, now: Date = Date(),
                    email: String? = "person@example.com") throws {
        let tokens = AgentChatGPTTokens(clientID: "oaiapp_test_client", accessToken: access, refreshToken: refresh,
                                        idToken: nil, expiresAt: now.addingTimeInterval(expiresIn),
                                        scopes: scopes ?? ["openid", "offline_access", "chatgpt.tokens.use.direct"])
        try store.saveSignIn(tokens.encoded(), note: email, for: .chatGPTTokens)
    }

    var savedTokens: AgentChatGPTTokens? { (try? store.signInData(.chatGPTTokens)).flatMap(AgentChatGPTTokens.init(data:)) }
    var savedRegistration: AgentChatGPTRegistration? {
        (try? store.signInData(.chatGPTRegistration)).flatMap(AgentChatGPTRegistration.init(data:))
    }
}
