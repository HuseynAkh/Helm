import XCTest
import HelmCore
@testable import HelmAgent

/// Where requests may go: a provider's fixed address, a port on this Mac, or an https host name the person typed.
/// Every other spelling of an address is refused, and none of them is ever taken for this Mac.
final class AgentEndpointTests: XCTestCase {
    private func refusal(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> AgentEndpointRefusal? {
        do {
            let endpoint = try AgentEndpoint(typed: text)
            XCTFail("\(text) was taken as \(endpoint.hostAndPort)", file: file, line: line)
            return nil
        } catch let refusal as AgentEndpointRefusal {
            return refusal
        } catch {
            XCTFail("\(text) threw \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: Fixed

    func testTheFourFixedAddresses() throws {
        let claude = try AgentEndpoint(fixed: .claude)
        XCTAssertEqual(claude.host, "api.anthropic.com")
        XCTAssertEqual(claude.port, 443)
        XCTAssertEqual(claude.basePath, "")
        XCTAssertTrue(claude.isSecure)
        XCTAssertFalse(claude.isLoopback)
        XCTAssertEqual(claude.hostLabel, "api.anthropic.com")
        XCTAssertEqual(claude.hostAndPort, "api.anthropic.com:443")

        let openAI = try AgentEndpoint(fixed: .openAI)
        XCTAssertEqual([openAI.host, openAI.basePath], ["api.openai.com", "/v1"])
        let gemini = try AgentEndpoint(fixed: .gemini)
        XCTAssertEqual([gemini.host, gemini.basePath], ["generativelanguage.googleapis.com", "/v1beta"])
        let grok = try AgentEndpoint(fixed: .grok)
        XCTAssertEqual([grok.host, grok.basePath], ["api.x.ai", "/v1"])
        for endpoint in [openAI, gemini, grok] {
            XCTAssertEqual(endpoint.port, 443)
            XCTAssertTrue(endpoint.isSecure)
            XCTAssertFalse(endpoint.isLoopback)
        }
    }

    func testAProviderWithoutAnAddressOfItsOwnIsNotFixed() {
        for provider in [AgentProviderID.ollama, .lmStudio, .other] {
            XCTAssertThrowsError(try AgentEndpoint(fixed: provider)) { XCTAssertEqual($0 as? AgentEndpointRefusal, .notFixed) }
        }
    }

    func testTheFixedAddressesAreTheOnlyOnesWritten() {
        XCTAssertEqual(AgentProviderCatalog.claudeBase, "https://api.anthropic.com")
        XCTAssertEqual(AgentProviderCatalog.openAIBase, "https://api.openai.com/v1")
        XCTAssertEqual(AgentProviderCatalog.geminiBase, "https://generativelanguage.googleapis.com/v1beta")
        XCTAssertEqual(AgentProviderCatalog.grokBase, "https://api.x.ai/v1")
    }

    // MARK: This Mac

    func testALocalPortIsPlainHTTPToThisMac() throws {
        let endpoint = try AgentEndpoint(localPort: 11434)
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(endpoint.port, 11434)
        XCTAssertEqual(endpoint.basePath, "")
        XCTAssertFalse(endpoint.isSecure)
        XCTAssertTrue(endpoint.isLoopback)
        XCTAssertEqual(endpoint.hostAndPort, "127.0.0.1:11434")
        XCTAssertNoThrow(try AgentEndpoint(localPort: 1024))
        XCTAssertNoThrow(try AgentEndpoint(localPort: 65535))
    }

    func testAPortOutsideTheRangeIsRefused() {
        for port in [-1, 0, 1, 80, 443, 1023, 65536, 100_000, Int.max, Int.min] {
            XCTAssertThrowsError(try AgentEndpoint(localPort: port), "\(port)") { XCTAssertEqual($0 as? AgentEndpointRefusal, .badPort) }
        }
    }

    // MARK: Typed

    func testATypedHTTPSHostIsTaken() throws {
        let plain = try AgentEndpoint(typed: "https://models.example.com")
        XCTAssertEqual(plain.host, "models.example.com")
        XCTAssertEqual(plain.port, 443)
        XCTAssertEqual(plain.basePath, "")
        XCTAssertTrue(plain.isSecure)
        XCTAssertFalse(plain.isLoopback)

        // The scheme may be left out, as the address is kept in ai.json.
        let bare = try AgentEndpoint(typed: "models.example.com/v1")
        XCTAssertEqual([bare.host, bare.basePath], ["models.example.com", "/v1"])
        XCTAssertEqual(bare.port, 443)
        XCTAssertTrue(bare.isSecure)
        XCTAssertEqual(try AgentEndpoint(typed: "models.example.com:8443/v1"), try AgentEndpoint(typed: "https://models.example.com:8443/v1"))

        // Upper case, a port, a slash at the end and space round it all.
        let loud = try AgentEndpoint(typed: "  HTTPS://Models.Example.COM:8443/v1/  ")
        XCTAssertEqual(loud.host, "models.example.com")
        XCTAssertEqual(loud.port, 8443)
        XCTAssertEqual(loud.basePath, "/v1")
        XCTAssertEqual(loud.hostAndPort, "models.example.com:8443")
        XCTAssertEqual(try AgentEndpoint(typed: "https://example.com/").basePath, "")
        XCTAssertEqual(try AgentEndpoint(typed: "https://openrouter.ai/api/v1").basePath, "/api/v1")
        XCTAssertEqual(try AgentEndpoint(typed: "https://my-models.example.co.uk").host, "my-models.example.co.uk")
    }

    func testAnythingButHTTPSNeedsHTTPS() {
        for text in ["http://models.example.com", "HTTP://models.example.com/v1", "http://127.0.0.1:11434", "http://localhost:1234",
                     "ftp://models.example.com", "ws://models.example.com", "wss://models.example.com", "file:///home/helm/x",
                     "smb://nas.local/share", "javascript://models.example.com", "://models.example.com"] {
            XCTAssertEqual(refusal(text), .needsHTTPS, text)
        }
    }

    /// Other spellings of this Mac, and names that only look like it. None is loopback, and none is plain http.
    func testTrickSpellingsOfThisMacAreNeverLoopback() throws {
        // A name in front of an "@" is an account, not a host: the host here is evil.example.
        XCTAssertEqual(refusal("https://127.0.0.1@evil.example/"), .hasCredentials)
        XCTAssertEqual(refusal("http://127.0.0.1@evil.example/"), .needsHTTPS)
        XCTAssertEqual(refusal("https://localhost@evil.example"), .hasCredentials)
        XCTAssertEqual(refusal("127.0.0.1@evil.example"), .hasCredentials)

        // A host that only starts or ends like this Mac is some other host, reached by https like any other.
        for text in ["https://localhost.evil.example", "https://127.0.0.1.evil.example", "https://evil.example.localhost.example"] {
            let endpoint = try AgentEndpoint(typed: text)
            XCTAssertFalse(endpoint.isLoopback, text)
            XCTAssertTrue(endpoint.isSecure, text)
            XCTAssertEqual("https://" + endpoint.host, text)
        }

        // Spellings of an IP address that some resolvers read as this Mac.
        for text in ["https://127.0.0.1", "https://127.0.0.1:11434", "https://127.1", "https://0x7f.0.0.1", "https://0x7f.0.0.0x1",
                     "https://2130706433", "https://0x7f000001", "https://0177.0.0.1", "https://0.0.0.0", "https://127.000.000.001",
                     "127.0.0.1", "127.0.0.1:1234/v1"] {
            XCTAssertEqual(refusal(text), .otherDevice, text)
        }
        // The link-local address a cloud machine keeps its own keys at, and addresses on a home network.
        for text in ["https://169.254.169.254", "https://10.0.0.5", "https://192.168.1.20:8080", "https://172.16.0.1/v1", "https://8.8.8.8"] {
            XCTAssertEqual(refusal(text), .otherDevice, text)
        }
        // The name of this Mac, in any case.
        for text in ["https://localhost", "https://LOCALHOST", "https://LocalHost:8080/v1", "localhost", "localhost:11434"] {
            XCTAssertEqual(refusal(text), .otherDevice, text)
        }
        // A dot at the end names the same host, so it is refused too.
        for text in ["https://localhost.", "https://models.example.com.", "https://127.0.0.1."] {
            XCTAssertNotNil(refusal(text), text)
        }
    }

    func testEveryIPv6AddressIsRefused() {
        for text in ["https://[::1]", "https://[::1]:8080/v1", "https://[0:0:0:0:0:0:0:1]", "https://[::ffff:127.0.0.1]",
                     "https://[::ffff:7f00:1]", "https://[fe80::1]", "https://[fe80::1%25en0]", "https://[::]",
                     "https://[2001:db8::1]", "[::1]", "[::1]:11434", "::1"] {
            XCTAssertNotNil(refusal(text), text)
        }
        XCTAssertEqual(refusal("https://[::1]"), .otherDevice)
        XCTAssertEqual(refusal("https://[::ffff:127.0.0.1]:8080"), .otherDevice)
        XCTAssertEqual(refusal("https://[fe80::1]"), .otherDevice)
    }

    func testAOneWordHostAndALocalNameAreOtherDevices() {
        for text in ["https://nas", "https://ollama:11434", "https://studio", "nas", "https://studio.local", "https://Mac-Studio.LOCAL:8080",
                     "studio.local/v1", "https://api.localhost", "https://models.internal.local"] {
            XCTAssertEqual(refusal(text), .otherDevice, text)
        }
    }

    func testANameOrAPasswordIsRefused() {
        for text in ["https://user@models.example.com", "https://user:pass@models.example.com", "https://:pass@models.example.com",
                     "user:pass@models.example.com/v1"] {
            XCTAssertEqual(refusal(text), .hasCredentials, text)
        }
    }

    func testAQueryOrAFragmentIsRefused() {
        for text in ["https://models.example.com/v1?key=abc", "https://models.example.com?", "https://models.example.com/#frag",
                     "https://models.example.com/v1#", "models.example.com/v1?x=1"] {
            XCTAssertEqual(refusal(text), .hasQueryOrFragment, text)
        }
    }

    func testABadPortIsRefused() {
        XCTAssertEqual(refusal("https://models.example.com:0"), .badPort)
        for text in ["https://models.example.com:65536", "https://models.example.com:99999", "https://models.example.com:abc",
                     "https://models.example.com:-1"] {
            XCTAssertNotNil(refusal(text), text)
        }
        XCTAssertEqual(try AgentEndpoint(typed: "https://models.example.com:65535").port, 65535)
        XCTAssertEqual(try AgentEndpoint(typed: "https://models.example.com:1").port, 1)
        // A colon with no number after it names no port, so the usual one is used.
        XCTAssertEqual(try AgentEndpoint(typed: "https://models.example.com:").port, 443)
    }

    func testTextThatIsNotAnAddressIsRefused() {
        for text in ["", "   ", "\n", "https://", "https:///v1", "models example.com", "https://models.example.com/a b",
                     "https://exa_mple.example.com", "https://-bad.example.com", "https://bad-.example.com", "https://a..example.com",
                     "https://.example.com", "https://models.example.com\\@evil.example", "https://models.example.com/v1/../admin",
                     "https://models.example.com/./v1", "https://models.example.com//v1", "https://models.example.com/a%2Fb",
                     "https://exam%70le.com", "https://models.example.com/v1\u{0}", "https://models.\u{202E}example.com",
                     "https://models.\u{200B}example.com", "https://" + String(repeating: "a", count: 64) + ".example.com",
                     "https://" + String(repeating: "a.", count: 130) + "com", String(repeating: "a", count: 3_000) + ".example.com"] {
            XCTAssertNotNil(refusal(text), text.prefix(60).description)
        }
        XCTAssertEqual(refusal(""), .notAnAddress)
        XCTAssertEqual(refusal("https://models.example.com/v1/../admin"), .notAnAddress)
        XCTAssertEqual(refusal("https://exa_mple.example.com"), .notAnAddress)
    }

    func testANameWithOtherLettersIsShownInASCII() throws {
        // Already encoded: taken as it is.
        XCTAssertEqual(try AgentEndpoint(typed: "https://xn--bcher-kva.example").hostLabel, "xn--bcher-kva.example")
        XCTAssertEqual(try AgentEndpoint(typed: "https://models.xn--p1ai").host, "models.xn--p1ai")
        // Typed with the letter itself: taken in its encoded form or refused, and never kept as typed.
        if let endpoint = try? AgentEndpoint(typed: "https://bücher.example") {
            XCTAssertEqual(endpoint.host, "xn--bcher-kva.example")
            XCTAssertTrue(endpoint.hostLabel.unicodeScalars.allSatisfy(\.isASCII))
        }
        // A look-alike of "example" written with a Cyrillic letter is not "example".
        if let endpoint = try? AgentEndpoint(typed: "https://models.ex\u{0430}mple.com") {
            XCTAssertNotEqual(endpoint.host, "models.example.com")
            XCTAssertTrue(endpoint.hostLabel.unicodeScalars.allSatisfy(\.isASCII))
        }
    }

    func testAnEndpointCannotBeLoadedFromAFile() {
        XCTAssertFalse((AgentEndpoint.self as Any) is any Decodable.Type)
        XCTAssertFalse((AgentEndpoint.self as Any) is any Encodable.Type)
        XCTAssertFalse((AgentProviderProfile.self as Any) is any Decodable.Type)
    }

    // MARK: Profiles and the catalog

    func testProfilesSayWhereRequestsGo() throws {
        let claude = AgentProviderProfile(id: .claude, endpoint: try AgentEndpoint(fixed: .claude))
        XCTAssertEqual(claude.name, "Claude")
        XCTAssertEqual(claude.destination, "Claude")
        XCTAssertEqual(claude.wire, .anthropicMessages)
        XCTAssertFalse(claude.isLocal)
        XCTAssertTrue(claude.needsKey)
        XCTAssertEqual(claude.secretID.account, "claude|api.anthropic.com:443")

        let ollama = AgentProviderProfile(id: .ollama, endpoint: try AgentEndpoint(localPort: 11434))
        XCTAssertEqual(ollama.destination, "Ollama on this Mac")
        XCTAssertTrue(ollama.isLocal)
        XCTAssertFalse(ollama.needsKey)
        XCTAssertEqual(ollama.secretID.account, "ollama|127.0.0.1:11434")

        let studio = AgentProviderProfile(id: .lmStudio, endpoint: try AgentEndpoint(localPort: 1234))
        XCTAssertEqual(studio.name, "LM Studio")
        XCTAssertEqual(studio.destination, "LM Studio on this Mac")
        XCTAssertTrue(studio.isLocal)
        XCTAssertFalse(studio.needsKey)

        let other = AgentProviderProfile(id: .other, endpoint: try AgentEndpoint(typed: "https://Models.Example.com/v1"))
        XCTAssertEqual(other.name, "Other")
        XCTAssertEqual(other.destination, "models.example.com")
        XCTAssertEqual(other.wire, .chatCompletions)
        XCTAssertFalse(other.isLocal)
        XCTAssertFalse(other.needsKey)
        XCTAssertEqual(other.secretID.account, "other|models.example.com:443")
    }

    func testTheCatalogsFixedFacts() {
        XCTAssertEqual(AgentProviderID.allCases.map(AgentProviderCatalog.name),
                       ["Claude", "OpenAI", "Gemini", "Grok", "Ollama", "LM Studio", "Other"])
        XCTAssertEqual(AgentProviderID.allCases.map(\.rawValue), ["claude", "openAI", "gemini", "grok", "ollama", "lmStudio", "other"])
        XCTAssertEqual(AgentProviderID.allCases.map(AgentProviderCatalog.wire),
                       [.anthropicMessages, .openAIResponses, .chatCompletions, .openAIResponses, .chatCompletions,
                        .chatCompletions, .chatCompletions])
        XCTAssertEqual(AgentProviderID.allCases.map(AgentProviderCatalog.defaultModel),
                       ["claude-opus-5-5", "gpt-6-astra", "gemini-4-hydrogen", "grok-4.7", nil, nil, nil])
        XCTAssertEqual(AgentProviderID.allCases.map(AgentProviderCatalog.defaultPort), [nil, nil, nil, nil, 11434, 1234, nil])
    }

    func testEveryRouteOfEveryProvider() throws {
        func profile(_ id: AgentProviderID) throws -> AgentProviderProfile {
            let config = AIConfig(provider: id.rawValue, otherAddress: "models.example.com")
            return try AgentProviderCatalog.profile(for: config).get()
        }
        func route(_ id: AgentProviderID, _ route: AgentRoute) throws -> AgentRouteSpec? {
            AgentProviderCatalog.route(route, for: try profile(id))
        }
        XCTAssertEqual(try route(.claude, .chat), AgentRouteSpec(method: "POST", path: "/v1/messages", auth: .xAPIKey))
        XCTAssertEqual(try route(.claude, .models), AgentRouteSpec(method: "GET", path: "/v1/models", query: ["limit": "1000"], auth: .xAPIKey))
        XCTAssertEqual(try route(.openAI, .chat), AgentRouteSpec(method: "POST", path: "/responses", auth: .bearer))
        XCTAssertEqual(try route(.openAI, .models), AgentRouteSpec(method: "GET", path: "/models", auth: .bearer))
        XCTAssertEqual(try route(.grok, .chat), AgentRouteSpec(method: "POST", path: "/responses", auth: .bearer))
        XCTAssertEqual(try route(.grok, .models), AgentRouteSpec(method: "GET", path: "/language-models", auth: .bearer))
        XCTAssertEqual(try route(.gemini, .chat), AgentRouteSpec(method: "POST", path: "/openai/chat/completions", auth: .bearer))
        XCTAssertEqual(try route(.gemini, .models), AgentRouteSpec(method: "GET", path: "/models", query: ["pageSize": "1000"], auth: .googAPIKey))
        XCTAssertEqual(try route(.ollama, .chat), AgentRouteSpec(method: "POST", path: "/v1/chat/completions", auth: AgentAuthStyle.none))
        XCTAssertEqual(try route(.ollama, .models), AgentRouteSpec(method: "GET", path: "/api/tags", auth: AgentAuthStyle.none))
        XCTAssertEqual(try route(.lmStudio, .chat), AgentRouteSpec(method: "POST", path: "/v1/chat/completions", auth: .bearer))
        XCTAssertEqual(try route(.lmStudio, .models), AgentRouteSpec(method: "GET", path: "/v1/models", auth: .bearer))
        XCTAssertEqual(try route(.other, .chat), AgentRouteSpec(method: "POST", path: "/chat/completions", auth: .bearer))
        XCTAssertEqual(try route(.other, .models), AgentRouteSpec(method: "GET", path: "/models", auth: .bearer))
        XCTAssertEqual(try route(.other, .modelsAlternate), AgentRouteSpec(method: "GET", path: "/v1/models", auth: .bearer))
        for id in AgentProviderID.allCases where id != .other {
            XCTAssertNil(try route(id, .modelsAlternate), id.rawValue)
        }
        // No route carries a key in its address.
        for id in AgentProviderID.allCases {
            for kind in [AgentRoute.chat, .models, .modelsAlternate] {
                guard let spec = try route(id, kind) else { continue }
                XCTAssertTrue(spec.path.hasPrefix("/"))
                XCTAssertFalse(spec.query.keys.contains { $0.lowercased().contains("key") }, "\(id) \(kind)")
            }
        }
    }

    func testOnlyClaudeHasFixedHeaders() throws {
        for id in AgentProviderID.allCases {
            let profile = try AgentProviderCatalog.profile(for: AIConfig(provider: id.rawValue, otherAddress: "models.example.com")).get()
            XCTAssertEqual(AgentProviderCatalog.fixedHeaders(for: profile), id == .claude ? ["anthropic-version": "2026-10-21"] : [:])
        }
    }

    func testTheProfileAConfigChooses() throws {
        XCTAssertEqual(AgentProviderCatalog.profile(for: AIConfig()), .failure(.notAnAddress))
        XCTAssertEqual(AgentProviderCatalog.profile(for: AIConfig(provider: "mystery")), .failure(.notAnAddress))
        XCTAssertEqual(try AgentProviderCatalog.profile(for: AIConfig(provider: "claude")).get().endpoint, try AgentEndpoint(fixed: .claude))

        // A local provider is its port: the one saved, else the usual one.
        XCTAssertEqual(try AgentProviderCatalog.profile(for: AIConfig(provider: "ollama")).get().endpoint.port, 11434)
        XCTAssertEqual(try AgentProviderCatalog.profile(for: AIConfig(provider: "lmStudio")).get().endpoint.port, 1234)
        let moved = AIConfig(provider: "ollama", ports: ["ollama": 11500, "lmStudio": 4321])
        XCTAssertEqual(try AgentProviderCatalog.profile(for: moved).get().endpoint.hostAndPort, "127.0.0.1:11500")
        XCTAssertEqual(AgentProviderCatalog.profile(for: AIConfig(provider: "ollama", ports: ["ollama": 80])), .failure(.badPort))

        // A typed provider is its address, held to the same rules as when it was typed. A fixed provider never reads it.
        XCTAssertEqual(AgentProviderCatalog.profile(for: AIConfig(provider: "other")), .failure(.notAnAddress))
        XCTAssertEqual(AgentProviderCatalog.profile(for: AIConfig(provider: "other", otherAddress: "192.168.1.20")), .failure(.otherDevice))
        XCTAssertEqual(AgentProviderCatalog.profile(for: AIConfig(provider: "other", otherAddress: "http://models.example.com")),
                       .failure(.needsHTTPS))
        XCTAssertEqual(AgentProviderCatalog.profile(for: AIConfig(provider: "other", otherAddress: "u:p@models.example.com")),
                       .failure(.hasCredentials))
        let other = try AgentProviderCatalog.profile(for: AIConfig(provider: "other", otherAddress: "models.example.com/v1")).get()
        XCTAssertEqual(other.endpoint.hostAndPort, "models.example.com:443")
        XCTAssertEqual(other.endpoint.basePath, "/v1")
        let claude = try AgentProviderCatalog.profile(for: AIConfig(provider: "claude", otherAddress: "evil.example.com")).get()
        XCTAssertEqual(claude.endpoint.host, "api.anthropic.com")
    }

    func testTheModelAConfigChooses() {
        XCTAssertNil(AgentProviderCatalog.model(for: AIConfig()))
        XCTAssertEqual(AgentProviderCatalog.model(for: AIConfig(provider: "claude")), "claude-opus-5-5")
        XCTAssertEqual(AgentProviderCatalog.model(for: AIConfig(provider: "claude", models: ["claude": "claude-haiku-5-5"])), "claude-haiku-5-5")
        // Another provider's saved model isn't this provider's.
        XCTAssertEqual(AgentProviderCatalog.model(for: AIConfig(provider: "openAI", models: ["claude": "claude-haiku-5-5"])), "gpt-6-astra")
        XCTAssertNil(AgentProviderCatalog.model(for: AIConfig(provider: "ollama")))
        XCTAssertEqual(AgentProviderCatalog.model(for: AIConfig(provider: "ollama", models: ["ollama": "llama3.2:latest"])), "llama3.2:latest")
        // A name no provider could have listed is no model.
        XCTAssertNil(AgentProviderCatalog.model(for: AIConfig(provider: "other", models: ["other": "two words"])))
        XCTAssertNil(AgentProviderCatalog.model(for: AIConfig(provider: "other", models: ["other": ""])))
    }

    func testAModelsIDIsHeldToItsCharacters() {
        XCTAssertEqual(AgentModelInfo(id: "claude-opus-5-5")?.id, "claude-opus-5-5")
        XCTAssertNotNil(AgentModelInfo(id: "models/gemini-4-hydrogen"))
        XCTAssertNotNil(AgentModelInfo(id: "llama3.2:latest"))
        XCTAssertNotNil(AgentModelInfo(id: "Org_Name/model.v2"))
        XCTAssertNotNil(AgentModelInfo(id: String(repeating: "a", count: 128)))
        for id in ["", " ", "two words", "new\nline", "tab\there", "quote\"d", "back\\slash", "naïve", "emoji🙂", "a<b", "a@b", "a,b", "a;b",
                   "a\u{200B}b", String(repeating: "a", count: 129)] {
            XCTAssertNil(AgentModelInfo(id: id), id)
        }
        XCTAssertEqual(AgentModelInfo.listCap, 500)
    }
}
