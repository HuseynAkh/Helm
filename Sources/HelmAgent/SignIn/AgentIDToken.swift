import Foundation
import HelmCore

/// One key from the list OpenAI's sign-in host publishes for checking the ID tokens it signs.
public struct AgentSigningKey: Sendable {
    public enum Kind: Sendable {
        case rsa(modulus: Data, exponent: Data)
        case p256(x: Data, y: Data)
    }
    /// The key's id, which a token's header names.
    public let id: String?
    public let kind: Kind
    public init(id: String?, kind: Kind) {
        self.id = id; self.kind = kind
    }

    /// The keys in a published list. A key Helm can't use, or one marked for something other than signing, is left out.
    /// At most 32 are read.
    static func keys(from body: Data) -> [AgentSigningKey] {
        guard let list = try? AgentJSON(data: body), let entries = list["keys"]?.arrayValue else { return [] }
        return entries.prefix(mostKeys).compactMap { entry in
            if let use = entry["use"]?.stringValue, use != "sig" { return nil }
            let id = entry["kid"]?.stringValue
            switch entry["kty"]?.stringValue {
            case "RSA":
                guard let modulus = entry["n"]?.stringValue.flatMap(AgentBase64URL.decode),
                      let exponent = entry["e"]?.stringValue.flatMap(AgentBase64URL.decode) else { return nil }
                return AgentSigningKey(id: id, kind: .rsa(modulus: modulus, exponent: exponent))
            case "EC":
                guard entry["crv"]?.stringValue == "P-256", let x = entry["x"]?.stringValue.flatMap(AgentBase64URL.decode),
                      let y = entry["y"]?.stringValue.flatMap(AgentBase64URL.decode) else { return nil }
                return AgentSigningKey(id: id, kind: .p256(x: x, y: y))
            default:
                return nil
            }
        }
    }

    private static let mostKeys = 32

    /// The algorithm a token signed with this key names.
    var algorithm: String {
        switch kind {
        case .rsa: return "RS256"
        case .p256: return "ES256"
        }
    }
}

/// What a checked ID token says about who signed in.
public struct AgentIDClaims: Equatable, Sendable {
    /// The account, as OpenAI names it for this client.
    public let subject: String
    /// For recognition only: shown in Settings, never sent to a model.
    public let email: String?
    public init(subject: String, email: String?) {
        self.subject = subject; self.email = email
    }
}

/// Why an ID token wasn't taken.
enum AgentIDTokenProblem: Error, Equatable {
    case shape, algorithm, noKey, signature, issuer, audience, expired, issued, subject, nonce
}

/// The checks an ID token passes before Helm believes it: its signature against a published key, then its issuer,
/// its audience, its times and the nonce this sign-in sent. A token with no signature, or one signed some other way,
/// fails the first.
enum AgentIDToken {
    /// Seconds a clock may be off by.
    static let tolerance: TimeInterval = 5
    /// The longest an email may be and still be shown.
    static let longestEmail = 254

    static func check(_ token: String, keys: [AgentSigningKey], clientID: String, nonce: String, now: Date,
                      verifies: (Data, Data, String, AgentSigningKey) -> Bool = AgentTokenSignature.verifies)
        throws -> AgentIDClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = AgentBase64URL.decode(parts[0]), let claimData = AgentBase64URL.decode(parts[1]),
              let signature = AgentBase64URL.decode(parts[2]), !signature.isEmpty,
              let header = try? AgentJSON(data: headerData), let claims = try? AgentJSON(data: claimData),
              header.objectValue != nil, claims.objectValue != nil else { throw AgentIDTokenProblem.shape }
        guard let algorithm = header["alg"]?.stringValue, algorithm == "RS256" || algorithm == "ES256" else {
            throw AgentIDTokenProblem.algorithm
        }
        let candidates = keys.filter { $0.algorithm == algorithm }
        let named = header["kid"]?.stringValue
        let key = named.map { id in candidates.first { $0.id == id } } ?? (candidates.count == 1 ? candidates.first : nil)
        guard let key else { throw AgentIDTokenProblem.noKey }
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        guard verifies(signature, signed, algorithm, key) else { throw AgentIDTokenProblem.signature }

        guard claims["iss"]?.stringValue == AgentProviderCatalog.openAISignInBase else { throw AgentIDTokenProblem.issuer }
        guard audience(claims, includes: clientID) else { throw AgentIDTokenProblem.audience }
        let seconds = now.timeIntervalSince1970
        guard let expires = number(claims["exp"]), seconds < expires + tolerance else { throw AgentIDTokenProblem.expired }
        guard let issued = number(claims["iat"]), issued <= seconds + 300 else { throw AgentIDTokenProblem.issued }
        guard let subject = claims["sub"]?.stringValue, !subject.isEmpty else { throw AgentIDTokenProblem.subject }
        if let session = claims["sid"], session.stringValue?.isEmpty ?? true { throw AgentIDTokenProblem.subject }
        guard let said = claims["nonce"]?.stringValue, said == nonce else { throw AgentIDTokenProblem.nonce }
        let email = claims["email"]?.stringValue.flatMap { text -> String? in
            text.utf8.count <= longestEmail && AgentTextEscaper.isClean(text) && text.contains("@") ? text : nil
        }
        return AgentIDClaims(subject: subject, email: email)
    }

    /// The token was issued to `clientID`: its audience is that client, or a list holding it, and a token for several
    /// audiences names it as the party it was given to.
    private static func audience(_ claims: AgentJSON, includes clientID: String) -> Bool {
        if let one = claims["aud"]?.stringValue { return one == clientID }
        guard let many = claims["aud"]?.arrayValue, many.contains(.string(clientID)) else { return false }
        return many.count == 1 || claims["azp"]?.stringValue == clientID
    }

    private static func number(_ value: AgentJSON?) -> Double? {
        guard case .number(let number)? = value, number.isFinite else { return nil }
        return number
    }
}
