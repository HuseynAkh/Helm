import XCTest
@testable import HelmAgent

/// The transport with a stub loader in front of the network: what it sends, what it refuses and where it stops.
/// Nothing here reaches a real host.
final class HTTPTransportStubTests: XCTestCase {
    private typealias T = AgentTransportTesting

    override func tearDown() {
        AgentStubLoader.reset { _ in [.fail(.cannotConnectToHost)] }
        super.tearDown()
    }

    private func transport(_ profile: AgentProviderProfile, secrets: any AgentSecretStoring = MemorySecretStore(),
                           limits: AgentTransportLimits = AgentTransportTesting.roomy) -> HTTPTransport {
        HTTPTransport(liveProfile: profile, secrets: secrets, limits: limits, testProtocols: [AgentStubLoader.self])
    }

    private func store(with key: String = AgentTransportTesting.key, for profile: AgentProviderProfile) throws -> MemorySecretStore {
        let store = MemorySecretStore()
        try store.save(T.secret(key), for: profile.secretID)
        return store
    }

    /// The status line of a streamed reply. A reply with no type would be held back until 512 bytes arrived, while the
    /// system guesses its type, so every streamed reply here says what it is, as providers' replies do.
    private static let streaming = AgentStubLoader.Step.respond(status: 200, headers: ["Content-Type": "text/event-stream"],
                                                                from: nil)

    /// An event stream that answers 200 with `body` and ends.
    private static func ok(_ body: String, headers: [String: String] = [:]) -> [AgentStubLoader.Step] {
        [.respond(status: 200, headers: ["Content-Type": "text/event-stream"].merging(headers) { $1 }, from: nil),
         .send(Data(body.utf8)), .finish]
    }

    // MARK: Where a request goes and what it carries

    func testAStreamGoesToTheRoutesAddressWithTheKeyInItsHeader() async throws {
        let profile = try T.claude()
        AgentStubLoader.reset { _ in Self.ok("event: ping\ndata: {\"type\":\"ping\"}\n\n") }
        let body = T.data("{\"model\":\"claude-opus-5-5\"}")
        let outcome = await T.drain(transport(profile, secrets: try store(for: profile)).stream(.chat, body: body))

        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.lines, ["event: ping", "data: {\"type\":\"ping\"}", ""])
        let seen = try XCTUnwrap(AgentStubLoader.seen.first)
        XCTAssertEqual(AgentStubLoader.seen.count, 1)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(seen.body, body)
        XCTAssertEqual(seen.header("x-api-key"), T.key)
        XCTAssertEqual(seen.header("anthropic-version"), "2026-10-21")
        XCTAssertEqual(seen.header("Content-Type"), "application/json")
        XCTAssertNil(seen.header("Authorization"))
        XCTAssertNil(seen.header("x-goog-api-key"))
    }

    func testNoOriginCookieOrSystemDetailsAreSent() async throws {
        let profile = try T.other()
        AgentStubLoader.reset { _ in Self.ok("data: one\n") }
        _ = await T.drain(transport(profile).stream(.chat, body: T.data("{}")))
        let seen = try XCTUnwrap(AgentStubLoader.seen.first)
        XCTAssertNil(seen.header("Origin"))
        XCTAssertNil(seen.header("Referer"))
        XCTAssertNil(seen.header("Cookie"))
        XCTAssertEqual(seen.header("User-Agent"), "Helm")
        XCTAssertEqual(seen.header("Accept-Language"), "en")
    }

    func testACookieIsNeverSentBack() async throws {
        let profile = try T.other()
        let transport = transport(profile)
        AgentStubLoader.reset { _ in
            [.respond(status: 200, headers: ["Set-Cookie": "session=abc123; Path=/; Secure", "Content-Type": "application/json"],
                      from: nil), .send(T.data("{}")), .finish]
        }
        _ = try await transport.fetch(.models)
        _ = try await transport.fetch(.models)
        _ = await T.drain(transport.stream(.chat, body: T.data("{}")))
        XCTAssertEqual(AgentStubLoader.seen.count, 3)
        for seen in AgentStubLoader.seen {
            XCTAssertNil(seen.header("Cookie"), seen.url.absoluteString)
        }
        let configuration = transport.sessionConfiguration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    }

    func testTheSessionKeepsNothing() throws {
        let configuration = transport(try T.claude(), limits: .cloud).sessionConfiguration
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 120)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 900)
        XCTAssertEqual(configuration.httpAdditionalHeaders?["User-Agent"] as? String, "Helm")
        XCTAssertEqual(configuration.httpAdditionalHeaders?["Accept-Language"] as? String, "en")
        XCTAssertEqual(configuration.httpAdditionalHeaders?.count, 2)
        let local = transport(try T.ollama(), limits: .local).sessionConfiguration
        XCTAssertEqual(local.timeoutIntervalForRequest, 300)
    }

    func testALoopbackProfilesSessionHasAnEmptyProxyDictionary() throws {
        for profile in [try T.ollama(), try T.lmStudio(), try T.ollama(port: 40_000)] {
            let proxies = transport(profile).sessionConfiguration.connectionProxyDictionary
            XCTAssertNotNil(proxies, profile.endpoint.hostAndPort)
            XCTAssertEqual(proxies?.count, 0, profile.endpoint.hostAndPort)
        }
        // A provider on the internet goes the way the system's settings say.
        for profile in [try T.claude(), try T.other()] {
            XCTAssertNil(transport(profile).sessionConfiguration.connectionProxyDictionary, profile.endpoint.hostAndPort)
        }
    }

    func testEachProvidersKeyGoesInItsOwnHeader() async throws {
        AgentStubLoader.reset { _ in [Self.streaming, .send(T.data("{}")), .finish] }
        let openAI = try T.openAI()
        _ = try await transport(openAI, secrets: try store(for: openAI)).fetch(.models)
        let gemini = try T.gemini()
        _ = try await transport(gemini, secrets: try store(for: gemini)).fetch(.models)
        _ = await T.drain(transport(gemini, secrets: try store(for: gemini)).stream(.chat, body: T.data("{}")))

        let seen = AgentStubLoader.seen
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(seen[0].url.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(seen[0].method, "GET")
        XCTAssertEqual(seen[0].header("Authorization"), "Bearer " + T.key)
        XCTAssertNil(seen[0].header("x-api-key"))
        XCTAssertEqual(seen[1].url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")
        XCTAssertEqual(seen[1].header("x-goog-api-key"), T.key)
        XCTAssertNil(seen[1].header("Authorization"))
        XCTAssertEqual(seen[2].url.absoluteString, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(seen[2].header("Authorization"), "Bearer " + T.key)
        XCTAssertNil(seen[2].header("x-goog-api-key"))
    }

    func testTheKeyHeaderIsThereForTheBoundHostAndAbsentWithNoKey() async throws {
        AgentStubLoader.reset { _ in Self.ok("data: one\n") }
        let bound = try T.other("models.example.com")
        _ = await T.drain(transport(bound, secrets: try store(for: bound)).stream(.chat, body: T.data("{}")))
        // The same key saved for another host is not this host's key.
        let elsewhere = try T.other("evil.example.com")
        _ = await T.drain(transport(elsewhere, secrets: try store(for: bound)).stream(.chat, body: T.data("{}")))
        // No key saved at all.
        _ = await T.drain(transport(bound).stream(.chat, body: T.data("{}")))

        let seen = AgentStubLoader.seen
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(seen[0].url.absoluteString, "https://models.example.com/chat/completions")
        XCTAssertEqual(seen[0].header("Authorization"), "Bearer " + T.key)
        XCTAssertEqual(seen[1].url.absoluteString, "https://evil.example.com/chat/completions")
        XCTAssertNil(seen[1].header("Authorization"))
        XCTAssertNil(seen[2].header("Authorization"))
        for request in seen {
            XCTAssertFalse(request.headers.values.contains { $0.contains(T.key) } && request.url.host != "models.example.com")
        }
    }

    func testAProviderThatNeedsAKeySendsNothingWithoutOne() async throws {
        AgentStubLoader.reset { _ in Self.ok("data: one\n") }
        let outcome = await T.drain(transport(try T.claude()).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .noKey)
        await XCTAssertThrowsTransport(.noKey) { _ = try await self.transport(try T.gemini()).fetch(.models) }
        XCTAssertEqual(AgentStubLoader.seen.count, 0)
    }

    func testARefusedKeyIsDeniedNotMissing() async throws {
        let profile = try T.claude()
        let secrets = try store(for: profile)
        secrets.denies = true
        AgentStubLoader.reset { _ in Self.ok("data: one\n") }
        let outcome = await T.drain(transport(profile, secrets: secrets).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .keyDenied)
        XCTAssertEqual(AgentStubLoader.seen.count, 0)
    }

    func testACloudKeyIsRefusedOnALoopbackEndpoint() async throws {
        // A cloud provider pointed at this Mac, with a key saved for exactly that address.
        let profile = AgentProviderProfile(id: .claude, endpoint: try AgentEndpoint(localPort: 8080))
        let secrets = AgentCountingSecretStore()
        try secrets.save(T.secret(), for: profile.secretID)
        AgentStubLoader.reset { _ in Self.ok("data: one\n") }
        let outcome = await T.drain(transport(profile, secrets: secrets).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .insecure)
        await XCTAssertThrowsTransport(.insecure) { _ = try await self.transport(profile, secrets: secrets).fetch(.models) }
        XCTAssertEqual(AgentStubLoader.seen.count, 0)
        XCTAssertEqual(secrets.secretAsks, 0, "the key isn't even read")
    }

    func testALocalServersOwnTokenGoesOverLoopback() async throws {
        let profile = try T.lmStudio()
        AgentStubLoader.reset { _ in Self.ok("data: one\n") }
        _ = await T.drain(transport(profile, secrets: try store(for: profile)).stream(.chat, body: T.data("{}")))
        let seen = try XCTUnwrap(AgentStubLoader.seen.first)
        XCTAssertEqual(seen.url.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
        XCTAssertEqual(seen.header("Authorization"), "Bearer " + T.key)
    }

    func testAProviderWithNoKeyHeaderNeverAsksTheStore() async throws {
        let profile = try T.ollama()
        let secrets = AgentCountingSecretStore()
        try secrets.save(T.secret(), for: profile.secretID)
        AgentStubLoader.reset { _ in Self.ok("data: one\n") }
        _ = await T.drain(transport(profile, secrets: secrets).stream(.chat, body: T.data("{}")))
        _ = try await transport(profile, secrets: secrets).fetch(.models)
        XCTAssertEqual(AgentStubLoader.seen.map(\.url.absoluteString),
                       ["http://127.0.0.1:11434/v1/chat/completions", "http://127.0.0.1:11434/api/tags"])
        XCTAssertNil(AgentStubLoader.seen[0].header("Authorization"))
        XCTAssertEqual(secrets.presenceAsks + secrets.secretAsks, 0)
    }

    func testTheKeyIsReadOnceAndForgottenAtShutdown() async throws {
        let profile = try T.claude()
        let secrets = AgentCountingSecretStore()
        try secrets.save(T.secret(), for: profile.secretID)
        let transport = transport(profile, secrets: secrets)
        XCTAssertEqual(secrets.secretAsks, 0, "nothing is read before a request")
        AgentStubLoader.reset { _ in Self.ok("data: one\n") }
        for _ in 0..<3 { _ = await T.drain(transport.stream(.chat, body: T.data("{}"))) }
        _ = try await transport.fetch(.models)
        XCTAssertEqual(secrets.secretAsks, 1)
        XCTAssertEqual(AgentStubLoader.seen.count, 4)

        await transport.shutdown()
        let after = await T.drain(transport.stream(.chat, body: T.data("{}")))
        XCTAssertEqual(after.failure, .cancelled)
        await XCTAssertThrowsTransport(.cancelled) { _ = try await transport.fetch(.models) }
        XCTAssertEqual(AgentStubLoader.seen.count, 4)
        XCTAssertEqual(secrets.secretAsks, 1)
    }

    func testPreparingReadsTheKeyBeforeAnyRequestAndTheRequestCarriesIt() async throws {
        let profile = try T.claude()
        let secrets = AgentCountingSecretStore()
        try secrets.save(T.secret(), for: profile.secretID)
        let transport = transport(profile, secrets: secrets)
        AgentStubLoader.reset { _ in Self.ok("data: one\n") }
        try await transport.prepareKey()
        XCTAssertEqual(secrets.secretAsks, 1, "read before any request")
        XCTAssertEqual(AgentStubLoader.seen.count, 0, "and nothing sent")
        let outcome = await T.drain(transport.stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.lines, ["data: one"])
        XCTAssertEqual(secrets.secretAsks, 1, "the request carries the key already read")
        await transport.shutdown()
        await XCTAssertThrowsTransport(.cancelled) { try await transport.prepareKey() }
        XCTAssertEqual(secrets.secretAsks, 1)
    }

    func testPreparingReadsNothingWhereNoKeyGoes() async throws {
        let secrets = AgentCountingSecretStore()
        // Ollama sends no key, and a cloud key may not go to this Mac.
        let ollama = try T.ollama()
        let cloudHere = AgentProviderProfile(id: .claude, endpoint: try AgentEndpoint(localPort: 8080))
        for profile in [ollama, cloudHere] {
            try secrets.save(T.secret(), for: profile.secretID)
            try await transport(profile, secrets: secrets).prepareKey()
        }
        XCTAssertEqual(secrets.presenceAsks + secrets.secretAsks, 0)
    }

    func testABodyThatHoldsTheKeyIsRefused() async throws {
        let profile = try T.claude()
        AgentStubLoader.reset { _ in Self.ok("data: one\n") }
        let plain = T.data("{\"note\":\"\(T.key)\"}")
        let outcome = await T.drain(transport(profile, secrets: try store(for: profile)).stream(.chat, body: plain))
        XCTAssertEqual(outcome.failure, .keyInBody)

        // JSON may write a slash as "\/", which still carries the key.
        let slashed = try T.other()
        let secrets = try store(with: T.keyWithSlash, for: slashed)
        let encoded = try JSONSerialization.data(withJSONObject: ["note": T.keyWithSlash])
        XCTAssertNil(encoded.range(of: T.data(T.keyWithSlash)), "the encoder escaped the slashes")
        let escaped = await T.drain(transport(slashed, secrets: secrets).stream(.chat, body: encoded))
        XCTAssertEqual(escaped.failure, .keyInBody)
        XCTAssertEqual(AgentStubLoader.seen.count, 0)

        // The same body without the key goes.
        _ = await T.drain(transport(profile, secrets: try store(for: profile)).stream(.chat, body: T.data("{\"note\":\"fine\"}")))
        XCTAssertEqual(AgentStubLoader.seen.count, 1)
    }

    // MARK: What is refused on the way back

    func testARedirectIsAnErrorAndTheSecondHostIsNeverAsked() async throws {
        let profile = try T.claude()
        let elsewhere = try XCTUnwrap(URL(string: "https://collector.example.net/v1/messages"))
        AgentStubLoader.reset { request in
            if request.url?.host == "collector.example.net" { return Self.ok("data: stolen\n") }
            return [.redirect(to: elsewhere, status: 307),
                    .respond(status: 307, headers: ["Location": elsewhere.absoluteString], from: nil), .finish]
        }
        let outcome = await T.drain(transport(profile, secrets: try store(for: profile)).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .redirected)
        XCTAssertEqual(outcome.lines, [])
        await XCTAssertThrowsTransport(.redirected) {
            _ = try await self.transport(profile, secrets: try self.store(for: profile)).fetch(.models)
        }
        XCTAssertEqual(AgentStubLoader.seen.map { $0.url.host }, ["api.anthropic.com", "api.anthropic.com"])
    }

    func testAThreeHundredStatusIsAnErrorEvenWithoutARedirect() async throws {
        AgentStubLoader.reset { _ in [.respond(status: 302, headers: [:], from: nil), .send(T.data("data: moved\n")), .finish] }
        let outcome = await T.drain(transport(try T.other()).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .redirected)
        XCTAssertEqual(outcome.lines, [])
    }

    func testAServerPasswordQuestionIsCancelled() async throws {
        AgentStubLoader.reset { _ in [.challenge(proxy: false), Self.streaming,
                                      .send(T.data("data: in\n")), .finish] }
        let outcome = await T.drain(transport(try T.other()).stream(.chat, body: T.data("{}")))
        // Cancelled: the loader is stopped, and nothing after the question is read.
        XCTAssertEqual(outcome.failure, .unreachable)
        XCTAssertEqual(outcome.lines, [])
        XCTAssertTrue(AgentStubLoader.challengeAnswers.allSatisfy { $0 == "cancel" }, "\(AgentStubLoader.challengeAnswers)")
        try await waitForStop()
    }

    func testAProxyPasswordQuestionIsCancelled() async throws {
        AgentStubLoader.reset { _ in [.challenge(proxy: true), Self.streaming,
                                      .send(T.data("data: in\n")), .finish] }
        let outcome = await T.drain(transport(try T.other()).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .proxyAuth)
        XCTAssertEqual(outcome.lines, [])
        XCTAssertTrue(AgentStubLoader.challengeAnswers.allSatisfy { $0 == "cancel" }, "\(AgentStubLoader.challengeAnswers)")
        try await waitForStop()
    }

    /// Waits until the loader has been stopped once, as a cancelled request is.
    private func waitForStop() async throws {
        for _ in 0..<250 where AgentStubLoader.stops == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(AgentStubLoader.stops, 1)
    }

    func testAReplyFromAnotherHostIsRefused() async throws {
        let other = try XCTUnwrap(URL(string: "https://elsewhere.example.org/v1/messages"))
        AgentStubLoader.reset { _ in [.respond(status: 200, headers: [:], from: other), .send(T.data("data: hi\n")), .finish] }
        let profile = try T.claude()
        let outcome = await T.drain(transport(profile, secrets: try store(for: profile)).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .wrongHost)
        XCTAssertEqual(outcome.lines, [])
        await XCTAssertThrowsTransport(.wrongHost) {
            _ = try await self.transport(profile, secrets: try self.store(for: profile)).fetch(.models)
        }
    }

    func testAStatusOutsideTwoHundredEndsAStreamWithItsBody() async throws {
        let body = "{\"error\":{\"type\":\"invalid_request_error\"}}"
        AgentStubLoader.reset { _ in [.respond(status: 400, headers: [:], from: nil), .send(T.data(body)), .finish] }
        let outcome = await T.drain(transport(try T.other()).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .http(status: 400, body: T.data(body)))
        XCTAssertEqual(outcome.lines, [])
    }

    func testAFetchAnswersWithTheStatusAndBody() async throws {
        AgentStubLoader.reset { request in
            request.url?.path == "/models"
                ? [.respond(status: 401, headers: [:], from: nil), .send(T.data("{\"error\":\"no\"}")), .finish]
                : [Self.streaming, .send(T.data("{\"models\":[]}")), .finish]
        }
        let profile = try T.other()
        let refused = try await transport(profile).fetch(.models)
        XCTAssertEqual(refused.status, 401)
        XCTAssertEqual(refused.body, T.data("{\"error\":\"no\"}"))
        let listed = try await transport(profile).fetch(.modelsAlternate)
        XCTAssertEqual(listed.status, 200)
        XCTAssertEqual(listed.body, T.data("{\"models\":[]}"))
        XCTAssertEqual(AgentStubLoader.seen.map(\.url.absoluteString),
                       ["https://models.example.com/models", "https://models.example.com/v1/models"])
    }

    func testARouteAProviderLacksSendsNothing() async throws {
        AgentStubLoader.reset { _ in Self.ok("data: one\n") }
        await XCTAssertThrowsTransport(.unreachable) { _ = try await self.transport(try T.ollama()).fetch(.modelsAlternate) }
        XCTAssertEqual(AgentStubLoader.seen.count, 0)
    }

    // MARK: Limits

    func testAStreamedReplyOverItsCapIsCut() async throws {
        // 33 chunks of 1,000,000 bytes, each 1,000 lines: past 32 MB.
        let chunk = Data((String(repeating: "x", count: 999) + "\n").utf8).repeated(1_000)
        AgentStubLoader.reset { _ in [Self.streaming, .sendRepeated(chunk, count: 33), .finish] }
        let outcome = await T.drain(transport(try T.ollama(), limits: .local).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .tooLarge)
        let handedOn = outcome.lines.reduce(0) { $0 + $1.utf8.count + 1 }
        XCTAssertLessThanOrEqual(handedOn, 32_000_000)
        XCTAssertGreaterThan(handedOn, 31_000_000)
        XCTAssertEqual(AgentStubLoader.seen.count, 1, "a reply that is too large isn't asked for again")
    }

    func testTheResponseCapIsExact() async throws {
        let limits = T.limits(response: 100)
        AgentStubLoader.reset { _ in [Self.streaming,
                                      .send(Data(repeating: UInt8(ascii: "a"), count: 99) + T.data("\n")), .finish] }
        let fits = await T.drain(transport(try T.ollama(), limits: limits).stream(.chat, body: T.data("{}")))
        XCTAssertNil(fits.failure)
        XCTAssertEqual(fits.lines.first?.count, 99)
        AgentStubLoader.reset { _ in [Self.streaming,
                                      .send(Data(repeating: UInt8(ascii: "a"), count: 100) + T.data("\n")), .finish] }
        let over = await T.drain(transport(try T.ollama(), limits: limits).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(over.failure, .tooLarge)
        XCTAssertEqual(over.lines, [])
    }

    func testALineOverItsCapIsCut() async throws {
        let cap = AgentTransportLimits.local.lineBytes
        XCTAssertEqual(cap, 4_000_000)
        let full = Data(repeating: UInt8(ascii: "b"), count: cap)
        AgentStubLoader.reset { _ in [Self.streaming, .send(full + T.data("\ndata: next\n")), .finish] }
        let fits = await T.drain(transport(try T.ollama(), limits: .local).stream(.chat, body: T.data("{}")))
        XCTAssertNil(fits.failure)
        XCTAssertEqual(fits.lines.map(\.utf8.count), [cap, 10])

        // One byte more, and no line break ever comes.
        AgentStubLoader.reset { _ in [Self.streaming, .send(T.data("data: first\n")),
                                      .send(full + T.data("b")), .pause(30), .finish] }
        let started = Date()
        let endless = await T.drain(transport(try T.ollama(), limits: .local).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(endless.failure, .tooLarge)
        XCTAssertEqual(endless.lines, ["data: first"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 25, "cut when the cap is passed, not when the reply ends")
    }

    func testAFetchedReplyOverTheListCapIsCut() async throws {
        let limits = T.limits(list: 1_000)
        AgentStubLoader.reset { _ in [Self.streaming,
                                      .send(Data(repeating: UInt8(ascii: "m"), count: 1_001)), .finish] }
        await XCTAssertThrowsTransport(.tooLarge) { _ = try await self.transport(try T.ollama(), limits: limits).fetch(.models) }
        AgentStubLoader.reset { _ in [Self.streaming,
                                      .send(Data(repeating: UInt8(ascii: "m"), count: 1_000)), .finish] }
        let fits = try await transport(try T.ollama(), limits: limits).fetch(.models)
        XCTAssertEqual(fits.body.count, 1_000)
        XCTAssertEqual(AgentTransportLimits.cloud.listBytes, 4_000_000)
    }

    func testTheIdleLimitEndsAStreamThatGoesQuiet() async throws {
        AgentStubLoader.reset { _ in [Self.streaming, .send(T.data("data: first\n")),
                                      .pause(60), .finish] }
        let started = Date()
        let outcome = await T.drain(transport(try T.ollama(), limits: T.limits(idle: 0.5)).stream(.chat, body: T.data("{}")))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome.failure, .timedOut)
        XCTAssertEqual(outcome.lines, ["data: first"])
        XCTAssertGreaterThanOrEqual(elapsed, 0.5)
        XCTAssertLessThan(elapsed, 30)
    }

    func testTheIdleLimitEndsARequestThatNeverAnswers() async throws {
        AgentStubLoader.reset { _ in [.pause(60), Self.streaming, .finish] }
        let started = Date()
        await XCTAssertThrowsTransport(.timedOut) {
            _ = try await self.transport(try T.ollama(), limits: T.limits(idle: 0.5)).fetch(.models)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    func testTheTotalLimitEndsAStreamThatNeverStops() async throws {
        var steps: [AgentStubLoader.Step] = [Self.streaming]
        for _ in 0..<600 { steps += [.pause(0.1), .send(T.data("data: more\n"))] }
        AgentStubLoader.reset { _ in steps + [.finish] }
        let started = Date()
        let outcome = await T.drain(transport(try T.ollama(), limits: T.limits(idle: 5, total: 1.5, retries: 2))
            .stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .timedOut)
        XCTAssertFalse(outcome.lines.isEmpty)
        XCTAssertLessThan(outcome.lines.count, 600)
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
        XCTAssertEqual(AgentStubLoader.seen.count, 1, "the whole request's limit is not tried again")
    }

    // MARK: Trying again

    func testAStatusThatSaysWaitIsTriedAgainAtMostTwice() async throws {
        AgentStubLoader.reset { _ in [.respond(status: 429, headers: ["Retry-After": "0"], from: nil),
                                      .send(T.data("{\"error\":{\"type\":\"rate_limit_error\"}}")), .finish] }
        let outcome = await T.drain(transport(try T.other(), limits: .cloud).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.failure, .http(status: 429, body: T.data("{\"error\":{\"type\":\"rate_limit_error\"}}")))
        XCTAssertEqual(AgentStubLoader.seen.count, 3)

        // A fetch that runs out of tries answers with the last reply.
        AgentStubLoader.reset { _ in [.respond(status: 529, headers: ["Retry-After": "0"], from: nil), .finish] }
        let reply = try await transport(try T.other(), limits: .cloud).fetch(.models)
        XCTAssertEqual(reply.status, 529)
        XCTAssertEqual(AgentStubLoader.seen.count, 3)
    }

    func testASecondTryThatWorksIsWhatTheCallerSees() async throws {
        let counter = AgentStubCounter()
        AgentStubLoader.reset { _ in
            counter.next() == 0
                ? [.respond(status: 503, headers: ["Retry-After": "0"], from: nil), .finish]
                : Self.ok("data: done\n")
        }
        let outcome = await T.drain(transport(try T.other(), limits: .cloud).stream(.chat, body: T.data("{}")))
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.lines, ["data: done"])
        XCTAssertEqual(AgentStubLoader.seen.count, 2)
    }

    func testWhatWaitingWontFixIsNotTriedAgain() async throws {
        let refusals: [(Int, [String: String], String)] = [
            (429, ["Retry-After": "0"], "{\"error\":{\"details\":{\"error_code\":\"enforced_spend_limit_reached\"}}}"),
            (429, ["Retry-After": "0"], "{\"error\":{\"type\":\"insufficient_quota\"}}"),
            (429, ["Retry-After": "60"], "{}"),
            (400, ["Retry-After": "0"], "{}"),
            (401, [:], "{}"),
            (500, ["Retry-After": "0"], "{}"),
        ]
        for (status, headers, body) in refusals {
            AgentStubLoader.reset { _ in [.respond(status: status, headers: headers, from: nil), .send(T.data(body)), .finish] }
            let outcome = await T.drain(transport(try T.other(), limits: .cloud).stream(.chat, body: T.data("{}")))
            XCTAssertEqual(outcome.failure, .http(status: status, body: T.data(body)), body)
            XCTAssertEqual(AgentStubLoader.seen.count, 1, "\(status) \(body)")
        }
    }

    func testNothingIsTriedAgainOnceALineWasHandedOn() async throws {
        // The pause lets the line arrive before the connection drops.
        AgentStubLoader.reset { _ in [Self.streaming, .send(T.data("data: half\n")), .pause(0.3),
                                      .fail(.networkConnectionLost)] }
        let outcome = await T.drain(transport(try T.other(), limits: .cloud).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(outcome.lines, ["data: half"])
        XCTAssertEqual(outcome.failure, .unreachable)
        XCTAssertEqual(AgentStubLoader.seen.count, 1)

        AgentStubLoader.reset { _ in [Self.streaming, .send(T.data("data: half\n")), .pause(60)] }
        let quiet = await T.drain(transport(try T.other(), limits: T.limits(idle: 0.4, retries: 2)).stream(.chat, body: T.data("{}")))
        XCTAssertEqual(quiet.failure, .timedOut)
        XCTAssertEqual(AgentStubLoader.seen.count, 1)
    }

    func testARequestThatHeardNothingIsTriedAgain() async throws {
        let counter = AgentStubCounter()
        AgentStubLoader.reset { _ in counter.next() == 0 ? [.pause(60)] : Self.ok("data: awake\n") }
        let outcome = await T.drain(transport(try T.ollama(), limits: T.limits(idle: 0.4, retries: 1))
            .stream(.chat, body: T.data("{}")))
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.lines, ["data: awake"])
        XCTAssertEqual(AgentStubLoader.seen.count, 2)
    }

    // MARK: Stopping

    func testShutdownEndsARequestThatIsRunning() async throws {
        AgentStubLoader.reset { _ in [Self.streaming, .send(T.data("data: first\n")), .pause(60)] }
        let transport = transport(try T.ollama())
        let stream = transport.stream(.chat, body: T.data("{}"))
        let reading = Task { await T.drain(stream) }
        for _ in 0..<500 where AgentStubLoader.seen.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(AgentStubLoader.seen.count, 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        await transport.shutdown()
        let outcome = await reading.value
        XCTAssertEqual(outcome.failure, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAReaderThatStopsCancelsTheRequest() async throws {
        AgentStubLoader.reset { _ in [Self.streaming, .send(T.data("data: first\n")), .pause(60)] }
        let transport = transport(try T.ollama())
        let started = Date()
        for try await line in transport.stream(.chat, body: T.data("{}")) {
            XCTAssertEqual(line, "data: first")
            break
        }
        // A new request still works after the reader walked away from the first.
        AgentStubLoader.reset { _ in Self.ok("data: again\n") }
        let next = await T.drain(transport.stream(.chat, body: T.data("{}")))
        XCTAssertEqual(next.lines, ["data: again"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}

/// Counts the requests a script was asked for.
final class AgentStubCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count - 1
    }
}

fileprivate extension Data {
    func repeated(_ times: Int) -> Data {
        var data = Data(capacity: count * times)
        for _ in 0..<times { data.append(self) }
        return data
    }
}

/// Fails unless `body` throws exactly `expected`.
func XCTAssertThrowsTransport(_ expected: AgentTransportError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected \(expected), and nothing was thrown", file: file, line: line)
    } catch let failure as AgentTransportError {
        XCTAssertEqual(failure, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
