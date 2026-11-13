import XCTest
@testable import HelmAgent

/// The transport's limits and its shutdown as a live session meets them: a key read while AI mode turns off, a
/// stream that arrives in small pieces, and tries that share one deadline. The stub loader stands in for the network.
final class AgentLiveTransportTests: XCTestCase {
    private typealias T = AgentTransportTesting

    override func tearDown() {
        AgentStubLoader.reset { _ in [.fail(.cannotConnectToHost)] }
        super.tearDown()
    }

    private func transport(_ profile: AgentProviderProfile, secrets: any AgentSecretStoring = MemorySecretStore(),
                           limits: AgentTransportLimits) -> HTTPTransport {
        HTTPTransport(liveProfile: profile, secrets: secrets, limits: limits, testProtocols: [AgentStubLoader.self])
    }

    private static let streaming = AgentStubLoader.Step.respond(status: 200, headers: ["Content-Type": "text/event-stream"],
                                                                from: nil)

    func testAKeyReadWhileTheTransportShutsDownIsNeverSent() async throws {
        let profile = try T.claude()
        let store = AgentHeldSecretStore()
        try store.inner.save(T.secret(), for: profile.secretID)
        AgentStubLoader.reset { _ in [.respond(status: 200, headers: ["Content-Type": "application/json"], from: nil),
                                      .send(T.data("{\"data\":[]}")), .finish] }
        let transport = transport(profile, secrets: store, limits: T.roomy)
        let request = Task { try await transport.fetch(.models) }
        // The key is being read, as while macOS asks for the keychain password, and AI mode turns off meanwhile.
        let deadline = Date().addingTimeInterval(10)
        while !store.wasAsked, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(store.wasAsked)
        await transport.shutdown()
        store.release()
        do {
            _ = try await request.value
            XCTFail("a request whose key arrived after shutdown went out")
        } catch let failure as AgentTransportError {
            XCTAssertEqual(failure, .cancelled)
        }
        XCTAssertEqual(AgentStubLoader.seen.count, 0, "nothing reached the loader")
    }

    func testAStreamOfSmallPiecesIsNotTakenForSilence() async throws {
        var steps: [AgentStubLoader.Step] = [Self.streaming]
        for _ in 0..<10 { steps += [.pause(0.2), .send(T.data("data: x\n"))] }
        AgentStubLoader.reset { _ in steps + [.finish] }
        let outcome = await T.drain(transport(try T.ollama(), limits: T.limits(idle: 0.6, retries: 0))
            .stream(.chat, body: T.data("{}")))
        XCTAssertNil(outcome.failure, "a line every 0.2 s is well inside a 0.6 s idle limit")
        XCTAssertEqual(outcome.lines.count, 10)
    }

    func testTriesShareTheWholeRequestsDeadline() async throws {
        // Silence before any line is tried again, after a second's wait. With 1.2 s for the whole request, that
        // wait would end past it, so the request ends at the first silence instead.
        AgentStubLoader.reset { _ in [Self.streaming, .pause(60), .finish] }
        let started = Date()
        let outcome = await T.drain(transport(try T.ollama(), limits: T.limits(idle: 0.4, total: 1.2, retries: 2))
            .stream(.chat, body: T.data("{}")))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome.failure, .timedOut)
        XCTAssertEqual(AgentStubLoader.seen.count, 1, "no second try that would outlast the request")
        XCTAssertLessThan(elapsed, 1.2)
    }
}

/// A key store whose key reads wait until the test lets them go, as a keychain does while macOS asks the person.
private final class AgentHeldSecretStore: AgentSecretStoring, @unchecked Sendable {
    let inner = MemorySecretStore()
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var asked = false

    var wasAsked: Bool { lock.lock(); defer { lock.unlock() }; return asked }
    func release() { gate.signal() }

    func has(_ id: AgentSecretID) -> Bool { inner.has(id) }
    func secret(for id: AgentSecretID) throws -> AgentSecret? {
        lock.lock(); asked = true; lock.unlock()
        gate.wait()
        return try inner.secret(for: id)
    }
    func save(_ secret: AgentSecret, for id: AgentSecretID) throws { try inner.save(secret, for: id) }
    func remove(_ id: AgentSecretID) throws { try inner.remove(id) }
    var isMemoryOnly: Bool { true }
}
