import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmAgent

/// A validator that turns any proposal into a plan, or answers what it is told, and records what it was asked.
final class AgentLoopFakeValidator: AgentPlanValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var verdicts: [AgentPlanVerdict] = []
    private var rechecks: [AgentRecheck] = []
    private var proposals: [AgentProposedChanges] = []
    private var recheckCount = 0

    /// The next answers to `validate`, in order. With none left, every proposal becomes a fresh plan.
    func answer(_ verdicts: AgentPlanVerdict...) { locked { self.verdicts += verdicts } }
    /// The next answers to `recheck`, in order. With none left, a recheck answers `.ok`.
    func recheckAnswers(_ answers: AgentRecheck...) { locked { rechecks += answers } }
    var proposed: [AgentProposedChanges] { locked { proposals } }
    var rechecked: Int { locked { recheckCount } }

    func validate(_ proposal: AgentProposedChanges, scope: any AgentHandleResolving, disk: any AgentDisk,
                  limits: AgentLimits) async -> AgentPlanVerdict {
        locked {
            proposals.append(proposal)
            return verdicts.isEmpty ? .plan(Self.plan()) : verdicts.removeFirst()
        }
    }

    func recheck(_ plan: AgentChangePlan, ticked: Set<Int>, scope: any AgentHandleResolving, disk: any AgentDisk) async -> AgentRecheck {
        locked {
            recheckCount += 1
            return rechecks.isEmpty ? .ok : rechecks.removeFirst()
        }
    }

    /// A plan of two groups: an ordinary one and one guarded by the Trash.
    static func plan(leftOut: [AgentToolCode: Int] = [:]) -> AgentChangePlan {
        AgentChangePlan(title: .move(2), steps: [], groups: [AgentPlanGroup(id: 1, kind: .renames, steps: []),
                                                            AgentPlanGroup(id: 2, kind: .trash, steps: [], guardedBy: .trash)],
                        notices: [], leftOut: leftOut)
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A model that starts a turn and never ends it, until the request is cancelled.
final class AgentLoopHangingClient: AgentModelClient, @unchecked Sendable {
    let providerName = "Claude", destination = "Claude", isLocal = false
    private let lock = NSLock()
    private var started = 0
    var turnsStarted: Int { lock.lock(); defer { lock.unlock() }; return started }

    func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error> {
        lock.lock(); started += 1; lock.unlock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                continuation.finish(throwing: AgentFailure.cancelled)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] {
        ScriptedModelClient().userItems(text: text, toolResults: toolResults)
    }
    func structured(_ ask: AgentStructuredAsk) async throws -> Data { throw AgentFailure.unreadable }
    func models() async throws -> [AgentModelInfo] { [] }
}

/// A scripted model whose every turn moves a clock on, so a request can run out of time.
final class AgentLoopSlowClient: AgentModelClient, @unchecked Sendable {
    let inner: ScriptedModelClient
    let clock: FakeClock
    let seconds: TimeInterval
    init(inner: ScriptedModelClient, clock: FakeClock, seconds: TimeInterval) {
        self.inner = inner; self.clock = clock; self.seconds = seconds
    }
    var providerName: String { inner.providerName }
    var destination: String { inner.destination }
    var isLocal: Bool { inner.isLocal }
    func turn(_ input: AgentTurnInput) -> AsyncThrowingStream<AgentModelEvent, Error> {
        clock.advance(by: seconds)
        return inner.turn(input)
    }
    func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] { inner.userItems(text: text, toolResults: toolResults) }
    func structured(_ ask: AgentStructuredAsk) async throws -> Data { try await inner.structured(ask) }
    func models() async throws -> [AgentModelInfo] { try await inner.models() }
}

enum AgentLoopKit {
    static let support = "/home/helm-support"

    /// A scripted client loaded from script JSON.
    static func client(_ json: String, isLocal: Bool = false) -> ScriptedModelClient {
        let client = ScriptedModelClient(isLocal: isLocal)
        do { try client.load(Data(json.utf8)) } catch { XCTFail("the script doesn't load: \(error)") }
        return client
    }

    static func parts(_ client: any AgentModelClient, disk: MemoryAgentDisk, home: String, clock: FakeClock = FakeClock(),
                      listSeconds: Double? = nil) -> AgentSessionParts {
        AgentSessionParts(client: { .success(client) }, disk: disk, home: home, supportFolder: support, clock: clock,
                          listSecondsOverride: { listSeconds })
    }

    /// Every event of one request.
    static func events(_ session: AgentSession, _ text: String, selected: [String] = []) async -> [AgentSessionEvent] {
        var events: [AgentSessionEvent] = []
        for await event in session.send(AgentPersonInput(typedByPerson: text, selectedPaths: selected)) { events.append(event) }
        return events
    }

    /// Events as short words, for comparing.
    static func words(_ events: [AgentSessionEvent]) -> [String] {
        events.map { event in
            switch event {
            case .status(let status): return "status \(status)"
            case .trace(let trace): return "trace \(trace)"
            case .reply(let text): return "reply \(text)"
            case .plan: return "plan"
            case .notice(let notice): return "notice \(notice)"
            case .failed(let failure): return "failed \(failure.rawValue)"
            case .finished: return "finished"
            }
        }
    }

    static func plans(_ events: [AgentSessionEvent]) -> [AgentChangePlan] {
        events.compactMap { if case .plan(let plan) = $0 { return plan } else { return nil } }
    }

    /// The tool results a model was sent in one turn's history item, as parsed JSON, by call id.
    static func results(in item: AgentJSON) -> [(id: String, json: AgentJSON)] {
        guard case .object(let members) = item, case .array(let results)? = members["results"] else { return [] }
        return results.compactMap { result in
            guard case .object(let fields) = result, case .string(let id)? = fields["id"], case .string(let text)? = fields["json"],
                  let json = try? AgentJSON(data: Data(text.utf8)) else { return nil }
            return (id, json)
        }
    }

    /// A member of a JSON object, or nil.
    static func member(_ json: AgentJSON?, _ key: String) -> AgentJSON? {
        guard case .object(let members)? = json else { return nil }
        return members[key]
    }

    static func string(_ json: AgentJSON?, _ key: String) -> String? {
        if case .string(let value)? = member(json, key) { return value }
        return nil
    }

    static func number(_ json: AgentJSON?, _ key: String) -> Double? {
        if case .number(let value)? = member(json, key) { return value }
        return nil
    }

    static func array(_ json: AgentJSON?, _ key: String) -> [AgentJSON] {
        if case .array(let values)? = member(json, key) { return values }
        return []
    }

    static func text(of item: AgentJSON) -> String? {
        string(item, "text")
    }
}

// MARK: Assertions that take a value already awaited

/// XCTest's assertions take their values as autoclosures, which can't wait. These take the values themselves, so
/// a call can be awaited right in the argument.
func agentEqual<Value: Equatable>(_ value: Value, _ expected: Value, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(value, expected, message, file: file, line: line)
}

func agentTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value, message, file: file, line: line)
}

func agentFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(value, message, file: file, line: line)
}

func agentNil<Value>(_ value: Value?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(value, message, file: file, line: line)
}

func agentNotNil<Value>(_ value: Value?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNotNil(value, message, file: file, line: line)
}
