import XCTest
@testable import HelmAgent

/// A key never shows itself, is only ever a plain ASCII word, and is found only under the address it was saved for.
final class AgentSecretTests: XCTestCase {
    /// Stand-in text for a key. It isn't shaped like any provider's.
    private let text = "plain-stand-in-for-tests"

    private struct Holder {
        let secret: AgentSecret
        let note = "note"
    }

    // MARK: Never printed

    func testASecretNeverPrints() throws {
        let secret = try XCTUnwrap(AgentSecret(pasted: text))
        var dumped = ""
        dump(secret, to: &dumped)
        var debugged = ""
        debugPrint(secret, to: &debugged)
        var printed = ""
        print(secret, to: &printed)
        let shown = ["\(secret)", String(describing: secret), String(reflecting: secret), dumped, debugged, printed,
                     "\(secret as Any)", secret.description, secret.debugDescription]
        for line in shown {
            XCTAssertFalse(line.contains(text), line)
            XCTAssertTrue(line.contains("AgentSecret(hidden)"), line)
        }
        XCTAssertEqual("\(secret)", "AgentSecret(hidden)")
        XCTAssertEqual(String(reflecting: secret), "AgentSecret(hidden)")
        XCTAssertTrue(Mirror(reflecting: secret).children.isEmpty)
    }

    func testASecretInsideAnotherValueNeverPrints() throws {
        let secret = try XCTUnwrap(AgentSecret(pasted: text))
        let holder = Holder(secret: secret)
        var dumped = ""
        dump(holder, to: &dumped)
        dump([secret], to: &dumped)
        dump(["key": secret], to: &dumped)
        dump(Optional(secret), to: &dumped)
        let shown = ["\(holder)", String(reflecting: holder), "\([secret])", String(reflecting: [secret, secret]),
                     "\(Optional(secret) as Any)", String(describing: ["key": secret]), "\((secret, 1))", dumped]
        for line in shown {
            XCTAssertFalse(line.contains(text), line)
        }
        XCTAssertTrue("\(holder)".contains("AgentSecret(hidden)"))
        XCTAssertTrue(dumped.contains("AgentSecret(hidden)"))
    }

    func testASecretCannotBeSavedComparedOrUsedAsAKey() {
        XCTAssertFalse((AgentSecret.self as Any) is any Encodable.Type)
        XCTAssertFalse((AgentSecret.self as Any) is any Decodable.Type)
        XCTAssertFalse((AgentSecret.self as Any) is any Equatable.Type)
        XCTAssertFalse((AgentSecret.self as Any) is any Hashable.Type)
    }

    // MARK: What a pasted key may be

    func testAPastedKeyIsTrimmed() {
        XCTAssertEqual(AgentSecret(pasted: "  \(text)\n")?.revealSecret(), text)
        XCTAssertEqual(AgentSecret(pasted: "\t\(text) \r\n")?.revealSecret(), text)
        XCTAssertEqual(AgentSecret(pasted: text)?.revealSecret(), text)
        // Every printing ASCII character is allowed.
        let punctuation = "Aa0-_.~+/=:!#$%&*"
        XCTAssertEqual(AgentSecret(pasted: punctuation)?.revealSecret(), punctuation)
    }

    func testAnEmptyKeyIsRefused() {
        XCTAssertNil(AgentSecret(pasted: ""))
        XCTAssertNil(AgentSecret(pasted: "   "))
        XCTAssertNil(AgentSecret(pasted: "\n\t "))
    }

    func testAKeyWithAControlCharacterIsRefused() {
        for hidden in ["\n", "\r", "\r\n", "\t", "\u{0}", "\u{1B}", "\u{7F}", "\u{8}"] {
            XCTAssertNil(AgentSecret(pasted: "first\(hidden)second"), "\(hidden.unicodeScalars.map(\.value))")
        }
        // A line break in a key would start a new header on the request it is put on.
        XCTAssertNil(AgentSecret(pasted: "abc\r\nX-Other: 1"))
    }

    func testAKeyWithACharacterOutsideASCIIIsRefused() {
        for text in ["ключ-для-теста", "kéy-for-tests", "key🙂", "key\u{00A0}more", "key\u{200B}more", "key\u{202E}more", "ｋｅｙ", "key\u{80}"] {
            XCTAssertNil(AgentSecret(pasted: text), text)
        }
    }

    func testAKeyOfMoreThan512CharactersIsRefused() {
        XCTAssertEqual(AgentSecret(pasted: String(repeating: "a", count: 512))?.revealSecret().count, 512)
        XCTAssertNil(AgentSecret(pasted: String(repeating: "a", count: 513)))
        XCTAssertNil(AgentSecret(pasted: String(repeating: "a", count: 10_000)))
        // The length is counted after the space round the key is removed.
        XCTAssertNotNil(AgentSecret(pasted: " " + String(repeating: "a", count: 512) + " "))
    }

    // MARK: Which key is which

    func testTheAccountNamesTheProviderTheHostAndThePort() {
        XCTAssertEqual(AgentSecretID(provider: .claude, host: "api.anthropic.com", port: 443).account, "claude|api.anthropic.com:443")
        XCTAssertEqual(AgentSecretID(provider: .lmStudio, host: "127.0.0.1", port: 1234).account, "lmStudio|127.0.0.1:1234")
        XCTAssertEqual(AgentSecretID(provider: .other, host: "models.example.com", port: 8443).account, "other|models.example.com:8443")
    }

    func testAKeySavedForOneHostIsNotFoundForAnother() throws {
        let store = MemorySecretStore()
        let secret = try XCTUnwrap(AgentSecret(pasted: text))
        let saved = AgentSecretID(provider: .other, host: "models.example.com", port: 443)
        try store.save(secret, for: saved)
        XCTAssertTrue(store.has(saved))
        XCTAssertEqual(try store.secret(for: saved)?.revealSecret(), text)

        let otherHost = AgentSecretID(provider: .other, host: "evil.example.com", port: 443)
        let otherPort = AgentSecretID(provider: .other, host: "models.example.com", port: 8443)
        let otherProvider = AgentSecretID(provider: .openAI, host: "models.example.com", port: 443)
        for id in [otherHost, otherPort, otherProvider] {
            XCTAssertFalse(store.has(id), id.account)
            XCTAssertNil(try store.secret(for: id), id.account)
        }
        XCTAssertEqual(store.accounts, ["other|models.example.com:443"])
    }

    func testAChangedAddressLooksForADifferentKey() throws {
        let store = MemorySecretStore()
        let first = try AgentProviderProfile(id: .other, endpoint: AgentEndpoint(typed: "models.example.com"))
        let second = try AgentProviderProfile(id: .other, endpoint: AgentEndpoint(typed: "evil.example.com"))
        try store.save(try XCTUnwrap(AgentSecret(pasted: text)), for: first.secretID)
        XCTAssertTrue(store.has(first.secretID))
        XCTAssertFalse(store.has(second.secretID))
        XCTAssertNil(try store.secret(for: second.secretID))
    }

    // MARK: The memory store

    func testTheMemoryStoreSavesReplacesAndRemoves() throws {
        let store = MemorySecretStore()
        XCTAssertTrue(store.isMemoryOnly)
        XCTAssertEqual(store.accounts, [])
        let claude = AgentSecretID(provider: .claude, host: "api.anthropic.com", port: 443)
        let grok = AgentSecretID(provider: .grok, host: "api.x.ai", port: 443)
        XCTAssertFalse(store.has(claude))
        XCTAssertNil(try store.secret(for: claude))

        try store.save(try XCTUnwrap(AgentSecret(pasted: "first-stand-in")), for: claude)
        try store.save(try XCTUnwrap(AgentSecret(pasted: "second-stand-in")), for: claude)
        try store.save(try XCTUnwrap(AgentSecret(pasted: "third-stand-in")), for: grok)
        XCTAssertEqual(try store.secret(for: claude)?.revealSecret(), "second-stand-in")
        XCTAssertEqual(store.accounts, ["claude|api.anthropic.com:443", "grok|api.x.ai:443"])

        try store.remove(claude)
        XCTAssertFalse(store.has(claude))
        XCTAssertNil(try store.secret(for: claude))
        XCTAssertTrue(store.has(grok))
        // Removing a key that isn't there is not an error.
        XCTAssertNoThrow(try store.remove(claude))
        XCTAssertEqual(store.accounts, ["grok|api.x.ai:443"])
    }

    func testAStoreThatDeniesStillSaysWhetherAKeyIsSaved() throws {
        let store = MemorySecretStore()
        let id = AgentSecretID(provider: .claude, host: "api.anthropic.com", port: 443)
        try store.save(try XCTUnwrap(AgentSecret(pasted: text)), for: id)
        XCTAssertFalse(store.denies)
        store.denies = true
        XCTAssertTrue(store.denies)
        XCTAssertTrue(store.has(id))
        XCTAssertThrowsError(try store.secret(for: id)) { XCTAssertEqual($0 as? AgentSecretError, .denied) }
        // A refusal is not "no key": a missing key throws as well while the store denies.
        let missing = AgentSecretID(provider: .openAI, host: "api.openai.com", port: 443)
        XCTAssertThrowsError(try store.secret(for: missing)) { XCTAssertEqual($0 as? AgentSecretError, .denied) }
        store.denies = false
        XCTAssertEqual(try store.secret(for: id)?.revealSecret(), text)
    }

    // MARK: Key-shaped text

    func testTextShapedLikeAKeyIsTold() {
        // Built here from parts, so no line of this file is shaped like a key.
        let tail = String(repeating: "aB3", count: 10)
        for prefix in ["sk-", "sk-ant-", "sk-proj-", "xai-", "AIza", "gsk_", "hf_", "pplx-"] {
            XCTAssertTrue(AgentKeyShape.looksLikeKey(prefix + tail), prefix)
            XCTAssertTrue(AgentKeyShape.looksLikeKey("  " + prefix + tail + "\n"), prefix)
        }
        XCTAssertTrue(AgentKeyShape.looksLikeKey("sk-" + String(repeating: "a", count: 17)))
        XCTAssertTrue(AgentKeyShape.looksLikeKey("sk-" + "abc_DEF-123" + String(repeating: "x", count: 20)))
    }

    func testOrdinaryTextIsNotAKey() {
        let tail = String(repeating: "aB3", count: 10)
        XCTAssertFalse(AgentKeyShape.looksLikeKey(""))
        XCTAssertFalse(AgentKeyShape.looksLikeKey("sk-" + String(repeating: "a", count: 16)), "19 characters")
        XCTAssertFalse(AgentKeyShape.looksLikeKey("sk-short"))
        XCTAssertFalse(AgentKeyShape.looksLikeKey("key-" + tail), "not a provider's prefix")
        XCTAssertFalse(AgentKeyShape.looksLikeKey(tail))
        XCTAssertFalse(AgentKeyShape.looksLikeKey("SK-" + tail), "the prefix is in lower case")
        XCTAssertFalse(AgentKeyShape.looksLikeKey("sk-" + tail + " and more"), "two words")
        XCTAssertFalse(AgentKeyShape.looksLikeKey("my key is sk-" + tail))
        XCTAssertFalse(AgentKeyShape.looksLikeKey("sk-" + "my-notes-from-2026-final.txt"), "a file's name")
        XCTAssertFalse(AgentKeyShape.looksLikeKey("organize my downloads folder by kind"))
        XCTAssertFalse(AgentKeyShape.looksLikeKey("skiing-photos-from-the-alps-2026"))
    }
}
