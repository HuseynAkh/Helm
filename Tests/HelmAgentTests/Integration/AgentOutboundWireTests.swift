import XCTest
import HelmCore
@testable import HelmAgent

/// What leaves the app, byte for byte, on each of the three wires. A whole request (folders listed, a plan
/// proposed and checked), the next request that carries the plan's held result, and an AI search's plan question
/// run through the real conversation and `LiveModelClient` into a transport that records every body and answers as
/// the provider would. The home's last component is a marker word, and the folders include a cloud folder whose
/// path holds an account and a server share; none of that, and no key, may be in anything sent.
final class AgentOutboundWireTests: XCTestCase {
    private static let home = "/home/zebramarker"
    private static let account = "me@example.com"
    private static let serverHost = "stand-in"
    private static let testKey = "test-key-outbound-wire-0001"
    private var cloud: String { Self.home + "/Library/CloudStorage/GoogleDrive-" + Self.account }

    func testAnthropicMessagesSendsNoPathAccountHostOrKey() async throws {
        try await checkOutbound(.claude, structured: "anthropic/structured-reply.json")
    }

    func testOpenAIResponsesSendsNoPathAccountHostOrKey() async throws {
        try await checkOutbound(.openAI, structured: "responses/structured-reply.json")
    }

    func testChatCompletionsSendsNoPathAccountHostOrKey() async throws {
        try await checkOutbound(.gemini, structured: "chat/structured-reply.json")
    }

    // MARK: The flows

    private func checkOutbound(_ provider: AgentProviderID, structured: String) async throws {
        let profile = AgentProviderProfile(id: provider, endpoint: try AgentEndpoint(fixed: provider))
        let secrets = MemorySecretStore()
        try secrets.save(try XCTUnwrap(AgentSecret(pasted: Self.testKey)), for: profile.secretID)
        let disk = makeDisk()
        let structuredLines = try ProviderFixtures.lines(structured)
        let transport = AgentOutboundRecorder { body, index in
            Self.answer(profile.wire, request: index, body: body, structured: structuredLines)
        }
        let client = LiveModelClient(profile: profile, model: ProviderFixtures.model, transport: transport)
        let parts = AgentSessionParts(client: { .success(client) }, disk: disk, home: Self.home,
                                      supportFolder: Self.home + "/Library/Application Support/Helm", clock: SystemHelmClock())
        let session = AgentSession(parts: parts, validator: AgentPlanValidator())

        // The home on show, the provider's own folder and a server share added beside it.
        guard case .root = await session.setTabFolder(AgentRootInput(fromPerson: Self.home, origin: .tab)) else {
            return XCTFail("the home is a root")
        }
        for added in [cloud, "/Volumes/share"] {
            guard case .added = await session.folder(for: AgentRootInput(fromPerson: added, origin: .typed)) else {
                return XCTFail("\(added) is added")
            }
        }
        let roots = await session.roots()
        XCTAssertEqual(roots.map(\.modelName), ["Home", "Google Drive", "Server"])

        // An organize that lists every folder and proposes one move into a new folder, with a selected item.
        var plan: AgentChangePlan?
        var failures: [AgentFailure] = []
        let organize = AgentPersonInput(typedByPerson: "Organize the items in \(roots[0].alias) into folders by kind. Depth: 2 levels.",
                                        selectedPaths: [Self.home + "/AgentMess/memo.txt"])
        for await event in session.send(organize) {
            if case .plan(let proposed) = event { plan = proposed }
            if case .failed(let failure) = event { failures.append(failure) }
        }
        XCTAssertEqual(failures, [], "\(provider)")
        let checked = try XCTUnwrap(plan, "the plan came back through the validator (\(provider))")
        XCTAssertEqual(checked.counts(ticked: checked.defaultTicked).line, "1 move · 1 new folder")

        // The next message carries the held result first, with the plan still pending.
        var reply = ""
        for await event in session.send(AgentPersonInput(typedByPerson: "hello", selectedPaths: [])) {
            if case .reply(let text) = event { reply += text }
        }
        XCTAssertEqual(reply, "Done.", "\(provider)")

        // An AI search's plan question, which offers no tools.
        _ = try? await AISearchSession(client: client).plan(request: "invoices from march", scopeLabel: "Home",
                                                            today: Date(timeIntervalSince1970: 1_780_000_000), languageCode: "en")

        let bodies = transport.recorded
        XCTAssertEqual(bodies.count, 4, "three model turns and one search question (\(provider))")
        let all = bodies.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(all[1].contains("photo-1.png"), "names do go out, inside tool results (\(provider))")
        XCTAssertTrue(all[2].contains("pending"), "the held result went out first (\(provider))")
        for (index, text) in all.enumerated() {
            for word in [Self.home, "zebramarker", Self.account, Self.serverHost, Self.testKey, "/Volumes", "/AgentMess"] {
                XCTAssertFalse(text.contains(word), "body \(index) on \(provider) holds \(word)")
            }
            // JSON may write a slash escaped.
            XCTAssertFalse(text.contains(Self.home.replacingOccurrences(of: "/", with: "\\/")), "body \(index) on \(provider)")
        }
    }

    /// The home folder with a messy folder in it, Google Drive's folder for the account, and a share on a server.
    private func makeDisk() -> MemoryAgentDisk {
        let disk = MemoryAgentDisk(home: Self.home)
        for name in ["photo-1.png", "memo.txt"] { disk.addFile(Self.home + "/AgentMess/" + name) }
        disk.addFile(cloud + "/Shared/plan.txt")
        disk.addFile("/Volumes/share/notes.txt")
        disk.setProbe(StorageProbe(isLocal: false, volumeRoot: "/Volumes/share"), under: "/Volumes/share")
        return disk
    }

    // MARK: The provider's side

    /// What the provider answers to each request: the first turn lists every root, the second proposes a move of
    /// photo-1.png into a new Images folder, the third says "Done.", and the search question gets its fixed reply.
    private static func answer(_ wire: AgentWire, request: Int, body: Data, structured: [String]) -> [String] {
        let text = String(decoding: body, as: UTF8.self)
        switch request {
        case 0:
            let aliases = Self.aliases(in: text)
            let calls = aliases.enumerated().map { index, alias in
                OutboundCall(id: "call_0_\(index)", name: "list_folder",
                             arguments: json(["folder": alias, "depth": 2, "after": ""]))
            }
            return lines(wire, text: "Looking.", calls: calls, turn: request)
        case 1:
            let photo = id(ofItemNamed: "photo-1.png", in: body) ?? "missing"
            let root = aliases(in: text).first ?? "missing"
            let arguments = json(["new_folders": [["key": "n1", "parent": root, "name": "Images"]],
                                  "moves": [["items": [photo], "all_in": "", "to": "n1"]],
                                  "copies": [] as [Any], "renames": [] as [Any], "trash": [] as [Any]])
            return lines(wire, text: "One folder.", calls: [OutboundCall(id: "call_1_0", name: "propose_changes", arguments: arguments)],
                         turn: request)
        case 2:
            return lines(wire, text: "Done.", calls: [], turn: request)
        default:
            return structured
        }
    }

    private struct OutboundCall {
        let id: String, name: String, arguments: String
    }

    /// One model turn as the wire streams it: words, then tool calls.
    private static func lines(_ wire: AgentWire, text: String, calls: [OutboundCall], turn: Int) -> [String] {
        switch wire {
        case .anthropicMessages:
            var out = event("message_start", ["type": "message_start", "message": ["id": "msg_\(turn)", "type": "message",
                                                                                   "role": "assistant", "content": [] as [Any]]])
            out += event("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
            out += event("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]])
            out += event("content_block_stop", ["type": "content_block_stop", "index": 0])
            for (offset, call) in calls.enumerated() {
                let index = offset + 1
                out += event("content_block_start", ["type": "content_block_start", "index": index,
                                                     "content_block": ["type": "tool_use", "id": call.id, "name": call.name,
                                                                       "input": [:] as [String: Any]]])
                out += event("content_block_delta", ["type": "content_block_delta", "index": index,
                                                     "delta": ["type": "input_json_delta", "partial_json": call.arguments]])
                out += event("content_block_stop", ["type": "content_block_stop", "index": index])
            }
            out += event("message_delta", ["type": "message_delta", "delta": ["stop_reason": calls.isEmpty ? "end_turn" : "tool_use"]])
            out += event("message_stop", ["type": "message_stop"])
            return out
        case .openAIResponses:
            var out = ["data: " + json(["type": "response.created", "response": ["id": "resp_\(turn)", "status": "in_progress",
                                                                                "output": [] as [Any]]]), ""]
            out += ["data: " + json(["type": "response.output_text.delta", "output_index": 0, "delta": text]), ""]
            out += ["data: " + json(["type": "response.output_item.done", "output_index": 0,
                                     "item": ["type": "message", "id": "msg_\(turn)", "role": "assistant", "status": "completed",
                                              "content": [["type": "output_text", "text": text]]]]), ""]
            for (offset, call) in calls.enumerated() {
                out += ["data: " + json(["type": "response.output_item.done", "output_index": offset + 1,
                                         "item": ["type": "function_call", "id": "fc_\(call.id)", "call_id": call.id,
                                                  "name": call.name, "arguments": call.arguments, "status": "completed"]]), ""]
            }
            out += ["data: " + json(["type": "response.completed", "response": ["id": "resp_\(turn)", "status": "completed",
                                                                                "output": [] as [Any]]]), "", "data: [DONE]"]
            return out
        case .chatCompletions:
            func chunk(_ delta: [String: Any], finish: String?) -> [String] {
                ["data: " + json(["id": "chatcmpl-\(turn)", "object": "chat.completion.chunk",
                                  "choices": [["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull()]]]), ""]
            }
            var out = chunk(["role": "assistant", "content": text], finish: nil)
            for (index, call) in calls.enumerated() {
                out += chunk(["tool_calls": [["index": index, "id": call.id, "type": "function",
                                              "function": ["name": call.name, "arguments": call.arguments]]]], finish: nil)
            }
            out += chunk([:], finish: calls.isEmpty ? "stop" : "tool_calls")
            return out + ["data: [DONE]"]
        }
    }

    private static func event(_ name: String, _ data: [String: Any]) -> [String] {
        ["event: " + name, "data: " + json(data), ""]
    }

    private static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The roots' aliases, in the order Helm's note about the folders names them.
    private static func aliases(in text: String) -> [String] {
        guard let note = text.range(of: "Folders: ") else { return [] }
        let rest = text[note.upperBound...]
        let end = rest.firstIndex(of: ".") ?? rest.endIndex
        return rest[..<end].components(separatedBy: "; ").compactMap { $0.split(separator: " ").first.map(String.init) }
    }

    /// The id a tool result gave the item with this name, looked for in every string of the body, a tool result's
    /// own JSON included.
    private static func id(ofItemNamed name: String, in body: Data) -> String? {
        guard let top = try? JSONSerialization.jsonObject(with: body) else { return nil }
        return search(top, for: name)
    }

    private static func search(_ value: Any, for name: String) -> String? {
        if let object = value as? [String: Any] {
            if object["name"] as? String == name, let id = object["id"] as? String { return id }
            for key in object.keys.sorted() {
                if let member = object[key], let found = search(member, for: name) { return found }
            }
        } else if let array = value as? [Any] {
            for element in array { if let found = search(element, for: name) { return found } }
        } else if let text = value as? String, text.hasPrefix("{"),
                  let inner = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            return search(inner, for: name)
        }
        return nil
    }
}

/// A transport that records every body it is handed and answers from a function of the request. It makes no
/// connection.
final class AgentOutboundRecorder: AgentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    private let answer: @Sendable (Data, Int) -> [String]

    init(answer: @escaping @Sendable (Data, Int) -> [String]) { self.answer = answer }

    var recorded: [Data] { lock.withLock { bodies } }

    func stream(_ route: AgentRoute, body: Data) -> AsyncThrowingStream<String, Error> {
        let index = lock.withLock { () -> Int in
            bodies.append(body)
            return bodies.count - 1
        }
        let lines = answer(body, index)
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    func fetch(_ route: AgentRoute) async throws -> AgentHTTPReply { throw AgentTransportError.unreachable }

    func shutdown() async {}
}
