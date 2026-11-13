import XCTest
import HelmCore
@testable import HelmAgent

/// The pieces a real launch runs on: the shipped client factory with its limits, and a runtime made with it that
/// reaches a model only while AI mode is on. The one request here goes to a listener on 127.0.0.1 inside the test.
@MainActor final class AgentLivePartsTests: XCTestCase {
    private typealias T = AgentTransportTesting
    private var servers: [AgentLoopbackServer] = []

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        super.tearDown()
    }

    func testALocalProviderGetsTheLocalLimitsAndEveryOtherTheCloudLimits() throws {
        XCTAssertEqual(AgentLiveParts.limits(for: try T.ollama()), .local)
        XCTAssertEqual(AgentLiveParts.limits(for: try T.lmStudio()), .local)
        for profile in [try T.claude(), try T.openAI(), try T.gemini(), try T.other()] {
            XCTAssertEqual(AgentLiveParts.limits(for: profile), .cloud, "\(profile.id)")
        }
    }

    func testMakingAClientAsksTheKeyStoreNothing() async throws {
        let store = AgentCountingSecretStore()
        try store.save(T.secret(), for: try T.claude().secretID)
        let client = AgentLiveParts.makeClient(try T.claude(), "claude-opus-5-5", store)
        XCTAssertTrue(client is LiveModelClient)
        XCTAssertFalse(client.isLocal)
        XCTAssertTrue(AgentLiveParts.makeClient(try T.ollama(), "stand-in:latest", store).isLocal)
        XCTAssertEqual(store.secretAsks, 0, "the key is read when a request needs it, not when the client is made")
        XCTAssertEqual(store.presenceAsks, 0)
        await client.shutdown()
    }

    func testTheShippedWiringAsksALocalModelOnlyWhileAIModeIsOn() async throws {
        let json = "{\"models\":[{\"name\":\"stand-in:latest\"}]}"
        let server: AgentLoopbackServer
        do {
            server = try AgentLoopbackServer(replies: [.init(status: "200 OK", headers: ["Content-Type": "application/json"],
                                                             pieces: [T.data(json)])])
            servers.append(server)
        } catch {
            throw XCTSkip("Loopback test skipped: the listener couldn't start (\(error)).")
        }
        let home = "/home/helm"
        let runtime = AgentRuntime(parts: AgentRuntimeParts(
            secrets: MemorySecretStore(), disk: MemoryAgentDisk(home: home), home: home, supportFolder: home + "/.helm-support",
            clock: SystemHelmClock(), buildStamp: "", makeClient: AgentLiveParts.makeClient,
            makeSession: AgentLiveParts.makeSession))
        var config = AIConfig()
        config.provider = AgentProviderID.ollama.rawValue
        config.ports[AgentProviderID.ollama.rawValue] = server.port
        config.models[AgentProviderID.ollama.rawValue] = "stand-in:latest"
        runtime.configure(config)

        // Off: nothing is built and nothing is asked.
        let whileOff = await runtime.check(config)
        XCTAssertEqual(whileOff, .off)
        XCTAssertNil(runtime.makeSession())
        XCTAssertEqual(runtime.clientBuildCount, 0)
        XCTAssertTrue(server.requests.isEmpty)

        // On: ready at once for a local provider, and the check goes over the real transport.
        runtime.setOn(true)
        XCTAssertEqual(runtime.state, .ready(provider: "Ollama", destination: AgentText.destinationOnThisMac("Ollama"),
                                             model: "stand-in:latest", isLocal: true))
        XCTAssertEqual(runtime.clientBuildCount, 0, "nothing is built before a request needs it")
        let answer = await runtime.check(config)
        guard case .connected(let models) = answer else {
            if server.requests.isEmpty { throw XCTSkip("Loopback test skipped: couldn't connect to the listener (\(answer)).") }
            return XCTFail("\(answer)")
        }
        XCTAssertEqual(models.map(\.id), ["stand-in:latest"])
        XCTAssertEqual(server.requests.first?.requestLine, "GET /api/tags HTTP/1.1")
        XCTAssertGreaterThan(runtime.clientBuildCount, 0)
        XCTAssertNotNil(runtime.makeSession(), "the real conversation, once a model is ready")

        // Off again: no client, and the next check asks nothing.
        runtime.setOn(false)
        await runtime.settle()
        let asked = server.requests.count
        let afterOff = await runtime.check(config)
        XCTAssertEqual(afterOff, .off)
        XCTAssertEqual(server.requests.count, asked)
        if case .failure(.off) = runtime.client() {} else { XCTFail("no client while AI mode is off") }
    }
}
