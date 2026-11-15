import XCTest
import HelmCore
@testable import HelmAgent

/// The fixed files under `Fixtures/Providers` and the pieces every provider test shares: a small tool, a system
/// prompt, a way to play a recorded stream through a reader, and a transport that records what it is sent.
enum ProviderFixtures {
    static let system = "You are Helm's file assistant. Work only in the listed roots."
    static let model = "test-model-1"

    /// A tool with a schema of its own, so a body fixture doesn't change when the real catalog does.
    static let tool = AgentToolSpec(
        name: "list_folder",
        description: "List what is in a folder.",
        schema: .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "required": .array([.string("folder"), .string("depth"), .string("after")]),
            "properties": .object([
                "folder": .object(["type": .string("string"), "description": .string("A root or folder id.")]),
                "depth": .object(["type": .string("integer")]),
                "after": .object(["type": .string("string")])
            ])
        ]))

    static let ask = AgentStructuredAsk(
        system: "Plan a search.", user: "invoices from march", schemaName: "search_plan",
        schema: .object(["type": .string("object"), "additionalProperties": .bool(false),
                         "required": .array([.string("sort")]),
                         "properties": .object(["sort": .object(["type": .string("string")])])]))

    /// The person's first message as Helm sends it, with the note about the folders before it.
    static let message = "[Helm] Folders: r1 this_mac (on show).\nOrganize this folder"

    static func url(_ name: String) throws -> URL {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return base.appendingPathComponent("Providers").appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func json(_ name: String) throws -> AgentJSON { try AgentJSON(data: data(name)) }

    /// A recorded stream, one element per line, as the transport hands lines on.
    static func lines(_ name: String) throws -> [String] {
        var lines = String(decoding: try data(name), as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func object(_ text: String) -> AgentJSON {
        (try? AgentJSON(data: Data(text.utf8))) ?? .null
    }

    /// Every line through a fresh reader, then its result.
    static func play(_ adapter: any AgentWireAdapter, _ lines: [String]) -> (texts: [String], tools: [String], result: AgentTurnResult) {
        let reader = adapter.makeReader()
        var texts: [String] = [], tools: [String] = []
        for line in lines {
            for event in reader.feed(line) {
                switch event {
                case .text(let text): texts.append(text)
                case .toolStarted(let name): tools.append(name)
                case .finished: XCTFail("a reader finishes only when asked")
                }
            }
        }
        return (texts, tools, reader.finish())
    }

    static func play(_ adapter: any AgentWireAdapter, fixture name: String) throws -> (texts: [String], tools: [String], result: AgentTurnResult) {
        play(adapter, try lines(name))
    }

    /// Every key of every object in a value, at any depth.
    static func keys(in value: AgentJSON) -> Set<String> {
        switch value {
        case .object(let members): return members.reduce(into: Set(members.keys)) { $0.formUnion(keys(in: $1.value)) }
        case .array(let values): return values.reduce(into: Set<String>()) { $0.formUnion(keys(in: $1)) }
        case .null, .bool, .number, .string: return []
        }
    }

    /// Keys that a body must never hold outside its history, at any depth: sampling settings, a tool choice, an
    /// effort, a thinking setting, stream options and a fallback. (The history is the provider's own items, where
    /// a thinking block is called `thinking`.)
    static let forbiddenKeys: Set<String> = ["temperature", "top_p", "top_k", "tool_choice", "effort", "reasoning_effort",
                                             "budget_tokens", "thinking", "stream_options", "reasoning", "parallel_tool_calls",
                                             "frequency_penalty", "presence_penalty", "fallbacks", "seed"]

    static func assertNothingForbidden(_ body: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        guard case .object(var members) = try AgentJSON(data: body) else { return XCTFail("not an object", file: file, line: line) }
        members["messages"] = nil
        members["input"] = nil
        let found = keys(in: .object(members)).intersection(forbiddenKeys)
        XCTAssertEqual(found, [], "a body holds a setting Helm never sends", file: file, line: line)
    }

    static func assertSameBytes(_ body: Data, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try data(name)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), String(decoding: expected, as: UTF8.self),
                       "the body differs from \(name)", file: file, line: line)
    }
}

/// A transport that answers from a list and records every request. It makes no connection.
final class ProviderRecordingTransport: AgentTransport, @unchecked Sendable {
    struct Sent {
        let route: AgentRoute
        let body: Data
        var json: AgentJSON { (try? AgentJSON(data: body)) ?? .null }
    }

    private let lock = NSLock()
    private var streamReplies: [Result<[String], AgentTransportError>]
    private var fetchReplies: [AgentRoute: Result<AgentHTTPReply, AgentTransportError>]
    private var sentRequests: [Sent] = []
    private var fetchedRoutes: [AgentRoute] = []
    private var shutDowns = 0

    init(streams: [Result<[String], AgentTransportError>] = [],
         fetches: [AgentRoute: Result<AgentHTTPReply, AgentTransportError>] = [:]) {
        streamReplies = streams; fetchReplies = fetches
    }

    var sent: [Sent] { locked { sentRequests } }
    var fetched: [AgentRoute] { locked { fetchedRoutes } }
    var shutDownCount: Int { locked { shutDowns } }

    func stream(_ route: AgentRoute, body: Data) -> AsyncThrowingStream<String, Error> {
        let reply = locked { () -> Result<[String], AgentTransportError> in
            sentRequests.append(Sent(route: route, body: body))
            return streamReplies.isEmpty ? .failure(.unreachable) : streamReplies.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch reply {
            case .success(let lines):
                for line in lines { continuation.yield(line) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    func fetch(_ route: AgentRoute) async throws -> AgentHTTPReply {
        let reply = locked { () -> Result<AgentHTTPReply, AgentTransportError> in
            fetchedRoutes.append(route)
            return fetchReplies[route] ?? .failure(.unreachable)
        }
        return try reply.get()
    }

    func shutdown() async { locked { shutDowns += 1 } }

    private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
