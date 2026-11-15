import XCTest
@testable import HelmAgent

/// PKCE and the ID token checks: the digest against published vectors, the challenge as RFC 7636 works it out, and
/// every reason an ID token is turned away, with keys made in memory for the test.
final class AgentPKCEAndIDTokenTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    // MARK: SHA-256 and PKCE

    func testSHA256MatchesThePublishedVectors() {
        XCTAssertEqual(hex(AgentSHA256.digest([])), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(AgentSHA256.digest(Array("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(AgentSHA256.digest(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "two blocks")
        XCTAssertEqual(hex(AgentSHA256.digest([UInt8](repeating: 0x61, count: 1_000))),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testTheChallengeIsTheVerifiersDigestInBase64URLAsRFC7636Shows() {
        // RFC 7636, appendix B.
        let pkce = AgentPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(AgentPKCE.method, "S256")
    }

    func testAVerifierIsFortyThreeAddressSafeCharactersAndNeverTheSameTwice() {
        let made = (0..<64).map { _ in AgentPKCE().verifier }
        XCTAssertEqual(Set(made).count, 64)
        for verifier in made {
            XCTAssertEqual(verifier.count, 43)
            XCTAssertTrue(verifier.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        }
        XCTAssertNotEqual(AgentSignInRandom.text(), AgentSignInRandom.text())
    }

    func testBase64URLRoundTripsAndRefusesOtherAlphabets() {
        let bytes = Data((0...255).map { UInt8($0) })
        let text = AgentBase64URL.encode(bytes)
        XCTAssertFalse(text.contains("+") || text.contains("/") || text.contains("="))
        XCTAssertEqual(AgentBase64URL.decode(text), bytes)
        XCTAssertNil(AgentBase64URL.decode("ab+c"))
        XCTAssertNil(AgentBase64URL.decode("abcde"), "a length no encoding gives")
    }

    // MARK: The signature

    func testAnRSAAndAP256SignatureVerifyAndATamperedOneDoesnt() {
        for signer in [AgentTestSigner.shared, AgentTestSigner(.p256)] {
            let input = Data("header.payload".utf8)
            let signature = signer.signature(over: input)
            XCTAssertTrue(AgentTokenSignature.verifies(signature, over: input, algorithm: signer.algorithm, key: signer.signingKey))
            XCTAssertFalse(AgentTokenSignature.verifies(signature, over: Data("header.payloaD".utf8), algorithm: signer.algorithm,
                                                        key: signer.signingKey))
            var flipped = signature
            flipped[flipped.count - 1] ^= 0x01
            XCTAssertFalse(AgentTokenSignature.verifies(flipped, over: input, algorithm: signer.algorithm, key: signer.signingKey))
            let other = signer.algorithm == "RS256" ? "ES256" : "RS256"
            XCTAssertFalse(AgentTokenSignature.verifies(signature, over: input, algorithm: other, key: signer.signingKey),
                           "a key of one kind never checks the other algorithm")
            XCTAssertFalse(AgentTokenSignature.verifies(signature, over: input, algorithm: "none", key: signer.signingKey))
        }
    }

    func testAShortRSAKeyIsRefused() {
        let weak = AgentTestSigner(.rsa, keyID: "test-weak", bits: 1024)
        let input = Data("header.payload".utf8)
        XCTAssertFalse(AgentTokenSignature.verifies(weak.signature(over: input), over: input, algorithm: "RS256", key: weak.signingKey))
    }

    func testThePublishedKeyListIsRead() {
        let keys = AgentSigningKey.keys(from: AgentTestSigner.shared.keyList)
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.id, "test-key-1")
        XCTAssertEqual(keys.first?.algorithm, "RS256")
        let encryption = #"{"keys":[{"kty":"RSA","use":"enc","kid":"e","n":"AQAB","e":"AQAB"},{"kty":"oct","k":"AA"}]}"#
        XCTAssertTrue(AgentSigningKey.keys(from: Data(encryption.utf8)).isEmpty, "keys for anything but signing are left out")
        XCTAssertTrue(AgentSigningKey.keys(from: Data("not json".utf8)).isEmpty)
    }

    // MARK: The claims

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func check(_ token: String, signer: AgentTestSigner = .shared, clientID: String = "oaiapp_test_client",
                       nonce: String = "nonce-test") throws -> AgentIDClaims {
        try AgentIDToken.check(token, keys: [signer.signingKey], clientID: clientID, nonce: nonce, now: now)
    }

    private func claims(_ change: (inout [String: AgentJSON]) -> Void = { _ in }) -> [String: AgentJSON] {
        var claims = AgentTestSigner.claims(clientID: "oaiapp_test_client", nonce: "nonce-test", now: now)
        change(&claims)
        return claims
    }

    private func XCTAssertTurnedAway(_ token: String, _ problem: AgentIDTokenProblem, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try check(token), file: file, line: line) { error in
            XCTAssertEqual(error as? AgentIDTokenProblem, problem, file: file, line: line)
        }
    }

    func testAGoodTokenGivesTheSubjectAndTheEmail() throws {
        let signer = AgentTestSigner.shared
        XCTAssertEqual(try check(signer.token(claims())), AgentIDClaims(subject: "user-test-subject", email: "person@example.com"))
        // An audience list that holds the client, for the party it was given to.
        let listed = signer.token(claims { $0["aud"] = .array([.string("oaiapp_test_client"), .string("other")])
                                           $0["azp"] = .string("oaiapp_test_client") })
        XCTAssertEqual(try check(listed).subject, "user-test-subject")
        // An email that isn't clean text is not shown.
        let odd = signer.token(claims { $0["email"] = .string("person@example.com\u{202E}") })
        XCTAssertNil(try check(odd).email)
        let p256 = AgentTestSigner(.p256)
        XCTAssertEqual(try check(p256.token(claims()), signer: p256).subject, "user-test-subject")
    }

    func testEachReasonATokenIsTurnedAway() {
        let signer = AgentTestSigner.shared
        XCTAssertTurnedAway(signer.token(claims { $0["iss"] = .string("https://auth.example.com") }), .issuer)
        XCTAssertTurnedAway(signer.token(claims { $0["aud"] = .string("oaiapp_other") }), .audience)
        XCTAssertTurnedAway(signer.token(claims { $0["aud"] = .array([.string("oaiapp_test_client"), .string("other")]) }), .audience)
        XCTAssertTurnedAway(signer.token(claims { $0["exp"] = .number(now.timeIntervalSince1970 - 60) }), .expired)
        XCTAssertTurnedAway(signer.token(claims { $0["exp"] = nil }), .expired)
        XCTAssertTurnedAway(signer.token(claims { $0["iat"] = nil }), .issued)
        XCTAssertTurnedAway(signer.token(claims { $0["iat"] = .number(now.timeIntervalSince1970 + 3_600) }), .issued)
        XCTAssertTurnedAway(signer.token(claims { $0["sub"] = .string("") }), .subject)
        XCTAssertTurnedAway(signer.token(claims { $0["nonce"] = .string("another-nonce") }), .nonce)
        XCTAssertTurnedAway(signer.token(claims { $0["nonce"] = nil }), .nonce)
        XCTAssertTurnedAway(signer.token(claims(), header: ["alg": .string("none")]), .algorithm)
        XCTAssertTurnedAway(signer.token(claims(), header: ["alg": .string("HS256")]), .algorithm)
        XCTAssertTurnedAway(signer.token(claims(), header: ["kid": .string("unknown-key")]), .noKey)
        XCTAssertTurnedAway("not.a-token", .shape)
        XCTAssertTurnedAway("a.b.c.d", .shape)
        // An unsigned token, and a token whose claims were changed after it was signed.
        let good = signer.token(claims())
        let parts = good.split(separator: ".").map(String.init)
        XCTAssertTurnedAway(parts[0] + "." + parts[1] + ".", .shape)
        let forged = AgentBase64URL.encode(AgentJSON.object(claims { $0["sub"] = .string("someone-else") }).data())
        XCTAssertTurnedAway(parts[0] + "." + forged + "." + parts[2], .signature)
        // A clock a few seconds off is forgiven.
        XCTAssertNoThrow(try check(signer.token(claims { $0["exp"] = .number(now.timeIntervalSince1970 - 2) })))
    }
}
