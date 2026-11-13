import Foundation
import HelmCore

/// Claude's Messages API. A history item is one message, `{"role": …, "content": [blocks]}`. A model turn is kept
/// as the exact blocks it streamed, thinking blocks and their signatures included, because Claude refuses a
/// thinking block that was changed.
///
/// A body holds the model, `max_tokens`, `stream`, the system prompt at the top, the messages, the tools (each
/// `strict`) and an automatic cache mark. Never a sampling setting, a `thinking` setting, a tool choice or an
/// effort: current models refuse some of them, and the person's model runs as it is.
public struct AnthropicMessagesAdapter: AgentWireAdapter {
    public init() {}

    public func turnBody(_ input: AgentTurnInput, model: String) throws -> Data {
        try AgentWireParts.check(model: model)
        var body: [String: AgentJSON] = [
            "model": .string(model),
            "max_tokens": .number(Double(AgentWireParts.maxTokens)),
            "stream": .bool(true),
            "messages": .array(input.history),
            "cache_control": .object(["type": .string("ephemeral")])
        ]
        if !input.system.isEmpty { body["system"] = .string(input.system) }
        if !input.tools.isEmpty { body["tools"] = .array(input.tools.map(Self.tool)) }
        return AgentJSON.object(body).data()
    }

    public func structuredBody(_ ask: AgentStructuredAsk, model: String) throws -> Data {
        try AgentWireParts.check(model: model)
        var body: [String: AgentJSON] = [
            "model": .string(model),
            "max_tokens": .number(Double(AgentWireParts.maxTokens)),
            "messages": .array([.object(["role": .string("user"), "content": .string(ask.user)])]),
            "output_config": .object(["format": .object(["type": .string("json_schema"), "schema": ask.schema])])
        ]
        if !ask.system.isEmpty { body["system"] = .string(ask.system) }
        return AgentJSON.object(body).data()
    }

    public func structuredAnswer(from body: Data) throws -> Data {
        guard let reply = try? AgentJSON(data: body), case .object = reply else { throw AgentFailure.unreadable }
        if reply["type"]?.stringValue == "error" { throw AgentErrorMapper.failure(streamError: reply) }
        // A refusal or a cut-off answer may not have the shape it was asked for.
        guard reply["stop_reason"]?.stringValue != "refusal", reply["stop_reason"]?.stringValue != "max_tokens" else {
            throw AgentFailure.unreadable
        }
        let text = (reply["content"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
        guard let answer = AgentWireParts.firstObject(in: text) else { throw AgentFailure.unreadable }
        return answer.data()
    }

    public func makeReader() -> any AgentStreamReading { Reader() }

    /// The results first, each as a `tool_result` block, then the person's text. All of them in one message, which
    /// is what Claude asks for after a turn with several calls.
    public func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] {
        var content: [AgentJSON] = toolResults.map { result in
            var block: [String: AgentJSON] = ["type": .string("tool_result"), "tool_use_id": .string(result.callID),
                                              "content": .string(result.json)]
            if result.isError { block["is_error"] = .bool(true) }
            return .object(block)
        }
        // Claude refuses an empty text block.
        if let text, !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])) }
        guard !content.isEmpty else { return [] }
        return [.object(["role": .string("user"), "content": .array(content)])]
    }

    public func failure(status: Int, body: Data) -> AgentFailure {
        AgentErrorMapper.failure(status: status, body: body, provider: .claude)
    }

    private static func tool(_ spec: AgentToolSpec) -> AgentJSON {
        .object(["name": .string(spec.name), "description": .string(spec.description), "input_schema": spec.schema,
                 "strict": .bool(true)])
    }

    // MARK: Reading a stream

    /// Puts the blocks of one streamed message back together by their index. Text is shown as it comes; a tool's
    /// input is gathered from its fragments and taken apart only when the message is over.
    final class Reader: AgentStreamReading {
        private struct Block {
            var start: [String: AgentJSON]
            var text = ""
            var thinking = ""
            var signature = ""
            var input = ""
        }

        /// The most blocks one message may hold.
        private static let mostBlocks = 1_024

        private var blocks: [Int: Block] = [:]
        private var stopReason: String?
        private var failure: AgentFailure?
        private var broken = false
        private var ended = false

        func feed(_ line: String) -> [AgentModelEvent] {
            guard !ended, failure == nil, !broken else { return [] }
            switch AgentWireParts.line(line) {
            case .nothing, .done: return []
            case .unreadable:
                broken = true
                return []
            case .json(let event): return take(event)
            }
        }

        func finish() -> AgentTurnResult {
            if let failure { return AgentTurnResult(rawItems: [], calls: [], stop: .failed(failure)) }
            guard !broken, let stopReason else { return AgentTurnResult(rawItems: [], calls: [], stop: .failed(.unreadable)) }
            switch stopReason {
            case "refusal": return AgentTurnResult(rawItems: [], calls: [], stop: .refusal)
            case "max_tokens", "model_context_window_exceeded": return AgentTurnResult(rawItems: [], calls: [], stop: .maxTokens)
            default: break
            }
            var content: [AgentJSON] = [], calls: [AgentToolCall] = []
            for index in blocks.keys.sorted() {
                guard let block = blocks[index] else { continue }
                let (item, call) = Self.finished(block)
                content.append(item)
                if let call { calls.append(call) }
            }
            // Claude refuses an empty assistant message, so a turn that said nothing leaves nothing in the history.
            let items: [AgentJSON] = content.isEmpty ? [] : [.object(["role": .string("assistant"), "content": .array(content)])]
            return AgentTurnResult(rawItems: items, calls: calls, stop: calls.isEmpty ? .endTurn : .toolUse)
        }

        private func take(_ event: AgentJSON) -> [AgentModelEvent] {
            switch event["type"]?.stringValue {
            case "content_block_start":
                guard let index = AgentWireParts.integer(event["index"]), (0..<Self.mostBlocks).contains(index),
                      let start = event["content_block"]?.objectValue else { return [] }
                var block = Block(start: start)
                block.text = start["text"]?.stringValue ?? ""
                block.thinking = start["thinking"]?.stringValue ?? ""
                block.signature = start["signature"]?.stringValue ?? ""
                blocks[index] = block
                switch start["type"]?.stringValue {
                case "text": return block.text.isEmpty ? [] : [.text(block.text)]
                case "tool_use": return [.toolStarted(name: start["name"]?.stringValue ?? "")]
                default: return []
                }
            case "content_block_delta":
                guard let index = AgentWireParts.integer(event["index"]), blocks[index] != nil,
                      let delta = event["delta"] else { return [] }
                switch delta["type"]?.stringValue {
                case "text_delta":
                    let text = delta["text"]?.stringValue ?? ""
                    blocks[index]?.text += text
                    return text.isEmpty ? [] : [.text(text)]
                case "input_json_delta": blocks[index]?.input += delta["partial_json"]?.stringValue ?? ""
                case "thinking_delta": blocks[index]?.thinking += delta["thinking"]?.stringValue ?? ""
                case "signature_delta": blocks[index]?.signature += delta["signature"]?.stringValue ?? ""
                default: break
                }
                return []
            case "message_delta":
                if let reason = event["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
                return []
            case "message_stop":
                ended = true
                return []
            case "error":
                failure = AgentErrorMapper.failure(streamError: event)
                return []
            default:
                // message_start, content_block_stop, ping, and any event a later API version adds.
                return []
            }
        }

        /// A block as it goes back into the history, and the call it makes when it is a tool's.
        private static func finished(_ block: Block) -> (AgentJSON, AgentToolCall?) {
            var item = block.start
            switch item["type"]?.stringValue {
            case "text":
                item["text"] = .string(block.text)
                return (.object(item), nil)
            case "thinking":
                item["thinking"] = .string(block.thinking)
                item["signature"] = .string(block.signature)
                return (.object(item), nil)
            case "tool_use":
                // The input as the model wrote it goes to the tool, which refuses what isn't its shape. The history
                // must hold an object, so input that isn't one is kept there as an empty object.
                let arguments: Data
                if block.input.isEmpty {
                    arguments = (item["input"] ?? .object([:])).data()
                } else {
                    arguments = Data(block.input.utf8)
                    let parsed = try? AgentJSON(data: arguments)
                    if case .object = parsed { item["input"] = parsed } else { item["input"] = .object([:]) }
                }
                let call = AgentToolCall(id: item["id"]?.stringValue ?? "", name: item["name"]?.stringValue ?? "",
                                         arguments: arguments)
                return (.object(item), call)
            default:
                // A redacted thinking block arrives whole; a block type Helm doesn't know goes back as it came.
                return (.object(item), nil)
            }
        }
    }
}
