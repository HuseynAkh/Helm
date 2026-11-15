import Foundation

/// This Mac's registration with ChatGPT's sign-in: its host ID, made once and kept, and the client OpenAI issued for
/// it at the first sign-in. Neither is a credential. Both stay in the keychain after a sign-out, so the next sign-in
/// is the same registration.
public struct AgentChatGPTRegistration: Equatable, Sendable {
    /// `urn:uuid:` and a random UUID. It names no person and no Mac.
    public let hostID: String
    /// The `oaiapp_` client issued at the first sign-in. Nil until then.
    public var clientID: String?
    public init(hostID: String, clientID: String?) {
        self.hostID = hostID; self.clientID = clientID
    }

    /// A new registration with a new host ID and no client yet.
    static func newHost() -> AgentChatGPTRegistration {
        AgentChatGPTRegistration(hostID: "urn:uuid:" + UUID().uuidString.lowercased(), clientID: nil)
    }

    func encoded() -> Data {
        var members: [String: AgentJSON] = ["hostID": .string(hostID)]
        if let clientID { members["clientID"] = .string(clientID) }
        return AgentJSON.object(members).data()
    }

    init?(data: Data) {
        guard let value = try? AgentJSON(data: data), let host = value["hostID"]?.stringValue,
              AgentChatGPTRegistration.isHostID(host) else { return nil }
        let client = value["clientID"]?.stringValue
        if let client, !AgentChatGPTRegistration.isClientID(client) { return nil }
        self.init(hostID: host, clientID: client)
    }

    /// A host ID as Helm makes them.
    static func isHostID(_ text: String) -> Bool {
        guard text.hasPrefix("urn:uuid:") else { return false }
        return UUID(uuidString: String(text.dropFirst("urn:uuid:".count))) != nil
    }

    /// The client OpenAI issued: a short run of letters, digits, `_` and `-`, and never the name every first sign-in
    /// starts with.
    static func isClientID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 128 && text != AgentChatGPTSignIn.registrationClient
            && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
    }
}

/// The tokens of a ChatGPT sign-in, saved and renewed together, with the client they were issued to. It prints as
/// "AgentChatGPTTokens(hidden)" however it is printed and has no mirror, so no token reaches a log or an assertion.
struct AgentChatGPTTokens: Sendable {
    let clientID: String
    let accessToken: String
    let refreshToken: String
    /// The ID token checked at sign-in, kept to name the account when signing in again.
    let idToken: String?
    let expiresAt: Date
    let scopes: [String]

    init(clientID: String, accessToken: String, refreshToken: String, idToken: String?, expiresAt: Date, scopes: [String]) {
        self.clientID = clientID; self.accessToken = accessToken; self.refreshToken = refreshToken
        self.idToken = idToken; self.expiresAt = expiresAt; self.scopes = scopes
    }

    /// The scope a ChatGPT plan's requests need.
    static let planScope = "chatgpt.tokens.use.direct"

    /// Whether these tokens may be spent on the person's plan.
    var allowsPlan: Bool { scopes.contains(Self.planScope) }

    /// The access token, for a request's header.
    var bearer: AgentSecret? { AgentSecret(bearerToken: accessToken) }

    /// Whether the access token ends within `margin` seconds of `now`.
    func expires(within margin: TimeInterval, of now: Date) -> Bool { expiresAt.timeIntervalSince(now) <= margin }

    /// The tokens after a refresh: the new access token, the new refresh token when one came (OpenAI rotates them), and
    /// the scopes the answer named, else the ones before.
    func refreshed(by reply: AgentTokenReply, now: Date) -> AgentChatGPTTokens {
        AgentChatGPTTokens(clientID: clientID, accessToken: reply.accessToken, refreshToken: reply.refreshToken ?? refreshToken,
                           idToken: idToken, expiresAt: now.addingTimeInterval(reply.expiresIn),
                           scopes: reply.scopes ?? scopes)
    }

    func encoded() -> Data {
        var members: [String: AgentJSON] = [
            "clientID": .string(clientID), "accessToken": .string(accessToken), "refreshToken": .string(refreshToken),
            "expiresAt": .number(expiresAt.timeIntervalSince1970.rounded()), "scopes": .array(scopes.map(AgentJSON.string))
        ]
        if let idToken { members["idToken"] = .string(idToken) }
        return AgentJSON.object(members).data()
    }

    init?(data: Data) {
        guard let value = try? AgentJSON(data: data), let client = value["clientID"]?.stringValue,
              AgentChatGPTRegistration.isClientID(client), let accessText = value["accessToken"]?.stringValue,
              AgentSecret(bearerToken: accessText) != nil, let refresh = value["refreshToken"]?.stringValue, !refresh.isEmpty,
              case .number(let seconds)? = value["expiresAt"], seconds.isFinite else { return nil }
        let scopes = (value["scopes"]?.arrayValue ?? []).compactMap(\.stringValue)
        self.init(clientID: client, accessToken: accessText, refreshToken: refresh, idToken: value["idToken"]?.stringValue,
                  expiresAt: Date(timeIntervalSince1970: seconds), scopes: scopes)
    }
}

extension AgentChatGPTTokens: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "AgentChatGPTTokens(hidden)" }
    var debugDescription: String { "AgentChatGPTTokens(hidden)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the token endpoint answered a code exchange or a refresh with.
struct AgentTokenReply: Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: TimeInterval
    /// The scopes granted, when the answer named them.
    let scopes: [String]?

    /// An hour, which is how long OpenAI says an access token lasts, for an answer that doesn't say.
    static let usualLifetime: TimeInterval = 3_600

    /// Nil for an answer with no usable access token.
    init?(data: Data) {
        guard let value = try? AgentJSON(data: data), let accessText = value["access_token"]?.stringValue,
              AgentSecret(bearerToken: accessText) != nil else { return nil }
        if let type = value["token_type"]?.stringValue, type.lowercased() != "bearer" { return nil }
        accessToken = accessText
        refreshToken = value["refresh_token"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        idToken = value["id_token"]?.stringValue
        if case .number(let seconds)? = value["expires_in"], seconds.isFinite, seconds > 0 {
            expiresIn = min(seconds, 86_400)
        } else {
            expiresIn = Self.usualLifetime
        }
        scopes = value["scope"]?.stringValue.map { $0.split(separator: " ").map(String.init) }
    }

    /// The error code a refused request names, such as `invalid_grant`, read from its body and never shown.
    static func errorCode(in body: Data) -> String? {
        guard let value = try? AgentJSON(data: body) else { return nil }
        if let code = value["error"]?.stringValue { return code }
        return value["error"]?["code"]?.stringValue ?? value["code"]?.stringValue
    }

    /// The codes that mean a refresh token can't be used again: the person signs in again.
    static let endedCodes: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                                          "refresh_token_invalidated", "refresh_token_reused"]
}

/// Form fields as `application/x-www-form-urlencoded` writes them: every byte but letters, digits and `-._~` escaped.
enum AgentFormBody {
    static func encode(_ fields: [(String, String)]) -> Data {
        Data(fields.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&").utf8)
    }

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
