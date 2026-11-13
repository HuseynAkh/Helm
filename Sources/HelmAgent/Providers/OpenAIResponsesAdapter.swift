import Foundation
import HelmCore

/// The Responses API, which OpenAI and Grok need for tool calls on their current models. A history item is one
/// input item: the person's message, each output item exactly as the model sent it (reasoning items included), and
/// a `function_call_output` for each call, keyed by its `call_id`.
///
/// Every body says `store: false`, so the provider keeps nothing, and asks for reasoning in its encrypted form so
/// that it can be sent back with the next turn. The instructions go with every request, since nothing is stored.
/// Never a sampling setting, a tool choice or an effort.
public struct OpenAIResponsesAdapter: AgentWireAdapter {
    public init() {}

    public func turnBody(_ input: AgentTurnInput, model: String) throws -> Data {
        try AgentWireParts.check(model: model)
        var body = Self.common(model: model, instructions: input.system)
        body["input"] = .array(input.history)
        body["stream"] = .bool(true)
        if !input.tools.isEmpty { body["tools"] = .array(input.tools.map(Self.tool)) }
        return AgentJSON.object(body).data()
    }

    public func structuredBody(_ ask: AgentStructuredAsk, model: String) throws -> Data {
        try AgentWireParts.check(model: model)
        var body = Self.common(model: model, instructions: ask.system)
        body["input"] = .array([.object(["role": .string("user"), "content": .string(ask.user)])])
        body["text"] = .object(["format": .object(["type": .string("json_schema"), "name": .string(ask.schemaName),
                                                   "schema": ask.schema, "strict": .bool(true)])])
        return AgentJSON.object(body).data()
    }

    public func structuredAnswer(from body: Data) throws -> Data {
        guard let reply = try? AgentJSON(data: body), case .object = reply else { throw AgentFailure.unreadable }
        if let error = reply["error"], error != .null { throw AgentErrorMapper.failure(streamError: reply) }
        guard reply["status"]?.stringValue ?? "completed" == "completed" else { throw AgentFailure.unreadable }
        var text = ""
        for item in reply["output"]?.arrayValue ?? [] where item["type"]?.stringValue == "message" {
            for part in item["content"]?.arrayValue ?? [] {
                switch part["type"]?.stringValue {
                case "output_text": text += part["text"]?.stringValue ?? ""
                case "refusal": throw AgentFailure.unreadable
                default: break
                }
            }
        }
        if text.isEmpty { text = reply["output_text"]?.stringValue ?? "" }
        guard let answer = AgentWireParts.firstObject(in: text) else { throw AgentFailure.unreadable }
        return answer.data()
    }

    public func makeReader() -> any AgentStreamReading { Reader() }

    /// The results first, each as a `function_call_output` keyed by its call's `call_id`, then the person's text.
    /// The wire has no error flag; a result that is an error says so in its own JSON.
    public func userItems(text: String?, toolResults: [AgentToolResult]) -> [AgentJSON] {
        var items: [AgentJSON] = toolResults.map { result in
            .object(["type": .string("function_call_output"), "call_id": .string(result.callID),
                     "output": .string(result.json)])
        }
        if let text, !text.isEmpty { items.append(.object(["role": .string("user"), "content": .string(text)])) }
        return items
    }

    public func failure(status: Int, body: Data) -> AgentFailure {
        AgentErrorMapper.failure(status: status, body: body, provider: .openAI)
    }

    /// What every request carries.
    private static func common(model: String, instructions: String) -> [String: AgentJSON] {
        var body: [String: AgentJSON] = [
            "model": .string(model),
            "store": .bool(false),
            "include": .array([.string("reasoning.encrypted_content")]),
            "max_output_tokens": .number(Double(AgentWireParts.maxOutputTokens))
        ]
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }
        return body
    }

    private static func tool(_ spec: AgentToolSpec) -> AgentJSON {
        .object(["type": .string("function"), "name": .string(spec.name), "description": .string(spec.description),
                 "parameters": spec.schema, "strict": .bool(true)])
    }

    // MARK: Reading a stream

    /// Keeps each output item from its `output_item.done` event, never from the earlier `added` one, whose
    /// reasoning may not be complete. Argument fragments are not needed: the finished item holds them all, which is
    /// also all a provider that sends a call whole gives.
    final class Reader: AgentStreamReading {
        private enum Ending {
            case completed(output: [AgentJSON])
            case incomplete(reason: String?)
            case failed(AgentFailure)
        }

        /// The most output items one response may hold.
        private static let mostItems = 1_024

        private var items: [Int: AgentJSON] = [:]
        private var announced: Set<String> = []
        private var refused = false
        private var ending: Ending?
        private var broken = false

        func feed(_ line: String) -> [AgentModelEvent] {
            guard ending == nil, !broken else { return [] }
            switch AgentWireParts.line(line) {
            case .nothing, .done: return []
            case .unreadable:
                broken = true
                return []
            case .json(let event): return take(event)
            }
        }

        func finish() -> AgentTurnResult {
            guard !broken, let ending else { return AgentTurnResult(rawItems: [], calls: [], stop: .failed(.unreadable)) }
            switch ending {
            case .failed(let failure):
                return AgentTurnResult(rawItems: [], calls: [], stop: .failed(failure))
            case .incomplete(let reason):
                return AgentTurnResult(rawItems: [], calls: [], stop: reason == "content_filter" ? .contentFilter : .maxTokens)
            case .completed(let output):
                let kept = items.isEmpty ? output : items.keys.sorted().compactMap { items[$0] }
                if refused || kept.contains(where: Self.holdsRefusal) {
                    return AgentTurnResult(rawItems: [], calls: [], stop: .refusal)
                }
                let calls = kept.filter { $0["type"]?.stringValue == "function_call" }.map { item in
                    AgentToolCall(id: item["call_id"]?.stringValue ?? "", name: item["name"]?.stringValue ?? "",
                                  arguments: Data((item["arguments"]?.stringValue ?? "").utf8))
                }
                return AgentTurnResult(rawItems: kept, calls: calls, stop: calls.isEmpty ? .endTurn : .toolUse)
            }
        }

        private func take(_ event: AgentJSON) -> [AgentModelEvent] {
            switch event["type"]?.stringValue {
            case "response.output_text.delta":
                guard let text = AgentWireParts.nonEmpty(event["delta"]) else { return [] }
                return [.text(text)]
            case "response.output_item.added":
                return announce(event["item"])
            case "response.output_item.done":
                guard let item = event["item"], case .object = item else { return [] }
                let index = AgentWireParts.integer(event["output_index"]) ?? (items.keys.max() ?? -1) + 1
                guard (0..<Self.mostItems).contains(index) else { return [] }
                items[index] = item
                return announce(item)
            case "response.refusal.delta", "response.refusal.done":
                refused = true
                return []
            case "response.completed":
                ending = Self.ending(of: event["response"])
                return []
            case "response.incomplete":
                ending = .incomplete(reason: event["response"]?["incomplete_details"]?["reason"]?.stringValue)
                return []
            case "response.failed":
                ending = .failed(AgentErrorMapper.failure(streamError: event["response"] ?? event))
                return []
            case "error":
                ending = .failed(AgentErrorMapper.failure(streamError: event))
                return []
            default:
                // response.created, in_progress, argument fragments, and any event a later version adds.
                return []
            }
        }

        /// A completed response, unless its own status says otherwise.
        private static func ending(of response: AgentJSON?) -> Ending {
            switch response?["status"]?.stringValue {
            case "incomplete": return .incomplete(reason: response?["incomplete_details"]?["reason"]?.stringValue)
            case "failed", "cancelled": return .failed(AgentErrorMapper.failure(streamError: response ?? .null))
            default: return .completed(output: response?["output"]?.arrayValue ?? [])
            }
        }

        /// The first word that a call has started, once for each call.
        private func announce(_ item: AgentJSON?) -> [AgentModelEvent] {
            guard let item, item["type"]?.stringValue == "function_call" else { return [] }
            let key = item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? ""
            guard announced.insert(key).inserted else { return [] }
            return [.toolStarted(name: item["name"]?.stringValue ?? "")]
        }

        private static func holdsRefusal(_ item: AgentJSON) -> Bool {
            guard item["type"]?.stringValue == "message" else { return false }
            return (item["content"]?.arrayValue ?? []).contains { $0["type"]?.stringValue == "refusal" }
        }
    }
}
