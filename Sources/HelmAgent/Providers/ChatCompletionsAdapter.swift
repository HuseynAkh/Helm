import Foundation
import HelmCore

/// The Chat Completions shape that Gemini's compatible endpoint, Ollama, LM Studio and most other servers share.
/// A history item is one message. The system prompt is not part of the history: it goes first in every request.
///
/// A model's message is sent back as it came, with every field Helm doesn't know about kept, on the message and on
/// each call: Gemini's thought signature rides on a call, and other servers keep their reasoning on the message.
/// A message with calls has `content: null`, since Gemini refuses one with text. A body holds the model, the
/// messages, the tools and `stream`, and a token ceiling only for a hosted endpoint; never a sampling setting, a
/// tool choice, an effort or stream options, which one server or another refuses.
public struct ChatCompletionsAdapter: AgentWireAdapter {
    private let sendsMaxTokens: Bool

    /// `sendsMaxTokens` is true for a hosted endpoint. A server on this Mac decides for itself.
    public init(sendsMaxTokens: Bool) {
        self.sendsMaxTokens = sendsMaxTokens
    }

    public func turnBody(_ input: AgentTurnInput, model: String) throws -> Data {
        try AgentWireParts.check(model: model)
        var body = common(model: model, system: input.system, messages: input.history)
        body["stream"] = .bool(true)
        if !input.tools.isEmpty { body["tools"] = .array(input.tools.map(Self.tool)) }
        return AgentJSON.object(body).data()
    }

    public func structuredBody(_ ask: AgentStructuredAsk, model: String) throws -> Data {
        try AgentWireParts.check(model: model)
        var body = common(model: model, system: ask.system,
                          messages: [.object(["role": .string("user"), "content": .string(ask.user)])])
        body["response_format"] = .object([
            "type": .string("json_schema"),
            "json_schema": .object(["name": .string(ask.schemaName), "schema": ask.schema, "strict": .bool(true)])
        ])
        return AgentJSON.object(body).data()
    }

    public func structuredAnswer(from body: Data) throws -> Data {
        guard let reply = try? AgentJSON(data: body), case .object = reply else { throw AgentFailure.unreadable }
        if let error = reply["error"], error != .null { throw AgentErrorMapper.failure(streamError: reply) }
        guard let message = reply["choices"]?.arrayValue?.first?["message"] else { throw AgentFailure.unreadable }
        if AgentWireParts.nonEmpty(message["refusal"]) != nil { throw AgentFailure.unreadable }
        let text: String
        if let parts = message["content"]?.arrayValue {
            text = parts.compactMap { $0["text"]?.stringValue }.joined()
        } else {
            text = message["content"]?.stringValue ?? ""
        }
        guard let answer = AgentWireParts.firstObject(in: text) else { throw AgentFailure.unreadable }
        return answer.data()
    }

    public func makeReader() -> any AgentStreamReading { Reader() }

    /// One `tool` message for each result, in the order of the calls, then the person's text.
    public func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] {
        var items: [AgentJSON] = toolResults.map { result in
            .object(["role": .string("tool"), "tool_call_id": .string(result.callID), "content": .string(result.json)])
        }
        if let text, !text.isEmpty { items.append(.object(["role": .string("user"), "content": .string(text)])) }
        return items
    }

    public func failure(status: Int, body: Data) -> AgentFailure {
        // This wire serves several providers, so the answer must not depend on which one sent it.
        AgentErrorMapper.failure(status: status, body: body)
    }

    private func common(model: String, system: String, messages: [AgentJSON]) -> [String: AgentJSON] {
        var all: [AgentJSON] = []
        if !system.isEmpty { all.append(.object(["role": .string("system"), "content": .string(system)])) }
        all += messages
        var body: [String: AgentJSON] = ["model": .string(model), "messages": .array(all)]
        // `max_tokens` is the field every one of these servers takes; the newer name isn't known to all of them.
        if sendsMaxTokens { body["max_tokens"] = .number(Double(AgentWireParts.maxTokens)) }
        return body
    }

    private static func tool(_ spec: AgentToolSpec) -> AgentJSON {
        .object(["type": .string("function"),
                 "function": .object(["name": .string(spec.name), "description": .string(spec.description),
                                      "parameters": spec.schema])])
    }

    // MARK: Reading a stream

    /// Gathers one message from its chunks. Calls are gathered by their index: an id and a name come once and the
    /// arguments in fragments, or a whole call comes in one chunk, or several do. Whether the model asked for tools
    /// is decided from the calls gathered, since some servers end a turn with calls as an ordinary stop.
    final class Reader: AgentStreamReading {
        private struct Call {
            var id = ""
            var type: String?
            var name = ""
            var arguments = ""
            /// Fields of the call Helm doesn't read, such as Gemini's `extra_content`, sent back as they came.
            var extra: [String: AgentJSON] = [:]
            /// The same, inside the call's `function`.
            var functionExtra: [String: AgentJSON] = [:]
        }

        /// The most calls one message may hold.
        private static let mostCalls = 256
        private static let messageFields: Set<String> = ["role", "content", "refusal", "tool_calls"]
        private static let callFields: Set<String> = ["index", "id", "type", "function"]
        private static let functionFields: Set<String> = ["name", "arguments"]

        private var text = ""
        private var calls: [Int: Call] = [:]
        /// Fields of the message Helm doesn't read, such as a server's reasoning, sent back as they came.
        private var extra: [String: AgentJSON] = [:]
        private var refused = false
        private var finishReason: String?
        private var failure: AgentFailure?
        private var sawDone = false
        private var broken = false

        func feed(_ line: String) -> [AgentModelEvent] {
            guard !sawDone, failure == nil, !broken else { return [] }
            switch AgentWireParts.line(line) {
            case .nothing: return []
            case .done:
                sawDone = true
                return []
            case .unreadable:
                broken = true
                return []
            case .json(let chunk): return take(chunk)
            }
        }

        func finish() -> AgentTurnResult {
            if let failure { return AgentTurnResult(rawItems: [], calls: [], stop: .failed(failure)) }
            // A stream that stopped before saying how it ended was cut off.
            guard !broken, finishReason != nil || sawDone else {
                return AgentTurnResult(rawItems: [], calls: [], stop: .failed(.unreadable))
            }
            if refused { return AgentTurnResult(rawItems: [], calls: [], stop: .refusal) }
            switch finishReason {
            case "length": return AgentTurnResult(rawItems: [], calls: [], stop: .maxTokens)
            case "content_filter": return AgentTurnResult(rawItems: [], calls: [], stop: .contentFilter)
            case "error": return AgentTurnResult(rawItems: [], calls: [], stop: .failed(.overloaded))
            default: break
            }
            let gathered = calls.keys.sorted().compactMap { calls[$0] }
            var message = extra
            message["role"] = .string("assistant")
            message["content"] = gathered.isEmpty ? .string(text) : .null
            var toolCalls: [AgentToolCall] = []
            if !gathered.isEmpty {
                message["tool_calls"] = .array(gathered.map { call in
                    var function = call.functionExtra
                    function["name"] = .string(call.name)
                    function["arguments"] = .string(Self.arguments(call))
                    var item = call.extra
                    item["id"] = .string(call.id)
                    item["type"] = .string(call.type ?? "function")
                    item["function"] = .object(function)
                    return .object(item)
                })
                toolCalls = gathered.map { AgentToolCall(id: $0.id, name: $0.name, arguments: Data(Self.arguments($0).utf8)) }
            }
            return AgentTurnResult(rawItems: [.object(message)], calls: toolCalls, stop: toolCalls.isEmpty ? .endTurn : .toolUse)
        }

        private static func arguments(_ call: Call) -> String { call.arguments.isEmpty ? "{}" : call.arguments }

        private func take(_ chunk: AgentJSON) -> [AgentModelEvent] {
            if let error = chunk["error"], error != .null {
                failure = AgentErrorMapper.failure(streamError: chunk)
                return []
            }
            // A server that ignored `stream` answers with whole `message` objects instead of `delta` ones.
            guard let choice = (chunk["choices"]?.arrayValue ?? []).first(where: { AgentWireParts.integer($0["index"]) ?? 0 == 0 })
            else { return [] }
            if let reason = choice["finish_reason"]?.stringValue { finishReason = reason }
            guard let delta = choice["delta"] ?? choice["message"], let fields = delta.objectValue else { return [] }
            var events: [AgentModelEvent] = []
            if let piece = AgentWireParts.nonEmpty(fields["content"]) {
                text += piece
                events.append(.text(piece))
            }
            if AgentWireParts.nonEmpty(fields["refusal"]) != nil { refused = true }
            for (position, entry) in (fields["tool_calls"]?.arrayValue ?? []).enumerated() {
                events += gather(entry, position: position)
            }
            for (key, value) in fields where !Self.messageFields.contains(key) && value != .null {
                extra[key] = Self.merged(extra[key], value)
            }
            return events
        }

        /// Adds one entry of a chunk's `tool_calls` to the call it belongs to.
        private func gather(_ entry: AgentJSON, position: Int) -> [AgentModelEvent] {
            guard let fields = entry.objectValue else { return [] }
            let id = AgentWireParts.nonEmpty(fields["id"])
            var slot: Int
            if let index = AgentWireParts.integer(fields["index"]) {
                slot = index
                // Two whole calls sent under one index are two calls. A server that repeats each call's id on every
                // piece under that one index sends the later pieces to the call that already holds the id.
                if let id, let held = calls[slot], !held.id.isEmpty, held.id != id {
                    slot = calls.first(where: { $0.value.id == id })?.key ?? (calls.keys.max() ?? -1) + 1
                }
            } else if let id {
                slot = calls.first(where: { $0.value.id == id })?.key ?? (calls.keys.max() ?? -1) + 1
            } else {
                slot = calls.keys.max() ?? position
            }
            guard (0..<Self.mostCalls).contains(slot) else { return [] }
            var call = calls[slot] ?? Call()
            let wasNamed = !call.name.isEmpty
            if let id, call.id.isEmpty { call.id = id }
            if let type = AgentWireParts.nonEmpty(fields["type"]) { call.type = type }
            if let function = fields["function"]?.objectValue {
                if let name = AgentWireParts.nonEmpty(function["name"]), call.name.isEmpty { call.name = name }
                switch function["arguments"] {
                case .string(let piece)?: call.arguments += piece
                // A server that sends the arguments as an object sends them whole.
                case .object(let members)?: call.arguments = String(decoding: AgentJSON.object(members).data(), as: UTF8.self)
                default: break
                }
                for (key, value) in function where !Self.functionFields.contains(key) && value != .null {
                    call.functionExtra[key] = Self.merged(call.functionExtra[key], value)
                }
            }
            for (key, value) in fields where !Self.callFields.contains(key) && value != .null {
                call.extra[key] = Self.merged(call.extra[key], value)
            }
            calls[slot] = call
            return !wasNamed && !call.name.isEmpty ? [.toolStarted(name: call.name)] : []
        }

        /// A field that arrives in pieces: text is joined, lists are added to, and anything else is the newest.
        private static func merged(_ held: AgentJSON?, _ piece: AgentJSON) -> AgentJSON {
            switch (held, piece) {
            case (.string(let first)?, .string(let more)): return .string(first + more)
            case (.array(let first)?, .array(let more)): return .array(first + more)
            default: return piece
            }
        }
    }
}
